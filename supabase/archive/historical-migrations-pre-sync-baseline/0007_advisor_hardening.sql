-- ===========================================================================
-- Phrasa — Supabase advisor hardening
--
-- Tightens function execution and policy performance after the initial schema
-- is applied. This keeps the public API surface narrow and removes the common
-- per-row auth.uid() RLS performance warning.
-- ===========================================================================

-- Keep helper lookup deterministic.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- The trigger on auth.users should be able to call this, but clients should not
-- be able to execute it directly through the Data API.
revoke execute on function public.handle_new_user() from public;
revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.handle_new_user() from authenticated;

-- Cover the nullable folder foreign key on scripts.
create index if not exists scripts_folder_id_idx on public.scripts (folder_id);

-- Recreate RLS policies with init-plan-friendly auth.uid() calls.
drop policy if exists "profiles: self read" on public.profiles;
create policy "profiles: self read"
  on public.profiles for select using ((select auth.uid()) = id);
drop policy if exists "profiles: self upsert" on public.profiles;
create policy "profiles: self upsert"
  on public.profiles for insert with check ((select auth.uid()) = id);
drop policy if exists "profiles: self update" on public.profiles;
create policy "profiles: self update"
  on public.profiles for update using ((select auth.uid()) = id);

drop policy if exists "folders: owner all" on public.folders;
create policy "folders: owner all"
  on public.folders for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "scripts: owner all" on public.scripts;
create policy "scripts: owner all"
  on public.scripts for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "user_settings: owner all" on public.user_settings;
create policy "user_settings: owner all"
  on public.user_settings for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "subscriptions: self read" on public.subscriptions;
create policy "subscriptions: self read"
  on public.subscriptions for select using ((select auth.uid()) = user_id);

drop policy if exists "uploads: owner read" on storage.objects;
create policy "uploads: owner read"
  on storage.objects for select
  using (
    bucket_id = 'script-uploads'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "uploads: owner write" on storage.objects;
create policy "uploads: owner write"
  on storage.objects for insert
  with check (
    bucket_id = 'script-uploads'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "uploads: owner delete" on storage.objects;
create policy "uploads: owner delete"
  on storage.objects for delete
  using (
    bucket_id = 'script-uploads'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
