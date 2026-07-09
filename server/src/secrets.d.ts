// Secrets are set with `wrangler secret put`, so they never appear in
// wrangler.jsonc and `wrangler types` can't emit them into the generated Env
// (worker-configuration.d.ts). Interface merging adds exactly these; all
// bindings and vars stay generated — never hand-write those here.
interface Env {
  OPENAI_API_KEY: string;
  // The App Attest team identifier and the static bearer token are both
  // optional: production runs App Attest with a team id and no token; the test
  // env sets both (token for the local smoke harness, App Attest for devices).
  APPLE_TEAM_ID?: string;
  SCAN_API_TOKEN?: string;
}
