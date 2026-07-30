import { describe, expect, it } from "vitest";
import {
  createWelcomeScript,
  isUntouchedWelcomeScript,
} from "./script";

describe("welcome script", () => {
  it("does not offer the untouched guest sample for cloud import", () => {
    expect(isUntouchedWelcomeScript(createWelcomeScript())).toBe(true);
  });

  it("treats an edited welcome sample as user content", () => {
    const script = createWelcomeScript();
    script.body += "\nMy own ending.";
    expect(isUntouchedWelcomeScript(script)).toBe(false);
  });
});
