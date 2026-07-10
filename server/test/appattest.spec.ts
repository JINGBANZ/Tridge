import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import {
  issueAttestChallenge,
  registerDevice,
  verifyScanAssertion,
  withinDeviceQuota,
} from "../src/appattest";
import fixtures from "./fixtures/appattest.json";

// In-memory stand-in for the DEVICE_KV binding. The cast is test-only
// scaffolding — production KV comes from the wrangler binding.
function fakeKV(): KVNamespace {
  const store = new Map<string, string>();
  return {
    async get(key: string) {
      return store.has(key) ? store.get(key)! : null;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
    async delete(key: string) {
      store.delete(key);
    },
  } as unknown as KVNamespace;
}

// overrides is a loose record: generated var types are narrow literal unions
// (e.g. DEVICE_DAILY_QUOTA is "30" | "50"), but tests set arbitrary values.
function makeEnv(kv: KVNamespace, overrides: Record<string, unknown> = {}): Env {
  return {
    OPENAI_API_KEY: "sk-test",
    APPLE_TEAM_ID: fixtures.teamIdentifier,
    APPLE_BUNDLE_ID: fixtures.bundleIdentifier,
    APP_ATTEST_ALLOW_DEV: "true",
    DEVICE_DAILY_QUOTA: "50",
    DEVICE_KV: kv,
    SCAN_RATE_LIMIT: { limit: vi.fn(async () => ({ success: true })) },
    ...overrides,
    // App Attest env intentionally sets a different bundle/team than the app's
    // real ids so the known-good library fixtures verify.
  } as unknown as Env;
}

function jsonRequest(path: string, body: unknown): Request {
  return new Request(`https://scan.example${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

const dev = fixtures.developmentAttestation;
const assertion = fixtures.assertion;
const payloadBytes = new TextEncoder().encode(assertion.payload);

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("attest challenge", () => {
  it("issues a challenge and stores it one-time in KV", async () => {
    const kv = fakeKV();
    const response = await issueAttestChallenge(makeEnv(kv));
    const { challenge } = (await response.json()) as { challenge: string };
    expect(challenge).toMatch(/^[A-Za-z0-9+/]+=*$/);
    expect(await kv.get(`challenge:${challenge}`)).toBe("1");
  });
});

describe("device registration (attestation)", () => {
  it("verifies a development attestation and stores the device key", async () => {
    const kv = fakeKV();
    await kv.put(`challenge:${dev.challenge}`, "1");
    const response = await registerDevice(
      jsonRequest("/v1/attest", { keyId: dev.keyId, attestation: dev.attestation, challenge: dev.challenge }),
      makeEnv(kv),
    );
    expect(response.status).toBe(200);
    const record = JSON.parse((await kv.get(`device:${dev.keyId}`))!);
    expect(record.signCount).toBe(0);
    expect(record.environment).toBe("development");
    expect(record.publicKey).toContain("BEGIN PUBLIC KEY");
  });

  it("consumes the challenge so it can't be replayed", async () => {
    const kv = fakeKV();
    await kv.put(`challenge:${dev.challenge}`, "1");
    const body = { keyId: dev.keyId, attestation: dev.attestation, challenge: dev.challenge };
    expect((await registerDevice(jsonRequest("/v1/attest", body), makeEnv(kv))).status).toBe(200);
    expect((await registerDevice(jsonRequest("/v1/attest", body), makeEnv(kv))).status).toBe(401);
  });

  it("401s an unknown or expired challenge", async () => {
    const kv = fakeKV();
    const body = { keyId: dev.keyId, attestation: dev.attestation, challenge: dev.challenge };
    expect((await registerDevice(jsonRequest("/v1/attest", body), makeEnv(kv))).status).toBe(401);
  });

  it("401s a tampered attestation", async () => {
    const kv = fakeKV();
    await kv.put(`challenge:${dev.challenge}`, "1");
    const response = await registerDevice(
      jsonRequest("/v1/attest", { keyId: dev.keyId, attestation: "bm90LWFuLWF0dGVzdGF0aW9u", challenge: dev.challenge }),
      makeEnv(kv),
    );
    expect(response.status).toBe(401);
  });

  it("400s a body missing required fields", async () => {
    const kv = fakeKV();
    expect((await registerDevice(jsonRequest("/v1/attest", { keyId: dev.keyId }), makeEnv(kv))).status).toBe(400);
  });

  it("rejects a development attestation when APP_ATTEST_ALLOW_DEV is off", async () => {
    const kv = fakeKV();
    await kv.put(`challenge:${dev.challenge}`, "1");
    const response = await registerDevice(
      jsonRequest("/v1/attest", { keyId: dev.keyId, attestation: dev.attestation, challenge: dev.challenge }),
      makeEnv(kv, { APP_ATTEST_ALLOW_DEV: "false" }),
    );
    expect(response.status).toBe(401);
  });
});

describe("scan assertion", () => {
  function seedDevice(kv: KVNamespace, keyId: string, signCount = 0): Promise<void> {
    return kv.put(`device:${keyId}`, JSON.stringify({ publicKey: assertion.publicKey, signCount, environment: "development" }));
  }

  function scanAssertionRequest(keyId: string): Request {
    return new Request("https://scan.example/v1/receipt-scan", {
      method: "POST",
      headers: { "content-type": "image/jpeg", "x-attest-key-id": keyId, "x-attest-assertion": assertion.assertion },
      body: payloadBytes,
    });
  }

  it("verifies a valid assertion and advances the sign counter", async () => {
    const kv = fakeKV();
    await seedDevice(kv, "device-1");
    const result = await verifyScanAssertion(scanAssertionRequest("device-1"), makeEnv(kv), payloadBytes);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.keyId).toBe("device-1");
    expect(JSON.parse((await kv.get("device:device-1"))!).signCount).toBe(1);
  });

  it("rejects a replayed assertion (sign counter must strictly increase)", async () => {
    const kv = fakeKV();
    await seedDevice(kv, "device-1", 1); // already advanced past this assertion's counter
    const result = await verifyScanAssertion(scanAssertionRequest("device-1"), makeEnv(kv), payloadBytes);
    expect(result.ok).toBe(false);
  });

  it("rejects an assertion over a different image", async () => {
    const kv = fakeKV();
    await seedDevice(kv, "device-1");
    const otherImage = new TextEncoder().encode("a different receipt");
    const result = await verifyScanAssertion(scanAssertionRequest("device-1"), makeEnv(kv), otherImage);
    expect(result.ok).toBe(false);
  });

  it("401s missing headers and unregistered devices", async () => {
    const kv = fakeKV();
    const noHeaders = new Request("https://scan.example/v1/receipt-scan", { method: "POST", body: payloadBytes });
    expect((await verifyScanAssertion(noHeaders, makeEnv(kv), payloadBytes)).ok).toBe(false);
    expect((await verifyScanAssertion(scanAssertionRequest("ghost"), makeEnv(kv), payloadBytes)).ok).toBe(false);
  });
});

describe("per-device quota", () => {
  it("allows up to the daily limit, then blocks", async () => {
    const kv = fakeKV();
    const env = makeEnv(kv, { DEVICE_DAILY_QUOTA: "2" });
    expect(await withinDeviceQuota(env, "d")).toBe(true);
    expect(await withinDeviceQuota(env, "d")).toBe(true);
    expect(await withinDeviceQuota(env, "d")).toBe(false);
  });
});

describe("scan handler with App Attest", () => {
  const RECEIPT_JSON = '{"items":[{"id":"milk","name":"Whole Milk","receipt_text":"WHL MLK","quantity":1,"shelf_life_days":7}]}';
  const openAIReply = { status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: RECEIPT_JSON }] }] };

  function scanRequest(keyId: string, ip = "203.0.113.7"): Request {
    const headers = new Headers({ "content-type": "image/jpeg", "x-attest-key-id": keyId, "x-attest-assertion": assertion.assertion });
    headers.set("cf-connecting-ip", ip);
    return new Request("https://scan.example/v1/receipt-scan", { method: "POST", headers, body: payloadBytes });
  }

  let kv: KVNamespace;
  beforeEach(async () => {
    kv = fakeKV();
    await kv.put(`device:phone`, JSON.stringify({ publicKey: assertion.publicKey, signCount: 0, environment: "development" }));
  });

  it("scans end-to-end via App Attest", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(openAIReply)));
    vi.stubGlobal("fetch", fetchMock);
    const response = await worker.fetch(scanRequest("phone") as Parameters<typeof worker.fetch>[0], makeEnv(kv));
    expect(response.status).toBe(200);
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(JSON.parse(init.body as string).store).toBe(true);
  });

  it("401s a scan with no attestation and no token configured", async () => {
    const bare = new Request("https://scan.example/v1/receipt-scan", {
      method: "POST",
      headers: { "content-type": "image/jpeg", "cf-connecting-ip": "203.0.113.9" },
      body: payloadBytes,
    });
    const response = await worker.fetch(bare as Parameters<typeof worker.fetch>[0], makeEnv(kv));
    expect(response.status).toBe(401);
  });

  it("429s once the device's daily quota is spent", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(openAIReply))));
    await kv.put(`quota:phone:${new Date().toISOString().slice(0, 10)}`, "50");
    const response = await worker.fetch(scanRequest("phone") as Parameters<typeof worker.fetch>[0], makeEnv(kv));
    expect(response.status).toBe(429);
  });

  it("404s the attest endpoints when App Attest is not configured", async () => {
    const tokenEnv = { OPENAI_API_KEY: "sk", SCAN_API_TOKEN: "t", SCAN_RATE_LIMIT: { limit: vi.fn(async () => ({ success: true })) } } as unknown as Env;
    const response = await worker.fetch(
      new Request("https://scan.example/v1/attest/challenge", { method: "POST" }) as Parameters<typeof worker.fetch>[0],
      tokenEnv,
    );
    expect(response.status).toBe(404);
  });
});
