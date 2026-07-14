// Public, no-auth policy page. Keeping it in the Worker gives App Store Connect
// a stable HTTPS URL without adding another hosted service.
const PRIVACY_POLICY_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tridge Privacy Policy</title>
  <style>
    body { margin: 0; background: #f6f8f6; color: #22281f; font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    main { max-width: 720px; margin: 0 auto; padding: 48px 24px 72px; }
    h1 { font-size: 2rem; margin: 0; }
    h2 { font-size: 1.25rem; margin: 2rem 0 .5rem; }
    p, li { max-width: 68ch; }
    a { color: #216b42; }
  </style>
</head>
<body>
  <main>
    <h1>Tridge Privacy Policy</h1>
    <p>Effective date: July 14, 2026</p>

    <h2>What Tridge does</h2>
    <p>Tridge turns a grocery-receipt image into an on-device fridge inventory. The inventory you save stays on your device; Tridge does not provide account sign-in, cloud inventory sync, advertising, or tracking.</p>

    <h2>Information used to scan a receipt</h2>
    <p>When you choose to scan a receipt, Tridge sends the receipt image to Tridge's Cloudflare Worker. The Worker sends it to OpenAI's Responses API to identify grocery items and return an inventory result. The Worker does not save the receipt image or the parsed inventory result after fulfilling the scan.</p>
    <p>The Worker sends <code>store: false</code> to OpenAI, which disables OpenAI Responses application-state storage for the request. OpenAI may still retain API content in abuse-monitoring logs for up to 30 days, or longer when needed for a safety or legal investigation. See <a href="https://developers.openai.com/api/docs/guides/your-data">OpenAI's data controls</a>.</p>

    <h2>Security and service-operation data</h2>
    <p>To protect the scan service from abuse, Tridge uses Apple App Attest. The Worker stores an attested device public key, a device key identifier, and a counter used to prevent replayed requests. This record is refreshed while the app is used and expires after up to 400 days of inactivity. A per-device daily scan-count record expires after up to two days. Cloudflare also processes IP address and request metadata to rate-limit and operate the service.</p>

    <h2>How information is shared</h2>
    <p>Receipt images are shared only with Cloudflare to run the Worker and OpenAI to perform the requested receipt scan. Tridge does not sell personal information or share it for advertising or cross-app tracking.</p>

    <h2>Your choices</h2>
    <p>You can use manual item entry instead of receipt scanning. You can delete your saved inventory from the app's Settings screen. If you have a privacy question or request, contact the project through the <a href="https://github.com/JINGBANZ/Tridge/issues">Tridge issue tracker</a>; do not include receipt images or other sensitive information in a public issue.</p>

    <h2>Changes to this policy</h2>
    <p>We will update this page and its effective date if Tridge's data practices materially change.</p>
  </main>
</body>
</html>`;

export function privacyPolicyResponse(): Response {
  return new Response(PRIVACY_POLICY_HTML, {
    headers: {
      "cache-control": "public, max-age=3600",
      "content-type": "text/html; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}
