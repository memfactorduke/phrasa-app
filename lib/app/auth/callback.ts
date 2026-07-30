export type ParsedAuthCallback = {
  code: string | null;
  oauthError: string | null;
  isRecovery: boolean;
  sanitizedPath: string;
  containsSensitiveParameters: boolean;
};

/**
 * Capture the callback values once, then reduce browser history to the only
 * application-owned flag. OAuth codes, provider errors, state, and hash tokens
 * must not remain visible in the address bar or a copied browser-history entry.
 */
export function parseAuthCallbackUrl(input: string): ParsedAuthCallback {
  const url = new URL(input);
  const code = url.searchParams.get("code");
  const oauthError =
    url.searchParams.get("error_description") ||
    url.searchParams.get("error");
  const isRecovery = url.searchParams.get("recovery") === "1";
  const sanitizedPath = `${url.pathname}${isRecovery ? "?recovery=1" : ""}`;

  return {
    code,
    oauthError,
    isRecovery,
    sanitizedPath,
    containsSensitiveParameters:
      url.hash.length > 0 ||
      Array.from(url.searchParams.keys()).some((key) => key !== "recovery"),
  };
}
