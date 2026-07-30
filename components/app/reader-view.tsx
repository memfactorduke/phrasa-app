"use client";

import Link from "next/link";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { AUTH_COPY } from "@/lib/app/auth/copy";
import { wordCount } from "@/lib/app/models/metrics";
import {
  COUNTDOWN_OPTIONS,
  countdownDisplaySequence,
  shouldBeginWithCountdown,
  type SpeedCountdownSeconds,
} from "@/lib/app/models/reader-settings";
import { useApp } from "./app-provider";

type Phase = "idle" | "countdown" | "playing" | "paused" | "done";

function targetOwnsSpaceShortcut(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  return Boolean(
    target.closest(
      "button, a, input, textarea, select, [contenteditable='true'], " +
        "[role='button'], [role='link'], [role='slider'], [role='menuitem'], [role='option']",
    ),
  );
}

export function ReaderView({ scriptId }: { scriptId: string }) {
  const { ready, library, readerSettings, updateReaderSettings, touchOpened } =
    useApp();
  const script = useMemo(
    () => library.scripts.find((s) => s.id === scriptId),
    [library.scripts, scriptId],
  );

  const scrollerRef = useRef<HTMLDivElement>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [countdownLeft, setCountdownLeft] = useState<number | null>(null);
  const [progress, setProgress] = useState(0);
  const [showChrome, setShowChrome] = useState(true);
  const [showSettings, setShowSettings] = useState(false);
  const [blackout, setBlackout] = useState(false);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const rafRef = useRef<number | null>(null);
  const lastTs = useRef<number | null>(null);

  useEffect(() => {
    if (script) touchOpened(script.id);
  }, [script?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const revealChrome = useCallback(() => {
    setShowChrome(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    if (phase === "playing") {
      hideTimer.current = setTimeout(() => setShowChrome(false), 2500);
    }
  }, [phase]);

  useEffect(() => {
    if (hideTimer.current) clearTimeout(hideTimer.current);
    if (phase !== "playing") {
      // Keep chrome visible outside active playback (async to satisfy effect rules).
      const t = window.setTimeout(() => setShowChrome(true), 0);
      return () => window.clearTimeout(t);
    }
    const show = window.setTimeout(() => setShowChrome(true), 0);
    hideTimer.current = setTimeout(() => setShowChrome(false), 2500);
    return () => {
      window.clearTimeout(show);
      if (hideTimer.current) clearTimeout(hideTimer.current);
    };
  }, [phase]);

  const maxScroll = useCallback(() => {
    const el = scrollerRef.current;
    if (!el) return 0;
    return Math.max(0, el.scrollHeight - el.clientHeight);
  }, []);

  const applyProgress = useCallback(
    (p: number) => {
      const el = scrollerRef.current;
      if (!el) return;
      const clamped = Math.min(1, Math.max(0, p));
      setProgress(clamped);
      const max = maxScroll();
      el.scrollTop = max * clamped;
      if (clamped >= 0.999 && max > 0) {
        setPhase("done");
      }
    },
    [maxScroll],
  );

  // Continuous scroll from actual word count and the measured scroll range.
  useEffect(() => {
    if (phase !== "playing") {
      lastTs.current = null;
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      return;
    }

    const durationSeconds = Math.max(
      1,
      (wordCount(script?.body ?? "") / readerSettings.speedWPM) * 60,
    );
    const resetFrameClock = () => {
      lastTs.current = null;
    };
    document.addEventListener("visibilitychange", resetFrameClock);

    const tick = (ts: number) => {
      if (lastTs.current == null) lastTs.current = ts;
      // A backgrounded/suspended tab must not jump forward on its first frame.
      const dt = Math.min(0.1, Math.max(0, (ts - lastTs.current) / 1000));
      lastTs.current = ts;
      const el = scrollerRef.current;
      if (!el) {
        rafRef.current = requestAnimationFrame(tick);
        return;
      }
      const max = Math.max(0, el.scrollHeight - el.clientHeight);
      if (max <= 0) {
        setPhase("done");
        return;
      }
      const pxPerSecond = max / durationSeconds;
      const next = el.scrollTop + pxPerSecond * dt;
      if (next >= max) {
        el.scrollTop = max;
        setProgress(1);
        setPhase("done");
        return;
      }
      el.scrollTop = next;
      setProgress(next / max);
      rafRef.current = requestAnimationFrame(tick);
    };

    rafRef.current = requestAnimationFrame(tick);
    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      document.removeEventListener("visibilitychange", resetFrameClock);
    };
  }, [phase, readerSettings.speedWPM, script?.body]);

  useEffect(() => {
    if (phase !== "countdown" || countdownLeft == null) return;
    const t = window.setTimeout(() => {
      if (countdownLeft <= 1) {
        setCountdownLeft(null);
        setPhase("playing");
      } else {
        setCountdownLeft(countdownLeft - 1);
      }
    }, 1000);
    return () => window.clearTimeout(t);
  }, [phase, countdownLeft]);

  const start = useCallback(() => {
    const countdown = readerSettings.speedCountdown;
    if (shouldBeginWithCountdown(progress, countdown)) {
      const seq = countdownDisplaySequence(countdown);
      setCountdownLeft(seq[0] ?? countdown);
      setPhase("countdown");
    } else {
      setPhase("playing");
    }
  }, [progress, readerSettings.speedCountdown]);

  const togglePlay = useCallback(() => {
    if (phase === "playing") {
      setPhase("paused");
      return;
    }
    if (phase === "countdown") {
      setPhase("paused");
      setCountdownLeft(null);
      return;
    }
    if (phase === "done") {
      applyProgress(0);
      setPhase("idle");
      return;
    }
    start();
  }, [phase, start, applyProgress]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (targetOwnsSpaceShortcut(e.target)) {
        return;
      }
      if (e.key === " " || e.code === "Space") {
        e.preventDefault();
        togglePlay();
        revealChrome();
      } else if (e.key === "Escape") {
        if (blackout) {
          setBlackout(false);
        } else if (showSettings) {
          setShowSettings(false);
        }
      } else if (e.key === "b" || e.key === "B") {
        setBlackout((v) => !v);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        updateReaderSettings({
          speedWPM: Math.min(400, readerSettings.speedWPM + 10),
        });
        revealChrome();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        updateReaderSettings({
          speedWPM: Math.max(40, readerSettings.speedWPM - 10),
        });
        revealChrome();
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        applyProgress(progress - 0.02);
        revealChrome();
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        applyProgress(progress + 0.02);
        revealChrome();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [
    togglePlay,
    revealChrome,
    blackout,
    showSettings,
    updateReaderSettings,
    readerSettings.speedWPM,
    applyProgress,
    progress,
  ]);

  const mirrorTransform = [
    readerSettings.mirrorHorizontal ? "scaleX(-1)" : "",
    readerSettings.mirrorVertical ? "scaleY(-1)" : "",
  ]
    .filter(Boolean)
    .join(" ");

  const fontFamily =
    readerSettings.font === "serif"
      ? "ui-serif, Georgia, Cambria, Times, serif"
      : readerSettings.font === "mono"
        ? "ui-monospace, SFMono-Regular, Menlo, monospace"
        : "var(--font-sans), ui-sans-serif, system-ui, sans-serif";

  const displayedFocusPosition = readerSettings.mirrorVertical
    ? 1 - readerSettings.focusPosition
    : readerSettings.focusPosition;

  if (!ready) {
    return (
      <div className="flex min-h-full items-center justify-center bg-canvas text-ink-muted">
        Loading reader…
      </div>
    );
  }

  if (!script) {
    return (
      <div className="flex min-h-full flex-col items-center justify-center gap-3 bg-canvas px-5 text-ink">
        <p>Script not found.</p>
        <Link href="/app" className="underline-offset-4 hover:underline">
          Back to library
        </Link>
      </div>
    );
  }

  return (
    <main
      className="relative flex h-dvh flex-col bg-canvas text-ink"
      data-testid="reader-root"
      onPointerDown={revealChrome}
      tabIndex={-1}
    >
      {blackout ? (
        <button
          type="button"
          className="absolute inset-0 z-40 bg-black"
          data-testid="blackout"
          aria-label="Blackout on. Press B or Escape to exit."
          onClick={() => setBlackout(false)}
        />
      ) : null}

      {showChrome ? (
        <header className="z-30 flex flex-wrap items-center justify-between gap-2 border-b border-divider bg-canvas/95 px-3 py-2 backdrop-blur-sm sm:px-4">
          <div className="flex min-h-11 flex-wrap items-center gap-2">
            <Link
              href={`/app/scripts/${script.id}`}
              className="inline-flex min-h-11 items-center px-2 text-sm text-ink-muted hover:text-ink"
            >
              Edit
            </Link>
            <Link
              href="/app"
              className="inline-flex min-h-11 items-center px-2 text-sm text-ink-muted hover:text-ink"
            >
              Library
            </Link>
            <span className="hidden text-sm text-ink sm:inline">{script.title}</span>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-ink-muted" data-testid="reader-wpm">
              {Math.round(readerSettings.speedWPM)} WPM
            </span>
            <button
              type="button"
              data-testid="reader-play"
              className="inline-flex min-h-11 items-center rounded-md bg-ink px-3 text-sm font-medium text-canvas"
              onClick={togglePlay}
            >
              {phase === "playing"
                ? "Pause"
                : phase === "countdown"
                  ? "Cancel"
                  : phase === "done"
                    ? "Restart"
                    : "Play"}
            </button>
            <button
              type="button"
              data-testid="reader-settings-toggle"
              className="inline-flex min-h-11 items-center rounded-md border border-divider px-3 text-sm text-ink"
              onClick={() => setShowSettings((v) => !v)}
              aria-expanded={showSettings}
            >
              Settings
            </button>
            <button
              type="button"
              className="inline-flex min-h-11 items-center rounded-md border border-divider px-3 text-sm text-ink-muted"
              onClick={() => setBlackout(true)}
            >
              Blackout
            </button>
          </div>
        </header>
      ) : null}

      {showSettings ? (
        <div
          className="z-30 border-b border-divider bg-surface px-4 py-4"
          data-testid="reader-settings"
        >
          <div className="mx-auto grid max-w-3xl gap-4 sm:grid-cols-2">
            <label className="block text-xs text-ink-muted">
              Countdown
              <select
                data-testid="countdown-select"
                className="mt-1 w-full min-h-11 rounded-md border border-divider bg-canvas px-2 text-sm text-ink"
                value={readerSettings.speedCountdown}
                onChange={(e) =>
                  updateReaderSettings({
                    speedCountdown: Number(e.target.value) as SpeedCountdownSeconds,
                  })
                }
              >
                {COUNTDOWN_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-xs text-ink-muted">
              Speed (WPM)
              <input
                type="range"
                min={40}
                max={400}
                step={5}
                data-testid="wpm-range"
                value={readerSettings.speedWPM}
                onChange={(e) =>
                  updateReaderSettings({ speedWPM: Number(e.target.value) })
                }
                className="mt-3 w-full"
              />
            </label>
            <label className="block text-xs text-ink-muted">
              Font size
              <input
                type="range"
                min={20}
                max={120}
                step={1}
                data-testid="font-size-range"
                value={readerSettings.fontSize}
                onChange={(e) =>
                  updateReaderSettings({ fontSize: Number(e.target.value) })
                }
                className="mt-3 w-full"
              />
            </label>
            <label className="block text-xs text-ink-muted">
              Focus line position
              <input
                type="range"
                min={15}
                max={85}
                step={1}
                data-testid="focus-range"
                value={Math.round(readerSettings.focusPosition * 100)}
                onChange={(e) =>
                  updateReaderSettings({
                    focusPosition: Number(e.target.value) / 100,
                  })
                }
                className="mt-3 w-full"
              />
            </label>
            <label className="block text-xs text-ink-muted">
              Side margins
              <input
                type="range"
                min={0}
                max={40}
                step={1}
                data-testid="margin-range"
                value={Math.round(readerSettings.horizontalMargin * 100)}
                onChange={(e) =>
                  updateReaderSettings({
                    horizontalMargin: Number(e.target.value) / 100,
                  })
                }
                className="mt-3 w-full"
              />
            </label>
            <label className="block text-xs text-ink-muted">
              Typeface
              <select
                className="mt-1 w-full min-h-11 rounded-md border border-divider bg-canvas px-2 text-sm text-ink"
                value={readerSettings.font}
                onChange={(e) =>
                  updateReaderSettings({
                    font: e.target.value as "sans" | "serif" | "mono",
                  })
                }
              >
                <option value="sans">Sans</option>
                <option value="serif">Serif</option>
                <option value="mono">Mono</option>
              </select>
            </label>
            <label className="flex min-h-11 items-center gap-2 text-sm text-ink">
              <input
                type="checkbox"
                data-testid="mirror-h"
                checked={readerSettings.mirrorHorizontal}
                onChange={(e) =>
                  updateReaderSettings({
                    mirrorHorizontal: e.target.checked,
                    mirrorVertical: e.target.checked
                      ? false
                      : readerSettings.mirrorVertical,
                  })
                }
              />
              Mirror horizontal
            </label>
            <label className="flex min-h-11 items-center gap-2 text-sm text-ink">
              <input
                type="checkbox"
                data-testid="mirror-v"
                checked={readerSettings.mirrorVertical}
                onChange={(e) =>
                  updateReaderSettings({
                    mirrorVertical: e.target.checked,
                    mirrorHorizontal: e.target.checked
                      ? false
                      : readerSettings.mirrorHorizontal,
                  })
                }
              />
              Mirror vertical
            </label>
          </div>
          <p className="mx-auto mt-4 max-w-3xl text-xs leading-relaxed text-ink-muted">
            {AUTH_COPY.noMicControls} {AUTH_COPY.voiceFollowNativeOnly}
          </p>
          <p className="mx-auto mt-2 max-w-3xl text-xs text-ink-muted">
            Keys: Space play/pause · ↑/↓ WPM · ←/→ nudge · B blackout · Esc close
          </p>
        </div>
      ) : null}

      {phase === "countdown" && countdownLeft != null ? (
        <div
          className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center"
          data-testid="countdown-overlay"
          role="status"
          aria-live="assertive"
        >
          <span className="text-7xl font-medium tabular-nums text-ink sm:text-8xl">
            {countdownLeft}
          </span>
        </div>
      ) : null}

      {/* Focus line */}
      <div
        data-testid="reader-focus-line"
        className="pointer-events-none absolute left-0 right-0 z-10 border-t border-ink/40"
        style={{ top: `${displayedFocusPosition * 100}%` }}
        aria-hidden
      />

      <div
        ref={scrollerRef}
        data-testid="reader-scroller"
        className="relative flex-1 overflow-y-auto"
        onScroll={(e) => {
          const el = e.currentTarget;
          const max = el.scrollHeight - el.clientHeight;
          if (max > 0) setProgress(el.scrollTop / max);
        }}
      >
        <div
          data-testid="reader-text"
          className="mx-auto whitespace-pre-wrap py-[40vh]"
          style={{
            fontFamily,
            fontSize: `${readerSettings.fontSize}px`,
            lineHeight: readerSettings.lineHeight,
            paddingLeft: `${readerSettings.horizontalMargin * 100}%`,
            paddingRight: `${readerSettings.horizontalMargin * 100}%`,
            transform: mirrorTransform || undefined,
            transformOrigin: "center center",
          }}
        >
          {script.body || "This script is empty."}
        </div>
      </div>

      {phase === "done" ? (
        <div
          className="absolute inset-x-0 bottom-0 z-20 border-t border-divider bg-surface px-4 py-4"
          data-testid="reader-done"
        >
          <p className="text-sm text-ink">Rehearsal complete.</p>
          <p className="mt-1 text-xs text-ink-muted">
            This rehearsal is complete. Session history and Voice Follow recap
            are native-only.
          </p>
          <button
            type="button"
            className="mt-3 inline-flex min-h-11 items-center rounded-md bg-ink px-3 text-sm font-medium text-canvas"
            onClick={() => {
              applyProgress(0);
              setPhase("idle");
            }}
          >
            Back to start
          </button>
        </div>
      ) : null}
    </main>
  );
}
