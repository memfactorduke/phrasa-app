/**
 * Supabase Edge Function: delete-apple-linked-account
 *
 * RELEASE BLOCKER: deployed in the production Phrasa project, but
 * disposable-account revoke/delete acceptance remains pending on both iOS and
 * Mac.
 *
 * Production path for Sign in with Apple account deletion:
 *   1. Authenticated caller + DELETE confirmation + fresh authorization_code
 *   2. Allowlist request client_id (iOS com.phrasa.app / Mac com.phrasa.mac)
 *   3. Exchange authorization_code → tokens using that allowlisted client_id
 *      (client_secret.sub must match; platforms are not interchangeable)
 *   4. Derive identity only from the id_token Apple returns over HTTPS; validate
 *      iss, aud==allowlisted client_id, exp, and sub against stored Apple identity
 *   5. Revoke with Apple (must succeed)
 *   6. Delete auth.users via service role (cascades folders/scripts/user_settings)
 *
 * Never trust a client-supplied identity_token. That field is not part of the
 * request contract; identity comes only from Apple's token-endpoint response.
 *
 * Apple private key (.p8), Team ID, Key ID, and client id allowlist never ship
 * in the app.
 *
 * Deploy only after:
 *   - supabase secrets set for REQUIRED_SECRET_NAMES + APPLE_CLIENT_IDS
 *   - function deployed to the dedicated Phrasa project
 *   - live revoke + delete tested on both iOS and Mac with disposable accounts
 *
 * Until then, native clients fail closed with APPLE_REVOCATION_NOT_CONFIGURED.
 */

import {
  APPLE_CLIENT_ID_SECRET,
  APPLE_CLIENT_IDS_SECRET,
  APPLE_JWKS_URL,
  APPLE_REVOKE_URL,
  APPLE_TOKEN_URL,
  AppleLinkedDeletionErrorCode,
  assertSecretsConfigured,
  buildClientSecretClaims,
  errorResponseBody,
  formEncode,
  parseAppleClientIdAllowlist,
  pickTokenForRevocation,
  resolveAllowlistedClientId,
  validateCallerMatchesExpected,
  validateDeletionRequest,
  validateExchangedAppleIdentity,
  type AppleTokenExchangeResult,
} from "./contract.ts";
import {
  verifyAppleIdTokenSignatureAgainstKeys,
  type AppleJwk,
} from "./apple-jwks.ts";

// Deno / Supabase Edge runtime globals.
declare const Deno: {
  env: { get(key: string): string | undefined };
  serve(handler: (req: Request) => Response | Promise<Response>): void;
};

type JsonRecord = Record<string, unknown>;

const appleJwksCache: {
  expiresAt: number;
  keys: AppleJwk[];
} = {
  expiresAt: 0,
  keys: [],
};

function jsonResponse(status: number, body: JsonRecord): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function envMap(): Record<string, string | undefined> {
  return {
    APPLE_TEAM_ID: Deno.env.get("APPLE_TEAM_ID"),
    APPLE_KEY_ID: Deno.env.get("APPLE_KEY_ID"),
    APPLE_PRIVATE_KEY: Deno.env.get("APPLE_PRIVATE_KEY"),
    [APPLE_CLIENT_IDS_SECRET]: Deno.env.get(APPLE_CLIENT_IDS_SECRET),
    [APPLE_CLIENT_ID_SECRET]: Deno.env.get(APPLE_CLIENT_ID_SECRET),
    SUPABASE_URL: Deno.env.get("SUPABASE_URL") ?? Deno.env.get("SUPABASE_PROJECT_URL"),
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  };
}

function bearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match?.[1]?.trim() || null;
}

/**
 * Minimal ES256 client_secret JWT using Web Crypto (PKCS8 .p8 PEM).
 * See Apple: Generate and validate tokens.
 * `clientId` must be the allowlisted platform client id for this exchange.
 */
async function createAppleClientSecret(input: {
  teamId: string;
  keyId: string;
  clientId: string;
  privateKeyPem: string;
  nowSeconds: number;
}): Promise<string> {
  const claims = buildClientSecretClaims({
    teamId: input.teamId,
    clientId: input.clientId,
    nowSeconds: input.nowSeconds,
  });
  const header = { alg: "ES256", kid: input.keyId, typ: "JWT" };
  const encode = (value: unknown) =>
    base64Url(new TextEncoder().encode(JSON.stringify(value)));
  const signingInput = `${encode(header)}.${encode(claims)}`;
  const key = await importApplePrivateKey(input.privateKeyPem);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]!);
  const b64 = btoa(binary);
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function loadAppleJwks(forceRefresh = false): Promise<AppleJwk[]> {
  const now = Date.now();
  if (
    !forceRefresh &&
    appleJwksCache.keys.length > 0 &&
    appleJwksCache.expiresAt > now
  ) {
    return appleJwksCache.keys;
  }

  const response = await fetch(APPLE_JWKS_URL, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) return [];
  const json = (await response.json()) as { keys?: unknown };
  if (!Array.isArray(json.keys)) return [];
  const keys = json.keys.filter(
    (candidate): candidate is AppleJwk =>
      candidate != null &&
      typeof candidate === "object" &&
      typeof (candidate as AppleJwk).kid === "string" &&
      (candidate as AppleJwk).kty === "RSA",
  );
  appleJwksCache.keys = keys;
  appleJwksCache.expiresAt = now + 60 * 60 * 1_000;
  return keys;
}

