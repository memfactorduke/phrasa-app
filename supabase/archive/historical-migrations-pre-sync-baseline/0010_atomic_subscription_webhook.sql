-- ===========================================================================
-- Phrasa — atomic Lemon Squeezy subscription webhook writes
--
-- Migration 0004 added the Lemon Squeezy event clock (`ls_event_at`), but the
-- first route implementation compared that clock in one request and wrote the
-- row in another. Concurrent deliveries could both pass the comparison and let
-- an older event commit last. This RPC serializes deliveries for one Lemon
-- Squeezy subscription and performs the comparison plus write in one database
-- transaction.
--
-- DEPLOYMENT ORDER: apply this migration before deploying the route that calls
-- it. If the route arrives first it deliberately returns 500 so Lemon Squeezy
-- retries; there is no non-atomic legacy fallback. Re-running this migration is
-- safe because the function is replaced and privileges are reset below.
--
-- The existing `subscriptions_ls_sub_idx` is intentionally treated as a
-- non-unique legacy lookup here. Automatically deleting or merging duplicate
-- subscription ids could grant paid access to the wrong user. The RPC instead
-- fails closed when it finds a legacy duplicate and prevents new cross-user
-- duplicates through this write path. Operators can find any rows needing
-- manual reconciliation before deployment with:
--
--   select ls_subscription_id, count(*)
--   from public.subscriptions
--   where ls_subscription_id is not null
--   group by ls_subscription_id
--   having count(*) > 1;
-- ===========================================================================

create or replace function public.apply_subscription_webhook_event(
  p_user_id uuid,
  p_plan text,
  p_status text,
  p_ls_customer_id text,
  p_ls_subscription_id text,
  p_ls_variant_id text,
  p_ls_order_id text,
  p_renews_at timestamptz,
  p_ends_at timestamptz,
  p_ls_event_at timestamptz
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
  matching_subscriptions integer;
begin
  -- The RPC is service-role-only, but validating the enum-like values here
  -- keeps a future trusted caller from relying on a raw table constraint error.
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

  -- Row locks serialize updates once a row exists. This transaction-scoped
  -- advisory lock also covers the creation race where the subscription row
  -- does not exist yet, and makes the user-id and subscription-id paths share
  -- the same lock whenever Lemon Squeezy supplied its subscription id.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      case
        when p_ls_subscription_id is not null
          then 'ls_subscription:' || p_ls_subscription_id
        else 'phrasa_user:' || p_user_id::text
      end,
      0
    )
  );

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

    -- All calls carrying this subscription id take the advisory lock above,
    -- so this ownership check and a later INSERT cannot be interleaved by a
    -- second call to this RPC. Never reassign an existing external billing id
    -- to a different Phrasa account.
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
      ls_event_at
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
      p_ls_event_at
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
      ls_event_at = excluded.ls_event_at
    -- Strictly newer clocks may update an existing row. Equal clocks are an
    -- idempotent redelivery, and an unclocked event cannot safely supersede a
    -- row that already exists, so both are acknowledged without mutation. An
    -- unclocked event can still create the initial row through the INSERT arm;
    -- a later clocked snapshot will supersede it normally.
    where excluded.ls_event_at is not null
      and (
        public.subscriptions.ls_event_at is null
        or excluded.ls_event_at > public.subscriptions.ls_event_at
      );

    get diagnostics affected_rows = row_count;
    if affected_rows > 0 then
      return 'applied';
    end if;

    return 'stale';
  end if;

  -- Events without custom_data.user_id can only update a row created by an
  -- earlier event. The same strict clock predicate is part of the UPDATE, so
  -- the comparison and mutation cannot be interleaved by another delivery.
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
    ls_event_at = p_ls_event_at
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
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz
) is
  'Atomically applies a strictly newer Lemon Squeezy subscription snapshot.';

-- SECURITY DEFINER is intentional so the table stays read-only under RLS.
-- Only the server-side service-role client may execute this function.
revoke all on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz
) from public;
revoke all on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz
) from anon;
revoke all on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz
) from authenticated;
grant execute on function public.apply_subscription_webhook_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, timestamptz
) to service_role;
