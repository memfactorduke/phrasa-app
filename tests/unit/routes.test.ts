import { existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { appRoutes, publicRoutes, retiredRoutes } from "@/lib/site";

const root = join(__dirname, "../..");
const appDir = join(root, "app");

function listPageRoutes(dir: string, base = ""): string[] {
  if (!existsSync(dir)) return [];
  const routes: string[] = [];
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".") || entry === "favicon.ico") continue;
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      if (entry.startsWith("(")) {
        routes.push(...listPageRoutes(full, base));
        continue;
      }
      if (entry.startsWith("[")) {
        routes.push(...listPageRoutes(full, `${base}/${entry}`));
        continue;
      }
      routes.push(...listPageRoutes(full, `${base}/${entry}`));
    } else if (
      entry === "page.tsx" ||
      entry === "page.ts" ||
      entry === "page.js"
    ) {
      routes.push(base || "/");
    }
  }
  return routes;
}

describe("public marketing routes", () => {
  it("ships marketing pages for the four public routes", () => {
    expect(existsSync(join(appDir, "page.tsx"))).toBe(true);
    expect(existsSync(join(appDir, "privacy/page.tsx"))).toBe(true);
    expect(existsSync(join(appDir, "terms/page.tsx"))).toBe(true);
    expect(existsSync(join(appDir, "support/page.tsx"))).toBe(true);
    expect([...publicRoutes]).toEqual([
      "/",
      "/privacy",
      "/terms",
      "/support",
    ]);
  });

  it("exposes robots and sitemap metadata routes", () => {
    expect(existsSync(join(appDir, "robots.ts"))).toBe(true);
    expect(existsSync(join(appDir, "sitemap.ts"))).toBe(true);
  });
});

describe("web companion routes", () => {
  it("ships /app library, editor, reader, and auth callback pages", () => {
    expect(existsSync(join(appDir, "app/page.tsx"))).toBe(true);
    expect(existsSync(join(appDir, "app/scripts/[id]/page.tsx"))).toBe(true);
    expect(existsSync(join(appDir, "app/scripts/[id]/read/page.tsx"))).toBe(
      true,
    );
    expect(existsSync(join(appDir, "auth/callback/page.tsx"))).toBe(true);
    expect(appRoutes).toContain("/app");
    expect(appRoutes).toContain("/auth/callback");
  });

  it("lists companion pages among discovered routes", () => {
    const pages = listPageRoutes(appDir);
    expect(pages).toContain("/app");
    expect(pages).toContain("/auth/callback");
    expect(pages).toContain("/app/scripts/[id]");
    expect(pages).toContain("/app/scripts/[id]/read");
  });
});

describe("retired browser-product routes", () => {
  it("does not keep page or route handlers for retired paths", () => {
    const checks: Array<[string, string]> = [
      ["/library", "app/(app)/library"],
      ["/editor", "app/(app)/editor"],
      ["/read", "app/read"],
      ["/login", "app/(auth)/login"],
      ["/signup", "app/(auth)/signup"],
      ["/forgot-password", "app/(auth)/forgot-password"],
      ["/account", "app/(app)/account"],
      ["/pricing", "app/pricing"],
      ["/offline", "app/offline"],
      ["/api/ai", "app/api/ai"],
      ["/api/billing", "app/api/billing"],
      ["/api/analytics", "app/api/analytics"],
      ["/api/webhooks", "app/api/webhooks"],
      ["/api/account", "app/api/account"],
    ];

    for (const [route, rel] of checks) {
      expect(retiredRoutes as readonly string[]).toContain(route);
      expect(existsSync(join(root, rel)), `${rel} should be deleted`).toBe(
        false,
      );
    }
  });

  it("does not ship PWA service worker or web proxy session middleware", () => {
    expect(existsSync(join(root, "public/sw.js"))).toBe(false);
    expect(existsSync(join(root, "proxy.ts"))).toBe(false);
    expect(existsSync(join(root, "app/manifest.ts"))).toBe(false);
    expect(existsSync(join(root, "components/pwa-register.tsx"))).toBe(false);
  });

  it("allows companion modules but forbids billing/AI service-role surfaces", () => {
    expect(existsSync(join(root, "lib/billing"))).toBe(false);
    expect(existsSync(join(root, "lib/ai"))).toBe(false);
    // Web companion auth/config lives under lib/app — publishable key only.
    expect(existsSync(join(root, "lib/app/auth/config.ts"))).toBe(true);
    expect(existsSync(join(root, "lib/app/auth/client.ts"))).toBe(true);
  });

  it("keeps active supabase sync baseline + ACL remediation only (no billing chain)", () => {
    const migrationsDir = join(root, "supabase/migrations");
    expect(existsSync(migrationsDir)).toBe(true);
    const migrations = readdirSync(migrationsDir)
      .filter((f) => f.endsWith(".sql"))
      .sort();
    expect(migrations).toEqual([
      "20260719000000_native_sync_baseline.sql",
      "20260719000001_sync_table_acl_remediation.sql",
    ]);
    expect(
      existsSync(
        join(
          root,
          "supabase/archive/historical-migrations-pre-sync-baseline/README.md",
        ),
      ),
    ).toBe(true);
  });
});
