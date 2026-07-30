-- ===========================================================================
-- Phrasa — billing / subscriptions (Lemon Squeezy)
-- One row per user describing their plan. Written ONLY by the Lemon Squeezy
-- webhook using the service-role key (which bypasses RLS); users may read
-- their own row but never write it.
-- ===========================================================================

create table if not exists public.subscriptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'pro')),
  status text not null default 'active'
    check (status in (
      'active', 'on_trial', 'past_due', 'cancelled', 'expired', 'paused'
    )),
  ls_customer_id text,
  ls_subscription_id text,
  ls_variant_id text,
  ls_order_id text,
  renews_at timestamptz,
  ends_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists subscriptions_ls_sub_idx
  on public.subscriptions (ls_subscription_id);

alter table public.subscriptions enable row level security;

-- Read-only for the owner. There are deliberately NO insert/update/delete
-- policies: only the webhook (service role) mutates this table.
-- Drop-before-create so this migration stays re-runnable (matches 0001/0007);
-- re-applying it must not error on the already-existing policy.
drop policy if exists "subscriptions: self read" on public.subscriptions;
create policy "subscriptions: self read"
  on public.subscriptions for select using (auth.uid() = user_id);

drop trigger if exists subscriptions_set_updated_at on public.subscriptions;
create trigger subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();
