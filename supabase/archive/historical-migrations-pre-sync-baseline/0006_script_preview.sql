-- ===========================================================================
-- Server-side library previews.
--
-- The library list needs only a ~180-char preview per script, but the client
-- had to download every full body to build it (a 50-script library of
-- ten-minute reads pulls ~0.5 MB of text on every /library load). This
-- generated column keeps the computation in Postgres so listScripts can
-- select everything *except* body.
--
-- The expression mirrors toSummary() in lib/scripts/types.ts exactly:
-- collapse whitespace runs to single spaces, trim, take the first 180 chars.
-- It recomputes automatically whenever body changes (STORED), and the client
-- falls back to selecting full rows if this column doesn't exist yet — so
-- app and migration can deploy in either order.
--
-- Idempotent / re-runnable: ADD COLUMN IF NOT EXISTS.
-- ===========================================================================

alter table public.scripts
  add column if not exists preview text
  generated always as (
    left(btrim(regexp_replace(body, '\s+', ' ', 'g')), 180)
  ) stored;
