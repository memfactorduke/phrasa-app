-- ===========================================================================
-- Phrasa — preserve Lemon Squeezy subscription identity across stale events
--
-- Migration 0010 made each subscription event atomic, but its user-id upsert
-- could still let a late event for old subscription A replace the same user's
-- current subscription B. This replacement keeps the two stable identities
-- separately locked and orders distinct ids by Lemon Squeezy's stable
-- subscription `created_at`, never by two subscriptions' independent update
-- clocks. That lets an expired/cancelled customer buy again without allowing
-- a late event for the older identity to displace the newer subscription.
-- Legacy rows do not yet have a subscription creation clock. For those rows,
-- an incoming identity is accepted only when its creation time is later than
-- the current identity's last known event time (a safe proof that it did not
-- exist yet). Any other missing/equal chronology is returned as indeterminate
-- so the webhook is retried instead of guessing from entitlement status.
--
-- This is a new migration rather than an edit to 0010 so environments that
-- already applied the merged release receive the corrected function too.
-- ===========================================================================

alter table public.subscriptions
  add column if not exists ls_subscription_created_at timestamptz;

-- Migration 0010 inherited a non-unique lookup index. Refuse to guess how to
-- reconcile legacy duplicates, then make external ownership a real database
-- invariant so even another trusted writer cannot race this RPC's preflight.
do $$
begin
  if exists (
    select 1
    from public.subscriptions
    where ls_subscription_id is not null
    group by ls_subscription_id
    having count(*) > 1
  ) then
    raise exception using
      errcode = 'P0003',
      message = 'Duplicate Lemon Squeezy subscription ids require manual reconciliation before migration 0011.';
  end if;
end
$$;

create unique index if not exists subscriptions_ls_subscription_id_unique
  on public.subscriptions (ls_subscription_id)
  where ls_subscription_id is not null;

-- Adding the stable creation clock changes the function signature. Remove the
-- 0010 version so the Data API exposes one unambiguous RPC contract.
drop function if exists public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz
);

create function public.apply_subscription_webhook_event(
  p_user_id uuid,
  p_plan text,
  p_status text,
  p_ls_customer_id text,
  p_ls_subscription_id text,
  p_ls_variant_id text,
  p_ls_order_id text,
  p_renews_at timestamptz,
  p_ends_at timestamptz,
  p_ls_event_at timestamptz,
  p_ls_subscription_created_at timestamptz
)
returns text
language plpgsql
security definer
set search_path = ''
set statement_timeout = '15s'
set lock_timeout = '10s'
as $$
declare
  affected_rows integer;
  allow_identity_replacement boolean := false;
  current_subscription_created_at timestamptz;
  current_subscription_event_at timestamptz;
  current_subscription_id text;
  matching_subscriptions integer;
