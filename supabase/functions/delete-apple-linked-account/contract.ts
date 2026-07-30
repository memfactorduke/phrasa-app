/**
 * Pure validation + error contract for Apple-linked account deletion.
 *
 * No Deno / Supabase / network imports — unit-tested from Vitest.
 * The Edge Function entrypoint (`index.ts`) owns secrets, Apple HTTP, and
 * Supabase admin deletion. Deployment is a release blocker until secrets and
 * live Apple/Supabase projects are configured.
 *
 * Trust model (do not regress):
 *   - Never trust a client-supplied identity_token subject. That field is not
 *     part of the request contract.
 *   - Native iOS (`com.phrasa.app`) and Mac (`com.phrasa.mac`) each issue
 *     authorization codes bound to their own SIWA client_id / App ID. A single
 *     APPLE_CLIENT_ID cannot safely exchange codes for both platforms; do not
 *     assume grouped App IDs make client_id interchangeable.
 *   - The client sends its current bundle/client id. The server allowlists it
 *     against configured secrets, then uses that same allowed client_id for
 *     Apple token exchange and for validating the returned id_token `aud`.
 *   - After Apple's HTTPS authorization-code exchange, derive identity from the
 *     id_token Apple returns over TLS with our client_secret.
 *   - Validate id_token claims (iss, aud/client_id, exp, sub) and require sub to
 *     match a stored Supabase Apple identity before any revoke/delete.
 *
 * Fail-closed order (cannot be transactional across Apple + Supabase):
 *   1. Validate secrets + caller JWT + body (incl. allowlisted client_id)
 *   2. Load stored Apple subjects for the user (no mutation)
 *   3. Exchange one-time authorization_code for tokens using allowed client_id
 *   4. Validate Apple-returned id_token claims + match sub
 *   5. Revoke with Apple (must succeed)
 *   6. Delete Supabase auth user (cascades folders/scripts/user_settings)
 * If step 6 fails after step 5, return PARTIAL_REVOKED_ACCOUNT_DELETE_FAILED.
 */

export const FUNCTION_NAME = "delete-apple-linked-account" as const;

export const CONFIRMATION_DELETE = "DELETE" as const;

/**
 * Known production SIWA client ids (App IDs / bundle ids). Documented for
 * operators; the runtime allowlist comes only from server secrets.
 */
export const KNOWN_PRODUCTION_APPLE_CLIENT_IDS = [
  "com.phrasa.app",
  "com.phrasa.mac",
] as const;

/**
 * Core secrets always required. Apple client ids are validated separately via
 * `parseAppleClientIdAllowlist` / `assertSecretsConfigured` because either
 * `APPLE_CLIENT_IDS` (preferred, comma-separated) or legacy `APPLE_CLIENT_ID`
 * may supply the allowlist.
 */
export const REQUIRED_SECRET_NAMES = [
  "APPLE_TEAM_ID",
  "APPLE_KEY_ID",
  "APPLE_PRIVATE_KEY",
  "SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
] as const;

export type RequiredSecretName = (typeof REQUIRED_SECRET_NAMES)[number];

/** Env key for comma-separated allowlist (preferred). */
export const APPLE_CLIENT_IDS_SECRET = "APPLE_CLIENT_IDS" as const;
/** Env key for a single client id (legacy / single-platform). */
export const APPLE_CLIENT_ID_SECRET = "APPLE_CLIENT_ID" as const;

export const AppleLinkedDeletionErrorCode = {
  NOT_CONFIGURED: "APPLE_REVOCATION_NOT_CONFIGURED",
  INVALID_REQUEST: "INVALID_REQUEST",
  UNAUTHORIZED: "UNAUTHORIZED",
  ACCOUNT_CHANGED: "ACCOUNT_CHANGED",
  APPLE_TOKEN_EXCHANGE_FAILED: "APPLE_TOKEN_EXCHANGE_FAILED",
  APPLE_TOKEN_REVOKE_FAILED: "APPLE_TOKEN_REVOKE_FAILED",
  APPLE_IDENTITY_MISMATCH: "APPLE_IDENTITY_MISMATCH",
  ACCOUNT_DELETE_FAILED: "ACCOUNT_DELETE_FAILED",
  PARTIAL_REVOKED_ACCOUNT_DELETE_FAILED: "APPLE_REVOKED_ACCOUNT_DELETE_FAILED",
} as const;

export type AppleLinkedDeletionErrorCode =
  (typeof AppleLinkedDeletionErrorCode)[keyof typeof AppleLinkedDeletionErrorCode];

