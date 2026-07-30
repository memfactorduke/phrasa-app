"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { getCloudConfig } from "@/lib/app/auth/config";
import { getSupabaseBrowserClient } from "@/lib/app/auth/client";
import { AUTH_COPY } from "@/lib/app/auth/copy";

/**
 * OAuth / email confirmation callback.
 * Exchanges `?code=` for a session when cloud is configured; otherwise explains guest mode.
 */
export default function AuthCallbackPage() {
  const router = useRouter();
  const [message, setMessage] = useState("Completing sign-in…");
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function complete() {
      const config = getCloudConfig();
      if (!config.configured) {
        if (!cancelled) {
          setFailed(true);
          setMessage(AUTH_COPY.cloudUnavailableSignInHint);
        }
        return;
      }

      const client = getSupabaseBrowserClient();
      if (!client) {
        if (!cancelled) {
          setFailed(true);
          setMessage(AUTH_COPY.cloudUnavailableSignInHint);
        }
        return;
      }

      const url = new URL(window.location.href);
      const code = url.searchParams.get("code");
      const oauthError =
        url.searchParams.get("error_description") ||
        url.searchParams.get("error");
      const isRecovery = url.searchParams.get("recovery") === "1";

      if (oauthError) {
        if (!cancelled) {
          setFailed(true);
          setMessage(
            "Sign-in could not be completed. Return to the web app and try again.",
          );
        }
        return;
      }

      if (code) {
        const { error } = await client.auth.exchangeCodeForSession(code);
        if (error) {
          if (!cancelled) {
            setFailed(true);
            setMessage(
              "This sign-in link could not be completed. It may have expired; return to the web app and try again.",
            );
          }
          return;
        }
      } else {
        // Hash tokens (implicit) or already-established session.
        const { data, error } = await client.auth.getSession();
        if (error) {
          if (!cancelled) {
            setFailed(true);
            setMessage(
              "This sign-in session could not be completed. Return to the web app and try again.",
            );
          }
          return;
        }
        if (!data.session) {
          if (!cancelled) {
            setFailed(true);
            setMessage(
              "No authorization code or session was found. Try signing in again from the web app.",
            );
          }
          return;
        }
      }

      if (!cancelled) {
        setMessage(
          isRecovery
            ? "Opening password recovery…"
            : "Signed in. Opening your library…",
        );
        router.replace(isRecovery ? "/app?recovery=1" : "/app");
      }
    }

    void complete();
    return () => {
      cancelled = true;
    };
  }, [router]);

  return (
    <main className="mx-auto flex min-h-full max-w-md flex-col justify-center gap-4 px-5 py-16 text-ink">
      <h1 className="text-xl font-medium tracking-tight">Sign-in</h1>
      <p
        role="status"
        className={`text-sm leading-relaxed ${failed ? "text-danger" : "text-ink-muted"}`}
        data-testid="auth-callback-status"
      >
        {message}
      </p>
      <div className="flex flex-wrap gap-3 text-sm">
        <Link
          href="/app"
          className="inline-flex min-h-11 items-center text-ink underline-offset-4 hover:underline"
        >
          Open web app
        </Link>
        <Link
          href="/"
          className="inline-flex min-h-11 items-center text-ink-muted underline-offset-4 hover:underline"
        >
          Home
        </Link>
      </div>
    </main>
  );
}
