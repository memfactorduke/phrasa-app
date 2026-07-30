-- ===========================================================================
-- Phrasa — sync table ACL remediation (forward-only)
--
-- Remediate verified live privilege drift on the three native-sync tables:
--   public.folders, public.scripts, public.user_settings
--
-- Desired exact table privileges (and nothing else):
--   authenticated: SELECT, INSERT, UPDATE, DELETE
--   service_role:  SELECT, INSERT, UPDATE, DELETE
--   anon:          none
--   PUBLIC:        none
--
-- Live drift this fixes:
--   - authenticated held SIDU plus TRUNCATE / REFERENCES / TRIGGER
--   - service_role lacked SIDU
--
-- Strategy (idempotent, ordered, per table):
--   1. REVOKE ALL from public, anon, authenticated, service_role
--   2. GRANT SELECT, INSERT, UPDATE, DELETE to authenticated and service_role
--
-- REVOKE ALL + GRANT of the exact DML set is safe to re-run. Does not touch
-- RLS policies, triggers, functions, or platform-managed objects.
-- ===========================================================================

-- ---- public.folders --------------------------------------------------------
revoke all on table public.folders from public;
revoke all on table public.folders from anon;
revoke all on table public.folders from authenticated;
revoke all on table public.folders from service_role;
grant select, insert, update, delete on table public.folders to authenticated;
grant select, insert, update, delete on table public.folders to service_role;

-- ---- public.scripts --------------------------------------------------------
revoke all on table public.scripts from public;
revoke all on table public.scripts from anon;
revoke all on table public.scripts from authenticated;
revoke all on table public.scripts from service_role;
grant select, insert, update, delete on table public.scripts to authenticated;
grant select, insert, update, delete on table public.scripts to service_role;

-- ---- public.user_settings --------------------------------------------------
revoke all on table public.user_settings from public;
revoke all on table public.user_settings from anon;
revoke all on table public.user_settings from authenticated;
revoke all on table public.user_settings from service_role;
grant select, insert, update, delete on table public.user_settings to authenticated;
grant select, insert, update, delete on table public.user_settings to service_role;