/**
 * Client → Edge Function body.
 *
 * - `identity_token` is intentionally absent / ignored.
 * - `client_id` is the platform SIWA client id (bundle id for native apps).
 *   It is not trusted until allowlist-checked against server secrets.
 */
export type DeletionRequestBody = {
  confirmation: string;
  expected_user_id: string;
  authorization_code: string;
  client_id: string;
};

export type ValidatedDeletionRequest = {
  confirmation: typeof CONFIRMATION_DELETE;
  expectedUserId: string;
  authorizationCode: string;
  /** Requested client id after shape validation only — still needs allowlist. */
  clientId: string;
};

export type ValidationFailure = {
  ok: false;
  code: AppleLinkedDeletionErrorCode;
  message: string;
  httpStatus: number;
};

export type ValidationSuccess = {
  ok: true;
  value: ValidatedDeletionRequest;
};

export type ValidationResult = ValidationSuccess | ValidationFailure;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Apple's canonical JWT issuer. Exact match only. */
export const APPLE_ID_TOKEN_ISSUERS = ["https://appleid.apple.com"] as const;

/** Small clock-skew allowance when checking id_token exp (seconds). */
export const ID_TOKEN_CLOCK_SKEW_SECONDS = 60;

/**
 * Loose shape for SIWA client ids / reverse-DNS bundle ids.
 * Exact membership is enforced only by the server allowlist.
 */
const CLIENT_ID_SHAPE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{1,253}$/;

export function isUuid(value: string): boolean {
  return UUID_RE.test(value.trim());
}

export function isPlausibleAppleClientId(value: string): boolean {
  const trimmed = value.trim();
  return trimmed.length > 0 && CLIENT_ID_SHAPE_RE.test(trimmed);
}

/**
 * Parse the server allowlist from secrets.
 * Prefer `APPLE_CLIENT_IDS` (comma/whitespace/semicolon separated). Also merge
 * a single `APPLE_CLIENT_ID` when present so single-platform setups still work.
 * Order is preserved; duplicates removed (case-sensitive — Apple client ids are
 * reverse-DNS and treated as exact match).
 */
export function parseAppleClientIdAllowlist(
  env: Record<string, string | undefined>,
): string[] {
  const collected: string[] = [];
  const multi = env[APPLE_CLIENT_IDS_SECRET];
  if (typeof multi === "string" && multi.trim()) {
    for (const part of multi.split(/[,;\s]+/)) {
      const id = part.trim();
      if (id) collected.push(id);
    }
  }
  const single = env[APPLE_CLIENT_ID_SECRET];
  if (typeof single === "string" && single.trim()) {
    collected.push(single.trim());
  }
  const seen = new Set<string>();
  const unique: string[] = [];
  for (const id of collected) {
    if (seen.has(id)) continue;
    seen.add(id);
    unique.push(id);
  }
  return unique;
}

export function missingSecrets(
  env: Record<string, string | undefined>,
): string[] {
  const missing: string[] = REQUIRED_SECRET_NAMES.filter((name) => {
    const raw = env[name];
    return raw == null || raw.trim().length === 0;
  });
  if (parseAppleClientIdAllowlist(env).length === 0) {
    missing.push(APPLE_CLIENT_IDS_SECRET);
  }
  return missing;
}

export function assertSecretsConfigured(
  env: Record<string, string | undefined>,
): ValidationFailure | null {
  const missing = missingSecrets(env);
  if (missing.length === 0) return null;
  return {
    ok: false,
    code: AppleLinkedDeletionErrorCode.NOT_CONFIGURED,
    message:
      "Apple token revocation is not configured on this project. Required server secrets are missing (including an APPLE_CLIENT_IDS allowlist for each SIWA client id such as com.phrasa.app and com.phrasa.mac). Nothing was deleted.",
    httpStatus: 503,
  };
}

/**
 * Exhaustive request validation before any Apple or Supabase mutation.
 * Rejects unknown shapes, wrong confirmation, empty codes, bad UUIDs, and
 * missing/ill-shaped client_id. Client-supplied identity_token is ignored.
 * Allowlist membership is checked separately via `resolveAllowlistedClientId`.
 */
