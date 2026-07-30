import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getCloudConfig } from "./config";

let cached: SupabaseClient | null | undefined;

/**
 * Browser Supabase client (publishable key only).
 * Returns null when cloud env vars are absent so guest mode stays fully offline.
 */
export function getSupabaseBrowserClient(): SupabaseClient | null {
  if (cached !== undefined) return cached;
  const config = getCloudConfig();
  if (!config.configured) {
    cached = null;
    return null;
  }
  cached = createClient(config.url, config.publishableKey, {
    auth: {
      flowType: "pkce",
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
      storageKey: "phrasa.web.auth",
    },
  });
  return cached;
}

/** Test helper to clear the module cache. */
export function resetSupabaseBrowserClientForTests(): void {
  cached = undefined;
}

export function authCallbackUrl(origin: string): string {
  return `${origin.replace(/\/+$/, "")}/auth/callback`;
}

export function passwordRecoveryCallbackUrl(origin: string): string {
  return `${authCallbackUrl(origin)}?recovery=1`;
}
