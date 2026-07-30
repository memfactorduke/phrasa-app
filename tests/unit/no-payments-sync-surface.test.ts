import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Historical billing/webhook migrations are archived and must not return as
 * part of the active native-sync product. This suite formerly pinned Lemon
 * Squeezy webhook atomicity SQL; it now asserts the no-payments sync surface.
 */
const DIR = join(process.cwd(), "supabase", "migrations");
const activeSql = readdirSync(DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => readFileSync(join(DIR, f), "utf8"))
  .join("\n")
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ")
  .replace(/\s+/g, " ");

describe("no-payments sync product (active migrations)", () => {
  it("does not install subscription webhook RPCs or Lemon Squeezy fields", () => {
    expect(activeSql).not.toMatch(/apply_subscription_webhook_event/i);
    expect(activeSql).not.toMatch(/ls_subscription_id/i);
    expect(activeSql).not.toMatch(/ls_subscription_created_at/i);
    expect(activeSql).not.toMatch(/ls_event_at/i);
    expect(activeSql).not.toMatch(/ls_customer_id/i);
    expect(activeSql).not.toMatch(/phrasa_user:/i);
    expect(activeSql).not.toMatch(/create table public\.subscriptions/i);
  });

  it("does not grant service_role billing RPCs in active migrations", () => {
    // Table SIDU grants to service_role are intentional ACL remediation.
    // Billing/function EXECUTE grants to service_role remain forbidden.
    expect(activeSql).not.toMatch(
      /grant execute on function public\.apply_subscription_webhook_event/i,
    );
    expect(activeSql).not.toMatch(
      /grant\s+execute\s+on\s+function\s+[^;]*\s+to\s+service_role/i,
    );
  });

  it("ships only the sync tables, not a payments surface", () => {
    expect(activeSql).toMatch(/create table public\.folders/i);
    expect(activeSql).toMatch(/create table public\.scripts/i);
    expect(activeSql).toMatch(/create table public\.user_settings/i);
    expect(activeSql).not.toMatch(/create table public\.profiles/i);
    expect(activeSql).not.toMatch(/create table public\.analytics_events/i);
  });
});
