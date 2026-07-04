# AGENTS.md

<!-- shared-rules:begin — machine-managed block; do not edit — propose changes in JINGBANZ/rules. -->
<!-- Empty until the first sync run populates it: Actions → "Sync shared rules" → Run workflow. -->
<!-- shared-rules:end -->

## Project overview

MyFridge ("What's In My Fridge") is a native iOS app: photograph a grocery receipt, an LLM parses
it into a fridge inventory with guessed expiration dates, and the home screen shows each item as an
image on a minimal background, turning amber → red as expiry nears. Stack: iOS 17+, SwiftUI,
SwiftData, direct Anthropic API calls — no backend, no third-party packages. The complete build
spec is `design/fridge-design.html`; start there (via @wiki/index.md).

## Setup

- Development happens on a Linux box; Xcode/macOS exists only in CI (GitHub Actions macOS runners).
  Structure pure-logic code (LLM response parsing, urgency rules, date-regex parsing) into targets
  that build and pass under `swift test` on Linux.
- The Anthropic API key is supplied by the end user at runtime (Settings → Keychain). No key is
  ever needed — or allowed — in the repo, CI, or build config.

## Commands

| Task     | Command                                                                  |
| -------- | ------------------------------------------------------------------------ |
| Test     | `swift test` (Linux-runnable logic targets)                              |
| Build    | `xcodebuild -scheme WhatsInMyFridge -destination 'generic/platform=iOS Simulator' build` (CI/macOS only) |
| **Gate** | `swift test` on Linux; on macOS/CI, build + full test suite              |

> No code exists yet. When creating the Xcode project, keep this table true — update it if the
> canonical commands differ.

## Code style

- SwiftUI + SwiftData idioms; `@Observable` for flow state; async/await for all I/O.
- All visual constants come from `AppTheme` (the design tokens in the spec) — no magic colors/sizes
  in views.
- No third-party dependencies. Wrap external services behind protocols (`LLMService`).

## Testing

- XCTest. Logic tests (LLM JSON parsing incl. fenced output, urgency thresholds, date regex) must
  run on Linux via `swift test`. UI/integration behavior is covered by the spec's acceptance
  criteria checklist.

## Repository etiquette

- **Branches:** `feat/<short-desc>`, `fix/<short-desc>`, `design/<short-desc>`
- **Pull requests:** describe intent, reference the spec section it implements, Gate passing.

## Security & safety

- Never commit an Anthropic API key or any receipt images with personal data. The key lives only
  in the device Keychain at runtime.

## Gotchas

- `design/fridge-design.html` is the single build spec — read the ENTIRE file before writing code;
  the mock markup/CSS encodes exact colors, sizes, and layout. If any other doc disagrees with it,
  the spec wins.
- "Done" means the spec's acceptance-criteria checklist passes, in its stated build order — not
  "it compiles".
- No tab bar, no tile/card backgrounds behind items, no user photos — these were explicit design
  reversals; don't reintroduce them.

## Further context

- **Design source of truth:** @wiki/index.md — specs, architecture, decisions, and current status.
