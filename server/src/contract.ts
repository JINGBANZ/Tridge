// The OpenAI half of the receipt-scan contract: prompt, model, schema, request
// body, and reply extraction. This worker is the sole holder of the OpenAI key
// and the receipt prompt — the app POSTs a receipt JPEG to it
// (Tridge/Services/ProxyLLMService.swift) and never talks to OpenAI directly.
import receiptSchema from "./receipt-schema.json";

export const OPENAI_ENDPOINT = "https://api.openai.com/v1/responses";
export const MODEL = "gpt-5-mini";
export const SCHEMA_NAME = "parsed_receipt";

// Content rules only — the response shape and the allowed "id" values are
// enforced by receipt-schema.json.
export const PROMPT = `This is a grocery store receipt. Extract the FOOD and BEVERAGE items that
belong in a fridge or freezer.
Rules:
- Expand abbreviations into clean, human-friendly names ("WHL MLK 1GAL" → "Whole Milk").
- "name" is the bare food name and nothing else — strip weights, sizes, counts,
  prices, packaging, and brand or marketing words ("Jalapeño Pepper (0.34 lb)" →
  "Jalapeño Pepper", "Local Eggs (dozen) — 6 dozens" → "Eggs").
- Skip non-food lines: tax, totals, coupons, bags, household goods, loyalty points.
- Skip food and drink that is NOT normally refrigerated or frozen — shelf-stable
  pantry goods kept at room temperature (canned goods, dry pasta and rice, chips
  and crackers, cookies, bottled water, soda, coffee, tea, unopened condiments).
  Only include items a person would actually store in the fridge or freezer.
- If one line has a quantity multiplier, set quantity accordingly.
- For "storage", say where the item belongs once home: "freezer" for items
  sold frozen or normally kept frozen, "fridge" for everything else.
- Estimate each item's typical shelf life in days from purchase, assuming it
  is stored appropriately at home (refrigerated promptly where applicable).
- For "id", pick the closest match from the allowed values. Prefer a specific
  id; if nothing specific fits, pick a generic one (fruit, vegetable, dairy,
  meat, seafood, bakery, beverage, grain, snack, condiment, frozen).
- If a line is probably food but you cannot tell what it is, use id "unknown"
  and name "Unknown item".`;

/** Responses API request body for one receipt image. */
export function buildOpenAIRequest(imageBase64: string): unknown {
  return {
    model: MODEL,
    // Generous cap: gpt-5 reasoning tokens count against it.
    max_output_tokens: 4000,
    reasoning: { effort: "low" },
    // Retain the request at OpenAI so failed scans stay inspectable in the
    // dashboard. Same in every environment (see wiki/decisions.md → 2026-07-10).
    store: true,
    input: [
      {
        role: "user",
        content: [
          { type: "input_image", image_url: `data:image/jpeg;base64,${imageBase64}` },
          { type: "input_text", text: PROMPT },
        ],
      },
    ],
    text: {
      format: {
        type: "json_schema",
        name: SCHEMA_NAME,
        strict: true,
        schema: receiptSchema,
      },
    },
  };
}

export class RefusalError extends Error {}

interface OutputContent {
  type?: string;
  text?: string;
  refusal?: string;
}

interface ResponseBody {
  status?: string;
  output?: { type?: string; content?: OutputContent[] }[];
}

/**
 * Pulls the reply text out of a Responses API body. The output timeline
 * interleaves reasoning and message items; the reply lives in message items'
 * output_text content. Throws RefusalError on refusal, Error on empty output.
 */
export function extractOutputText(decoded: unknown): string {
  if (typeof decoded !== "object" || decoded === null) throw new Error("unrecognized response shape");
  const body = decoded as ResponseBody;
  const contents = (body.output ?? [])
    .filter((item) => item.type === "message")
    .flatMap((item) => item.content ?? []);
  const refusal = contents.find((content) => content.type === "refusal")?.refusal;
  if (refusal !== undefined) throw new RefusalError(refusal);
  const text = contents
    .filter((content) => content.type === "output_text")
    .map((content) => content.text ?? "")
    .join("");
  if (text === "") throw new Error(`empty output, status ${body.status ?? "unknown"}`);
  return text;
}

/**
 * Strips Markdown code fences and any prose around the JSON object — the
 * same defense-in-depth the app's ReceiptResponseParser applies.
 */
export function extractJSONText(raw: string): string {
  let text = raw.trim();
  if (text.startsWith("```")) {
    const lines = text.split("\n");
    lines.shift();
    if (lines.length > 0 && lines[lines.length - 1].trim().startsWith("```")) lines.pop();
    text = lines.join("\n");
  }
  const first = text.indexOf("{");
  const last = text.lastIndexOf("}");
  if (first === -1 || last === -1 || first >= last) return text;
  return text.slice(first, last + 1);
}
