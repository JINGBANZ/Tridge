// The OpenAI half of the receipt-scan contract. During the BYOK→proxy
// migration this deliberately mirrors the app's OpenAIService
// (WhatsInMyFridge/Services/LLMService.swift): same prompt, model, schema,
// and reply extraction. Tests/FridgeCoreTests/ServerContractParityTests.swift
// pins the two copies together — a change on either side fails `swift test`
// until the other side matches.
import receiptSchema from "./receipt-schema.json";

export const OPENAI_ENDPOINT = "https://api.openai.com/v1/responses";
export const MODEL = "gpt-5-mini";
export const SCHEMA_NAME = "parsed_receipt";

// Content rules only — the response shape and the allowed "id" values are
// enforced by receipt-schema.json. Verbatim copy of OpenAIService.prompt
// (the parity test does a literal substring match against this file).
export const PROMPT = `This is a grocery store receipt. Extract every FOOD and BEVERAGE item.
Rules:
- Expand abbreviations into clean, human-friendly names ("WHL MLK 1GAL" → "Whole Milk").
- Skip non-food lines: tax, totals, coupons, bags, household goods, loyalty points.
- If one line has a quantity multiplier, set quantity accordingly.
- Estimate each item's typical shelf life in days from purchase, assuming it
  is stored appropriately at home (refrigerated promptly where applicable).
- For "id", pick the closest match from the allowed values. Prefer a specific
  id; if nothing specific fits, pick a generic one (fruit, vegetable, dairy,
  meat, seafood, bakery, beverage, grain, snack, condiment, frozen).
- If a line is probably food but you cannot tell what it is, use id "unknown"
  and name "Unknown item".`;

/** Responses API request body for one receipt image. */
export function buildOpenAIRequest(imageBase64: string, store: boolean): unknown {
  return {
    model: MODEL,
    // Generous cap: gpt-5 reasoning tokens count against it.
    max_output_tokens: 4000,
    reasoning: { effort: "low" },
    // true only in the test environment, so failed scans can be inspected in
    // OpenAI's dashboard; the production environment will set it to false
    // (receipts are personal data).
    store,
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
