import { describe, expect, it } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import {
  APPLE_CLIENT_ID_SECRET,
  APPLE_CLIENT_IDS_SECRET,
  APPLE_ID_TOKEN_ISSUERS,
  APPLE_JWKS_URL,
  APPLE_REVOKE_URL,
  APPLE_TOKEN_URL,
  AppleLinkedDeletionErrorCode,
  CONFIRMATION_DELETE,
  DELETION_PIPELINE_STAGES,
  FAIL_CLOSED_RULES,
  FUNCTION_NAME,
  KNOWN_PRODUCTION_APPLE_CLIENT_IDS,
  REQUIRED_SECRET_NAMES,
  assertSecretsConfigured,
  buildClientSecretClaims,
  formEncode,
  missingSecrets,
  parseAppleClientIdAllowlist,
  pickTokenForRevocation,
  resolveAllowlistedClientId,
  validateAppleIdTokenClaims,
  validateAppleIdentityMatch,
  validateCallerMatchesExpected,
  validateDeletionRequest,
  validateExchangedAppleIdentity,
  appleSubjectFromIdToken,
  // Extensionless import keeps website tsc happy. The Deno entrypoint retains
  // the explicit "./contract.ts" suffix required by its runtime.
} from "../../supabase/functions/delete-apple-linked-account/contract";
import {
  verifyAppleIdTokenSignatureAgainstKeys,
  type AppleJwk,
} from "../../supabase/functions/delete-apple-linked-account/apple-jwks";

const ROOT = process.cwd();
const FN_DIR = join(ROOT, "supabase", "functions", "delete-apple-linked-account");

