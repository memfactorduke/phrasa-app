import { describe, expect, it } from "vitest";
import { parseAuthCallbackUrl } from "./callback";

describe("auth callback URL sanitization", () => {
  it("captures the PKCE code while retaining only the recovery marker", () => {
    const callback = parseAuthCallbackUrl(
      "https://phrasa.app/auth/callback?recovery=1&code=secret-code&state=secret-state",
    );

    expect(callback).toEqual({
      code: "secret-code",
      oauthError: null,
      isRecovery: true,
      sanitizedPath: "/auth/callback?recovery=1",
      containsSensitiveParameters: true,
    });
  });

  it("marks provider errors and hash credentials for removal without reflecting them", () => {
    const callback = parseAuthCallbackUrl(
      "https://phrasa.app/auth/callback?error=access_denied&error_description=%3Cscript%3Ebad%3C%2Fscript%3E#access_token=secret",
    );

    expect(callback.oauthError).toBe("<script>bad</script>");
    expect(callback.sanitizedPath).toBe("/auth/callback");
    expect(callback.containsSensitiveParameters).toBe(true);
  });

  it("leaves an already-clean recovery callback alone", () => {
    const callback = parseAuthCallbackUrl(
      "https://phrasa.app/auth/callback?recovery=1",
    );

    expect(callback.containsSensitiveParameters).toBe(false);
    expect(callback.sanitizedPath).toBe("/auth/callback?recovery=1");
  });
});
