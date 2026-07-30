import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { sourceCodeUrl } from "@/lib/site";

const root = join(__dirname, "../..");
const read = (path: string) => readFileSync(join(root, path), "utf8");

describe("open-source release surfaces", () => {
  it("ships a recognized Apache 2.0 license and trademark notice", () => {
    expect(read("LICENSE")).toMatch(/Apache License/);
    expect(read("LICENSE")).toMatch(/Version 2\.0, January 2004/);
    expect(read("LICENSE")).toMatch(/Copyright 2026 Memorable Factor/);
    expect(read("NOTICE")).toMatch(
      /does not grant permission[\s\S]*Phrasa/i,
    );
  });

  it("uses one canonical public source URL", () => {
    expect(sourceCodeUrl).toBe(
      "https://github.com/memfactorduke/phrasa-app",
    );
    expect(read("README.md")).toContain(sourceCodeUrl);
    expect(read("app/page.tsx")).toContain("sourceCodeUrl");
    expect(read("ios-native/Phrasa/Design/AppLegalDestinations.swift")).toContain(
      sourceCodeUrl,
    );
    expect(read("ios-native/PhrasaMac/Settings/MacSettingsView.swift")).toContain(
      sourceCodeUrl,
    );
  });

  it("keeps App Store open-source advertising complete and within limits", () => {
    const promotionalText = read(
      "ios-native/AppStore/Submission/en-US/promotional-text.txt",
    ).trim();
    const description = read(
      "ios-native/AppStore/Submission/en-US/description.txt",
    ).trim();

    expect(promotionalText.length).toBeLessThanOrEqual(170);
    expect(promotionalText).toMatch(/open-source/i);
    expect(description.length).toBeLessThanOrEqual(4_000);
    expect(description).toMatch(/open source/i);
    expect(description).toMatch(/Apache License 2\.0/i);
    expect(description).toContain(sourceCodeUrl);
  });
});