begin
  if p_plan not in ('free', 'pro') then
    raise exception using
      errcode = '22023',
      message = 'Invalid subscription plan.';
  end if;

  if p_status not in (
    'active', 'on_trial', 'past_due', 'cancelled', 'expired', 'paused'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Invalid subscription status.';
  end if;

  if p_user_id is null and p_ls_subscription_id is null then
    return 'not_found';
  end if;

  -- Calls carrying both identities always lock the user first. Calls carrying
  -- only a subscription never acquire a later user lock, so this protocol
  -- serializes same-user/different-subscription races without creating a lock
  -- cycle with subscription-only deliveries.
  if p_user_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('phrasa_user:' || p_user_id::text, 0)
    );
  end if;

  if p_ls_subscription_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'ls_subscription:' || p_ls_subscription_id,
        0
      )
    );
  end if;

  if p_ls_subscription_id is not null then
    select count(*)
    into matching_subscriptions
    from public.subscriptions
    where ls_subscription_id = p_ls_subscription_id;

    if matching_subscriptions > 1 then
      raise exception using
        errcode = 'P0003',
        message = 'Duplicate Lemon Squeezy subscription ids require manual reconciliation.';
    end if;

    -- Never reassign an existing external billing id to another Phrasa user.
    if p_user_id is not null and exists (
      select 1
      from public.subscriptions
      where ls_subscription_id = p_ls_subscription_id
        and user_id <> p_user_id
    ) then
      raise exception using
        errcode = '23505',
        message = 'Lemon Squeezy subscription id already belongs to another user.';
    end if;
  end if;

  if p_user_id is not null then
    -- Lock the user's current row while deciding whether a distinct external
    -- id is an old event or a legitimate re-subscription. Creation time is the
    -- generation signal across identities; `updated_at` clocks are comparable
    -- only within one subscription. A legacy row's last event clock is a safe
    -- lower bound only in one direction: an identity created after that event
    -- is definitely newer. Status is never chronology. The incoming identity
    -- must also remain entitled, so a newer expired/paused row cannot displace
    -- a paid row.
    select
      ls_subscription_id,
      ls_subscription_created_at,
      ls_event_at
    into
      current_subscription_id,
      current_subscription_created_at,
      current_subscription_event_at
    from public.subscriptions
    where user_id = p_user_id
    for update;

    if found
      and current_subscription_id is not null
      and current_subscription_id is distinct from p_ls_subscription_id
    then
      -- A non-entitled or identity-less snapshot is deliberately unable to
      -- replace the row. It cannot restore paid access, and retrying it cannot
      -- produce a stable external identity.
      if p_ls_subscription_id is null or p_plan <> 'pro' then
        return 'subscription_mismatch';
      end if;

      -- Missing creation time cannot order distinct subscriptions. Ask Lemon
      -- Squeezy to retry rather than permanently acknowledging a paid event
      -- that might be the user's legitimate re-subscription.
      if p_ls_subscription_created_at is null then
        return 'subscription_order_indeterminate';
      end if;

      if current_subscription_created_at is not null then
        if p_ls_subscription_created_at
          > current_subscription_created_at
        then
          allow_identity_replacement := true;
        elsif p_ls_subscription_created_at
          < current_subscription_created_at
        then
          return 'subscription_mismatch';
        else
          -- Distinct ids with equal creation clocks have no provable order.
          return 'subscription_order_indeterminate';
        end if;
      elsif current_subscription_event_at is not null
        and p_ls_subscription_created_at > current_subscription_event_at
      then
        -- A subscription's event time cannot precede its own creation. The
        -- incoming subscription was created after the current identity's last
        -- known event, so it is provably the newer generation.
        allow_identity_replacement := true;
      else
        -- The current legacy row has no creation clock, and the available
        -- event clock does not prove which distinct identity came first.
        return 'subscription_order_indeterminate';
      end if;

      if not allow_identity_replacement then
        return 'subscription_mismatch';
      end if;
    end if;

    insert into public.subscriptions (
      user_id,
      plan,
      status,
      ls_customer_id,
      ls_subscription_id,
      ls_variant_id,
      ls_order_id,
      renews_at,
      ends_at,
      ls_event_at,
      ls_subscription_created_at
    )
    values (
      p_user_id,
      p_plan,
      p_status,
      p_ls_customer_id,
      p_ls_subscription_id,
      p_ls_variant_id,
      p_ls_order_id,
      p_renews_at,
      p_ends_at,
      p_ls_event_at,
      p_ls_subscription_created_at
    )
    on conflict (user_id) do update
    set
      plan = excluded.plan,
      status = excluded.status,
      ls_customer_id = excluded.ls_customer_id,
      ls_subscription_id = excluded.ls_subscription_id,
      ls_variant_id = excluded.ls_variant_id,
      ls_order_id = excluded.ls_order_id,
      renews_at = excluded.renews_at,
      ends_at = excluded.ends_at,
      ls_event_at = excluded.ls_event_at,
      ls_subscription_created_at = case
        when public.subscriptions.ls_subscription_id
          is distinct from excluded.ls_subscription_id
          then excluded.ls_subscription_created_at
        else coalesce(
          public.subscriptions.ls_subscription_created_at,
          excluded.ls_subscription_created_at
        )
      end
    -- Compare update clocks only within one subscription identity. Distinct
    -- identities are generations, so their stable creation timestamps decide
    -- which one owns the row even if the newer subscription's first update
    -- happened before a delayed final update for the old subscription.
    where (
      (
        (
          public.subscriptions.ls_subscription_id is null
          or public.subscriptions.ls_subscription_id
            is not distinct from excluded.ls_subscription_id
        )
        and excluded.ls_event_at is not null
        and (
          public.subscriptions.ls_event_at is null
          or excluded.ls_event_at > public.subscriptions.ls_event_at
        )
      )
      or (
        public.subscriptions.ls_subscription_id is not null
        and public.subscriptions.ls_subscription_id
          is distinct from excluded.ls_subscription_id
        and excluded.plan = 'pro'
        and excluded.ls_subscription_created_at is not null
        and (
          (
            public.subscriptions.ls_subscription_created_at is not null
            and excluded.ls_subscription_created_at
              > public.subscriptions.ls_subscription_created_at
          )
          or (
            public.subscriptions.ls_subscription_created_at is null
            and public.subscriptions.ls_event_at is not null
            and excluded.ls_subscription_created_at
              > public.subscriptions.ls_event_at
          )
        )
      )
    );

    get diagnostics affected_rows = row_count;
    if affected_rows > 0 then
      return 'applied';
    end if;

    return 'stale';
  end if;

  -- An event without custom_data.user_id can only address the row already
  -- carrying its external subscription id, so it cannot replace identities.
  update public.subscriptions
  set
    plan = p_plan,
    status = p_status,
    ls_customer_id = p_ls_customer_id,
    ls_subscription_id = p_ls_subscription_id,
    ls_variant_id = p_ls_variant_id,
    ls_order_id = p_ls_order_id,
    renews_at = p_renews_at,
    ends_at = p_ends_at,
    ls_event_at = p_ls_event_at,
    ls_subscription_created_at = coalesce(
      ls_subscription_created_at,
      p_ls_subscription_created_at
    )
  where ls_subscription_id = p_ls_subscription_id
    and p_ls_event_at is not null
    and (
      ls_event_at is null
      or p_ls_event_at > ls_event_at
    );

  get diagnostics affected_rows = row_count;
  if affected_rows > 0 then
    return 'applied';
  end if;

  if exists (
    select 1
    from public.subscriptions
    where ls_subscription_id = p_ls_subscription_id
  ) then
    return 'stale';
  end if;

  return 'not_found';
end;
$$;

comment on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz,
  timestamptz
) is
  'Atomically applies newer Lemon Squeezy snapshots and orders subscription generations by stable creation time.';

revoke all on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz,
  timestamptz
) from public;
revoke all on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz,
  timestamptz
) from anon;
revoke all on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz,
  timestamptz
) from authenticated;
grant execute on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz,
  timestamptz
) to service_role;
