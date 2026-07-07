// Secrets are set with `wrangler secret put`, so they never appear in
// wrangler.jsonc and `wrangler types` can't emit them into the generated Env
// (worker-configuration.d.ts). Interface merging adds exactly these two; all
// bindings and vars stay generated — never hand-write those here.
interface Env {
  OPENAI_API_KEY: string;
  SCAN_API_TOKEN: string;
}
