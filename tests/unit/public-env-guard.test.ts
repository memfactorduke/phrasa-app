import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const script = join(process.cwd(), "scripts", "guard-public-env.mjs");

function runGuard(url: string | undefined, key: string | undefined) {
  const env = { ...process.env };
  delete env.NEXT_PUBLIC_PHRASA_SUPABASE_URL;
  delete env.NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY;
  if (url !== undefined) env.NEXT_PUBLIC_PHRASA_SUPABASE_URL = url;
  if (key !== undefined) {
    env.NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY = key;
  }
  return spawnSync(process.execPath, [script], {
    env,
    encoding: "utf8",
  });
}

describe("public Supabase environment build guard", () => {
  it("allows guest-only builds and complete publishable configuration", () => {
    expect(runGuard(undefined, undefined).status).toBe(0);
    expect(
      runGuard(
        "https://example.supabase.co",
        "sb_publishable_browser-safe",
      ).status,
    ).toBe(0);
  });

  it("rejects half-configured cloud builds", () => {
    expect(runGuard("https://example.supabase.co", undefined).status).toBe(1);
    expect(runGuard(undefined, "sb_publishable_browser-safe").status).toBe(1);
  });

  it("rejects privileged keys without echoing their value", () => {
    const secrets = [
      "sb_secret_do-not-print",
      "contains-service_role-marker",
      "e30.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature",
    ];
    for (const secret of secrets) {
      const result = runGuard("https://example.supabase.co", secret);
      expect(result.status).toBe(1);
      expect(`${result.stdout}${result.stderr}`).not.toContain(secret);
    }
  });
});
