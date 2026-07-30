import { describe, expect, it } from "vitest";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Static validation of the active native sync baseline.
 * No live Supabase credentials — parses committed SQL only.
 */
const ROOT = process.cwd();
const MIGRATIONS_DIR = join(ROOT, "supabase", "migrations");
const ARCHIVE_DIR = join(
  ROOT,
  "supabase",
  "archive",
  "historical-migrations-pre-sync-baseline",
);

const ACTIVE_FILES = readdirSync(MIGRATIONS_DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort();

const sql = ACTIVE_FILES.map((f) =>
  readFileSync(join(MIGRATIONS_DIR, f), "utf8"),
).join("\n");

/** Strip comments so prose cannot satisfy structural assertions. */
const stripped = sql
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ")
  .replace(/\s+/g, " ");

function policyStatements(text: string): string[] {
  return text.match(/create\s+policy[\s\S]*?;/gi) ?? [];
}

function createTableBody(table: string): string | null {
  const startRe = new RegExp(
    `create\\s+table\\s+public\\.${table}\\s*\\(`,
    "i",
  );
  const start = sql.search(startRe);
  if (start < 0) return null;
  const open = sql.indexOf("(", start);
  let depth = 0;
  for (let i = open; i < sql.length; i++) {
    const ch = sql[i];
    if (ch === "(") depth += 1;
    else if (ch === ")") {
      depth -= 1;
      if (depth === 0) return sql.slice(open + 1, i);
    }
  }
  return null;
}

describe("active migrations layout", () => {
  it("ships baseline then forward ACL remediation only", () => {
    expect(ACTIVE_FILES).toEqual([
      "20260719000000_native_sync_baseline.sql",
      "20260719000001_sync_table_acl_remediation.sql",
    ]);
  });

  it("keeps historical SQL outside the active migrations directory", () => {
    expect(existsSync(ARCHIVE_DIR)).toBe(true);
    const archived = readdirSync(ARCHIVE_DIR)
      .filter((f) => f.endsWith(".sql"))
      .sort();
    expect(archived).toEqual([
      "0001_init.sql",
      "0002_billing.sql",
      "0003_outline.sql",
      "0004_webhook_event_ordering.sql",
      "0005_touch_opened_preserves_updated_at.sql",
      "0006_script_preview.sql",
      "0007_advisor_hardening.sql",
      "0008_analytics_events.sql",
      "0009_self_service_account_deletion.sql",
      "0010_atomic_subscription_webhook.sql",
      "0011_subscription_identity_ordering.sql",
    ]);
    const archiveReadme = readFileSync(join(ARCHIVE_DIR, "README.md"), "utf8");
    expect(archiveReadme).toMatch(/Do not apply/i);
    expect(archiveReadme).toMatch(/historical/i);
    expect(archiveReadme).toMatch(/never/i);
  });
});

describe("required sync tables and columns", () => {
  it("creates folders with owner FK cascade, created_at, and (id, user_id) unique", () => {
    const body = createTableBody("folders");
    expect(body, "public.folders missing").toBeTruthy();
    expect(body!).toMatch(/user_id\s+uuid\s+not\s+null\s+references\s+auth\.users\s*\(\s*id\s*\)\s+on\s+delete\s+cascade/i);
    expect(body!).toMatch(/\bname\s+text\s+not\s+null/i);
    expect(body!).toMatch(/\bcreated_at\s+timestamptz\s+not\s+null/i);
    // Composite unique key is the FK target for same-owner script→folder refs.
    expect(body!).toMatch(/unique\s*\(\s*id\s*,\s*user_id\s*\)/i);
    expect(body!).not.toMatch(/\bupdated_at\b/i);
  });

  it("creates scripts with columns required by SupabaseCloudRepository", () => {
    const body = createTableBody("scripts");
    expect(body, "public.scripts missing").toBeTruthy();

    const required = [
      /user_id\s+uuid\s+not\s+null\s+references\s+auth\.users\s*\(\s*id\s*\)\s+on\s+delete\s+cascade/i,
      // folder_id is a plain nullable uuid; same-owner is a table constraint.
      /\bfolder_id\s+uuid\b/i,
      /\btitle\s+text\s+not\s+null/i,
      /\bbody\s+text\s+not\s+null/i,
      /\bsource_type\s+text\s+not\s+null/i,
      /\boutline\s+jsonb\b/i,
      /\bword_count\s+integer\s+not\s+null/i,
      /\best_seconds\s+integer\s+not\s+null/i,
      /\btags\s+text\[\]\s+not\s+null/i,
      /\blast_opened_at\s+timestamptz\b/i,
      /\bcreated_at\s+timestamptz\s+not\s+null/i,
      /\bupdated_at\s+timestamptz\s+not\s+null/i,
    ];
    for (const re of required) {
      expect(body!, `scripts missing column matching ${re}`).toMatch(re);
    }

    // Forbidden columns from the retired browser/billing surface.
    expect(body!).not.toMatch(/\bpreview\b/i);
    expect(body!).not.toMatch(/original_file_path/i);
  });

  it("enforces same-owner script→folder via composite FK with folder_id-only SET NULL", () => {
    const body = createTableBody("scripts");
    expect(body, "public.scripts missing").toBeTruthy();

    // Composite FK: (folder_id, user_id) → folders (id, user_id).
    // Rejects cross-tenant folder UUIDs even when the UUID is known.
    expect(body!).toMatch(
      /foreign\s+key\s*\(\s*folder_id\s*,\s*user_id\s*\)\s*references\s+public\.folders\s*\(\s*id\s*,\s*user_id\s*\)/i,
    );
    // Postgres 15+ column-list form: null only folder_id; preserve non-null user_id.
    expect(body!).toMatch(/on\s+delete\s+set\s+null\s*\(\s*folder_id\s*\)/i);
    // Must not use a bare single-column folder_id → folders(id) FK (cross-tenant hole).
    expect(body!).not.toMatch(
      /folder_id\s+uuid\s+references\s+public\.folders\s*\(\s*id\s*\)/i,
    );
    // Must not SET NULL the whole composite key (would null user_id).
    expect(body!).not.toMatch(
      /on\s+delete\s+set\s+null\s*(?!\s*\(\s*folder_id\s*\))/i,
    );
  });

  it("creates user_settings with cascade FK, jsonb settings, and updated_at", () => {
    const body = createTableBody("user_settings");
    expect(body, "public.user_settings missing").toBeTruthy();
    expect(body!).toMatch(
      /user_id\s+uuid\s+primary\s+key\s+references\s+auth\.users\s*\(\s*id\s*\)\s+on\s+delete\s+cascade/i,
    );
    expect(body!).toMatch(/\bsettings\s+jsonb\s+not\s+null/i);
    expect(body!).toMatch(/\bupdated_at\s+timestamptz\s+not\s+null/i);
  });
});

describe("indexes", () => {
  it("defines owner and lookup indexes for folders and scripts", () => {
    expect(stripped).toMatch(
      /create\s+index\s+folders_user_id_idx\s+on\s+public\.folders\s*\(\s*user_id\s*\)/i,
    );
    expect(stripped).toMatch(
      /create\s+index\s+scripts_user_id_idx\s+on\s+public\.scripts\s*\(\s*user_id\s*\)/i,
    );
    expect(stripped).toMatch(
      /create\s+index\s+scripts_updated_at_idx\s+on\s+public\.scripts\s*\(\s*user_id\s*,\s*updated_at\s+desc\s*\)/i,
    );
    expect(stripped).toMatch(
      /create\s+index\s+scripts_folder_id_idx\s+on\s+public\.scripts\s*\(\s*folder_id\s*\)/i,
    );
  });
});

describe("RLS policies", () => {
  const policies = policyStatements(sql);

  it("enables RLS on every sync table", () => {
    for (const t of ["folders", "scripts", "user_settings"]) {
      expect(
        new RegExp(
          `alter\\s+table\\s+public\\.${t}\\s+enable\\s+row\\s+level\\s+security`,
          "i",
        ).test(sql),
        `RLS not enabled on public.${t}`,
      ).toBe(true);
    }
  });

  it("defines owner-only authenticated policies with optimized auth.uid()", () => {
    expect(policies.length).toBe(3);
    for (const p of policies) {
      expect(p).toMatch(/\bto\s+authenticated\b/i);
      expect(p).toMatch(/\(select\s+auth\.uid\(\)\)/i);
      expect(p).toMatch(/using\s*\(\s*\(select\s+auth\.uid\(\)\)\s*=\s*(user_id|id)/i);
      expect(p).toMatch(/with\s+check\s*\(\s*\(select\s+auth\.uid\(\)\)\s*=\s*(user_id|id)/i);
      // Bare auth.uid() without select wrapper is the per-row form advisors warn about.
      expect(p).not.toMatch(/using\s*\(\s*auth\.uid\(\)/i);
    }
  });

  it("covers folders, scripts, and user_settings only", () => {
    const tables = policies.map((p) => {
      const m = p.match(/on\s+public\.(\w+)/i);
      return m?.[1]?.toLowerCase();
    });
    expect(tables.sort()).toEqual(["folders", "scripts", "user_settings"]);
  });
});

describe("updated_at function and triggers", () => {
  it("hardens set_updated_at search_path and revokes client execute", () => {
    expect(stripped).toMatch(
      /create\s+or\s+replace\s+function\s+public\.set_updated_at\s*\(\s*\)\s*returns\s+trigger\s+language\s+plpgsql\s+set\s+search_path\s*=\s*''/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.set_updated_at\s*\(\s*\)\s+from\s+public/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.set_updated_at\s*\(\s*\)\s+from\s+anon/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.set_updated_at\s*\(\s*\)\s+from\s+authenticated/i,
    );
  });

  it("defines a dedicated scripts open-stamp trigger function with hardened search_path", () => {
    expect(stripped).toMatch(
      /create\s+or\s+replace\s+function\s+public\.scripts_preserve_updated_at_on_open\s*\(\s*\)\s*returns\s+trigger\s+language\s+plpgsql\s+set\s+search_path\s*=\s*''/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.scripts_preserve_updated_at_on_open\s*\(\s*\)\s+from\s+public/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.scripts_preserve_updated_at_on_open\s*\(\s*\)\s+from\s+anon/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.scripts_preserve_updated_at_on_open\s*\(\s*\)\s+from\s+authenticated/i,
    );
  });

  it("compares every synchronized business field before preserving updated_at", () => {
    // Extract the dedicated scripts trigger function body.
    const fnMatch = sql.match(
      /create\s+or\s+replace\s+function\s+public\.scripts_preserve_updated_at_on_open\s*\(\s*\)[\s\S]*?as\s+\$\$([\s\S]*?)\$\$\s*;/i,
    );
    expect(fnMatch, "scripts_preserve_updated_at_on_open body missing").toBeTruthy();
    const body = fnMatch![1];

    // Every native-sync business column the client can mutate (except
    // last_opened_at / updated_at themselves) must participate in the compare.
    const businessFields = [
      "folder_id",
      "title",
      "body",
      "source_type",
      "outline",
      "word_count",
      "est_seconds",
      "tags",
      "created_at",
    ];
    for (const field of businessFields) {
      expect(
        body,
        `scripts open-stamp function must compare ${field}`,
      ).toMatch(
        new RegExp(
          `new\\.${field}\\s+is\\s+not\\s+distinct\\s+from\\s+old\\.${field}`,
          "i",
        ),
      );
    }

    // last_opened_at-only path preserves prior updated_at.
    expect(body).toMatch(/new\.updated_at\s*=\s*old\.updated_at/i);
    // Any real field change (including combined with last_opened_at) bumps now().
    expect(body).toMatch(/new\.updated_at\s*=\s*pg_catalog\.now\s*\(\s*\)/i);

    // Must not rely on comparing only last_opened_at (misses combined updates).
    expect(body).not.toMatch(
      /if\s+new\.last_opened_at\s+is\s+not\s+distinct\s+from\s+old\.last_opened_at/i,
    );
  });

  it("always invokes the scripts open-stamp function (no fragile WHEN predicate)", () => {
    // Trigger must fire on every UPDATE and call the dedicated function.
    expect(stripped).toMatch(
      /create\s+trigger\s+scripts_set_updated_at\s+before\s+update\s+on\s+public\.scripts\s+for\s+each\s+row\s+execute\s+function\s+public\.scripts_preserve_updated_at_on_open\s*\(\s*\)/i,
    );
    // Explicitly forbid the old WHEN (last_opened_at unchanged) shortcut.
    expect(stripped).not.toMatch(
      /create\s+trigger\s+scripts_set_updated_at[\s\S]{0,200}when\s*\(\s*new\.last_opened_at/i,
    );
  });

  it("bumps user_settings.updated_at on every update", () => {
    expect(stripped).toMatch(
      /create\s+trigger\s+user_settings_set_updated_at\s+before\s+update\s+on\s+public\.user_settings\s+for\s+each\s+row\s+execute\s+function\s+public\.set_updated_at\s*\(\s*\)/i,
    );
  });
});

describe("delete_own_account", () => {
  it("is security definer with empty search_path and explicit confirmation guard", () => {
    expect(stripped).toMatch(
      /create\s+or\s+replace\s+function\s+public\.delete_own_account\s*\(\s*confirmation\s+text\s*,\s*expected_user_id\s+uuid\s*\)/i,
    );
    expect(stripped).toMatch(/security\s+definer/i);
    expect(stripped).toMatch(/set\s+search_path\s*=\s*''/i);
    expect(stripped).toMatch(
      /target_user_id\s+uuid\s*:=\s*\(\s*select\s+auth\.uid\s*\(\s*\)\s*\)/i,
    );
    expect(stripped).toMatch(
      /if\s+expected_user_id\s+is\s+distinct\s+from\s+target_user_id\s+then/i,
    );
    expect(stripped).toMatch(
      /if\s+confirmation\s+is\s+distinct\s+from\s+'DELETE'\s+then/i,
    );
    expect(stripped).toMatch(
      /delete\s+from\s+auth\.users\s+where\s+id\s*=\s*target_user_id/i,
    );
  });

  it("never deletes an arbitrary user id from arguments", () => {
    // The only DELETE target must be the local target_user_id derived from auth.uid().
    expect(stripped).not.toMatch(
      /delete\s+from\s+auth\.users\s+where\s+id\s*=\s*expected_user_id/i,
    );
    expect(stripped).not.toMatch(
      /delete\s+from\s+auth\.users\s+where\s+id\s*=\s*\$/i,
    );
  });

  it("grants execute only to authenticated", () => {
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.delete_own_account\s*\(\s*text\s*,\s*uuid\s*\)\s+from\s+public/i,
    );
    expect(stripped).toMatch(
      /revoke\s+all\s+on\s+function\s+public\.delete_own_account\s*\(\s*text\s*,\s*uuid\s*\)\s+from\s+anon/i,
    );
    expect(stripped).toMatch(
      /grant\s+execute\s+on\s+function\s+public\.delete_own_account\s*\(\s*text\s*,\s*uuid\s*\)\s+to\s+authenticated/i,
    );
  });
});

describe("table grants for publishable client + RLS", () => {
  const tables = ["folders", "scripts", "user_settings"] as const;
  const grantees = ["public", "anon", "authenticated", "service_role"] as const;

  for (const table of tables) {
    it(`ends ${table} at SIDU for authenticated/service_role only`, () => {
      for (const role of grantees) {
        expect(stripped).toMatch(
          new RegExp(
            `revoke\\s+all\\s+on\\s+table\\s+public\\.${table}\\s+from\\s+${role}\\b`,
            "i",
          ),
        );
      }
      expect(stripped).toMatch(
        new RegExp(
          `grant\\s+select\\s*,\\s*insert\\s*,\\s*update\\s*,\\s*delete\\s+on\\s+table\\s+public\\.${table}\\s+to\\s+authenticated\\b`,
          "i",
        ),
      );
      expect(stripped).toMatch(
        new RegExp(
          `grant\\s+select\\s*,\\s*insert\\s*,\\s*update\\s*,\\s*delete\\s+on\\s+table\\s+public\\.${table}\\s+to\\s+service_role\\b`,
          "i",
        ),
      );
      // No elevated table privileges re-granted after the SIDU set.
      expect(stripped).not.toMatch(
        new RegExp(
          `grant\\s+[^;]*\\b(truncate|references|trigger)\\b[^;]*\\s+on\\s+table\\s+public\\.${table}\\b`,
          "i",
        ),
      );
      // anon and PUBLIC never receive table DML grants.
      expect(stripped).not.toMatch(
        new RegExp(
          `grant\\s+[^;]+\\s+on\\s+table\\s+public\\.${table}\\s+to\\s+anon\\b`,
          "i",
        ),
      );
      expect(stripped).not.toMatch(
        new RegExp(
          `grant\\s+[^;]+\\s+on\\s+table\\s+public\\.${table}\\s+to\\s+public\\b`,
          "i",
        ),
      );
    });
  }

  it("grants schema usage to authenticated", () => {
    expect(stripped).toMatch(
      /grant\s+usage\s+on\s+schema\s+public\s+to\s+authenticated/i,
    );
  });
});

describe("forbidden payment / analytics / profile / storage objects", () => {
  const forbiddenTables = [
    "profiles",
    "subscriptions",
    "analytics_events",
  ];

  it("does not create retired tables", () => {
    for (const t of forbiddenTables) {
      expect(
        new RegExp(`create\\s+table(?:\\s+if\\s+not\\s+exists)?\\s+public\\.${t}\\b`, "i").test(
          stripped,
        ),
        `active migration must not create public.${t}`,
      ).toBe(false);
    }
  });

  it("does not install Lemon Squeezy or subscription webhook machinery", () => {
    expect(stripped).not.toMatch(/apply_subscription_webhook_event/i);
    expect(stripped).not.toMatch(/ls_subscription_id/i);
    expect(stripped).not.toMatch(/ls_customer_id/i);
    expect(stripped).not.toMatch(/lemon\s*squeezy/i);
    expect(stripped).not.toMatch(/\bplan\b.*\bpro\b/i);
  });

  it("does not create profiles trigger/helpers or storage upload bucket", () => {
    expect(stripped).not.toMatch(/handle_new_user/i);
    expect(stripped).not.toMatch(/on_auth_user_created/i);
    expect(stripped).not.toMatch(/script-uploads/i);
    expect(stripped).not.toMatch(/storage\.buckets/i);
    expect(stripped).not.toMatch(/storage\.objects/i);
    expect(stripped).not.toMatch(/storage\.foldername/i);
  });

  it("does not add scripts.preview generated column", () => {
    expect(stripped).not.toMatch(/\bpreview\s+text\b/i);
    expect(stripped).not.toMatch(/generated\s+always\s+as/i);
  });
});