export function validateDeletionRequest(input: unknown): ValidationResult {
  if (input == null || typeof input !== "object" || Array.isArray(input)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message: "Request body must be a JSON object.",
      httpStatus: 400,
    };
  }

  const body = input as Record<string, unknown>;
  const confirmation =
    typeof body.confirmation === "string" ? body.confirmation.trim() : "";
  const expectedUserId =
    typeof body.expected_user_id === "string"
      ? body.expected_user_id.trim()
      : "";
  const authorizationCode =
    typeof body.authorization_code === "string"
      ? body.authorization_code.trim()
      : "";
  const clientId =
    typeof body.client_id === "string" ? body.client_id.trim() : "";

  if (confirmation !== CONFIRMATION_DELETE) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message: "Account deletion was not confirmed.",
      httpStatus: 400,
    };
  }

  if (!expectedUserId || !isUuid(expectedUserId)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message: "expected_user_id must be a UUID.",
      httpStatus: 400,
    };
  }

  if (!authorizationCode) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message:
        "authorization_code is required. Obtain a fresh Sign in with Apple authorization code before deleting.",
      httpStatus: 400,
    };
  }

  if (!clientId || !isPlausibleAppleClientId(clientId)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message:
        "client_id is required and must be this app's Sign in with Apple client id (bundle id on native).",
      httpStatus: 400,
    };
  }

  return {
    ok: true,
    value: {
      confirmation: CONFIRMATION_DELETE,
      expectedUserId,
      authorizationCode,
      clientId,
    },
  };
}

/**
 * Bind the request client_id to the server allowlist. Exact string match only.
 * On success returns the allowlisted id to use for exchange + aud validation.
 */
export function resolveAllowlistedClientId(
  requestedClientId: string,
  allowlist: readonly string[],
):
  | { ok: true; clientId: string }
  | ValidationFailure {
  const requested = requestedClientId.trim();
  if (!requested || !isPlausibleAppleClientId(requested)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message:
        "client_id is required and must be this app's Sign in with Apple client id (bundle id on native).",
      httpStatus: 400,
    };
  }
  if (allowlist.length === 0) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.NOT_CONFIGURED,
      message:
        "No Apple client id allowlist is configured on the server. Nothing was deleted.",
      httpStatus: 503,
    };
  }
  if (!allowlist.includes(requested)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.INVALID_REQUEST,
      message:
        "client_id is not allowlisted for Apple token exchange on this project. Nothing was deleted.",
      httpStatus: 400,
    };
  }
  return { ok: true, clientId: requested };
}

/**
 * Caller JWT subject must equal expected_user_id (session-swap guard).
 */
export function validateCallerMatchesExpected(
  callerUserId: string | null | undefined,
  expectedUserId: string,
): ValidationFailure | null {
  if (!callerUserId || !isUuid(callerUserId)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.UNAUTHORIZED,
      message: "Authentication is required to delete an account.",
      httpStatus: 401,
    };
  }
  if (callerUserId.toLowerCase() !== expectedUserId.toLowerCase()) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.ACCOUNT_CHANGED,
      message:
        "The signed-in account changed before deletion was confirmed. Nothing was deleted.",
      httpStatus: 403,
    };
  }
  return null;
}

/**
 * Decode JWT payload for the pure claim validator. The Edge Function verifies
 * Apple's RS256 signature against APPLE_JWKS_URL before calling that validator.
 */