async function verifyAppleIdTokenSignature(
  idToken: string | null | undefined,
): Promise<boolean> {
  let result = await verifyAppleIdTokenSignatureAgainstKeys(
    idToken,
    await loadAppleJwks(),
  );
  if (result === null) {
    // Apple may have rotated signing keys since the one-hour cache was filled.
    result = await verifyAppleIdTokenSignatureAgainstKeys(
      idToken,
      await loadAppleJwks(true),
    );
  }
  return result === true;
}

async function importApplePrivateKey(pem: string): Promise<CryptoKey> {
  const normalized = pem
    .replace(/\\n/g, "\n")
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const raw = Uint8Array.from(atob(normalized), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    raw,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

async function exchangeAuthorizationCode(input: {
  clientId: string;
  clientSecret: string;
  code: string;
}): Promise<
  | { ok: true; tokens: AppleTokenExchangeResult }
  | { ok: false; status: number; body: string }
> {
  const body = formEncode({
    client_id: input.clientId,
    client_secret: input.clientSecret,
    code: input.code,
    grant_type: "authorization_code",
  });
  const response = await fetch(APPLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const text = await response.text();
  if (!response.ok) {
    return { ok: false, status: response.status, body: text };
  }
  try {
    const tokens = JSON.parse(text) as AppleTokenExchangeResult;
    return { ok: true, tokens };
  } catch {
    return { ok: false, status: response.status, body: text };
  }
}

async function revokeAppleToken(input: {
  clientId: string;
  clientSecret: string;
  token: string;
  tokenTypeHint: "refresh_token" | "access_token";
}): Promise<{ ok: true } | { ok: false; status: number; body: string }> {
  const body = formEncode({
    client_id: input.clientId,
    client_secret: input.clientSecret,
    token: input.token,
    token_type_hint: input.tokenTypeHint,
  });
  const response = await fetch(APPLE_REVOKE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (response.ok) return { ok: true };
  const text = await response.text();
  return { ok: false, status: response.status, body: text };
}

async function resolveCallerUserId(
  supabaseUrl: string,
  userJwt: string,
): Promise<string | null> {
  const response = await fetch(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${userJwt}`,
      apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "",
    },
  });
  if (!response.ok) return null;
  const json = (await response.json()) as { id?: string };
  return typeof json.id === "string" ? json.id : null;
}

async function loadStoredAppleSubjects(
  supabaseUrl: string,
  serviceRoleKey: string,
  userId: string,
): Promise<string[]> {
  const response = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/auth/v1/admin/users/${userId}`,
    {
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        apikey: serviceRoleKey,
      },
    },
  );
  if (!response.ok) return [];
  const json = (await response.json()) as {
    identities?: Array<{ provider?: string; identity_data?: { sub?: string }; id?: string }>;
  };
  const subjects: string[] = [];
  for (const identity of json.identities ?? []) {
    if ((identity.provider ?? "").toLowerCase() !== "apple") continue;
    // Apple subject is only identity_data.sub — never the Supabase identity row
    // UUID (identity.id). Falling back to id would accept/compare the wrong
    // principal and can never honestly match Apple's id_token.sub.
    const sub = identity.identity_data?.sub;
    if (typeof sub === "string" && sub.trim()) subjects.push(sub.trim());
  }
  return subjects;
}

async function deleteSupabaseUser(
  supabaseUrl: string,
  serviceRoleKey: string,
  userId: string,
): Promise<{ ok: true } | { ok: false; status: number; body: string }> {
  const response = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/auth/v1/admin/users/${userId}`,
    {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        apikey: serviceRoleKey,
      },
    },
  );
  if (response.ok || response.status === 404) return { ok: true };
  const text = await response.text();
  return { ok: false, status: response.status, body: text };
}

if (typeof Deno !== "undefined") Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse(
      405,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.INVALID_REQUEST,
        "Method not allowed.",
      ),
    );
  }

  const secrets = envMap();
  const secretsFailure = assertSecretsConfigured(secrets);
  if (secretsFailure) {
    return jsonResponse(
      secretsFailure.httpStatus,
      errorResponseBody(secretsFailure.code, secretsFailure.message),
    );
  }

  const userJwt = bearerToken(req);
  if (!userJwt) {
    return jsonResponse(
      401,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.UNAUTHORIZED,
        "Authentication is required to delete an account.",
      ),
    );
  }

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return jsonResponse(
      400,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.INVALID_REQUEST,
        "Request body must be JSON.",
      ),
    );
  }

  const validated = validateDeletionRequest(rawBody);
  if (!validated.ok) {
    return jsonResponse(
      validated.httpStatus,
      errorResponseBody(validated.code, validated.message),
    );
  }

  const allowlist = parseAppleClientIdAllowlist(secrets);
  const allowedClient = resolveAllowlistedClientId(
    validated.value.clientId,
    allowlist,
  );
  if (!allowedClient.ok) {
    return jsonResponse(
      allowedClient.httpStatus,
      errorResponseBody(allowedClient.code, allowedClient.message),
    );
  }
  const appleClientId = allowedClient.clientId;

  const supabaseUrl = secrets.SUPABASE_URL!;
  const serviceRoleKey = secrets.SUPABASE_SERVICE_ROLE_KEY!;

  const callerUserId = await resolveCallerUserId(supabaseUrl, userJwt);
  const callerFailure = validateCallerMatchesExpected(
    callerUserId,
    validated.value.expectedUserId,
  );
  if (callerFailure) {
    return jsonResponse(
      callerFailure.httpStatus,
      errorResponseBody(callerFailure.code, callerFailure.message),
    );
  }

  // Admin read only — used after exchange to bind Apple's id_token sub.
  // Fail early when the account has no Apple identity so we do not burn the
  // one-time authorization_code needlessly.
  const storedAppleSubjects = await loadStoredAppleSubjects(
    supabaseUrl,
    serviceRoleKey,
    validated.value.expectedUserId,
  );
  if (storedAppleSubjects.length === 0) {
    return jsonResponse(
      403,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
        "This account has no Apple identity on the server. Nothing was deleted.",
      ),
    );
  }

  let clientSecret: string;
  try {
    clientSecret = await createAppleClientSecret({
      teamId: secrets.APPLE_TEAM_ID!,
      keyId: secrets.APPLE_KEY_ID!,
      clientId: appleClientId,
      privateKeyPem: secrets.APPLE_PRIVATE_KEY!,
      nowSeconds: Math.floor(Date.now() / 1000),
    });
  } catch {
    return jsonResponse(
      503,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.NOT_CONFIGURED,
        "Apple client secret could not be generated from server credentials. Nothing was deleted.",
      ),
    );
  }

  const exchange = await exchangeAuthorizationCode({
    clientId: appleClientId,
    clientSecret,
    code: validated.value.authorizationCode,
  });
  if (!exchange.ok) {
    return jsonResponse(
      502,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.APPLE_TOKEN_EXCHANGE_FAILED,
        "Apple did not accept the one-time authorization code for this client id. Nothing was deleted.",
      ),
    );
  }

  // Identity trust boundary: only the id_token from Apple's HTTPS exchange.
  // Verify Apple's RS256 signature against the live JWKS before trusting any
  // claims. A missing/rotated kid triggers one forced refresh. Client-supplied
  // identity_token (if any) is never read.
  const signatureValid = await verifyAppleIdTokenSignature(
    exchange.tokens.id_token,
  );
  if (!signatureValid) {
    return jsonResponse(
      403,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
        "Apple id_token signature could not be verified. Nothing was deleted.",
      ),
    );
  }

  // Audience must equal the same allowlisted client_id used for exchange.
  const identityFailure = validateExchangedAppleIdentity(
    exchange.tokens.id_token,
    appleClientId,
    storedAppleSubjects,
    Math.floor(Date.now() / 1000),
  );
  if (identityFailure) {
    return jsonResponse(
      identityFailure.httpStatus,
      errorResponseBody(identityFailure.code, identityFailure.message),
    );
  }

  const revokeMaterial = pickTokenForRevocation(exchange.tokens);
  if (!revokeMaterial) {
    return jsonResponse(
      502,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.APPLE_TOKEN_EXCHANGE_FAILED,
        "Apple token exchange did not return a revocable token. Nothing was deleted.",
      ),
    );
  }

  const revoked = await revokeAppleToken({
    clientId: appleClientId,
    clientSecret,
    token: revokeMaterial.token,
    tokenTypeHint: revokeMaterial.tokenTypeHint,
  });
  if (!revoked.ok) {
    return jsonResponse(
      502,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.APPLE_TOKEN_REVOKE_FAILED,
        "Apple token revocation failed. The Phrasa account was left unchanged.",
      ),
    );
  }

  const deleted = await deleteSupabaseUser(
    supabaseUrl,
    serviceRoleKey,
    validated.value.expectedUserId,
  );
  if (!deleted.ok) {
    return jsonResponse(
      500,
      errorResponseBody(
        AppleLinkedDeletionErrorCode.PARTIAL_REVOKED_ACCOUNT_DELETE_FAILED,
        "Apple access was revoked, but the Phrasa cloud account could not be deleted. Retry deletion or contact support.",
      ),
    );
  }

  return jsonResponse(200, {
    ok: true,
    revoked: true,
    deleted: true,
    user_id: validated.value.expectedUserId,
    client_id: appleClientId,
  });
});
