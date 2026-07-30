import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Static validation of the forward ACL remediation migration.
 * No live Supabase credentials — parses committed SQL only.
 *
 * Desired exact table privileges on folders/scripts/user_settings:
 *   authenticated: SELECT, INSERT, UPDATE, DELETE
 *   service_role:  SELECT, INSERT, UPDATE, DELETE
 *   anon / PUBLIC: none
 */
const ROOT = process.cwd();
const MIGRATIONS_DIR = join(ROOT, "supabase", "migrations");
const REMEDIATION_FILE = "20260719000001_sync_table_acl_remediation.sql";
const TABLES = ["folders", "scripts", "user_settings"] as const;
const REVOKE_ROLES = ["public", "anon", "authenticated", "service_role"] as const;
const GRANT_ROLES = ["authenticated", "service_role"] as const;
const SIDU = "select, insert, update, delete";

const remediationPath = join(MIGRATIONS_DIR, REMEDIATION_FILE);
const raw = readFileSync(remediationPath, "utf8");

/** Strip comments so prose cannot satisfy structural assertions. */
const stripped = raw
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ")
  .replace(/\s+/g, " ")
  .trim();

/** Ordered executable statements (semicolon-terminated). */
function statements(text: string): string[] {
  return text
    .split(";")
    .map((s) => s.trim().toLowerCase().replace(/\s+/g, " "))
    .filter((s) => s.length > 0);
}

const stmts = statements(stripped);

describe("ACL remediation migration layout", () => {
  it("is the sole forward migration after the native sync baseline", () => {
    const active = readdirSync(MIGRATIONS_DIR)
      .filter((f) => f.endsWith(".sql"))
      .sort();
    expect(active).toEqual([
      "20260719000000_native_sync_baseline.sql",
      REMEDIATION_FILE,
    ]);
  });

  it("contains only fixed REVOKE/GRANT SQL (idempotent, no dynamic SQL)", () => {
    for (const s of stmts) {
      expect(
        /^(revoke|grant)\b/.test(s),
        `unexpected non-privilege statement: ${s}`,
      ).toBe(true);
    }
    // No DO blocks, EXECUTE, or conditionals that would make re-runs diverge.
    expect(stripped).not.toMatch(/\bdo\s+\$\$/i);
    expect(stripped).not.toMatch(/\bexecute\s+/i);
    expect(stripped).not.toMatch(/\bif\s+exists\b/i);
    expect(stripped).not.toMatch(/\bcreate\b|\balter\b|\bdrop\b/i);
  });
});

describe("exact role/table privilege intent", () => {
  for (const table of TABLES) {
    it(`remediates public.${table} for all four grantees`, () => {
      for (const role of REVOKE_ROLES) {
        expect(stmts).toContain(
          `revoke all on table public.${table} from ${role}`,
        );
      }
      for (const role of GRANT_ROLES) {
        expect(stmts).toContain(
          `grant ${SIDU} on table public.${table} to ${role}`,
        );
      }
    });
  }

  it("covers every table and every revoke/grant grantee exactly once each", () => {
    // 3 tables × (4 revokes + 2 grants) = 18 statements; fixed order only.
    expect(stmts).toHaveLength(TABLES.length * (REVOKE_ROLES.length + GRANT_ROLES.length));

    for (const table of TABLES) {
      for (const role of REVOKE_ROLES) {
        const matches = stmts.filter(
          (s) => s === `revoke all on table public.${table} from ${role}`,
        );
        expect(matches, `duplicate/missing revoke ${table}/${role}`).toHaveLength(1);
      }
      for (const role of GRANT_ROLES) {
        const matches = stmts.filter(
          (s) => s === `grant ${SIDU} on table public.${table} to ${role}`,
        );
        expect(matches, `duplicate/missing grant ${table}/${role}`).toHaveLength(1);
      }
    }
  });

  it("never grants table privileges to anon or PUBLIC", () => {
    expect(stripped).not.toMatch(
      /grant\s+[^;]+\s+on\s+table\s+public\.(folders|scripts|user_settings)\s+to\s+(anon|public)\b/i,
    );
  });

  it("never re-grants TRUNCATE, REFERENCES, or TRIGGER on sync tables", () => {
    expect(stripped).not.toMatch(
      /grant\s+[^;]*\b(truncate|references|trigger)\b/i,
    );
  });
});

describe("revoke-before-grant order per table", () => {
  for (const table of TABLES) {
    it(`revokes all four roles on ${table} before any SIDU grant`, () => {
      const tableStmts = stmts.filter((s) =>
        s.includes(`on table public.${table} `),
      );

      // Expected per-table order: 4 revokes (public→anon→authenticated→service_role),
      // then 2 grants (authenticated, service_role).
      expect(tableStmts).toEqual([
        `revoke all on table public.${table} from public`,
        `revoke all on table public.${table} from anon`,
        `revoke all on table public.${table} from authenticated`,
        `revoke all on table public.${table} from service_role`,
        `grant ${SIDU} on table public.${table} to authenticated`,
        `grant ${SIDU} on table public.${table} to service_role`,
      ]);

      const firstGrant = tableStmts.findIndex((s) => s.startsWith("grant "));
      const lastRevoke = tableStmts
        .map((s, i) => (s.startsWith("revoke ") ? i : -1))
        .filter((i) => i >= 0)
        .at(-1);
      expect(firstGrant).toBeGreaterThan(-1);
      expect(lastRevoke).toBeGreaterThan(-1);
      expect(lastRevoke!).toBeLessThan(firstGrant);
    });
  }

  it("processes tables in fixed order: folders, scripts, user_settings", () => {
    const firstIdx = (table: string) =>
      stmts.findIndex((s) => s.includes(`on table public.${table} `));
    expect(firstIdx("folders")).toBeLessThan(firstIdx("scripts"));
    expect(firstIdx("scripts")).toBeLessThan(firstIdx("user_settings"));
  });
});
