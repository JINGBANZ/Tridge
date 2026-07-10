import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";

const TOKEN = "test-app-token";
const RECEIPT_JSON = '{"items":[{"id":"milk","name":"Whole Milk","receipt_text":"WHL MLK","quantity":1,"shelf_life_days":7}]}';

function openAIReply(text: string) {
  return {
    status: "completed",
    output: [
      { type: "reasoning" },
      { type: "message", content: [{ type: "output_text", text }] },
    ],
  };
}

function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    OPENAI_API_KEY: "sk-test",
    SCAN_API_TOKEN: TOKEN,
    SCAN_RATE_LIMIT: { limit: vi.fn(async () => ({ success: true })) },
    ...overrides,
  } as Env;
}

function makeRequest({
  path = "/v1/receipt-scan",
  method = "POST",
  token = TOKEN as string | null,
  contentType = "image/jpeg",
  body = new Uint8Array([0xff, 0xd8, 0xff]) as BodyInit | null,
  ip = "203.0.113.7",
} = {}): Request {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  if (contentType) headers.set("content-type", contentType);
  headers.set("cf-connecting-ip", ip);
  return new Request(`https://scan.example${path}`, { method, headers, body: method === "POST" ? body : null });
}

async function run(request: Request, env: Env) {
  // The runtime type equals the standard Request; only the cf-properties generic differs.
  const response = await worker.fetch(request as Parameters<typeof worker.fetch>[0], env);
  return { response, body: (await response.json()) as any };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("request validation", () => {
  it("404s unknown paths and 405s non-POST", async () => {
    const env = makeEnv();
    expect((await run(makeRequest({ path: "/nope" }), env)).response.status).toBe(404);
    expect((await run(makeRequest({ method: "GET", body: null }), env)).response.status).toBe(405);
  });

  it("401s a missing or wrong bearer token", async () => {
    const env = makeEnv();
    expect((await run(makeRequest({ token: null }), env)).response.status).toBe(401);
    expect((await run(makeRequest({ token: "wrong" }), env)).response.status).toBe(401);
  });

  it("415s a non-JPEG content type", async () => {
    expect((await run(makeRequest({ contentType: "image/png" }), makeEnv())).response.status).toBe(415);
  });

  it("413s an oversized body and 400s an empty one", async () => {
    const big = new Uint8Array(8 * 1024 * 1024 + 1);
    expect((await run(makeRequest({ body: big }), makeEnv())).response.status).toBe(413);
    expect((await run(makeRequest({ body: new Uint8Array(0) }), makeEnv())).response.status).toBe(400);
  });

  it("429s with Retry-After when the rate limiter says no", async () => {
    const limiter = { limit: vi.fn(async () => ({ success: false })) };
    const { response } = await run(makeRequest({ ip: "198.51.100.9" }), makeEnv({ SCAN_RATE_LIMIT: limiter }));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(limiter.limit).toHaveBeenCalledWith({ key: "198.51.100.9" });
  });

  it("rate-limits before auth so tokens can't be brute-forced faster", async () => {
    const limiter = { limit: vi.fn(async () => ({ success: false })) };
    const { response } = await run(makeRequest({ token: "wrong" }), makeEnv({ SCAN_RATE_LIMIT: limiter }));
    expect(response.status).toBe(429);
  });
});

describe("scan proxying", () => {
  it("returns the parsed receipt and forwards our key + store:true", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(openAIReply(RECEIPT_JSON))));
    vi.stubGlobal("fetch", fetchMock);

    const { response, body } = await run(makeRequest(), makeEnv());
    expect(response.status).toBe(200);
    expect(body.items).toHaveLength(1);
    expect(body.items[0].id).toBe("milk");

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://api.openai.com/v1/responses");
    expect((init.headers as Record<string, string>).authorization).toBe("Bearer sk-test");
    const sent = JSON.parse(init.body as string);
    expect(sent.store).toBe(true);
    expect(sent.input[0].content[0].image_url).toMatch(/^data:image\/jpeg;base64,/);
  });

  it("retries once on an unparseable reply, then succeeds", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(openAIReply("not json at all"))))
      .mockResolvedValueOnce(new Response(JSON.stringify(openAIReply(RECEIPT_JSON))));
    vi.stubGlobal("fetch", fetchMock);

    const { response } = await run(makeRequest(), makeEnv());
    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("422s when both attempts are unparseable (incl. refusals)", async () => {
    const refusal = {
      output: [{ type: "message", content: [{ type: "refusal", refusal: "cannot help" }] }],
    };
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(refusal)));
    vi.stubGlobal("fetch", fetchMock);

    const { response } = await run(makeRequest(), makeEnv());
    expect(response.status).toBe(422);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("502s an upstream HTTP error without retrying (mirrors the app)", async () => {
    const fetchMock = vi.fn(async () => new Response("quota", { status: 429 }));
    vi.stubGlobal("fetch", fetchMock);

    const { response, body } = await run(makeRequest(), makeEnv());
    expect(response.status).toBe(502);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(body)).not.toContain("quota"); // upstream bodies never leak
  });

  it("502s network failures", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("connect timeout"); }));
    expect((await run(makeRequest(), makeEnv())).response.status).toBe(502);
  });
});
