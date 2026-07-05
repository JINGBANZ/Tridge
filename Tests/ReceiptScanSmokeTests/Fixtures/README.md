# Receipt smoke-test fixtures

Each fixture is a directory containing **one receipt image** (`.jpg`/`.jpeg`/`.png`,
any file name) and an **`expected.json`**. The live smoke test
(`ReceiptScanSmokeTests`) sends every fixture image through the real OpenAI
structured-outputs call and asserts the parsed inventory satisfies the
expectations. Run it with:

```sh
OPENAI_API_KEY=sk-… swift test --filter ReceiptScanSmokeTests
```

Without the key the test skips, so plain `swift test` and CI stay green.

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

Every field except `items[].name` is optional.

```jsonc
{
  "min_items": 6,               // bounds on the number of parsed food items
  "max_items": 6,
  "items": [                    // each entry must match a DISTINCT parsed item
    {
      "name": ["whole milk", "milk"],          // string or list; any keyword
                                               // (case-insensitive substring) matches
      "id": "milk",                            // exact ItemID rawValue (see
                                               // WhatsInMyFridge/Core/Types.swift)
      "quantity": 1,                           // exact
      "shelf_life_days": { "min": 3, "max": 21 } // inclusive bounds
    }
  ],
  "absent": ["bag fee", "tax"]  // no parsed item name may contain these —
                                // catches non-food lines leaking through
}
```
