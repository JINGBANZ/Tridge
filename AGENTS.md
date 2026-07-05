# AGENTS.md

<!-- shared-rules:begin — machine-managed block; do not edit — propose changes in JINGBANZ/rules. -->

## Working principles

- **Think before coding.** State assumptions explicitly. If a request has multiple reasonable
  interpretations, surface them and ask — don't silently pick one. Push back when something
  looks wrong instead of running with it.
- **Simplicity first.** Write the minimum code that solves the problem. No speculative features,
  no abstractions for single-use code, no error handling for cases that can't occur. Ask whether
  a senior engineer would find the solution overcomplicated.
- **Surgical changes.** Every changed line should trace to the request — but it's fine to refactor
  or improve nearby code and remove pre-existing dead code where there's clear room for improvement.
- **Goal-driven execution.** Turn the request into verifiable success criteria, state a brief plan
  for complex tasks, then loop until the criteria are met.
- **Document non-obvious decisions in comments** — explain *why*, not *what*.

## Workflow

- **Explore → plan → implement.** For non-trivial changes, understand the relevant code and
  agree on an approach before editing. Skip planning only for small, well-scoped fixes.
- **Evidence, not assertion.** Before claiming work is done, run the **Gate** command and show the
  output. Don't say "it works" without the passing result to back it.
- **Match existing patterns.** Before adding a file, find where similar code already lives and mirror
  its structure, naming, and idioms. Don't impose a pattern the repo doesn't already use.
- **Prefer running focused tests** over the whole suite while iterating, then run the full **Gate**
  before finishing.
- **Open a PR when the work is done.** Once the change is complete and the **Gate** passes, commit
  to a branch and open a pull request without waiting to be asked. Don't leave finished work
  uncommitted on a local branch.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary` in
lowercase imperative mood (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`).
Mark breaking changes with `!` (`feat!:`) or a `BREAKING CHANGE:` footer. One logical change per commit.

## Security & safety

- Never hardcode or log secrets, tokens, or credentials; read them from env/secret storage.
- Validate and sanitize all external input; treat user data as untrusted.

## Never

- **Never** skip pre-commit/pre-push hooks (e.g. `--no-verify`) or the **Gate**.
- **Never** commit secrets, `.env` files, or credentials — nor generated artifacts or large binaries.
- **Never** commit directly to the default branch; open a PR.
- **Never** `git push --force` to a shared branch.
- **Never** modify or delete a test to make a broken change pass — fix the code, not the test.
- **Never** suppress an error or warning to hide a problem — address the root cause.

<!-- shared-rules:end -->

## Project overview

MyFridge ("What's In My Fridge") is a native iOS app: photograph a grocery receipt, an LLM parses
it into a fridge inventory with guessed expiration dates, and the home screen shows each item as an
image on a minimal background, turning amber → red as expiry nears. Stack: iOS 17+, SwiftUI,
SwiftData, direct OpenAI API calls — no backend, no third-party packages. The complete build
spec is `design/fridge-design.html`; start there (via @wiki/index.md).

## Setup

- Development happens on a Linux box; Xcode/macOS exists only in CI (GitHub Actions macOS runners).
  Structure pure-logic code (LLM response parsing, urgency rules, date-regex parsing) into targets
  that build and pass under `swift test` on Linux.
- The OpenAI API key is supplied by the end user at runtime (Settings → Keychain). No key is
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

- Never commit an OpenAI API key or any receipt images with personal data. The key lives only
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
