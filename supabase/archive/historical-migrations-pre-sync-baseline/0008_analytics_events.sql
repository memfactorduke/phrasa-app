-- ===========================================================================
-- Reader analytics events.
--
-- A thin, privacy-respecting funnel for diagnosing where voice-following trust
-- breaks down: voice entry, mic grant/deny, first track, completion, abandon.
-- NO PII and NO script content is ever stored — only the event name, primitive
-- props (counts/booleans/short enums), and an anonymous per-session id that is
-- NOT tied to an account.
--
-- Writes come exclusively from the service-role analytics route
-- (app/api/analytics/route.ts), which bypasses RLS. RLS is enabled with NO
-- policies, so anon and authenticated clients can neither read nor write the
-- table directly. The route degrades gracefully when this table is absent, so
-- the NEXT_PUBLIC_ANALYTICS_ENABLED flag and this migration can deploy in
-- either order.
--
-- Idempotent / re-runnable.
-- ===========================================================================

create table if not exists public.analytics_events (
  id          bigint generated always as identity primary key,
  event       text not null,
  props       jsonb not null default '{}'::jsonb,
  session_id  text,
  created_at  timestamptz not null default now()
);

-- Funnel queries slice by event over time.
create index if not exists analytics_events_event_created_idx
  on public.analytics_events (event, created_at desc);

alter table public.analytics_events enable row level security;
-- Intentionally NO policies: only the service role (which bypasses RLS) reads
-- or writes. There is no use case for client-side access to raw events.
