// The receipt-scan API: POST /v1/receipt-scan with a raw image/jpeg body and
// the app bearer token; responds with the ParsedReceipt JSON the app's
// ReceiptResponseParser already accepts. Protection layers (test env):
// per-IP rate limit → bearer token (timing-safe) → content-type → size cap.
import {
  buildOpenAIRequest,
  extractJSONText,
  extractOutputText,
  OPENAI_ENDPOINT,
  RefusalError,
} from "./contract";

const SCAN_PATH = "/v1/receipt-scan";
// The app compresses receipts to ≲1 MB (max edge 1568 px); 8 MB is headroom,
// not a target. Also enforced before buffering via Content-Length.
const MAX_BODY_BYTES = 8 * 1024 * 1024;

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await handleScan(request, env);
    } catch (error) {
      // Explicit catch-all: never leak stacks or upstream bodies to callers.
      log("unhandled_error", { message: error instanceof Error ? error.message : String(error) });
      return jsonError(500, "Internal error. Please try again.");
    }
  },
} satisfies ExportedHandler<Env>;

async function handleScan(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== SCAN_PATH) return jsonError(404, "Not found.");
  if (request.method !== "POST") return jsonError(405, "Use POST.");

  // Rate limit first (keyed by client IP) so a leaked or brute-forced token
  // can't be hammered faster than the limit either.
  const clientIP = request.headers.get("cf-connecting-ip") ?? "unknown";
  const { success } = await env.SCAN_RATE_LIMIT.limit({ key: clientIP });
  if (!success) {
    log("rate_limited", {});
    return jsonError(429, "Too many scans. Wait a minute and try again.", { "retry-after": "60" });
  }

  if (!(await authorized(request, env))) return jsonError(401, "Missing or invalid app token.");

  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("image/jpeg")) {
    return jsonError(415, "Send the receipt as a raw image/jpeg body.");
  }
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) return jsonError(413, "Receipt image must be 8 MB or less.");
  const imageBytes = new Uint8Array(await request.arrayBuffer());
  if (imageBytes.byteLength === 0) return jsonError(400, "Empty body — send the receipt JPEG.");
  if (imageBytes.byteLength > MAX_BODY_BYTES) return jsonError(413, "Receipt image must be 8 MB or less.");

  const requestBody = buildOpenAIRequest(base64Encode(imageBytes), env.STORE_RESPONSES === "true");

  // Upstream HTTP errors fail immediately; an unparseable reply gets exactly
  // one retry.
  const first = await requestReceipt(env.OPENAI_API_KEY, requestBody);
  if (first.kind === "ok") return jsonResponse(first.receipt);
  if (first.kind === "http_error") return jsonError(502, "The parsing service is unavailable. Please try again.");
  const second = await requestReceipt(env.OPENAI_API_KEY, requestBody);
  if (second.kind === "ok") return jsonResponse(second.receipt);
  if (second.kind === "http_error") return jsonError(502, "The parsing service is unavailable. Please try again.");
  return jsonError(422, "Couldn't make sense of that receipt. Try scanning it again.");
}

type ScanResult =
  | { kind: "ok"; receipt: unknown }
  | { kind: "http_error"; status: number }
  | { kind: "unparseable" };

async function requestReceipt(apiKey: string, body: unknown): Promise<ScanResult> {
  let response: Response;
  try {
    response = await fetch(OPENAI_ENDPOINT, {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (error) {
    log("openai_network_error", { message: error instanceof Error ? error.message : String(error) });
    return { kind: "http_error", status: 0 };
  }
  if (!response.ok) {
    // The error body names the exact cause (bad param, quota, model); log a
    // prefix for debugging, never echo it to the caller.
    const errorBody = (await response.text()).slice(0, 400);
    log("openai_http_error", { status: response.status, body: errorBody });
    return { kind: "http_error", status: response.status };
  }
  const decoded: unknown = await response.json();
  try {
    const text = extractOutputText(decoded);
    const receipt: unknown = JSON.parse(extractJSONText(text));
    if (typeof receipt !== "object" || receipt === null || !Array.isArray((receipt as { items?: unknown }).items)) {
      log("unparseable", { reason: "not a receipt object" });
      return { kind: "unparseable" };
    }
    log("parsed", { items: (receipt as { items: unknown[] }).items.length });
    return { kind: "ok", receipt };
  } catch (error) {
    log("unparseable", {
      reason: error instanceof RefusalError ? "refusal" : "bad reply text",
      message: error instanceof Error ? error.message.slice(0, 200) : String(error),
    });
    return { kind: "unparseable" };
  }
}

async function authorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  if (token === "" || !env.SCAN_API_TOKEN) return false;
  return timingSafeEqualStrings(token, env.SCAN_API_TOKEN);
}

/** Constant-time comparison via fixed-length digests (no length leak). */
async function timingSafeEqualStrings(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [digestA, digestB] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  // Workers ships a non-standard timingSafeEqual; the Node test runtime doesn't.
  const subtle = crypto.subtle as SubtleCrypto & {
    timingSafeEqual?: (x: ArrayBuffer, y: ArrayBuffer) => boolean;
  };
  if (subtle.timingSafeEqual) return subtle.timingSafeEqual(digestA, digestB);
  const bytesA = new Uint8Array(digestA);
  const bytesB = new Uint8Array(digestB);
  let difference = 0;
  for (let i = 0; i < bytesA.length; i++) difference |= bytesA[i] ^ bytesB[i];
  return difference === 0;
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000; // avoid per-call argument limits on large images
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
  });
}

function jsonError(status: number, message: string, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}

/** Structured JSON logs — queryable in Workers Logs; never includes images or keys. */
function log(event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, ...fields }));
}
