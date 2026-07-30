/** Web reader settings aligned with native ReaderSettings concepts. */

export type SpeedCountdownSeconds = 0 | 5 | 15;

export type ReadingFont = "sans" | "serif" | "mono";

export type ReaderSettings = {
  font: ReadingFont;
  fontSize: number;
  lineHeight: number;
  horizontalMargin: number;
  /** Focus band vertical position (0 = top, 1 = bottom). */
  focusPosition: number;
  speedWPM: number;
  speedCountdown: SpeedCountdownSeconds;
  mirrorHorizontal: boolean;
  mirrorVertical: boolean;
};

export const DEFAULT_READER_SETTINGS: ReaderSettings = {
  font: "sans",
  fontSize: 42,
  lineHeight: 1.45,
  horizontalMargin: 0.12,
  focusPosition: 0.25,
  speedWPM: 140,
  speedCountdown: 5,
  mirrorHorizontal: false,
  mirrorVertical: false,
};

export const COUNTDOWN_OPTIONS: ReadonlyArray<{
  value: SpeedCountdownSeconds;
  label: string;
  shortLabel: string;
}> = [
  { value: 0, label: "Off", shortLabel: "Off" },
  { value: 5, label: "5 seconds", shortLabel: "5s" },
  { value: 15, label: "15 seconds", shortLabel: "15s" },
];

function clamp(n: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, n));
}

export function normalizeReaderSettings(
  input: Partial<ReaderSettings> | null | undefined,
): ReaderSettings {
  const base = { ...DEFAULT_READER_SETTINGS, ...(input ?? {}) };
  const mirrorVertical = Boolean(base.mirrorVertical);
  // Mutually exclusive, matching native feature contract.
  let mirrorHorizontal = Boolean(base.mirrorHorizontal);
  if (mirrorVertical) mirrorHorizontal = false;

  let speedCountdown: SpeedCountdownSeconds = 5;
  if (base.speedCountdown === 0 || base.speedCountdown === 5 || base.speedCountdown === 15) {
    speedCountdown = base.speedCountdown;
  }

  const font: ReadingFont =
    base.font === "serif" || base.font === "mono" || base.font === "sans"
      ? base.font
      : "sans";

  const num = (value: unknown, fallback: number) => {
    const n = typeof value === "number" ? value : Number(value);
    return Number.isFinite(n) ? n : fallback;
  };

  return {
    font,
    fontSize: clamp(num(base.fontSize, DEFAULT_READER_SETTINGS.fontSize), 20, 120),
    lineHeight: clamp(
      num(base.lineHeight, DEFAULT_READER_SETTINGS.lineHeight),
      1,
      2.4,
    ),
    horizontalMargin: clamp(
      num(base.horizontalMargin, DEFAULT_READER_SETTINGS.horizontalMargin),
      0,
      0.4,
    ),
    focusPosition: clamp(
      num(base.focusPosition, DEFAULT_READER_SETTINGS.focusPosition),
      0.15,
      0.85,
    ),
    speedWPM: clamp(num(base.speedWPM, DEFAULT_READER_SETTINGS.speedWPM), 40, 400),
    speedCountdown,
    mirrorHorizontal,
    mirrorVertical,
  };
}

/** Pure policy: show countdown when starting speed mode near the beginning. */
export function shouldBeginWithCountdown(
  progress: number,
  countdown: SpeedCountdownSeconds,
  nearStartThreshold = 0.01,
): boolean {
  return progress < nearStartThreshold && countdown > 0;
}

export function countdownDisplaySequence(
  countdown: SpeedCountdownSeconds,
): number[] {
  if (countdown <= 0) return [];
  const seq: number[] = [];
  for (let i = countdown; i >= 1; i -= 1) seq.push(i);
  return seq;
}
