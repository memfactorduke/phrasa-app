import { describe, expect, it } from "vitest";
import {
  estimatedDurationSeconds,
  estimatedSecondsRounded,
  previewText,
  wordCount,
} from "./metrics";

describe("text metrics", () => {
  it("counts words like native TextMetrics", () => {
    expect(wordCount("")).toBe(0);
    expect(wordCount("   ")).toBe(0);
    expect(wordCount("hello")).toBe(1);
    expect(wordCount("hello world")).toBe(2);
    expect(wordCount("  one   two\nthree  ")).toBe(3);
  });

  it("estimates duration at 150 WPM by default", () => {
    // 150 words → 60 seconds
    const body = Array.from({ length: 150 }, () => "word").join(" ");
    expect(estimatedDurationSeconds(body)).toBeCloseTo(60, 5);
    expect(estimatedSecondsRounded(body)).toBe(60);
  });

  it("previews flattened body text", () => {
    expect(previewText("a\n\nb  c")).toBe("a b c");
    expect(previewText("x".repeat(200)).length).toBe(180);
  });
});
