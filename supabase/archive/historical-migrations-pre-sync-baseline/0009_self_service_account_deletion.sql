-- ===========================================================================
-- Phrasa — authenticated self-service account deletion
--
-- Mobile clients cannot carry a Supabase service-role secret. This narrowly
-- scoped SECURITY DEFINER RPC lets an authenticated user delete only themself.
-- The target id always comes from the verified JWT via auth.uid(); callers can
-- neither supply nor influence another user's id.
--
-- Deleting auth.users is transactional and every Phrasa-owned row references
-- it ON DELETE CASCADE (profiles, folders, scripts, user_settings,
-- subscriptions). Supabase Storage is deliberately NOT modified here: its SQL
-- rows are metadata only, so SQL deletion would orphan the real objects. The
-- mobile client removes files through the Storage API first. Supabase also
-- refuses to delete auth users who still own Storage objects, making any missed
-- file fail closed rather than leaving an orphan.
-- ===========================================================================

drop function if exists public.delete_own_account(text);

create or replace function public.delete_own_account(
  confirmation text,
  expected_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
set statement_timeout = '15s'
as $$
declare
  target_user_id uuid := (select auth.uid());
begin
  if target_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication is required to delete an account.';
  end if;

  -- The client supplies the identity it displayed in the destructive
  -- confirmation UI. It never controls the delete target: this equality guard
  -- only stops a concurrent session swap from deleting the newly active user.
  if expected_user_id is distinct from target_user_id then
    raise exception using
      errcode = '42501',
      message = 'The signed-in account changed before deletion was confirmed.';
  end if;

  if confirmation is distinct from 'DELETE' then
    raise exception using
      errcode = '22023',
      message = 'Account deletion was not confirmed.';
  end if;

  delete from auth.users
  where id = target_user_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'The authenticated account no longer exists.';
  end if;
end;
$$;

revoke all on function public.delete_own_account(text, uuid) from public;
revoke all on function public.delete_own_account(text, uuid) from anon;
grant execute on function public.delete_own_account(text, uuid) to authenticated;