function b64urlJson(obj: unknown): string {
  return Buffer.from(JSON.stringify(obj), "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function b64urlBytes(bytes: Uint8Array): string {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function fakeJwt(payload: Record<string, unknown>): string {
  return `${b64urlJson({ alg: "ES256", typ: "JWT" })}.${b64urlJson(payload)}.sig`;
}

const VALID_UUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const NOW = 1_700_000_000;
const IOS_CLIENT_ID = "com.phrasa.app";
const MAC_CLIENT_ID = "com.phrasa.mac";
const APPLE_SUB = "001234.apple";

function validBody(overrides: Record<string, unknown> = {}) {
  return {
    confirmation: CONFIRMATION_DELETE,
    expected_user_id: VALID_UUID,
    authorization_code: "fresh-apple-auth-code",
    client_id: IOS_CLIENT_ID,
    ...overrides,
  };
}

function validExchangeIdToken(
  clientId: string,
  overrides: Record<string, unknown> = {},
): string {
  return fakeJwt({
    iss: "https://appleid.apple.com",
    aud: clientId,
    exp: NOW + 3600,
    sub: APPLE_SUB,
    ...overrides,
  });
}

function fullSecrets(
  overrides: Record<string, string | undefined> = {},
): Record<string, string | undefined> {
  return {
    APPLE_TEAM_ID: "TEAM",
    APPLE_KEY_ID: "KEY",
    APPLE_PRIVATE_KEY: "PEM",
    [APPLE_CLIENT_IDS_SECRET]: `${IOS_CLIENT_ID},${MAC_CLIENT_ID}`,
    SUPABASE_URL: "https://example.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "service-role",
    ...overrides,
  };
}

describe("delete-apple-linked-account scaffold files", () => {
  it("ships contract, Deno entry, and operator README", () => {
    expect(existsSync(join(FN_DIR, "contract.ts"))).toBe(true);
    expect(existsSync(join(FN_DIR, "index.ts"))).toBe(true);
    expect(existsSync(join(FN_DIR, "apple-jwks.ts"))).toBe(true);
    expect(existsSync(join(FN_DIR, "README.md"))).toBe(true);
  });

  it("documents multi-client allowlist and no client identity_token", () => {
    const readme = readFileSync(join(FN_DIR, "README.md"), "utf8");
    expect(readme).toMatch(/RELEASE BLOCKER|not deployed/i);
    for (const name of REQUIRED_SECRET_NAMES) {
      expect(readme).toContain(name);
    }
    expect(readme).toContain(APPLE_CLIENT_IDS_SECRET);
    expect(readme).toContain(IOS_CLIENT_ID);
    expect(readme).toContain(MAC_CLIENT_ID);
    expect(readme).toContain(FUNCTION_NAME);
    expect(readme).toMatch(/not interchangeable|Do \*\*not\*\* send `identity_token`/i);
    expect(readme).toMatch(/id_token/);
  });

  it("entrypoint uses allowlisted client_id and exchange id_token only", () => {
    const index = readFileSync(join(FN_DIR, "index.ts"), "utf8");
    const jwks = readFileSync(join(FN_DIR, "apple-jwks.ts"), "utf8");
    expect(index).toContain('from "./contract.ts"');
    expect(index).toContain("Deno.serve");
    expect(index).toContain("parseAppleClientIdAllowlist");
    expect(index).toContain("resolveAllowlistedClientId");
    expect(index).toContain("validateExchangedAppleIdentity");
    expect(index).toContain("verifyAppleIdTokenSignature");
    expect(jwks).toContain("RSASSA-PKCS1-v1_5");
    expect(APPLE_JWKS_URL).toBe("https://appleid.apple.com/auth/keys");
    expect(index).toContain("exchange.tokens.id_token");
    expect(index).not.toMatch(/validated\.value\.identityToken/);
    expect(index).not.toMatch(/appleSubjectFromIdentityToken/);
    // Stored Apple subject is only identity_data.sub (never Supabase identity.id).
    expect(index).toMatch(/identity_data\?\.sub/);
    expect(index).not.toMatch(/identity_data\?\.sub\s*\?\?\s*identity\.id/);
    expect(index).toMatch(/RELEASE BLOCKER/);
    expect(APPLE_TOKEN_URL).toBe("https://appleid.apple.com/auth/token");
    expect(APPLE_REVOKE_URL).toBe("https://appleid.apple.com/auth/revoke");
    expect(index).not.toMatch(
      /-----BEGIN PRIVATE KEY-----\s*[A-Za-z0-9+/=\n]{80,}\s*-----END PRIVATE KEY-----/,
    );

    // Call sites inside Deno.serve (not earlier function declarations).
    const serveBody = index.slice(index.indexOf("Deno.serve"));
    const allowlistIdx = serveBody.indexOf("resolveAllowlistedClientId");
    const exchangeIdx = serveBody.indexOf("exchangeAuthorizationCode({");
    const signatureIdx = serveBody.indexOf("verifyAppleIdTokenSignature(");
    const identityIdx = serveBody.indexOf("validateExchangedAppleIdentity(");
    const revokeIdx = serveBody.indexOf("revokeAppleToken({");
    const deleteIdx = serveBody.indexOf("deleteSupabaseUser(");
    expect(allowlistIdx).toBeGreaterThan(0);
    expect(exchangeIdx).toBeGreaterThan(allowlistIdx);
    expect(signatureIdx).toBeGreaterThan(exchangeIdx);
    expect(identityIdx).toBeGreaterThan(signatureIdx);
    expect(revokeIdx).toBeGreaterThan(identityIdx);
    expect(deleteIdx).toBeGreaterThan(revokeIdx);
  });

  it("contract rejects trusting client identity_token as the request contract", () => {
    const contract = readFileSync(join(FN_DIR, "contract.ts"), "utf8");
    expect(contract).toMatch(/Never trust a client-supplied identity_token/);
    expect(contract).toMatch(/not interchangeable/i);
    expect(contract).toContain(IOS_CLIENT_ID);
    expect(contract).toContain(MAC_CLIENT_ID);
  });
});

describe("Apple JWKS signature verification", () => {
  it("accepts a valid RS256 signature and rejects tampering or an unknown kid", async () => {
    const keyPair = (await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const publicJwk = (await crypto.subtle.exportKey(
      "jwk",
      keyPair.publicKey,
    )) as AppleJwk;
    publicJwk.kid = "test-apple-key";
    publicJwk.alg = "RS256";
    publicJwk.use = "sig";

    const encodedHeader = b64urlJson({
      alg: "RS256",
      kid: publicJwk.kid,
      typ: "JWT",
    });
    const encodedPayload = b64urlJson({
      iss: "https://appleid.apple.com",
      aud: IOS_CLIENT_ID,
      exp: NOW + 3600,
      sub: APPLE_SUB,
    });
    const signingInput = `${encodedHeader}.${encodedPayload}`;
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      keyPair.privateKey,
      new TextEncoder().encode(signingInput),
    );
    const token = `${signingInput}.${b64urlBytes(new Uint8Array(signature))}`;

    expect(
      await verifyAppleIdTokenSignatureAgainstKeys(token, [publicJwk]),
    ).toBe(true);

    const tampered = `${encodedHeader}.${b64urlJson({
      iss: "https://attacker.invalid",
      aud: IOS_CLIENT_ID,
      exp: NOW + 3600,
      sub: APPLE_SUB,
    })}.${b64urlBytes(new Uint8Array(signature))}`;
    expect(
      await verifyAppleIdTokenSignatureAgainstKeys(tampered, [publicJwk]),
    ).toBe(false);

    expect(
      await verifyAppleIdTokenSignatureAgainstKeys(token, [
        { ...publicJwk, kid: "rotated-key" },
      ]),
    ).toBeNull();
  });
});

describe("required secrets and client id allowlist", () => {
  it("lists core server-only credentials without a single-client assumption", () => {
    expect(REQUIRED_SECRET_NAMES).toEqual([
      "APPLE_TEAM_ID",
      "APPLE_KEY_ID",
      "APPLE_PRIVATE_KEY",
      "SUPABASE_URL",
      "SUPABASE_SERVICE_ROLE_KEY",
    ]);
    expect(KNOWN_PRODUCTION_APPLE_CLIENT_IDS).toEqual([
      IOS_CLIENT_ID,
      MAC_CLIENT_ID,
    ]);
  });

  it("parses APPLE_CLIENT_IDS multi allowlist and merges legacy APPLE_CLIENT_ID", () => {
    expect(
      parseAppleClientIdAllowlist({
        [APPLE_CLIENT_IDS_SECRET]: "com.phrasa.app, com.phrasa.mac",
      }),
    ).toEqual([IOS_CLIENT_ID, MAC_CLIENT_ID]);
    expect(
      parseAppleClientIdAllowlist({
        [APPLE_CLIENT_ID_SECRET]: IOS_CLIENT_ID,
      }),
    ).toEqual([IOS_CLIENT_ID]);
    expect(
      parseAppleClientIdAllowlist({
        [APPLE_CLIENT_IDS_SECRET]: IOS_CLIENT_ID,
        [APPLE_CLIENT_ID_SECRET]: MAC_CLIENT_ID,
      }),
    ).toEqual([IOS_CLIENT_ID, MAC_CLIENT_ID]);
    expect(
      parseAppleClientIdAllowlist({
        [APPLE_CLIENT_IDS_SECRET]: "com.phrasa.app;com.phrasa.app,com.phrasa.mac",
      }),
    ).toEqual([IOS_CLIENT_ID, MAC_CLIENT_ID]);
  });

  it("fails closed when core secrets or allowlist missing", () => {
    expect(missingSecrets(fullSecrets())).toEqual([]);
    expect(assertSecretsConfigured(fullSecrets())).toBeNull();

    for (const name of REQUIRED_SECRET_NAMES) {
      const partial = fullSecrets({ [name]: "  " });
      expect(missingSecrets(partial)).toContain(name);
      expect(assertSecretsConfigured(partial)?.code).toBe(
        AppleLinkedDeletionErrorCode.NOT_CONFIGURED,
      );
    }

    const noClients = fullSecrets({
      [APPLE_CLIENT_IDS_SECRET]: "",
      [APPLE_CLIENT_ID_SECRET]: undefined,
    });
    expect(missingSecrets(noClients)).toContain(APPLE_CLIENT_IDS_SECRET);
    expect(assertSecretsConfigured(noClients)?.httpStatus).toBe(503);
  });

  it("allowlists only exact configured client ids", () => {
    const allowlist = [IOS_CLIENT_ID, MAC_CLIENT_ID];
    expect(resolveAllowlistedClientId(IOS_CLIENT_ID, allowlist)).toEqual({
      ok: true,
      clientId: IOS_CLIENT_ID,
    });
    expect(resolveAllowlistedClientId(MAC_CLIENT_ID, allowlist)).toEqual({
      ok: true,
      clientId: MAC_CLIENT_ID,
    });
    const rejected = resolveAllowlistedClientId("com.attacker.app", allowlist);
    expect(rejected.ok).toBe(false);
    if (!rejected.ok) {
      expect(rejected.code).toBe(AppleLinkedDeletionErrorCode.INVALID_REQUEST);
      expect(rejected.message.toLowerCase()).toContain("allowlisted");
    }
    // iOS client id must not be accepted when only Mac is configured
    const macOnly = resolveAllowlistedClientId(IOS_CLIENT_ID, [MAC_CLIENT_ID]);
    expect(macOnly.ok).toBe(false);
  });
});

describe("validateDeletionRequest", () => {
  it("accepts a well-formed DELETE payload with client_id and without identity_token", () => {
    const result = validateDeletionRequest(validBody());
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.expectedUserId).toBe(VALID_UUID);
      expect(result.value.authorizationCode).toBe("fresh-apple-auth-code");
      expect(result.value.clientId).toBe(IOS_CLIENT_ID);
      expect(result.value.confirmation).toBe("DELETE");
      expect(
        "identityToken" in (result.value as unknown as Record<string, unknown>),
      ).toBe(false);
    }
  });

  it("accepts Mac client_id and ignores client-supplied identity_token", () => {
    const result = validateDeletionRequest(
      validBody({
        client_id: MAC_CLIENT_ID,
        identity_token: fakeJwt({ sub: "attacker.forged" }),
      }),
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.clientId).toBe(MAC_CLIENT_ID);
      expect(
        "identityToken" in (result.value as unknown as Record<string, unknown>),
      ).toBe(false);
    }
  });

  it("rejects non-objects, wrong confirmation, bad UUID, empty code, missing client_id", () => {
    expect(validateDeletionRequest(null).ok).toBe(false);
    expect(validateDeletionRequest([]).ok).toBe(false);
    expect(
      validateDeletionRequest(validBody({ confirmation: "CHECK" })).ok,
    ).toBe(false);
    expect(
      validateDeletionRequest(validBody({ expected_user_id: "not-a-uuid" })).ok,
    ).toBe(false);
    expect(
      validateDeletionRequest(validBody({ authorization_code: "  " })).ok,
    ).toBe(false);
    expect(validateDeletionRequest(validBody({ client_id: "" })).ok).toBe(
      false,
    );
    expect(validateDeletionRequest(validBody({ client_id: "!!" })).ok).toBe(
      false,
    );
  });

  it("never treats CHECK as a successful delete confirmation", () => {
    const result = validateDeletionRequest(
      validBody({ confirmation: "CHECK" }),
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.code).toBe(AppleLinkedDeletionErrorCode.INVALID_REQUEST);
      expect(result.message.toLowerCase()).toContain("not confirmed");
    }
  });
});

