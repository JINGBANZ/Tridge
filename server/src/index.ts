// The receipt-scan API: POST /v1/receipt-scan with a raw image/jpeg body;
// responds with the ParsedReceipt JSON the app's ReceiptResponseParser accepts.
// Protection layers, in order: per-IP rate limit → client auth → input
// validation → sanitized errors → structured logs.
//
// Client auth has two postures behind the same endpoint:
//   • App Attest (production) — per-scan assertion + per-device quota. Active
//     wherever the DEVICE_KV binding and app identity are configured.
//   • Static bearer token (test env / local smoke harness) — used only when a
//     request presents no App Attest headers and SCAN_API_TOKEN is set.
// Production sets no SCAN_API_TOKEN, so it is App Attest only.
import {
  buildOpenAIRequest,
  extractJSONText,
  extractOutputText,
  OPENAI_ENDPOINT,
  RefusalError,
} from "./contract";
import {
  appAttestEnabled,
  issueAttestChallenge,
  registerDevice,
  verifyScanAssertion,
  withinDeviceQuota,
} from "./appattest";
import { privacyPolicyResponse } from "./privacy";
import { base64FromBytes, errorMessage, jsonError, jsonResponse, log } from "./util";

const SCAN_PATH = "/v1/receipt-scan";
const ATTEST_CHALLENGE_PATH = "/v1/attest/challenge";
const ATTEST_PATH = "/v1/attest";
const PRIVACY_PATH = "/privacy";
// The app compresses receipts to ≲1 MB (max edge 1568 px); 8 MB is headroom,
// not a target. Also enforced before buffering via Content-Length.
const MAX_BODY_BYTES = 8 * 1024 * 1024;

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      // Explicit catch-all: never leak stacks or upstream bodies to callers.
      log("unhandled_error", { message: errorMessage(error) });
      return jsonError(500, "Internal error. Please try again.");
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const path = new URL(request.url).pathname;
  // App Store reviewers need a public policy URL. This static page has no
  // user data or Worker state, so it does not need scan authentication/rate limits.
  if (request.method === "GET" && path === PRIVACY_PATH) return privacyPolicyResponse();

  // Rate limit first, for every route — the unauthenticated attest endpoints
  // (KV writes + X.509/ECDSA verification) must be throttled too, not just the
  // scan path. Keyed by client IP, checked before auth so credentials can't be
  // brute-forced faster than the limit either.
  const clientIP = request.headers.get("cf-connecting-ip") ?? "unknown";
  const { success } = await env.SCAN_RATE_LIMIT.limit({ key: clientIP });
  if (!success) {
    log("rate_limited", {});
    return jsonError(429, "Too many requests. Wait a minute and try again.", { "retry-after": "60" });
  }

  if (request.method !== "POST") return jsonError(405, "Use POST.");

  if (path === SCAN_PATH) return handleScan(request, env);
  if (appAttestEnabled(env)) {
    if (path === ATTEST_CHALLENGE_PATH) return issueAttestChallenge(env);
    if (path === ATTEST_PATH) return registerDevice(request, env);
  }
  return jsonError(404, "Not found.");
}

async function handleScan(request: Request, env: Env): Promise<Response> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("image/jpeg")) {
    return jsonError(415, "Send the receipt as a raw image/jpeg body.");
  }
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) return jsonError(413, "Receipt image must be 8 MB or less.");
  const imageBytes = new Uint8Array(await request.arrayBuffer());
  if (imageBytes.byteLength === 0) return jsonError(400, "Empty body — send the receipt JPEG.");
  if (imageBytes.byteLength > MAX_BODY_BYTES) return jsonError(413, "Receipt image must be 8 MB or less.");

  // Auth binds to the image bytes (App Attest signs over them), so it runs
  // after the body is buffered but before any billable OpenAI work.
  const auth = await authenticate(request, env, imageBytes);
  if (!auth.ok) return auth.response;
  if (auth.keyId && !(await withinDeviceQuota(env, auth.keyId))) {
    return jsonError(429, "Daily scan limit reached for this device.", { "retry-after": "3600" });
  }

  const requestBody = buildOpenAIRequest(base64FromBytes(imageBytes));

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

type AuthResult = { ok: true; keyId?: string } | { ok: false; response: Response };

/**
 * App Attest when the request carries attestation headers and it's configured;
 * otherwise the static bearer token if one is set. `keyId` is present only on
 * the App Attest path (it keys the per-device quota).
 */
async function authenticate(request: Request, env: Env, imageBytes: Uint8Array): Promise<AuthResult> {
  if (appAttestEnabled(env) && request.headers.has("x-attest-key-id")) {
    const result = await verifyScanAssertion(request, env, imageBytes);
    return result.ok ? { ok: true, keyId: result.keyId } : { ok: false, response: result.response };
  }
  if (env.SCAN_API_TOKEN) {
    if (await tokenAuthorized(request, env.SCAN_API_TOKEN)) return { ok: true };
    return { ok: false, response: jsonError(401, "Missing or invalid app token.") };
  }
  return { ok: false, response: jsonError(401, "Missing App Attest credentials.") };
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
    log("openai_network_error", { message: errorMessage(error) });
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

async function tokenAuthorized(request: Request, expected: string): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  if (token === "") return false;
  return timingSafeEqualStrings(token, expected);
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