export function decodeJwtPayloadUnsafe(
  jwt: string,
): Record<string, unknown> | null {
  const parts = jwt.split(".");
  if (parts.length !== 3 || parts.some((p) => p.length === 0)) return null;
  try {
    const normalized = parts[1]!.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const json =
      typeof atob === "function"
        ? atob(padded)
        : Buffer.from(padded, "base64").toString("utf8");
    const parsed = JSON.parse(json) as unknown;
    if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function appleSubjectFromIdToken(idToken: string): string | null {
  const payload = decodeJwtPayloadUnsafe(idToken);
  if (!payload) return null;
  const sub = payload.sub;
  return typeof sub === "string" && sub.trim().length > 0 ? sub.trim() : null;
}

/**
 * @deprecated Prefer appleSubjectFromIdToken. Alias kept for older test names.
 */
export function appleSubjectFromIdentityToken(
  identityToken: string,
): string | null {
  return appleSubjectFromIdToken(identityToken);
}

export type ValidatedAppleIdToken = {
  sub: string;
  iss: string;
  aud: string;
  exp: number;
};

/**
 * Validate id_token claims returned by Apple's token endpoint.
 * `expectedClientId` must be the same allowlisted client_id used for exchange.
 */
export function validateAppleIdTokenClaims(
  idToken: string | null | undefined,
  expectedClientId: string,
  nowSeconds: number,
  clockSkewSeconds: number = ID_TOKEN_CLOCK_SKEW_SECONDS,
):
  | { ok: true; value: ValidatedAppleIdToken }
  | ValidationFailure {
  if (!idToken || !idToken.trim()) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_TOKEN_EXCHANGE_FAILED,
      message:
        "Apple token exchange did not return an id_token. Nothing was deleted.",
      httpStatus: 502,
    };
  }

  const jwtParts = idToken.trim().split(".");
  if (jwtParts.length !== 3 || jwtParts.some((p) => p.length === 0)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_TOKEN_EXCHANGE_FAILED,
      message:
        "Apple token exchange returned a malformed id_token. Nothing was deleted.",
      httpStatus: 502,
    };
  }

  const payload = decodeJwtPayloadUnsafe(idToken.trim());
  if (!payload) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_TOKEN_EXCHANGE_FAILED,
      message:
        "Apple token exchange returned an unreadable id_token. Nothing was deleted.",
      httpStatus: 502,
    };
  }

  const issRaw = payload.iss;
  const iss = typeof issRaw === "string" ? issRaw.trim() : "";
  if (!iss || !APPLE_ID_TOKEN_ISSUERS.some((allowed) => allowed === iss)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message: "Apple id_token issuer is not trusted. Nothing was deleted.",
      httpStatus: 403,
    };
  }

  const expectedAud = expectedClientId.trim();
  if (!expectedAud) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.NOT_CONFIGURED,
      message:
        "No Apple client id was selected for audience validation. Nothing was deleted.",
      httpStatus: 503,
    };
  }

  const audRaw = payload.aud;
  let audMatch = false;
  let audValue = "";
  if (typeof audRaw === "string") {
    audValue = audRaw.trim();
    audMatch = audValue === expectedAud;
  } else if (Array.isArray(audRaw)) {
    const audiences = audRaw
      .filter((v): v is string => typeof v === "string")
      .map((v) => v.trim())
      .filter(Boolean);
    audMatch = audiences.includes(expectedAud);
    audValue = audiences[0] ?? "";
  }
  if (!audMatch) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message:
        "Apple id_token audience does not match the client id used for exchange. Nothing was deleted.",
      httpStatus: 403,
    };
  }

  const expRaw = payload.exp;
  const exp =
    typeof expRaw === "number"
      ? expRaw
      : typeof expRaw === "string" && expRaw.trim()
        ? Number(expRaw)
        : NaN;
  if (!Number.isFinite(exp)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message:
        "Apple id_token is missing a valid expiry. Nothing was deleted.",
      httpStatus: 403,
    };
  }
  if (exp + clockSkewSeconds < nowSeconds) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message: "Apple id_token has expired. Nothing was deleted.",
      httpStatus: 403,
    };
  }

  const subRaw = payload.sub;
  const sub = typeof subRaw === "string" ? subRaw.trim() : "";
  if (!sub) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message: "Apple id_token is missing a subject claim. Nothing was deleted.",
      httpStatus: 403,
    };
  }

  return {
    ok: true,
    value: {
      sub,
      iss,
      aud: audValue || expectedAud,
      exp,
    },
  };
}

/**
 * The Apple `sub` from the exchange id_token must match a stored Apple
 * identity for this Supabase user. Otherwise reject (fail closed).
 */
export function validateAppleIdentityMatch(
  tokenSubject: string | null,
  storedAppleSubjects: readonly string[],
): ValidationFailure | null {
  if (!tokenSubject) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message: "Apple id_token is missing a subject claim. Nothing was deleted.",
      httpStatus: 403,
    };
  }
  const normalizedStored = storedAppleSubjects
    .map((s) => s.trim())
    .filter(Boolean);
  if (normalizedStored.length === 0) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message:
        "This account has no Apple identity on the server. Nothing was deleted.",
      httpStatus: 403,
    };
  }
  if (!normalizedStored.includes(tokenSubject)) {
    return {
      ok: false,
      code: AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      message:
        "The Apple account used for confirmation does not match this Phrasa account. Nothing was deleted.",
      httpStatus: 403,
    };
  }
  return null;
}

/**
 * Combined post-exchange gate: claim validation + stored-subject match.
 * Call only with the id_token from Apple's token endpoint response and the
 * same allowlisted client_id used for the exchange.
 */
export function validateExchangedAppleIdentity(
  idToken: string | null | undefined,
  expectedClientId: string,
  storedAppleSubjects: readonly string[],
  nowSeconds: number,
): ValidationFailure | null {
  const claims = validateAppleIdTokenClaims(
    idToken,
    expectedClientId,
    nowSeconds,
  );
  if (!claims.ok) return claims;
  return validateAppleIdentityMatch(claims.value.sub, storedAppleSubjects);
}

