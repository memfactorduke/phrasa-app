-- ===========================================================================
-- Opening a script must not look like editing it.
--
-- touchOpened() updates only last_opened_at, but the scripts_set_updated_at
-- trigger (0001) fired on EVERY update and overwrote updated_at with now().
-- So in cloud mode merely opening a script in the prompter reordered the
-- library (listScripts sorts by updated_at desc) and made the card show
-- "edited just now" for a script that was only read. Local mode preserves
-- updatedAt on open; this brings cloud (web and mobile) in line.
--
-- Fix: fire the trigger only when last_opened_at is UNCHANGED. App code never
-- changes last_opened_at and content in the same UPDATE — touchOpened touches
-- only last_opened_at, every other write never touches it — so a pure
-- read-stamp keeps the old updated_at while real edits still bump it.
--
-- Idempotent / re-runnable: drop + recreate, same pattern as 0001.
-- ===========================================================================

drop trigger if exists scripts_set_updated_at on public.scripts;
create trigger scripts_set_updated_at
  before update on public.scripts
  for each row
  when (new.last_opened_at is not distinct from old.last_opened_at)
  execute function public.set_updated_at();
