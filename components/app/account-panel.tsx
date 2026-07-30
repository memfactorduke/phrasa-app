"use client";

import { useState } from "react";
import { AUTH_COPY, accountModeLabel, signInAvailabilityMessage } from "@/lib/app/auth/copy";
import { getCloudConfig } from "@/lib/app/auth/config";
import { useApp } from "./app-provider";

export function AccountPanel() {
  const {
    cloudConfigured,
    user,
    authError,
    authNotice,
    authView,
    setAuthView,
    clearAuthError,
    signInWithApple,
    signInWithEmail,
    sendPasswordReset,
    completePasswordRecovery,
    signOut,
    clearThisBrowser,
    syncNow,
    guestImportPending,
    importGuestLibrary,
    skipGuestImport,
  } = useApp();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const config = getCloudConfig();

  async function run(action: () => Promise<void>) {
    setBusy(true);
    clearAuthError();
    try {
      await action();
    } finally {
      setBusy(false);
    }
  }

  return (
    <section
      aria-labelledby="account-heading"
      className="space-y-4 rounded-md border border-divider bg-surface p-4"
    >
      <div>
        <h2 id="account-heading" className="text-sm font-medium text-ink">
          Account
        </h2>
        <p className="mt-1 text-xs leading-relaxed text-ink-muted">
          {accountModeLabel({
            cloudConfigured,
            userId: user?.id ?? null,
            email: user?.email,
          })}
        </p>
      </div>

      {!cloudConfigured ? (
        <div className="space-y-2 border-t border-divider pt-3">
          <p className="text-sm font-medium text-ink">
            {AUTH_COPY.cloudUnavailableTitle}
          </p>
          <p className="text-xs leading-relaxed text-ink-muted">
            {AUTH_COPY.cloudUnavailableBody}
          </p>
        </div>
      ) : null}

      {cloudConfigured && !user ? (
        <div className="space-y-3 border-t border-divider pt-3">
          <p className="text-xs leading-relaxed text-ink-muted">
            {signInAvailabilityMessage(config)}
          </p>
          <button
            type="button"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-md bg-ink px-3 text-sm font-medium text-canvas transition-opacity hover:opacity-90 disabled:opacity-50"
            disabled={busy}
            onClick={() => void run(signInWithApple)}
          >
            {AUTH_COPY.applePrimaryCta}
          </button>
          {authView === "idle" ? (
            <button
              type="button"
              className="inline-flex min-h-11 w-full items-center justify-center rounded-md border border-divider px-3 text-sm text-ink-muted transition-colors hover:text-ink"
              onClick={() => setAuthView("email")}
            >
              {AUTH_COPY.emailSecondaryToggle}
            </button>
          ) : (
            <form
              className="space-y-2"
              onSubmit={(e) => {
                e.preventDefault();
                void run(() => signInWithEmail(email, password));
              }}
            >
              <label className="block text-xs text-ink-muted">
                Email
                <input
                  type="email"
                  autoComplete="email"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="mt-1 w-full min-h-11 rounded-md border border-divider bg-canvas px-3 text-sm text-ink"
                />
              </label>
              <label className="block text-xs text-ink-muted">
                Password
                <input
                  type="password"
                  autoComplete="current-password"
                  required
                  minLength={8}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="mt-1 w-full min-h-11 rounded-md border border-divider bg-canvas px-3 text-sm text-ink"
                />
              </label>
              <div className="flex flex-col gap-2">
                <button
                  type="submit"
                  disabled={busy}
                  className="inline-flex min-h-11 items-center justify-center rounded-md bg-ink px-3 text-sm font-medium text-canvas disabled:opacity-50"
                >
                  {AUTH_COPY.emailSignIn}
                </button>
                <button
                  type="button"
                  disabled={busy || !email.trim()}
                  className="inline-flex min-h-11 items-center justify-center rounded-md border border-divider px-3 text-sm text-ink-muted"
                  onClick={() => void run(() => sendPasswordReset(email))}
                >
                  {AUTH_COPY.emailPasswordReset}
                </button>
                <button
                  type="button"
                  className="text-xs text-ink-muted underline-offset-4 hover:underline"
                  onClick={() => setAuthView("idle")}
                >
                  Back
                </button>
              </div>
            </form>
          )}
        </div>
      ) : null}

      {user && authView === "recovery" ? (
        <form
          className="space-y-3 border-t border-divider pt-3"
          onSubmit={(event) => {
            event.preventDefault();
            void run(() => completePasswordRecovery(password));
          }}
        >
          <div>
            <h3 className="text-sm font-medium text-ink">Choose a new password</h3>
            <p className="mt-1 text-xs leading-relaxed text-ink-muted">
              Use at least 8 characters. This changes the password for your
              existing Phrasa account.
            </p>
          </div>
          <label className="block text-xs text-ink-muted">
            New password
            <input
              type="password"
              autoComplete="new-password"
              required
              minLength={8}
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              className="mt-1 min-h-11 w-full rounded-md border border-divider bg-canvas px-3 text-sm text-ink"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="inline-flex min-h-11 w-full items-center justify-center rounded-md bg-ink px-3 text-sm font-medium text-canvas disabled:opacity-50"
          >
            Update password
          </button>
        </form>
      ) : null}

      {user && authView !== "recovery" ? (
        <div className="space-y-2 border-t border-divider pt-3">
          <button
            type="button"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-md border border-divider px-3 text-sm text-ink"
            onClick={() => void syncNow()}
          >
            Sync now
          </button>
          <button
            type="button"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-md border border-divider px-3 text-sm text-ink-muted"
            onClick={() => void signOut()}
          >
            {AUTH_COPY.signOut}
          </button>
          <p className="text-xs leading-relaxed text-ink-muted">
            {AUTH_COPY.signOutDataSafety}
          </p>
        </div>
      ) : null}

      {guestImportPending && user ? (
        <div
          role="region"
          aria-label="Import guest scripts"
          className="space-y-2 border-t border-divider pt-3"
        >
          <p className="text-xs leading-relaxed text-ink-muted">
            {AUTH_COPY.guestImportPrompt}
          </p>
          <p className="text-xs text-ink">
            {guestImportPending.scripts.length} script
            {guestImportPending.scripts.length === 1 ? "" : "s"} ready
          </p>
          <button
            type="button"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-md bg-ink px-3 text-sm font-medium text-canvas"
            onClick={() => void importGuestLibrary()}
          >
            {AUTH_COPY.guestImportConfirm}
          </button>
          <button
            type="button"
            className="inline-flex min-h-11 w-full items-center justify-center rounded-md border border-divider px-3 text-sm text-ink-muted"
            onClick={skipGuestImport}
          >
            {AUTH_COPY.guestImportSkip}
          </button>
        </div>
      ) : null}

      {authError ? (
        <p role="alert" className="text-xs text-danger">
          {authError}
        </p>
      ) : null}
      {authNotice ? (
        <p role="status" className="text-xs text-ink">
          {authNotice}
        </p>
      ) : null}

      <div className="space-y-2 border-t border-divider pt-3">
        <button
          type="button"
          disabled={busy}
          className="inline-flex min-h-11 w-full items-center justify-center rounded-md border border-danger/40 px-3 text-sm text-danger disabled:opacity-50"
          onClick={() => {
            const confirmed = window.confirm(
              user
                ? "Clear this browser’s cached Phrasa library and settings, then sign out? Your cloud library will not be deleted."
                : "Clear this browser’s local Phrasa library and settings? This cannot be undone unless you exported a copy.",
            );
            if (confirmed) void run(clearThisBrowser);
          }}
        >
          Clear this browser
        </button>
        <p className="text-xs leading-relaxed text-ink-muted">
          {user
            ? "Removes only this browser’s cache and settings. Your synced cloud library remains."
            : "Removes this browser’s guest library and settings. Export first if you need a copy."}
        </p>
      </div>

      <p className="border-t border-divider pt-3 text-xs leading-relaxed text-ink-muted">
        {AUTH_COPY.voiceFollowNativeOnly}
      </p>
    </section>
  );
}
