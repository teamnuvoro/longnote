-- Review fixes (16 Nov 2026):
--  1. summarize/ask reserve an estimated cost atomically BEFORE calling OpenAI
--     and settle to the real cost after (was check-then-spend).
--  2. transcribe-start claims a job atomically before calling Soniox, so two
--     parallel starts for one note cannot create two Soniox transcriptions.
--  3. Per-IP daily caps (hashed IP) for transcribe-start / summarize / ask.
--  4. A self-expiring test override for the global cost cap (e2e only).

-- ---------------------------------------------------------------------------
-- Test override: lowers the global cap until expires_at (never raises it).
-- Written only by the service role / psql during an e2e run.
-- ---------------------------------------------------------------------------
create table if not exists public.ln_test_overrides (
  key        text primary key,
  value      numeric not null,
  expires_at timestamptz not null
);
alter table public.ln_test_overrides enable row level security;
revoke all on public.ln_test_overrides from anon, authenticated;
grant all on public.ln_test_overrides to service_role;

create or replace function public.ln_global_cap(p_cap numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select least(p_cap, coalesce((select value from ln_test_overrides
                                where key = 'global_usd_cap' and expires_at > now()), p_cap));
$$;

-- ---------------------------------------------------------------------------
-- 1. Reserve / settle the estimated cost of one summary or ask call.
-- Returns {"verdict": "ok"|"user_day"|"global_day", "day": "YYYY-MM-DD"}.
-- The user count and the global reservation happen in one transaction; the
-- global part is a single conditional UPDATE (row lock), so parallel calls
-- can never push est_usd over the cap.
-- ---------------------------------------------------------------------------
create or replace function public.ln_reserve_call(
  p_user uuid, p_kind text, p_limit integer, p_global_cap numeric, p_est_usd numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day date := public.ln_utc_day();
  v_n integer;
  v_cap numeric := public.ln_global_cap(p_global_cap);
  v_ok boolean;
begin
  if p_kind not in ('summary', 'ask') then raise exception 'bad kind'; end if;
  if p_est_usd < 0 then raise exception 'bad estimate'; end if;

  insert into usage_daily (user_id, day) values (p_user, v_day) on conflict do nothing;
  if p_kind = 'summary' then
    select summary_calls into v_n from usage_daily where user_id = p_user and day = v_day for update;
  else
    select ask_calls into v_n from usage_daily where user_id = p_user and day = v_day for update;
  end if;
  if v_n + 1 > p_limit then
    return jsonb_build_object('verdict', 'user_day', 'day', v_day);
  end if;

  insert into cost_daily (day) values (v_day) on conflict do nothing;
  update cost_daily set est_usd = est_usd + p_est_usd
    where day = v_day and est_usd + p_est_usd <= v_cap
    returning true into v_ok;
  if v_ok is null then
    return jsonb_build_object('verdict', 'global_day', 'day', v_day);
  end if;

  if p_kind = 'summary' then
    update usage_daily set summary_calls = summary_calls + 1 where user_id = p_user and day = v_day;
  else
    update usage_daily set ask_calls = ask_calls + 1 where user_id = p_user and day = v_day;
  end if;
  return jsonb_build_object('verdict', 'ok', 'day', v_day);
end $$;

-- Move a reservation to the real cost (0 when OpenAI was never reached).
create or replace function public.ln_settle_cost(p_day date, p_reserved numeric, p_actual numeric)
returns void
language sql security definer set search_path = public as $$
  update cost_daily set est_usd = greatest(0, est_usd + (p_actual - p_reserved)) where day = p_day;
$$;

-- transcribe-start: the global part of ln_reserve_audio also honours the
-- test override (same body as before otherwise).
create or replace function public.ln_reserve_audio(
  p_job uuid, p_seconds integer, p_usd numeric,
  p_day_limit integer, p_hour_limit integer, p_global_cap numeric
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
  v_day date := public.ln_utc_day();
  v_used integer;
  v_hour integer;
  v_cost numeric;
  v_cap numeric := public.ln_global_cap(p_global_cap);
begin
  select user_id into v_user from jobs where id = p_job for update;
  if v_user is null then raise exception 'job not found'; end if;

  insert into usage_daily (user_id, day) values (v_user, v_day) on conflict do nothing;
  select audio_seconds into v_used from usage_daily
    where user_id = v_user and day = v_day for update;
  if v_used + p_seconds > p_day_limit then return 'user_day'; end if;

  select coalesce(sum(charged_seconds), 0) into v_hour from jobs
    where user_id = v_user and charged_at > now() - interval '1 hour';
  if v_hour + p_seconds > p_hour_limit then return 'user_hour'; end if;

  insert into cost_daily (day) values (v_day) on conflict do nothing;
  select est_usd into v_cost from cost_daily where day = v_day for update;
  if v_cost + p_usd > v_cap then return 'global_day'; end if;

  update usage_daily set audio_seconds = audio_seconds + p_seconds
    where user_id = v_user and day = v_day;
  update cost_daily set est_usd = est_usd + p_usd where day = v_day;
  update jobs set charged_seconds = p_seconds, charged_usd = p_usd, charged_at = now()
    where id = p_job;
  return 'ok';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Start claim. Only the caller that sets start_claimed_at may call Soniox.
-- A claim older than 3 min is abandoned (edge functions time out at 150 s).
-- ---------------------------------------------------------------------------
alter table public.jobs add column if not exists start_claimed_at timestamptz;

create or replace function public.ln_claim_start(p_job uuid) returns boolean
language sql security definer set search_path = public as $$
  with c as (
    update jobs set start_claimed_at = now()
    where id = p_job and status = 'uploaded'
      and (start_claimed_at is null or start_claimed_at < now() - interval '3 minutes')
    returning 1
  )
  select exists (select 1 from c);
$$;

-- ---------------------------------------------------------------------------
-- 3. Per-IP daily caps. ip_hash = HMAC-SHA256(server secret, ip); the raw IP
-- is never stored. kind: 'audio' (seconds), 'summary', 'ask' (calls).
-- ---------------------------------------------------------------------------
create table if not exists public.ip_daily (
  ip_hash text not null check (length(ip_hash) between 16 and 128),
  day     date not null,
  kind    text not null check (kind in ('audio', 'summary', 'ask')),
  used    integer not null default 0,
  primary key (ip_hash, day, kind)
);
alter table public.ip_daily enable row level security;
revoke all on public.ip_daily from anon, authenticated;
grant all on public.ip_daily to service_role;

-- Adds p_amount if the total stays within p_limit. True = allowed.
create or replace function public.ln_ip_reserve(p_ip_hash text, p_kind text, p_amount integer, p_limit integer)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_day date := public.ln_utc_day();
  v_ok boolean;
begin
  insert into ip_daily (ip_hash, day, kind) values (p_ip_hash, v_day, p_kind) on conflict do nothing;
  update ip_daily set used = used + p_amount
    where ip_hash = p_ip_hash and day = v_day and kind = p_kind and used + p_amount <= p_limit
    returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

-- Gives back an amount (Soniox refused to start). Never below 0.
create or replace function public.ln_ip_release(p_ip_hash text, p_kind text, p_amount integer)
returns void
language sql security definer set search_path = public as $$
  update ip_daily set used = greatest(0, used - p_amount)
  where ip_hash = p_ip_hash and day = public.ln_utc_day() and kind = p_kind;
$$;

-- Cleanup (pg_cron every 15 min): also drops IP rows older than 2 days and
-- expired test overrides.
create or replace function public.ln_cleanup_db() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a integer; b integer; c integer; d integer;
begin
  update jobs set result = null
    where result is not null
      and ((status = 'fetched' and fetched_at < now() - interval '15 minutes')
           or created_at < now() - interval '7 days');
  get diagnostics a = row_count;
  delete from jobs where created_at < now() - interval '30 days';
  get diagnostics b = row_count;
  delete from usage_daily where day < public.ln_utc_day() - 90;
  get diagnostics c = row_count;
  delete from ip_daily where day < public.ln_utc_day() - 2;
  get diagnostics d = row_count;
  delete from ln_test_overrides where expires_at < now();
  return jsonb_build_object('results_cleared', a, 'jobs_deleted', b, 'usage_rows_deleted', c,
                            'ip_rows_deleted', d);
end $$;

revoke all on function
  public.ln_global_cap(numeric),
  public.ln_reserve_call(uuid, text, integer, numeric, numeric),
  public.ln_settle_cost(date, numeric, numeric),
  public.ln_claim_start(uuid),
  public.ln_ip_reserve(text, text, integer, integer),
  public.ln_ip_release(text, text, integer)
  from public, anon, authenticated;

grant execute on function
  public.ln_global_cap(numeric),
  public.ln_reserve_call(uuid, text, integer, numeric, numeric),
  public.ln_settle_cost(date, numeric, numeric),
  public.ln_claim_start(uuid),
  public.ln_ip_reserve(text, text, integer, integer),
  public.ln_ip_release(text, text, integer)
  to service_role;

-- ln_count_call (check-then-spend) is replaced by ln_reserve_call.
drop function if exists public.ln_count_call(uuid, text, integer, numeric);
