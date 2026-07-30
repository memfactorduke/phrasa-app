# Supabase Edge Functions (Phrasa)

| Function | Purpose | Deployed? |
| --- | --- | --- |
| `delete-apple-linked-account` | SIWA reauth code + allowlisted client_id → Apple revoke → delete Supabase user | **Yes** (production endpoint and secret gate verified 2026-07-28; disposable-account acceptance still required) |

This checkout is linked to the dedicated Phrasa production project. The live
endpoint returned the function's structured method error and advanced past its
required-secret gate to the expected unauthenticated error on 2026-07-28.
That proves deployment/configuration presence, not successful Apple revocation
or account deletion. Never put the service-role key or Apple `.p8` in the
native apps.

Cross-platform note: iOS (`com.phrasa.app`) and Mac (`com.phrasa.mac`) use
distinct SIWA client ids. Configure `APPLE_CLIENT_IDS` with both before
production deletion on either platform. See
`delete-apple-linked-account/README.md`.