describe("caller and Apple identity guards", () => {
  it("requires caller JWT subject to match expected_user_id", () => {
    expect(validateCallerMatchesExpected(null, VALID_UUID)?.code).toBe(
      AppleLinkedDeletionErrorCode.UNAUTHORIZED,
    );
    expect(validateCallerMatchesExpected(VALID_UUID, VALID_UUID)).toBeNull();
    expect(
      validateCallerMatchesExpected(
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        VALID_UUID,
      )?.code,
    ).toBe(AppleLinkedDeletionErrorCode.ACCOUNT_CHANGED);
  });

  it("requires exchange id_token sub to match a stored Apple identity", () => {
    const sub = appleSubjectFromIdToken(validExchangeIdToken(IOS_CLIENT_ID));
    expect(sub).toBe(APPLE_SUB);
    expect(validateAppleIdentityMatch(sub, [APPLE_SUB])).toBeNull();
    expect(validateAppleIdentityMatch(sub, ["other.apple"])?.code).toBe(
      AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
    );
    expect(validateAppleIdentityMatch(sub, [])?.code).toBe(
      AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
    );
  });
});

describe("validateAppleIdTokenClaims (exchange id_token only)", () => {
  it("accepts well-formed tokens for iOS and Mac client ids", () => {
    for (const clientId of [IOS_CLIENT_ID, MAC_CLIENT_ID]) {
      const result = validateAppleIdTokenClaims(
        validExchangeIdToken(clientId),
        clientId,
        NOW,
      );
      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.value.sub).toBe(APPLE_SUB);
        expect(result.value.aud).toBe(clientId);
        expect(
          APPLE_ID_TOKEN_ISSUERS.map((s) => s.toLowerCase()),
        ).toContain(result.value.iss.toLowerCase());
      }
    }
  });

  it("rejects when aud is the other platform client id", () => {
    // Mac-issued token must not pass validation against iOS client id
    const result = validateAppleIdTokenClaims(
      validExchangeIdToken(MAC_CLIENT_ID),
      IOS_CLIENT_ID,
      NOW,
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.code).toBe(
        AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
      );
    }
  });

  it("requires Apple's canonical HTTPS issuer and accepts aud as array", () => {
    expect(
      validateAppleIdTokenClaims(
        validExchangeIdToken(IOS_CLIENT_ID, { iss: "appleid.apple.com" }),
        IOS_CLIENT_ID,
        NOW,
      ).ok,
    ).toBe(false);
    expect(
      validateAppleIdTokenClaims(
        validExchangeIdToken(IOS_CLIENT_ID, {
          aud: [IOS_CLIENT_ID, "other"],
        }),
        IOS_CLIENT_ID,
        NOW,
      ).ok,
    ).toBe(true);
  });

  it("rejects missing, malformed, wrong iss/aud, expired, or missing sub", () => {
    expect(validateAppleIdTokenClaims(null, IOS_CLIENT_ID, NOW).ok).toBe(
      false,
    );
    expect(
      validateAppleIdTokenClaims("not.a.jwt", IOS_CLIENT_ID, NOW).ok,
    ).toBe(false);
    expect(
      validateAppleIdTokenClaims(
        validExchangeIdToken(IOS_CLIENT_ID, {
          iss: "https://evil.example",
        }),
        IOS_CLIENT_ID,
        NOW,
      ).ok,
    ).toBe(false);
    expect(
      validateAppleIdTokenClaims(
        validExchangeIdToken(IOS_CLIENT_ID, { exp: NOW - 120 }),
        IOS_CLIENT_ID,
        NOW,
      ).ok,
    ).toBe(false);
    expect(
      validateAppleIdTokenClaims(
        validExchangeIdToken(IOS_CLIENT_ID, { sub: "" }),
        IOS_CLIENT_ID,
        NOW,
      ).ok,
    ).toBe(false);
  });

  it("allows small clock skew on exp", () => {
    expect(
      validateAppleIdTokenClaims(
        validExchangeIdToken(IOS_CLIENT_ID, { exp: NOW - 30 }),
        IOS_CLIENT_ID,
        NOW,
      ).ok,
    ).toBe(true);
  });
});

