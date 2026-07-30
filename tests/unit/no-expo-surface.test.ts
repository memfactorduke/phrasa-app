import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const root = join(__dirname, "../..");

describe("Expo retirement surface guard", () => {
  it("does not keep the retired mobile/ Expo tree", () => {
    expect(existsSync(join(root, "mobile"))).toBe(false);
  });

  it("keeps Atkinson Hyperlegible under the native resources path", () => {
    expect(
      existsSync(
        join(
          root,
          "ios-native/Phrasa/Resources/Fonts/AtkinsonHyperlegible-Regular.ttf"
        )
      )
    ).toBe(true);
  });

  it("passes scripts/guard-no-expo.mjs", () => {
    const output = execFileSync(
      process.execPath,
      [join(root, "scripts/guard-no-expo.mjs")],
      { encoding: "utf8", cwd: root }
    );
    expect(output).toMatch(/Expo retirement guard passed/);
  });
});
