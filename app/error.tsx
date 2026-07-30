"use client";

import { useEffect } from "react";
import Link from "next/link";

export default function AppError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="grid min-h-dvh place-items-center bg-canvas px-5 text-center text-ink">
      <div className="max-w-md">
        <p className="text-xs font-medium uppercase tracking-[0.18em] text-ink-muted">
          Error
        </p>
        <h1 className="mt-4 text-3xl font-medium tracking-tight">
          Something went wrong
        </h1>
        <p className="mt-3 text-sm text-ink-muted">
          An unexpected error interrupted this page. Try again, or return home.
        </p>
        {error.digest && (
          <p className="mt-4 text-xs text-ink-muted">
            Reference: {error.digest}
          </p>
        )}
        <div className="mt-8 flex flex-wrap justify-center gap-3">
          <button
            type="button"
            onClick={reset}
            className="inline-flex min-h-11 items-center justify-center rounded-[var(--radius-md)] bg-ink px-6 text-sm font-medium text-canvas"
          >
            Try again
          </button>
          <Link
            href="/"
            className="inline-flex min-h-11 items-center justify-center rounded-[var(--radius-md)] border border-divider px-6 text-sm font-medium text-ink"
          >
            Home
          </Link>
        </div>
      </div>
    </div>
  );
}