describe("validateExchangedAppleIdentity integration-shaped gate", () => {
  it("passes for iOS and Mac when claims and stored subject match", () => {
    for (const clientId of [IOS_CLIENT_ID, MAC_CLIENT_ID]) {
      expect(
        validateExchangedAppleIdentity(
          validExchangeIdToken(clientId),
          clientId,
          [APPLE_SUB],
          NOW,
        ),
      ).toBeNull();
    }
  });

  it("fails closed on forged client-style token with wrong aud even if sub matches", () => {
    const forged = fakeJwt({
      iss: "https://appleid.apple.com",
      aud: "com.attacker.app",
      exp: NOW + 3600,
      sub: APPLE_SUB,
    });
    const failure = validateExchangedAppleIdentity(
      forged,
      IOS_CLIENT_ID,
      [APPLE_SUB],
      NOW,
    );
    expect(failure?.code).toBe(
      AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
    );
  });

  it("fails closed when sub does not match stored Apple identity", () => {
    const failure = validateExchangedAppleIdentity(
      validExchangeIdToken(IOS_CLIENT_ID, { sub: "different.apple" }),
      IOS_CLIENT_ID,
      [APPLE_SUB],
      NOW,
    );
    expect(failure?.code).toBe(
      AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
    );
  });

  it("fails closed when Apple returns no id_token", () => {
    const failure = validateExchangedAppleIdentity(
      undefined,
      IOS_CLIENT_ID,
      [APPLE_SUB],
      NOW,
    );
    expect(failure?.code).toBe(
      AppleLinkedDeletionErrorCode.APPLE_TOKEN_EXCHANGE_FAILED,
    );
  });

  it("fails closed when account has no stored Apple identity", () => {
    const failure = validateExchangedAppleIdentity(
      validExchangeIdToken(IOS_CLIENT_ID),
      IOS_CLIENT_ID,
      [],
      NOW,
    );
    expect(failure?.code).toBe(
      AppleLinkedDeletionErrorCode.APPLE_IDENTITY_MISMATCH,
    );
  });
});

