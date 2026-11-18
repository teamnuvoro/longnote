-- Server-side subscription events (18 Nov 2026). docs/BACKEND-API.md 4.6-4.7,
-- docs/ANALYTICS.md "Server events".
--   tracking_profiles      what the app tells us so the server can send Meta /
--                          Amplitude events for this user (and whether it may)
--   appstore_notifications every App Store Server Notification V2 we accepted
--                          (idempotency on notificationUUID + what we sent)
--   subscriptions          latest state per originalTransactionId
-- Re-runnable (if not exists / drop ... if exists / create or replace).

-- ---------------------------------------------------------------- profiles
create table if not exists public.tracking_profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  share_analytics boolean not null,
  att_enabled boolean,
  meta_anon_id text check (meta_anon_id is null or length(meta_anon_id) between 1 and 100),
  app_version text check (app_version is null or length(app_version) <= 32),
  os_version text check (os_version is null or length(os_version) <= 32),
  device_model text check (device_model is null or length(device_model) <= 64),
  locale text check (locale is null or length(locale) <= 35),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  extinfo jsonb check (extinfo is null or (jsonb_typeof(extinfo) = 'array'
    and jsonb_array_length(extinfo) = 16 and octet_length(extinfo::text) <= 2048)),
  updated_at timestamptz not null default now()
);
alter table public.tracking_profiles enable row level security;

-- A user may read, insert and update only their own row (the app writes it
-- through the tracking-profile function with the service role today; the
-- policies keep direct PostgREST access safe too). No delete: the row goes
-- with the user (on delete cascade).
drop policy if exists tracking_profiles_select_own on public.tracking_profiles;
create policy tracking_profiles_select_own on public.tracking_profiles
  for select to authenticated using (user_id = auth.uid());
drop policy if exists tracking_profiles_insert_own on public.tracking_profiles;
create policy tracking_profiles_insert_own on public.tracking_profiles
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists tracking_profiles_update_own on public.tracking_profiles;
create policy tracking_profiles_update_own on public.tracking_profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.tracking_profiles from anon, authenticated;
grant select, insert, update on public.tracking_profiles to authenticated;
grant all on public.tracking_profiles to service_role;

-- ------------------------------------------------------ App Store notifications
create table if not exists public.appstore_notifications (
  notification_uuid text primary key,
  notification_type text not null,
  subtype text,
  environment text,
  signed_date timestamptz,
  original_transaction_id text,
  transaction_id text,
  product_id text,
  user_id uuid,
  -- decoded notification + transaction + renewal info (no signatures)
  payload jsonb not null,
  -- received -> processing -> planned -> done (or ignored)
  state text not null default 'processing',
  attempts int not null default 1,
  claimed_at timestamptz not null default now(),
  kind text,
  plan jsonb,
  meta_result text,
  amplitude_result text,
  received_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists appstore_notifications_received on public.appstore_notifications (received_at);
create index if not exists appstore_notifications_otid on public.appstore_notifications (original_transaction_id);
alter table public.appstore_notifications enable row level security;
revoke all on public.appstore_notifications from anon, authenticated;
grant all on public.appstore_notifications to service_role;

-- ------------------------------------------------------------- subscriptions
create table if not exists public.subscriptions (
  original_transaction_id text primary key,
  user_id uuid references auth.users (id) on delete set null,
  environment text,
  product_id text,
  status text,
  currency text,
  expires_at timestamptz,
  auto_renew boolean,
  auto_renew_product_id text,
  last_transaction_id text,
  last_offer_type int,
  last_offer_discount_type text,
  last_price numeric,
  paid_count int not null default 0,
  last_notification_type text,
  last_subtype text,
  last_signed_date timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists subscriptions_user on public.subscriptions (user_id);
alter table public.subscriptions enable row level security;
revoke all on public.subscriptions from anon, authenticated;
grant all on public.subscriptions to service_role;

-- Atomic insert-or-claim for one notification (Apple retries until it gets
-- a 200, and may deliver the same notification twice at once).
--   'claimed'   new row, or a row whose earlier run died before planning
--               ('processing' for > 2 min): process it now
--   'planned'   an earlier run stored the plan but may not have sent it:
--               send the stored plan (never recompute: state already moved)
--   'duplicate' already done / being done
create or replace function public.ln_appstore_claim(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare st text;
begin
  insert into public.appstore_notifications (notification_uuid, notification_type, subtype, environment,
    signed_date, original_transaction_id, transaction_id, product_id, payload)
  values (p->>'notification_uuid', p->>'notification_type', p->>'subtype', p->>'environment',
    (p->>'signed_date')::timestamptz, p->>'original_transaction_id', p->>'transaction_id',
    p->>'product_id', p->'payload')
  on conflict (notification_uuid) do nothing;
  if found then return 'claimed'; end if;

  update public.appstore_notifications
     set state = 'processing', claimed_at = now(), attempts = attempts + 1
   where notification_uuid = p->>'notification_uuid'
     and state = 'processing' and claimed_at < now() - interval '2 minutes';
  if found then return 'claimed'; end if;

  update public.appstore_notifications
     set state = 'sending', claimed_at = now(), attempts = attempts + 1
   where notification_uuid = p->>'notification_uuid'
     and state = 'planned' and claimed_at < now() - interval '2 minutes'
  returning state into st;
  if found then return 'planned'; end if;
  return 'duplicate';
end $$;
revoke all on function public.ln_appstore_claim(jsonb) from public, anon, authenticated;
grant execute on function public.ln_appstore_claim(jsonb) to service_role;

-- Keep notifications 13 months (refund / renewal audit), then delete.
select cron.unschedule('longnote-appstore-notifications-ttl')
  where exists (select 1 from cron.job where jobname = 'longnote-appstore-notifications-ttl');
select cron.schedule(
  'longnote-appstore-notifications-ttl',
  '41 3 * * *',
  $$ delete from public.appstore_notifications where received_at < now() - interval '13 months'; $$
);
