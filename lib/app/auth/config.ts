/**
 * Browser Supabase configuration for the web companion.
 * Uses publishable (anon) key only — never a service-role secret.
 */

export const SUPABASE_URL_ENV = "NEXT_PUBLIC_PHRASA_SUPABASE_URL";
export const SUPABASE_PUBLISHABLE_KEY_ENV =
  "NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY";

export type CloudConfig =
  | { configured: true; url: string; publishableKey: string }
  | { configured: false; url: null; publishableKey: null };

function decodeJwtPayload(key: string): Record<string, unknown> | null {
  const components = key.split(".");
  if (components.length !== 3 || typeof globalThis.atob !== "function") {
    return null;
  }

  try {
    const base64 = components[1]
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(Math.ceil(components[1].length / 4) * 4, "=");
    const parsed: unknown = JSON.parse(globalThis.atob(base64));
    return parsed !== null && typeof parsed === "object"
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

/** Fail closed before a key can be bundled into browser JavaScript. */
export function isPrivilegedSupabaseKey(key: string): boolean {
  const normalized = key.trim().toLowerCase();
  if (
    normalized.startsWith("sb_secret_") ||
    normalized.includes("service_role")
  ) {
    return true;
  }

  const role = decodeJwtPayload(key)?.role;
  return typeof role === "string" && role.toLowerCase() === "service_role";
}

export function resolveCloudConfig(
  env: Record<string, string | undefined> = typeof process !== "undefined"
    ? process.env
    : {},
): CloudConfig {
  const url = env[SUPABASE_URL_ENV]?.trim() || undefined;
  const publishableKey = env[SUPABASE_PUBLISHABLE_KEY_ENV]?.trim() || undefined;
  if (url && publishableKey && !isPrivilegedSupabaseKey(publishableKey)) {
    return { configured: true, url, publishableKey };
  }
  return { configured: false, url: null, publishableKey: null };
}

/** Runtime helper for client modules that read process.env at call time. */
export function isCloudConfigured(): boolean {
  return resolveCloudConfig().configured;
}

export function getCloudConfig(): CloudConfig {
  // Next.js only inlines NEXT_PUBLIC_* values when their exact property names
  // appear statically in source. Dynamic process.env[name] lookups remain
  // undefined in browser bundles.
  return resolveCloudConfig({
    [SUPABASE_URL_ENV]:
      typeof process !== "undefined"
        ? process.env.NEXT_PUBLIC_PHRASA_SUPABASE_URL
        : undefined,
    [SUPABASE_PUBLISHABLE_KEY_ENV]:
      typeof process !== "undefined"
        ? process.env.NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY
        : undefined,
  });
}
