import Link from "next/link";
import type { Metadata } from "next";
import { SiteShell } from "@/components/site/site-shell";

export const metadata: Metadata = { title: "Not found" };

export default function NotFound() {
  return (
    <SiteShell>
      <div className="mx-auto max-w-3xl px-5 py-24 text-center">
        <p className="text-xs font-medium uppercase tracking-[0.18em] text-ink-muted">
          404
        </p>
        <h1 className="mt-4 text-3xl font-medium tracking-tight sm:text-4xl">
          Page not found
        </h1>
        <p className="mx-auto mt-4 max-w-md text-ink-muted">
          That address does not exist. You can return to the product site or
          open the web companion for its browser library, editor, and speed
          teleprompter.
        </p>
        <div className="mt-8 flex flex-wrap justify-center gap-3">
          <Link
            href="/"
            className="inline-flex min-h-11 items-center justify-center rounded-[var(--radius-md)] bg-ink px-6 text-sm font-medium text-canvas"
          >
            Back to home
          </Link>
          <Link
            href="/app"
            className="inline-flex min-h-11 items-center justify-center rounded-[var(--radius-md)] border border-divider px-6 text-sm font-medium text-ink"
          >
            Open web companion
          </Link>
        </div>
      </div>
    </SiteShell>
  );
}
