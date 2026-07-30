"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { Logo } from "@/components/brand/logo";
import { useApp } from "./app-provider";
import { AccountPanel } from "./account-panel";

export function AppShell({
  children,
  title,
  actions,
}: {
  children: ReactNode;
  title?: string;
  actions?: ReactNode;
}) {
  const pathname = usePathname();
  const { ready, syncStatus, persistenceIssue } = useApp();
  const inReader = pathname?.includes("/read");

  function downloadRecoveryCopy(raw: string) {
    const blob = new Blob([raw], { type: "application/json;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `phrasa-browser-recovery-${new Date()
      .toISOString()
      .replace(/[:.]/g, "-")}.json`;
    link.click();
    URL.revokeObjectURL(url);
  }

  if (inReader) {
    return <>{children}</>;
  }

  return (
    <div className="flex min-h-full flex-col bg-canvas text-ink">
      <a href="#app-main" className="skip-link">
        Skip to app
      </a>
      <header className="border-b border-divider">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-4 py-3 sm:px-5">
          <div className="flex min-h-11 items-center gap-4">
            <Logo href="/app" />
            {title ? (
              <h1 className="text-sm font-medium text-ink-muted sm:text-base">
                {title}
              </h1>
            ) : null}
          </div>
          <div className="flex flex-wrap items-center gap-2 sm:gap-3">
            {actions}
            <Link
              href="/"
              className="inline-flex min-h-11 items-center px-2 text-sm text-ink-muted transition-colors hover:text-ink"
            >
              Marketing
            </Link>
          </div>
        </div>
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-2 border-t border-divider px-4 py-2 text-xs text-ink-muted sm:px-5">
          <p role="status" aria-live="polite">
            {ready ? syncStatus.message : "Loading library…"}
            {syncStatus.lastSyncedAt
              ? ` · ${new Date(syncStatus.lastSyncedAt).toLocaleString()}`
              : null}
          </p>
          {syncStatus.detail ? (
            <p className="max-w-md text-right text-ink-muted">{syncStatus.detail}</p>
          ) : null}
        </div>
      </header>
      {persistenceIssue ? (
        <div
          role="alert"
          className="mx-auto mt-4 flex w-[calc(100%-2rem)] max-w-5xl flex-wrap items-center justify-between gap-3 rounded-md border border-danger/40 bg-surface px-4 py-3 text-sm text-danger sm:w-[calc(100%-2.5rem)]"
        >
          <p className="max-w-3xl leading-relaxed">{persistenceIssue.message}</p>
          {persistenceIssue.recoveryRaw !== undefined ? (
            <button
              type="button"
              className="inline-flex min-h-11 items-center justify-center rounded-md border border-danger/40 px-3 font-medium"
              onClick={() =>
                downloadRecoveryCopy(persistenceIssue.recoveryRaw ?? "")
              }
            >
              Download recovery copy
            </button>
          ) : null}
        </div>
      ) : null}
      <div className="mx-auto grid w-full max-w-5xl flex-1 gap-6 px-4 py-6 sm:px-5 lg:grid-cols-[minmax(0,1fr)_16rem]">
        <main id="app-main" tabIndex={-1} className="min-w-0 outline-none">
          {children}
        </main>
        <aside className="min-w-0 lg:border-l lg:border-divider lg:pl-6">
          <AccountPanel />
        </aside>
      </div>
    </div>
  );
}
