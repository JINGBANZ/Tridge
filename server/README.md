# server/ — receipt-scan API (Cloudflare Worker)

A Cloudflare Worker that holds the OpenAI key so the app doesn't have to: the
app POSTs the receipt JPEG, the worker calls the OpenAI Responses API and
returns the `ParsedReceipt` JSON the app already parses. One codebase, two
deployments from `wrangler.jsonc`:

| | test (`tridge-scan-api-test`) | production (`tridge-scan-api`, `--env prod`) |
| --- | --- | --- |
| Client auth | App Attest **or** static bearer token | App Attest only |
| App Attest env | development + production accepted | production only |
| `STORE_RESPONSES` | `true` (scans inspectable in OpenAI dashboard) | `false` (receipts are personal data) |
| Per-device quota | 50/day | 30/day |
| OpenAI key | dedicated test key, budget-capped | separate prod key, budget-capped |

Debug app builds hit the test worker; Release builds (TestFlight/App Store) hit
production. The static bearer token exists only so the local receipt smoke
harness can drive the test worker from Linux — it never ships in the app.

## API

```
POST /v1/receipt-scan
  Content-Type: image/jpeg              (raw body, ≤ 8 MB)
  App Attest:   X-Attest-Key-Id: <keyId> + X-Attest-Assertion: <base64>   (assertion over the image bytes)
  or token:     Authorization: Bearer <SCAN_API_TOKEN>                      (test env / smoke harness)
  200 {"items":[{"id":"milk","name":"Whole Milk","receipt_text":"WHL MLK","quantity":1,"shelf_life_days":7}]}
  400 empty · 401 bad auth/unregistered device · 404/405 route/method · 413 too large
  415 not image/jpeg · 422 unparseable (after 1 retry) · 429 IP-rate-limited or device quota · 502 OpenAI failure

POST /v1/attest/challenge          → {"challenge":"<base64>"}   (one-time, App Attest registration)
POST /v1/attest                    → {"ok":true}                (body: {keyId, attestation, challenge})
```

Protection layers, in order: per-IP rate limit → client auth → input
validation → sanitized errors → structured logs. Error bodies are
`{"error":"…"}`; upstream OpenAI bodies are logged (Workers Logs, structured
JSON), never echoed. App Attest verification uses the `node-app-attest` library
(CBOR + X.509 chain to Apple's App Attest root); device public keys, sign
counters, and quota counts live in the `DEVICE_KV` namespace. See
`src/appattest.ts` and `wiki/decisions.md` → *2026-07-09*.

## Develop

```sh
npm install
cp .dev.vars.example .dev.vars   # fill in a test OpenAI key, APPLE_TEAM_ID, and a random token
npm run typecheck                # wrangler types + tsc
npm test                         # vitest (incl. App Attest verification against known-good vectors)
npm run dev                      # local worker on http://localhost:8787
```

## Deploy

Two workers, each bootstrapped once. Auth via `wrangler login`, or
`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` on a headless box.

**1. Create the KV namespaces** and paste the ids into `wrangler.jsonc`
(replacing the `REPLACE_WITH_*_DEVICE_KV_ID` placeholders):

```sh
npx wrangler kv namespace create DEVICE_KV              # → id for the test env
npx wrangler kv namespace create DEVICE_KV --env prod   # → id for env.prod
```

**2. Set secrets** (add `--env prod` for production; use a *separate*,
budget-capped OpenAI key per environment):

```sh
npx wrangler secret put OPENAI_API_KEY [--env prod]     # dedicated key with a budget cap
npx wrangler secret put APPLE_TEAM_ID  [--env prod]     # Apple Developer team id for com.tridge.app
npx wrangler secret put SCAN_API_TOKEN                  # test env only — openssl rand -base64 32
```

**3. Deploy:** `npm run deploy` (test) and `npx wrangler deploy --env prod`.

Ongoing deploys use **Cloudflare Workers Builds** (the platform-recommended git
integration, no tokens in GitHub). Connect each worker once — dashboard → the
worker → Settings → Builds → Connect the GitHub repo, root directory `server`,
branch `main`, build watch paths `server/**`, and for production set the deploy
command to `npx wrangler deploy --env prod`. Every `main` push touching
`server/` then builds and deploys. Secrets set with `wrangler secret put`
persist across deploys.
