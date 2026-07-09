// Apple App Attest is the production client-auth layer: it proves each scan
// comes from a genuine, unmodified Tridge install on real Apple hardware,
// replacing the static bearer token that a shipped binary inevitably leaks.
//
// Two phases (Apple's "Validating Apps That Connect to Your Server"):
//   1. Registration — once per install, the device attests a Secure Enclave
//      key against a one-time server challenge. We verify the attestation
//      (cert chain to Apple's App Attest root, nonce, App ID, key id) and
//      persist the device's public key + sign counter in KV, keyed by keyId.
//   2. Assertion — every scan carries a signature over the request image. We
//      verify it with the stored public key and require the sign counter to
//      strictly increase, which is what makes a captured assertion un-replayable.
//
// The crypto (CBOR decode, X.509 chain validation, ECDSA verify) is delegated
// to the audited `node-app-attest` library; this module owns the KV state,
// challenge lifecycle, per-device quota, and request/response plumbing.
import { verifyAttestation, verifyAssertion } from "node-app-attest";
import { base64FromBytes, errorMessage, jsonError, jsonResponse, log } from "./util";

const CHALLENGE_BYTES = 32;
const CHALLENGE_TTL_SECONDS = 5 * 60; // one-time, short-lived; registration is immediate
// Device records are refreshed on every scan, so this is really an
// abandoned-install reaper: a key unused for this long is dropped and the app
// silently re-attests. ~13 months comfortably spans seasonal usage gaps.
const DEVICE_TTL_SECONDS = 400 * 24 * 60 * 60;
const QUOTA_TTL_SECONDS = 2 * 24 * 60 * 60; // outlives one UTC day with margin
const DEFAULT_DAILY_QUOTA = 50;

interface DeviceRecord {
  /** SPKI PEM of the attested key; verifies every future assertion. */
  publicKey: string;
  /** Last accepted App Attest sign counter; assertions must exceed it. */
  signCount: number;
  environment: "production" | "development";
}

/** App Attest is active only where the KV binding and app identity are configured. */
export function appAttestEnabled(env: Env): boolean {
  return Boolean(env.DEVICE_KV && env.APPLE_TEAM_ID && env.APPLE_BUNDLE_ID);
}

/** POST /v1/attest/challenge — hand out a one-time challenge for registration. */
export async function issueAttestChallenge(env: Env): Promise<Response> {
  const challenge = base64FromBytes(crypto.getRandomValues(new Uint8Array(CHALLENGE_BYTES)));
  await env.DEVICE_KV.put(challengeKey(challenge), "1", { expirationTtl: CHALLENGE_TTL_SECONDS });
  return jsonResponse({ challenge });
}

interface RegisterBody {
  keyId?: string;
  attestation?: string; // base64 CBOR attestation object
  challenge?: string; // base64, exactly as issued by /v1/attest/challenge
}

/** POST /v1/attest — verify an attestation and register the device's key. */
export async function registerDevice(request: Request, env: Env): Promise<Response> {
  let body: RegisterBody;
  try {
    body = (await request.json()) as RegisterBody;
  } catch {
    return jsonError(400, "Send a JSON body with keyId, attestation, and challenge.");
  }
  const { keyId, attestation, challenge } = body;
  if (!keyId || !attestation || !challenge) {
    return jsonError(400, "keyId, attestation, and challenge are required.");
  }

  // Consume the challenge before verifying so it can never be reused, even if
  // verification below fails. Absent → unknown, expired, or already spent.
  const seen = await env.DEVICE_KV.get(challengeKey(challenge));
  if (seen === null) return jsonError(401, "Unknown or expired challenge.");
  await env.DEVICE_KV.delete(challengeKey(challenge));

  let result: { publicKey: string; environment: string };
  try {
    result = verifyAttestation({
      attestation: Buffer.from(attestation, "base64"),
      challenge: Buffer.from(challenge, "base64"),
      keyId,
      bundleIdentifier: env.APPLE_BUNDLE_ID,
      teamIdentifier: env.APPLE_TEAM_ID,
      allowDevelopmentEnvironment: env.APP_ATTEST_ALLOW_DEV === "true",
    });
  } catch (error) {
    log("attest_failed", { message: errorMessage(error) });
    return jsonError(401, "Attestation could not be verified.");
  }

  const record: DeviceRecord = {
    publicKey: result.publicKey,
    signCount: 0,
    environment: result.environment === "production" ? "production" : "development",
  };
  await env.DEVICE_KV.put(deviceKey(keyId), JSON.stringify(record), { expirationTtl: DEVICE_TTL_SECONDS });
  log("device_registered", { environment: record.environment });
  return jsonResponse({ ok: true });
}

export type AssertionResult = { ok: true; keyId: string } | { ok: false; response: Response };

/**
 * Verify the App Attest assertion carried by a scan request. The signed
 * payload is the raw image, so an assertion is bound to exactly one image and
 * one sign-counter value — it can't be lifted onto a different upload or replayed.
 */
export async function verifyScanAssertion(request: Request, env: Env, imageBytes: Uint8Array): Promise<AssertionResult> {
  const keyId = request.headers.get("x-attest-key-id") ?? "";
  const assertion = request.headers.get("x-attest-assertion") ?? "";
  if (!keyId || !assertion) {
    return fail(jsonError(401, "Missing App Attest credentials."));
  }

  const stored = await env.DEVICE_KV.get(deviceKey(keyId));
  if (stored === null) {
    // App re-attests and retries on this; not an error worth alerting on.
    return fail(jsonError(401, "Unregistered device. Attest before scanning."));
  }
  const record = JSON.parse(stored) as DeviceRecord;

  let verified: { signCount: number };
  try {
    verified = verifyAssertion({
      assertion: Buffer.from(assertion, "base64"),
      payload: Buffer.from(imageBytes),
      publicKey: record.publicKey,
      bundleIdentifier: env.APPLE_BUNDLE_ID,
      teamIdentifier: env.APPLE_TEAM_ID,
      signCount: record.signCount,
    });
  } catch (error) {
    log("assertion_failed", { message: errorMessage(error) });
    return fail(jsonError(401, "Assertion could not be verified."));
  }

  record.signCount = verified.signCount;
  await env.DEVICE_KV.put(deviceKey(keyId), JSON.stringify(record), { expirationTtl: DEVICE_TTL_SECONDS });
  return { ok: true, keyId };
}

/**
 * Per-device daily quota, on top of the per-IP rate limit. KV is eventually
 * consistent, so this is a best-effort cap — a single device can't
 * meaningfully race itself, and the IP limit backstops burst abuse.
 */
export async function withinDeviceQuota(env: Env, keyId: string): Promise<boolean> {
  const limit = Number(env.DEVICE_DAILY_QUOTA) || DEFAULT_DAILY_QUOTA;
  const key = quotaKey(keyId, utcDayStamp());
  const used = Number((await env.DEVICE_KV.get(key)) ?? "0");
  if (used >= limit) {
    log("device_quota_exceeded", { used, limit });
    return false;
  }
  await env.DEVICE_KV.put(key, String(used + 1), { expirationTtl: QUOTA_TTL_SECONDS });
  return true;
}

function utcDayStamp(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
}

const challengeKey = (challenge: string): string => `challenge:${challenge}`;
const deviceKey = (keyId: string): string => `device:${keyId}`;
const quotaKey = (keyId: string, day: string): string => `quota:${keyId}:${day}`;

function fail(response: Response): AssertionResult {
  return { ok: false, response };
}
