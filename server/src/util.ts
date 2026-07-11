// Shared HTTP + logging helpers used by the scan handler and the App Attest
// layer. Kept tiny and dependency-free so both modules stay in sync on the
// error-body shape ({"error": …}) and the structured-log format.

export function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { "content-type": "application/json", ...init.headers },
  });
}

export function jsonError(status: number, message: string, extraHeaders: Record<string, string> = {}): Response {
  return jsonResponse({ error: message }, { status, headers: extraHeaders });
}

/** Structured JSON logs — queryable in Workers Logs; never includes images or keys. */
export function log(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export function base64FromBytes(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000; // avoid per-call argument limits on large images
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
