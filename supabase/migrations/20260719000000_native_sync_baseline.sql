-- ===========================================================================
-- Phrasa — native sync baseline (strict minimal schema)
--
-- Single active migration for a brand-new dedicated Supabase project.
-- Tables: folders, scripts, user_settings
-- RPC: delete_own_account (owner-only security definer)
--
-- Deliberately omitted: profiles, subscriptions, Lemon Squeezy fields/functions,
-- analytics_events, scripts.preview, storage buckets/policies, Realtime, Edge
-- Functions, web auth helpers, payment machinery.
--
-- Client contract: ios-native SupabaseCloudRepository at b449214
--   scripts columns: id, folder_id, title, body, source_type, outline,
--     word_count, est_seconds, tags, last_opened_at, created_at, updated_at
--   folders columns: id, name, created_at
--   user_settings columns: user_id, settings
--
-- Postgres requirement: ON DELETE SET NULL (column_list) needs Postgres 15+
-- (Supabase hosted Postgres is 15+).
-- ===========================================================================

-- ---- Helper: keep updated_at fresh (hardened search_path) ------------------
-- Used by user_settings (and any future simple tables). Scripts use a dedicated
-- trigger function so last_opened_at-only updates do not bump updated_at.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = pg_catalog.now();
  return new;
end;
$$;

revoke all on function public.set_updated_at() from public;
revoke all on function public.set_updated_at() from anon;
revoke all on function public.set_updated_at() from authenticated;

-- ---- folders ---------------------------------------------------------------
create table public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  -- Composite unique target for scripts (folder_id, user_id) same-owner FK.
  -- id alone is already unique (PK); (id, user_id) is required so Postgres can
  -- reference both columns and reject cross-tenant folder pointers.
  unique (id, user_id)
);

create index folders_user_id_idx on public.folders (user_id);

alter table public.folders enable row level security;

drop policy if exists "folders: owner all" on public.folders;
create policy "folders: owner all"
  on public.folders for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- ---- scripts ---------------------------------------------------------------
create table public.scripts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- Nullable folder pointer. Same-owner enforced by composite FK below
  -- (not a bare folder_id → folders.id reference, which would allow user A
  -- to store user B's folder UUID).
  folder_id uuid,
  title text not null default 'Untitled script',
  body text not null default '',
  source_type text not null default 'manual'
    check (source_type in ('manual', 'upload', 'gdrive')),
  outline jsonb,
  word_count integer not null default 0,
  est_seconds integer not null default 0,
  tags text[] not null default '{}',
  last_opened_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Cross-tenant guard: script.user_id must match folders.user_id for the
  -- referenced folder. ON DELETE SET NULL (folder_id) nulls only the folder
  -- pointer (Postgres 15+ column-list form) so scripts.user_id stays NOT NULL.
  constraint scripts_folder_same_owner_fkey
    foreign key (folder_id, user_id)
    references public.folders (id, user_id)
    on delete set null (folder_id)
);

create index scripts_user_id_idx on public.scripts (user_id);
create index scripts_updated_at_idx on public.scripts (user_id, updated_at desc);
create index scripts_folder_id_idx on public.scripts (folder_id);

alter table public.scripts enable row level security;

drop policy if exists "scripts: owner all" on public.scripts;
create policy "scripts: owner all"
  on public.scripts for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- Opening a script must not look like editing it.
-- Always-on BEFORE UPDATE trigger: a last_opened_at-only stamp keeps the prior
-- updated_at; any change to a synchronized business field (even in the same
-- UPDATE that also sets last_opened_at) sets updated_at = now(). Avoids a
-- fragile WHEN predicate that would skip combined content+open updates.
create or replace function public.scripts_preserve_updated_at_on_open()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if
    new.folder_id is not distinct from old.folder_id
    and new.title is not distinct from old.title
    and new.body is not distinct from old.body
    and new.source_type is not distinct from old.source_type
    and new.outline is not distinct from old.outline
    and new.word_count is not distinct from old.word_count
    and new.est_seconds is not distinct from old.est_seconds
    and new.tags is not distinct from old.tags
    and new.created_at is not distinct from old.created_at
  then
    -- No synchronized business-field change (last_opened_at may still change).
    new.updated_at = old.updated_at;
  else
    new.updated_at = pg_catalog.now();
  end if;
  return new;
end;
$$;

revoke all on function public.scripts_preserve_updated_at_on_open() from public;
revoke all on function public.scripts_preserve_updated_at_on_open() from anon;
revoke all on function public.scripts_preserve_updated_at_on_open() from authenticated;

drop trigger if exists scripts_set_updated_at on public.scripts;
create trigger scripts_set_updated_at
  before update on public.scripts
  for each row
  execute function public.scripts_preserve_updated_at_on_open();

-- ---- user_settings ---------------------------------------------------------
create table public.user_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_settings enable row level security;

drop policy if exists "user_settings: owner all" on public.user_settings;
create policy "user_settings: owner all"
  on public.user_settings for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop trigger if exists user_settings_set_updated_at on public.user_settings;
create trigger user_settings_set_updated_at
  before update on public.user_settings
  for each row
  execute function public.set_updated_at();

-- ---- Self-service account deletion -----------------------------------------
-- Authenticated clients cannot hold a service-role secret. This SECURITY
-- DEFINER RPC deletes only the caller: target id always comes from auth.uid(),
-- with an expected_user_id equality guard against concurrent session swaps.
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

-- ---- Table / schema privileges ---------------------------------------------
-- Publishable (anon) key + RLS: authenticated role may use owner tables;
-- anonymous role gets no table DML; service_role retains admin access for
-- platform operations (still never ship service-role in a client).
grant usage on schema public to authenticated;

revoke all on table public.folders from public;
revoke all on table public.folders from anon;
grant select, insert, update, delete on table public.folders to authenticated;

revoke all on table public.scripts from public;
revoke all on table public.scripts from anon;
grant select, insert, update, delete on table public.scripts to authenticated;

revoke all on table public.user_settings from public;
revoke all on table public.user_settings from anon;
grant select, insert, update, delete on table public.user_settings to authenticated;
