# MyFridge — "What's In My Fridge"

An iOS app: scan a grocery receipt, an LLM parses it into a fridge inventory with
guessed expiration dates, and the home screen shows every item as an image on a
minimal background, turning amber → red as it nears expiry.

## The single source of truth

**`design/fridge-design.html`** is the complete build spec. Read the ENTIRE file
(it is plain HTML — read the text and the mock markup/CSS, which encode exact
colors, sizes, and layout) before writing any code. It contains:

- Design direction + three screen mocks (home grid, drag-to-consume, review sheet)
- Design tokens: palette, type, item-sprite spec, pills, drop zones, motion, haptics
- All screens and every interaction, including edge/empty/error states
- The SwiftData schema (field-by-field)
- The exact Anthropic API request, the verbatim receipt-parsing prompt, and the
  JSON contract the app must decode
- Project/file layout to follow
- Acceptance criteria (the definition of done) and the recommended build order

If this file and the spec ever disagree, the spec wins.

## Hard constraints

- Native iOS 17+, Swift 5.10, SwiftUI, SwiftData. **No third-party packages.**
- Xcode project name: `WhatsInMyFridge`, in the repo root.
- LLM calls go direct to the Anthropic Messages API (`claude-haiku-4-5`) with a
  user-supplied key from Keychain, behind an `LLMService` protocol. No backend.
- Item art is a prebuilt set (emoji for v1) resolved via an `artKey` lookup —
  no user photos, no tile/card backgrounds behind items, no tab bar (one scan button).
- Out of scope for v1: grocery list, recipes, stats screen, CloudKit sync.

## Environment notes

- This repo is developed on a Linux box; macOS/Xcode is only available in CI.
  Structure the code so pure-logic targets (LLM response parsing, urgency rules,
  date-regex parsing) build and pass under `swift test` on Linux.
- CI (GitHub Actions, macos runner) is the path to a real build + TestFlight.
  If asked to set it up, keep it minimal: build, run tests, archive.

## Definition of done

Work through the acceptance-criteria checklist at the bottom of the spec, in the
build order given in its final callout. Do not stop at "it compiles" — every
checklist item is expected to pass.
