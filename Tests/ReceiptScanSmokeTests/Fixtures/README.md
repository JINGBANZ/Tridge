# Receipt smoke-test fixtures

Each fixture is a directory containing **one receipt image** (`.jpg`/`.jpeg`/`.png`,
any file name) and an **`expected.json`**. The live smoke test
(`ReceiptScanSmokeTests`) sends every fixture image through the real OpenAI
structured-outputs call and asserts the parsed inventory satisfies the
expectations. Set the key up once — copy `env.sample` at the repo root to
`.env` (gitignored) and fill in your `OPENAI_API_KEY` — then run:

```sh
swift test --filter ReceiptScanSmokeTests
```

(An `OPENAI_API_KEY` environment variable also works and takes precedence.)
Without a key the test skips, so plain `swift test` stays green. The smoke
test is local-only by design: the key is never allowed in the repo or CI.

## Adding a fixture

1. Create `Fixtures/<name>/` with the photo. Keep images reasonably sized
   (≤ ~1600 px long edge) — the test sends them as-is.
2. Write `expected.json`. Keep expectations **fuzzy**: the LLM's wording varies
   between runs, so match on lowercase name keywords and ranges, never exact
   strings or absolute dates.

**Never commit a receipt with personal data** (card digits, loyalty numbers,
names). Either blur/crop it first, or put it in `Fixtures/private/<name>/` —
that directory is gitignored but still picked up when the tests run locally.

## expected.json format

Every field except `items[].name` is optional. Fixtures are read straight from
this directory in the source tree (no resource bundling), so an image can also
live elsewhere in the repo and be referenced by path — the sample fixture
reuses the app bundle's `WhatsInMyFridge/Resources/SampleReceipt.jpg` this way
instead of committing a duplicate.

```jsonc
{
  "image": "../../../../WhatsInMyFridge/Resources/SampleReceipt.jpg",
                                // optional, relative to this fixture's folder;
                                // omit when the image sits in the folder itself
  "min_items": 6,               // bounds on the number of parsed food items
  "max_items": 6,
  "items": [                    // each entry must match a DISTINCT parsed item
    {
      "name": ["whole milk", "milk"],          // string or list; any keyword
                                               // (case-insensitive substring) matches
      "id": ["milk", "dairy"],                 // acceptable ItemID rawValues (see
                                               // WhatsInMyFridge/Core/Types.swift);
                                               // string or list — list the near
                                               // misses the LLM may fairly pick
      "quantity": 1,                           // exact
      "shelf_life_days": { "min": 1 }            // inclusive bounds; keep loose —
                                               // usually just min 1 (users correct
                                               // dates themselves in review)
    }
  ],
  "absent": ["bag fee", "tax"]  // no parsed item name may contain these —
                                // catches non-food lines leaking through
}
```
