import { describe, expect, it } from "vitest";
import {
  countdownDisplaySequence,
  DEFAULT_READER_SETTINGS,
  normalizeReaderSettings,
  shouldBeginWithCountdown,
} from "./reader-settings";

describe("reader settings", () => {
  it("defaults countdown to 5 seconds", () => {
    expect(DEFAULT_READER_SETTINGS.speedCountdown).toBe(5);
    expect(normalizeReaderSettings({}).speedCountdown).toBe(5);
  });

  it("accepts Off / 5 / 15 only", () => {
    expect(normalizeReaderSettings({ speedCountdown: 0 }).speedCountdown).toBe(0);
    expect(normalizeReaderSettings({ speedCountdown: 15 }).speedCountdown).toBe(15);
    expect(
      normalizeReaderSettings({ speedCountdown: 7 as 5 }).speedCountdown,
    ).toBe(5);
  });

  it("clamps WPM, font size, focus, and margins", () => {
    const s = normalizeReaderSettings({
      speedWPM: 10,
      fontSize: 500,
      focusPosition: 0,
      horizontalMargin: 0.9,
    });
    expect(s.speedWPM).toBe(40);
    expect(s.fontSize).toBe(120);
    expect(s.focusPosition).toBe(0.15);
    expect(s.horizontalMargin).toBe(0.4);
  });

  it("makes horizontal and vertical mirror mutually exclusive", () => {
    const s = normalizeReaderSettings({
      mirrorHorizontal: true,
      mirrorVertical: true,
    });
    expect(s.mirrorVertical).toBe(true);
    expect(s.mirrorHorizontal).toBe(false);
  });

  it("countdown policy matches near-start speed starts", () => {
    expect(shouldBeginWithCountdown(0, 5)).toBe(true);
    expect(shouldBeginWithCountdown(0.5, 5)).toBe(false);
    expect(shouldBeginWithCountdown(0, 0)).toBe(false);
    expect(countdownDisplaySequence(5)).toEqual([5, 4, 3, 2, 1]);
    expect(countdownDisplaySequence(0)).toEqual([]);
  });
});