describe("Apple token helpers", () => {
  it("builds client_secret claims with platform-specific sub", () => {
    for (const clientId of [IOS_CLIENT_ID, MAC_CLIENT_ID]) {
      const claims = buildClientSecretClaims({
        teamId: "TEAM123456",
        clientId,
        nowSeconds: 1_700_000_000,
      });
      expect(claims.iss).toBe("TEAM123456");
      expect(claims.sub).toBe(clientId);
      expect(claims.aud).toBe("https://appleid.apple.com");
      expect(claims.exp).toBe(claims.iat + 300);
    }
  });

  it("prefers refresh_token over access_token for revocation", () => {
    expect(
      pickTokenForRevocation({
        refresh_token: "r1",
        access_token: "a1",
      }),
    ).toEqual({ token: "r1", tokenTypeHint: "refresh_token" });
    expect(pickTokenForRevocation({ access_token: "a1" })).toEqual({
      token: "a1",
      tokenTypeHint: "access_token",
    });
    expect(pickTokenForRevocation({})).toBeNull();
  });

  it("form-encodes Apple POST bodies", () => {
    expect(formEncode({ a: "1", b: "x y" })).toBe("a=1&b=x%20y");
  });
});

describe("fail-closed pipeline contract", () => {
  it("orders allowlist → exchange → id_token validate → match → revoke → delete", () => {
    expect(DELETION_PIPELINE_STAGES).toEqual([
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
    ]);

    const allowlistAt = DELETION_PIPELINE_STAGES.indexOf(
      "resolve_allowlisted_client_id",
    );
    const exchangeAt = DELETION_PIPELINE_STAGES.indexOf(
      "exchange_authorization_code",
    );
    const validateAt = DELETION_PIPELINE_STAGES.indexOf(
      "validate_exchanged_id_token",
    );
    const matchAt = DELETION_PIPELINE_STAGES.indexOf("match_apple_identity");
    const revokeAt = DELETION_PIPELINE_STAGES.indexOf("revoke_apple_token");
    const deleteAt = DELETION_PIPELINE_STAGES.indexOf("delete_supabase_user");
    expect(allowlistAt).toBeLessThan(exchangeAt);
    expect(exchangeAt).toBeLessThan(validateAt);
    expect(validateAt).toBeLessThan(matchAt);
    expect(matchAt).toBeLessThan(revokeAt);
    expect(revokeAt).toBeLessThan(deleteAt);

    for (const stage of DELETION_PIPELINE_STAGES.slice(0, revokeAt)) {
      expect(FAIL_CLOSED_RULES[stage].mayMutateApple).toBe(false);
      expect(FAIL_CLOSED_RULES[stage].mayMutateSupabase).toBe(false);
    }
    expect(FAIL_CLOSED_RULES.revoke_apple_token.mayMutateSupabase).toBe(false);
    expect(FAIL_CLOSED_RULES.delete_supabase_user.mayMutateApple).toBe(true);
    expect(FAIL_CLOSED_RULES.validate_exchanged_id_token.note).toMatch(
      /allowlisted client_id/i,
    );
  });

  it("exposes stable error codes consumed by the native mapper", () => {
    expect(Object.values(AppleLinkedDeletionErrorCode).sort()).toEqual(
      [
        "ACCOUNT_CHANGED",
        "ACCOUNT_DELETE_FAILED",
        "APPLE_IDENTITY_MISMATCH",
        "APPLE_REVOCATION_NOT_CONFIGURED",
        "APPLE_REVOKED_ACCOUNT_DELETE_FAILED",
        "APPLE_TOKEN_EXCHANGE_FAILED",
        "APPLE_TOKEN_REVOKE_FAILED",
        "INVALID_REQUEST",
        "UNAUTHORIZED",
      ].sort(),
    );
  });
});
