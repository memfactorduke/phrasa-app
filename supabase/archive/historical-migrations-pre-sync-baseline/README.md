# Historical Supabase migrations (pre sync baseline)

**Do not apply these files to any new Phrasa Supabase project.**

This directory archives the pre-rebuild SQL chain (`0001`–`0011`) that mixed
optional native library sync with browser-era billing, Lemon Squeezy webhooks,
analytics, profiles, storage uploads, and related hardening patches.

They remain only as archaeology for reading past design decisions. The active
schema for a dedicated Phrasa project is the single migration under
`supabase/migrations/`. Supabase CLI / dashboard workflows that scan
`supabase/migrations` will not install this archive.

| File | Why it is historical only |
| --- | --- |
| `0001_init.sql` | profiles, storage `script-uploads`, unhardened helpers |
| `0002_billing.sql` | Lemon Squeezy `subscriptions` |
| `0003_outline.sql` | outline column (now in the active baseline) |
| `0004_webhook_event_ordering.sql` | billing webhook ordering |
| `0005_touch_opened_preserves_updated_at.sql` | `last_opened_at` trigger (now in baseline) |
| `0006_script_preview.sql` | generated `preview` column (not used by native sync) |
| `0007_advisor_hardening.sql` | advisor pass over the old surface |
| `0008_analytics_events.sql` | analytics ingest table |
| `0009_self_service_account_deletion.sql` | account deletion RPC (now in baseline) |
| `0010_atomic_subscription_webhook.sql` | billing webhook RPC |
| `0011_subscription_identity_ordering.sql` | subscription identity ordering |

If you need those behaviors, redesign them deliberately. Never reintroduce this
chain by moving files back into `supabase/migrations/`.
