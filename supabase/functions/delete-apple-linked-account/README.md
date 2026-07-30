# `delete-apple-linked-account`

Server-only Sign in with Apple **token revocation + Phrasa account deletion**.

**RELEASE BLOCKER: deployed ACTIVE in the production Phrasa project, but
end-to-end disposable-account acceptance is still pending.**
The live endpoint and required-secret gate were safely verified on 2026-07-28
without sending a deletion request. Native clients call this function for
Apple-linked deletion and **fail closed** until a fresh Apple authorization
successfully revokes access and deletes a disposable account in live QA on both
platforms.

## Why this exists

Apple requires apps that use Sign in with Apple to support account deletion and
to revoke the user’s Apple tokens via the Sign in with Apple REST API when the
account is deleted (see Apple TN3194 and `/auth/revoke`).

Apple private credentials (`.p8` key, Team ID, Key ID) **must never ship in the
iOS/Mac app**. This Edge Function holds them as Supabase secrets, exchanges a
**fresh one-time `authorization_code`** from SIWA reauthorization on the device
using the **platform’s own SIWA client id**, derives identity from the
**`id_token` Apple returns on that HTTPS exchange**, revokes with Apple, then
deletes the Supabase `auth.users` row (cascading folders / scripts /
user_settings).

## Cross-platform client ids (do not simplify incorrectly)

| Platform | Bundle / SIWA client id |
| --- | --- |
| iOS / iPadOS | `com.phrasa.app` |
| macOS | `com.phrasa.mac` |

Authorization codes are issued to a specific client id. **A single
`APPLE_CLIENT_ID` cannot necessarily exchange codes issued to both clients.**
Grouped App IDs (shared Apple user across devices) do **not** make `client_id`
interchangeable on Apple’s token/revoke endpoints. Operators must allowlist
**both** values for production iOS + Mac deletion.

## Trust model

- **Do not trust a client-supplied `identity_token`.** That field is not part of
  the request contract and is never used for subject matching.
- Client sends `client_id` = current app bundle id. Server checks exact membership
  in the configured allowlist (`APPLE_CLIENT_IDS`, optionally plus legacy
  `APPLE_CLIENT_ID`).
- That same allowlisted `client_id` is used for:
  1. `client_secret` JWT `sub`
  2. Apple `/auth/token` exchange `client_id`
  3. Returned `id_token` `aud` validation
  4. Apple `/auth/revoke` `client_id`
- After a successful exchange, validate the returned `id_token`:
  - RS256 signature against Apple’s live JWKS (one-hour cache, forced refresh
    once when a signing key rotates)
  - `iss` exactly equals `https://appleid.apple.com`
  - `aud` == the allowlisted client id used for exchange
  - `exp` not expired (small clock-skew allowance)
  - `sub` present and equal to a stored Supabase Apple identity for the user
- Only then revoke; only then delete.

## Fail-closed order

1. Require configured secrets (including a non-empty client id allowlist)  
2. Validate body (`confirmation=DELETE`, UUID, authorization_code, client_id shape)  
3. Require caller JWT `sub` == `expected_user_id`  
4. Resolve request `client_id` against server allowlist  
5. Load stored Apple identities for the user (admin read; no mutation)  
6. Exchange `authorization_code` → tokens with that allowlisted client_id  
7. Verify Apple-returned `id_token` signature, validate claims, and match `sub`
8. **Revoke** with Apple (must succeed)  
9. **Then** delete Supabase user via service role  

If steps 4–7 fail → stop; **nothing deleted**.  
If step 8 fails → HTTP 502, **nothing deleted**.  
If step 9 fails after 8 → HTTP 500 `APPLE_REVOKED_ACCOUNT_DELETE_FAILED` (partial).

## Required secrets

Set on the dedicated Phrasa Supabase project (never commit values):

| Secret | Source |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer → Membership |
| `APPLE_KEY_ID` | Keys → Sign in with Apple key |
| `APPLE_PRIVATE_KEY` | Contents of `AuthKey_XXXXX.p8` (PEM; `\n` newlines OK) |
| `APPLE_CLIENT_IDS` | Comma-separated allowlist, e.g. `com.phrasa.app,com.phrasa.mac` |
| `APPLE_CLIENT_ID` | Optional single-id legacy; merged into allowlist if set |
| `SUPABASE_URL` | Project URL (often injected automatically) |
| `SUPABASE_SERVICE_ROLE_KEY` | Project settings → API (server only) |
| `SUPABASE_ANON_KEY` or `SUPABASE_PUBLISHABLE_KEY` | For `/auth/v1/user` caller resolve |

Example (operator machine with Supabase CLI linked to the project):

```bash
supabase secrets set \
  APPLE_TEAM_ID=XXXXXXXXXX \
  APPLE_KEY_ID=YYYYYYYYYY \
  APPLE_CLIENT_IDS="com.phrasa.app,com.phrasa.mac" \
  APPLE_PRIVATE_KEY="$(cat AuthKey_XXXXX.p8)"
# SUPABASE_* usually provided by the Edge runtime; set service role only if needed.
```

## Deploy / update (operator — not automated here)

```bash
supabase functions deploy delete-apple-linked-account --project-ref <project-ref>
```

After deployment or any secret/code change, live-test with disposable Apple
sandbox accounts on **both** platforms:

1. Sign in with Apple in Phrasa (iOS and Mac)  
2. Delete account → type DELETE → Continue with Apple  
3. Confirm Apple ID → Sign in with Apple no longer lists Phrasa (or shows revoked)  
4. Confirm Supabase user and synced rows are gone  
5. Confirm email/password deletion path still works without this function  

## Client contract

`POST /functions/v1/delete-apple-linked-account`

Headers: `Authorization: Bearer <user access token>`

```json
{
  "confirmation": "DELETE",
  "expected_user_id": "<uuid>",
  "authorization_code": "<from ASAuthorizationAppleIDCredential>",
  "client_id": "com.phrasa.app"
}
```

Mac sends `"client_id": "com.phrasa.mac"`. Do **not** send `identity_token`.
The server ignores client identity tokens and binds identity only to Apple’s
exchange `id_token`.

Stable error `code` values: see `contract.ts` (`AppleLinkedDeletionErrorCode`).

## Residual blockers (do not clear without evidence)

- `APPLE_CLIENT_IDS` must include every shipping platform’s SIWA client id  
- No live sandbox revoke + delete evidence recorded on iOS and Mac  
- SIWA provider enabled in Supabase Auth and Apple capability/profiles still
  required for the whole auth product  
- Deploy the reviewed JWKS-verification update before claiming it is active in
  production; this repository change alone does not alter the live function
