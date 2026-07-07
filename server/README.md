# server/ — receipt-scan API (test environment)

A Cloudflare Worker that holds the OpenAI key so the app doesn't have to: the
app POSTs the receipt JPEG, the worker calls the OpenAI Responses API (same
prompt/model/schema as the app's BYOK path — `swift test` enforces parity),
and returns the `ParsedReceipt` JSON the app already parses.

**This is the test environment**: `STORE_RESPONSES=true` (scans inspectable in
OpenAI's dashboard) and a static bearer token. Production will be a separate
environment with `store:false`, App Attest, and per-device quotas — see
`wiki/decisions.md` → *2026-07-07* entries.

## API

```
POST /v1/receipt-scan
Authorization: Bearer <SCAN_API_TOKEN>
Content-Type: image/jpeg            (raw body, ≤ 8 MB)

200 {"items":[{"id":"milk","name":"Whole Milk","receipt_text":"WHL MLK","quantity":1,"shelf_life_days":7}]}
400 empty body · 401 bad token · 404/405 wrong route/method · 413 too large
415 not image/jpeg · 422 unparseable receipt/refusal (after 1 retry) · 429 rate limited · 502 OpenAI failure
```

Errors are `{"error":"<human-readable message>"}`; upstream OpenAI bodies are
logged (Workers Logs, structured JSON), never echoed to callers.

## Develop

```sh
npm install
cp .dev.vars.example .dev.vars   # fill in a test OpenAI key + a random token
npm run typecheck                # wrangler types + tsc
npm test                         # vitest
npm run dev                      # local worker on http://localhost:8787
```

## Deploy

One-time bootstrap (auth via `wrangler login`, or `CLOUDFLARE_API_TOKEN` +
`CLOUDFLARE_ACCOUNT_ID` env vars on a headless box):

```sh
npx wrangler secret put OPENAI_API_KEY   # dedicated test-project key with a budget cap
npx wrangler secret put SCAN_API_TOKEN   # openssl rand -base64 32
npm run deploy
```

Ongoing deploys use **Cloudflare Workers Builds** (the platform-recommended
git integration, no tokens in GitHub): dashboard → the worker → Settings →
Builds → Connect the GitHub repo, root directory `server`, branch `main`,
build watch paths `server/**`. Every `main` push touching `server/` then
builds and deploys automatically. Secrets set with `wrangler secret put`
persist across deploys.
