import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const DIR = join(process.cwd(), "supabase", "migrations");
const migration = readdirSync(DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => readFileSync(join(DIR, f), "utf8"))
  .join("\n")
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ")
  .replace(/\s+/g, " ");

describe("self-service account-deletion migration", () => {
  it("derives the delete target from auth.uid and guards against session swaps", () => {
    expect(migration).toMatch(/target_user_id uuid := \(select auth\.uid\(\)\)/i);
    expect(migration).toMatch(
      /if expected_user_id is distinct from target_user_id then/i,
    );
    expect(migration).toMatch(/if confirmation is distinct from 'DELETE' then/i);
    expect(migration).toMatch(
      /delete from auth\.users where id = target_user_id/i,
    );
  });

  it("does not allow deleting an arbitrary user via the expected_user_id argument", () => {
    expect(migration).not.toMatch(
      /delete from auth\.users where id = expected_user_id/i,
    );
  });

  it("keeps the security-definer function narrowly available", () => {
    expect(migration).toMatch(/security definer set search_path = ''/i);
    expect(migration).toMatch(
      /revoke all on function public\.delete_own_account\(text, uuid\) from public/i,
    );
    expect(migration).toMatch(
      /revoke all on function public\.delete_own_account\(text, uuid\) from anon/i,
    );
    expect(migration).toMatch(
      /grant execute on function public\.delete_own_account\(text, uuid\) to authenticated/i,
    );
  });
});