/** Ordered pipeline stages for documentation and tests. */
export const DELETION_PIPELINE_STAGES = [
  "validate_secrets",
  "validate_request",
  "validate_caller",
  "resolve_allowlisted_client_id",
  "load_stored_apple_subjects",
  "exchange_authorization_code",
  "validate_exchanged_id_token",
  "match_apple_identity",
  "revoke_apple_token",
  "delete_supabase_user",
  "clear_client_session",
] as const;

export type DeletionPipelineStage = (typeof DELETION_PIPELINE_STAGES)[number];

/**
 * Documents the fail-closed branch for each stage. Used by tests so the
 * scaffold cannot silently re-order “delete before revoke” or trust client tokens.
 */
export const FAIL_CLOSED_RULES: Record<
  DeletionPipelineStage,
  { mayMutateApple: boolean; mayMutateSupabase: boolean; note: string }
> = {
  validate_secrets: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "Missing secrets / empty APPLE_CLIENT_IDS allowlist → 503; no network calls.",
  },
  validate_request: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "Invalid body → 400. Client identity_token is not required or trusted. client_id required by shape only.",
  },
  validate_caller: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "JWT missing or expected_user_id mismatch → 401/403.",
  },
  resolve_allowlisted_client_id: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "Request client_id must be an exact member of server allowlist; that id is used for exchange + aud.",
  },
  load_stored_apple_subjects: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "Admin read only; empty Apple identities fail closed before exchange when possible.",
  },
  exchange_authorization_code: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "Token endpoint uses the allowlisted client_id + matching client_secret.sub. Failure → stop.",
  },
  validate_exchanged_id_token: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "Require iss/aud/exp/sub on Apple-returned id_token only — aud must equal allowlisted client_id used for exchange.",
  },
  match_apple_identity: {
    mayMutateApple: false,
    mayMutateSupabase: false,
    note: "id_token sub must match stored Apple identity; do not revoke on mismatch.",
  },
  revoke_apple_token: {
    mayMutateApple: true,
    mayMutateSupabase: false,
    note: "Revoke must succeed before any Supabase user delete; uses same client_id as exchange.",
  },
  delete_supabase_user: {
    mayMutateApple: true,
    mayMutateSupabase: true,
    note: "Only after successful revoke. Failure here is partial (Apple already revoked).",
  },
  clear_client_session: {
    mayMutateApple: true,
    mayMutateSupabase: true,
    note: "Client-side only after 2xx from this function.",
  },
};

export function errorResponseBody(
  code: AppleLinkedDeletionErrorCode,
  message: string,
): { code: string; message: string; error: string } {
  return { code, message, error: message };
}

/** application/x-www-form-urlencoded body for Apple token + revoke endpoints. */
export function formEncode(fields: Record<string, string>): string {
  return Object.entries(fields)
    .map(
      ([key, value]) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(value)}`,
    )
    .join("&");
}

export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

/**
 * client_secret JWT claims per Apple Generate and validate tokens docs.
 * `sub` must equal the client_id used on the token/revoke request for that
 * platform (com.phrasa.app vs com.phrasa.mac are not interchangeable).
 */
export function buildClientSecretClaims(input: {
  teamId: string;
  clientId: string;
  nowSeconds: number;
  expiresInSeconds?: number;
}): { iss: string; iat: number; exp: number; aud: string; sub: string } {
  const expiresIn = input.expiresInSeconds ?? 60 * 5;
  return {
    iss: input.teamId,
    iat: input.nowSeconds,
    exp: input.nowSeconds + expiresIn,
    aud: "https://appleid.apple.com",
    sub: input.clientId,
  };
}

export type AppleTokenExchangeResult = {
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
  token_type?: string;
  expires_in?: number;
};

/**
 * Prefer refresh_token for revoke; fall back to access_token.
 * Returns null when neither is present (caller must fail closed).
 */
export function pickTokenForRevocation(
  tokens: AppleTokenExchangeResult,
): { token: string; tokenTypeHint: "refresh_token" | "access_token" } | null {
  if (tokens.refresh_token && tokens.refresh_token.trim()) {
    return {
      token: tokens.refresh_token.trim(),
      tokenTypeHint: "refresh_token",
    };
  }
  if (tokens.access_token && tokens.access_token.trim()) {
    return {
      token: tokens.access_token.trim(),
      tokenTypeHint: "access_token",
    };
  }
  return null;
}
