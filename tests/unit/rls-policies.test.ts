import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Authorization-model guardrail for the sync-only product.
 * Full behavioral RLS testing (user A cannot read user B) needs live Postgres.
 * This parses committed active migrations and pins invariants a future
 * migration could silently break.
 */
const DIR = join(process.cwd(), "supabase", "migrations");

const sql = readdirSync(DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => readFileSync(join(DIR, f), "utf8"))
  .join("\n")
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ");

/** Each `create policy … ;` statement (they span multiple lines). */
function policyStatements(text: string): string[] {
  return text.match(/create\s+policy[\s\S]*?;/gi) ?? [];
}

describe("RLS authorization model (migration guardrails)", () => {
  const policies = policyStatements(sql);

  it("defines RLS policies", () => {
    expect(policies.length).toBeGreaterThan(0);
  });

  it("scopes every policy by auth.uid() — no accidentally-open policy", () => {
    for (const p of policies) {
      expect(
        /auth\.uid\(\)/.test(p),
        `policy is not scoped by auth.uid():\n${p}`,
      ).toBe(true);
      expect(
        /using\s*\(\s*true\s*\)/i.test(p),
        `open using (true) policy:\n${p}`,
      ).toBe(false);
    }
  });

  it("restricts policies to authenticated (anonymous access must not work)", () => {
    for (const p of policies) {
      expect(
        /\bto\s+authenticated\b/i.test(p),
        `policy missing TO authenticated:\n${p}`,
      ).toBe(true);
      expect(
        /\bto\s+anon\b/i.test(p),
        `policy must not target anon:\n${p}`,
      ).toBe(false);
    }
  });

  it("uses optimized (select auth.uid()) expressions", () => {
    for (const p of policies) {
      expect(
        /\(select\s+auth\.uid\(\)\)/i.test(p),
        `policy missing (select auth.uid()):\n${p}`,
      ).toBe(true);
    }
  });

  it("enables RLS only on the sync tables (no billing/analytics/profile surface)", () => {
    for (const t of ["scripts", "folders", "user_settings"]) {
      expect(
        new RegExp(
          `alter\\s+table\\s+public\\.${t}\\s+enable\\s+row\\s+level\\s+security`,
          "i",
        ).test(sql),
        `RLS not enabled on public.${t}`,
      ).toBe(true);
    }

    for (const t of ["profiles", "subscriptions", "analytics_events"]) {
      expect(
        new RegExp(
          `alter\\s+table\\s+public\\.${t}\\s+enable\\s+row\\s+level\\s+security`,
          "i",
        ).test(sql),
        `retired table public.${t} must not appear in active migrations`,
      ).toBe(false);
    }
  });

  it("does not define policies on retired payment/analytics/profile/storage objects", () => {
    for (const p of policies) {
      expect(p).not.toMatch(/on\s+public\.subscriptions/i);
      expect(p).not.toMatch(/on\s+public\.analytics_events/i);
      expect(p).not.toMatch(/on\s+public\.profiles/i);
      expect(p).not.toMatch(/on\s+storage\.objects/i);
    }
  });
});
