-- ===========================================================================
-- Phrasa — Outline mode
-- Adds an optional outline (ordered talking points) to scripts. Stored as JSON:
--   [{ "id": "...", "text": "...", "note": "..." }, ...]
-- RLS already covers the scripts table, so no new policies are needed.
-- ===========================================================================

alter table public.scripts
  add column if not exists outline jsonb;
