-- ===========================================================================
-- Phrasa — webhook event-ordering guard
-- Lemon Squeezy retries aggressively and does not guarantee in-order webhook
-- delivery, so the webhook needs an event clock to refuse stale deliveries
-- (e.g. a re-delivered `paused` arriving after a `resumed`). We persist the
-- subscription object's own `updated_at` from the event payload here; the
-- table's `updated_at` can't serve that purpose because it is trigger-managed
-- server write time.
-- ===========================================================================

alter table public.subscriptions
  add column if not exists ls_event_at timestamptz;
