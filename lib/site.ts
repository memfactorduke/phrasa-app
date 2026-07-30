/**
 * Public site configuration. Marketing pages render without product secrets.
 * The optional web companion at `/app` uses guest localStorage always; cloud
 * auth/sync only when Phrasa Supabase publishable env vars are present.
 */

const DEFAULT_SITE_URL = "https://phrasa.app";

/**
 * Public base URL for canonicals, Open Graph, sitemap, and robots.
 * Resolution: explicit env → Vercel/Netlify host → production default.
 */
export function resolveSiteUrl(): string {
  const explicit = process.env.NEXT_PUBLIC_SITE_URL;
  if (explicit) return explicit.replace(/\/+$/, "");

  if (process.env.VERCEL_URL) return `https://${process.env.VERCEL_URL}`;
  const netlify = process.env.DEPLOY_PRIME_URL ?? process.env.URL;
  if (netlify) return netlify.replace(/\/+$/, "");

  return DEFAULT_SITE_URL;
}

export const siteUrl = resolveSiteUrl();

export const siteName = "Phrasa";

export const sourceCodeUrl = "https://github.com/memfactorduke/phrasa-app";

export const siteDescription =
  "An open-source, local-first teleprompter for iPhone and iPad, with a browser companion for scripts and speed prompting and a prerelease Mac workspace. Voice Follow is native-only on iOS.";

/**
 * Public App Store URL when the listing is live.
 * Empty until a public apps.apple.com URL exists in the repository.
 * App Store Connect app ID `6780259086` (com.phrasa.app) is recorded for
 * release ops, but is not a public download link.
 */
export const appStoreUrl: string | null = null;

export const platforms = ["iPhone", "iPad", "Web", "Mac prerelease"] as const;

/** Indexed marketing routes (sitemap). */
export const publicRoutes = ["/", "/privacy", "/terms", "/support"] as const;

/** Product app routes (not marketing-only; may be noindex). */
export const appRoutes = [
  "/app",
  "/app/scripts/[id]",
  "/app/scripts/[id]/read",
  "/auth/callback",
] as const;

/** Retired browser-product routes — must not ship as pages. */
export const retiredRoutes = [
  "/library",
  "/editor",
  "/read",
  "/login",
  "/signup",
  "/forgot-password",
  "/account",
  "/pricing",
  "/offline",
  "/api/ai",
  "/api/billing",
  "/api/analytics",
  "/api/webhooks",
  "/api/account",
] as const;
