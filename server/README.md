# server/ — receipt-scan API (Cloudflare Worker)

A Cloudflare Worker that holds the OpenAI key so the app doesn't have to: the
app POSTs the receipt JPEG, the worker calls the OpenAI Responses API and
returns the `ParsedReceipt` JSON the app already parses.

**One worker today** (`tridge-scan-api-test`) serves every build — Xcode-dev and
TestFlight alike. Client auth is **Apple App Attest**; a static bearer token is
also accepted, solely so the local receipt smoke harness (which can't produce
App Attest assertions) can drive the worker from Linux. `store:false` and the rest
of the behavior here are already the production posture, so standing up a
dedicated production worker later is purely additive — see
[Adding a production worker later](#adding-a-production-worker-later).

## API

```
POST /v1/receipt-scan
  Content-Type: image/jpeg              (raw body, ≤ 8 MB)
  App Attest:   X-Attest-Key-Id: <keyId> + X-Attest-Assertion: <base64>   (assertion over the image bytes)
  or token:     Authorization: Bearer <SCAN_API_TOKEN>                      (smoke harness only)
  200 {"items":[{"id":"milk","name":"Whole Milk","receipt_text":"WHL MLK","quantity":1,"shelf_life_days":7,"storage":"fridge"}]}
  400 empty · 401 bad auth/unregistered device · 404/405 route/method · 413 too large
  415 not image/jpeg · 422 unparseable (after 1 retry) · 429 IP-rate-limited or device quota · 502 OpenAI failure

POST /v1/attest/challenge          → {"challenge":"<base64>"}   (one-time, App Attest registration)
POST /v1/attest                    → {"ok":true}                (body: {keyId, attestation, challenge})
GET  /privacy                       → public privacy policy (no authentication)
```

Protection layers, in order: per-IP rate limit → client auth → input
validation → sanitized errors → structured logs. Error bodies are
`{"error":"…"}`; upstream OpenAI bodies are logged (Workers Logs, structured
JSON), never echoed. App Attest verification uses the `node-app-attest` library
(CBOR + X.509 chain to Apple's App Attest root); device public keys, sign
counters, and quota counts live in the `DEVICE_KV` namespace. See
`src/appattest.ts` and `wiki/decisions.md` → *2026-07-10*.

## Develop

```sh
npm install
cp .dev.vars.example .dev.vars   # fill in an OpenAI key, APPLE_TEAM_ID, and a random token
npm run typecheck                # wrangler types + tsc
npm test                         # vitest (incl. App Attest verification against known-good vectors)
npm run dev                      # local worker on http://localhost:8787
```

## Deploy

One-time bootstrap. Auth via `wrangler login`, or `CLOUDFLARE_API_TOKEN` +
`CLOUDFLARE_ACCOUNT_ID` on a headless box.

```sh
npx wrangler kv namespace create DEVICE_KV        # paste the id into wrangler.jsonc (DEVICE_KV)
npx wrangler secret put OPENAI_API_KEY            # dedicated key with a budget cap
npx wrangler secret put APPLE_TEAM_ID             # Apple Developer team id for com.tridge.app
npx wrangler secret put SCAN_API_TOKEN            # openssl rand -base64 32 (smoke harness)
npm run deploy
```

Ongoing deploys use **Cloudflare Workers Builds** (the platform-recommended git
integration, no tokens in GitHub): dashboard → the worker → Settings → Builds →
Connect the GitHub repo, root directory `server`, branch `main`, watch paths
`server/**`. Every `main` push touching `server/` then builds and deploys.
Secrets set with `wrangler secret put` persist across deploys.

## Adding a production worker later

The worker is already env-driven, so a dedicated production deployment (separate
URL, isolated budget-capped OpenAI key, production-only attestations) is additive:

1. Add an `env.prod` block to `wrangler.jsonc` (`name`, its own `vars` with
   `APP_ATTEST_ALLOW_DEV: "false"` + its own `DEVICE_DAILY_QUOTA`, its own
   `kv_namespaces` with a distinct id, and a `ratelimits` entry with a distinct
   `namespace_id`). Named envs don't inherit these, so redefine them in full.
2. `wrangler kv namespace create DEVICE_KV --env prod` and set the secrets with
   `--env prod` (a *separate* `OPENAI_API_KEY`).
3. `npx wrangler deploy --env prod`, and connect a second Workers Builds hookup
   with deploy command `npx wrangler deploy --env prod`.
4. In the app, make `ScanAPIConfig.baseURL` build-config-driven (`#if DEBUG` →
   test URL, `#else` → prod URL) so Release/TestFlight builds hit production.

No behavior changes on the existing worker — it already runs the production
posture (`store:false`, App Attest, per-device quotas).

## Privacy policy

The Worker serves the App Store privacy policy at
`https://tridge-scan-api-test.forrestzjb.workers.dev/privacy`. It is public and
does not require App Attest or a scan token. The policy describes the receipt
scan processor, App Attest/rate-limit data, and the `store:false` OpenAI
Responses setting. After this change is deployed, enter that URL in App Store
Connect → App Privacy → Privacy Policy URL.
