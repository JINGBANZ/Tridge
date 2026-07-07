import { describe, expect, it } from "vitest";
import {
  buildOpenAIRequest,
  extractJSONText,
  extractOutputText,
  MODEL,
  PROMPT,
  RefusalError,
  SCHEMA_NAME,
} from "../src/contract";
import receiptSchema from "../src/receipt-schema.json";

describe("buildOpenAIRequest", () => {
  const request = buildOpenAIRequest("SGVsbG8=", true) as Record<string, any>;

  it("mirrors the app's OpenAIService request", () => {
    expect(request.model).toBe(MODEL);
    expect(request.max_output_tokens).toBe(4000);
    expect(request.reasoning).toEqual({ effort: "low" });
    expect(request.text.format).toEqual({
      type: "json_schema",
      name: SCHEMA_NAME,
      strict: true,
      schema: receiptSchema,
    });
  });

  it("sends the image as a base64 data URL plus the prompt", () => {
    const content = request.input[0].content;
    expect(request.input[0].role).toBe("user");
    expect(content[0]).toEqual({ type: "input_image", image_url: "data:image/jpeg;base64,SGVsbG8=" });
    expect(content[1]).toEqual({ type: "input_text", text: PROMPT });
  });

  it("passes the store flag through", () => {
    expect(request.store).toBe(true);
    expect((buildOpenAIRequest("x", false) as Record<string, any>).store).toBe(false);
  });
});

describe("receipt-schema.json", () => {
  const itemSchema = (receiptSchema as any).properties.items.items;

  it("is the strict-mode schema the app enforces", () => {
    expect((receiptSchema as any).additionalProperties).toBe(false);
    expect(itemSchema.additionalProperties).toBe(false);
    expect(itemSchema.required).toEqual(["id", "name", "receipt_text", "quantity", "shelf_life_days"]);
  });

  it("carries the full 100-id curated vocabulary, unknown last", () => {
    const ids: string[] = itemSchema.properties.id.enum;
    expect(ids).toHaveLength(100);
    expect(ids[0]).toBe("apple");
    expect(ids[ids.length - 1]).toBe("unknown");
    for (const id of ["sweet_potato", "ice_cream", "ground_meat", "canned_goods", "peanut_butter", "frozen_meal"]) {
      expect(ids).toContain(id);
    }
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe("extractOutputText", () => {
  it("joins output_text across message items and skips reasoning items", () => {
    const text = extractOutputText({
      output: [
        { type: "reasoning" },
        { type: "message", content: [{ type: "output_text", text: '{"items"' }] },
        { type: "message", content: [{ type: "output_text", text: ":[]}" }] },
      ],
    });
    expect(text).toBe('{"items":[]}');
  });

  it("throws RefusalError on a refusal", () => {
    const body = {
      output: [{ type: "message", content: [{ type: "refusal", refusal: "no" }] }],
    };
    expect(() => extractOutputText(body)).toThrow(RefusalError);
  });

  it("throws on empty or malformed output", () => {
    expect(() => extractOutputText({ output: [] })).toThrow();
    expect(() => extractOutputText("garbage")).toThrow();
    expect(() => extractOutputText(null)).toThrow();
  });
});

describe("extractJSONText", () => {
  const json = '{"items":[]}';

  it("passes plain JSON through", () => {
    expect(extractJSONText(json)).toBe(json);
  });

  it("strips markdown fences", () => {
    expect(extractJSONText("```json\n" + json + "\n```")).toBe(json);
    expect(extractJSONText("```\n" + json + "\n```")).toBe(json);
  });

  it("extracts the object from surrounding prose", () => {
    expect(extractJSONText("Here you go:\n" + json + "\nEnjoy!")).toBe(json);
  });

  it("returns brace-less input unchanged", () => {
    expect(extractJSONText("no json here")).toBe("no json here");
  });
});
