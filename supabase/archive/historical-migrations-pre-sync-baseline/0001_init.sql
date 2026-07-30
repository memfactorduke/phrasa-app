-- ===========================================================================
-- Phrasa — initial schema
-- Tables: profiles, folders, scripts, user_settings
-- Security: Row-Level Security so each user only ever sees their own rows.
-- ===========================================================================

-- ---- Helper: keep updated_at fresh -----------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---- profiles --------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Postgres has no CREATE POLICY IF NOT EXISTS, so every policy below is
-- preceded by DROP POLICY IF EXISTS. That keeps this migration re-runnable
-- (e.g. re-pasting into the SQL editor after a partial failure) just like the
-- IF NOT EXISTS tables/indexes and DROP TRIGGER IF EXISTS patterns it sits
-- alongside — without changing what the policies do.
drop policy if exists "profiles: self read" on public.profiles;
create policy "profiles: self read"
  on public.profiles for select using (auth.uid() = id);
drop policy if exists "profiles: self upsert" on public.profiles;
create policy "profiles: self upsert"
  on public.profiles for insert with check (auth.uid() = id);
drop policy if exists "profiles: self update" on public.profiles;
create policy "profiles: self update"
  on public.profiles for update using (auth.uid() = id);

-- Create a profile row automatically when a new auth user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---- folders ---------------------------------------------------------------
create table if not exists public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create index if not exists folders_user_id_idx on public.folders (user_id);

alter table public.folders enable row level security;

drop policy if exists "folders: owner all" on public.folders;
create policy "folders: owner all"
  on public.folders for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---- scripts ---------------------------------------------------------------
create table if not exists public.scripts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  folder_id uuid references public.folders (id) on delete set null,
  title text not null default 'Untitled script',
  body text not null default '',
  source_type text not null default 'manual'
    check (source_type in ('manual', 'upload', 'gdrive')),
  original_file_path text,
  word_count integer not null default 0,
  est_seconds integer not null default 0,
  tags text[] not null default '{}',
  last_opened_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists scripts_user_id_idx on public.scripts (user_id);
create index if not exists scripts_updated_at_idx on public.scripts (user_id, updated_at desc);

alter table public.scripts enable row level security;

drop policy if exists "scripts: owner all" on public.scripts;
create policy "scripts: owner all"
  on public.scripts for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop trigger if exists scripts_set_updated_at on public.scripts;
create trigger scripts_set_updated_at
  before update on public.scripts
  for each row execute function public.set_updated_at();

-- ---- user_settings ---------------------------------------------------------
create table if not exists public.user_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_settings enable row level security;

drop policy if exists "user_settings: owner all" on public.user_settings;
create policy "user_settings: owner all"
  on public.user_settings for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop trigger if exists user_settings_set_updated_at on public.user_settings;
create trigger user_settings_set_updated_at
  before update on public.user_settings
  for each row execute function public.set_updated_at();

-- ---- Storage: uploaded script originals ------------------------------------
insert into storage.buckets (id, name, public)
values ('script-uploads', 'script-uploads', false)
on conflict (id) do nothing;

-- Each user can only touch files under a folder named after their user id.
drop policy if exists "uploads: owner read" on storage.objects;
create policy "uploads: owner read"
  on storage.objects for select
  using (
    bucket_id = 'script-uploads'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "uploads: owner write" on storage.objects;
create policy "uploads: owner write"
  on storage.objects for insert
  with check (
    bucket_id = 'script-uploads'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "uploads: owner delete" on storage.objects;
create policy "uploads: owner delete"
  on storage.objects for delete
  using (
    bucket_id = 'script-uploads'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
