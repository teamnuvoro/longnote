-- Review B fixes (docs/REVIEW-FABLE-2026-11-16.md, section B), 16 Nov 2026.
--
--  B1  Separate global pools for audio and LLM (cost_daily.audio_usd /
--      llm_usd) and dollar caps per user (usage_daily.llm_usd) and per IP
--      (ip_daily kind 'llm', column usd). Call-count caps stay as a second
--      guard. Everything is checked and charged in ONE function per product
--      (ln_reserve_llm, ln_reserve_audio_v2), so a refused call charges
--      nothing (L1).
--  B2  jobs.started_at, set on every successful start claim; the cleanup
--      timers use it (coalesce with created_at).
--  B4  uploads bucket: 100 MB per object; at most 25 objects per user.
--  B5  report: count + insert in one function, per-user and per-IP caps.
--  B6  IP audio charge is stored on the job and settled/refunded with it.
--  A5  summary_cache: a summarize re-send within a few minutes returns the
--      cached result (no second OpenAI call).
--  L3  transcript kept until ack or 24 h after the first fetch.
--  L9  anonymous users with no session activity for 90 days are deleted.
--  L10 index on jobs.audio_path.
-- Every statement is re-runnable.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.jobs add column if not exists started_at timestamptz;
alter table public.jobs add column if not exists ip_hash text;
alter table public.jobs add column if not exists ip_charged_seconds integer not null default 0;
update public.jobs set started_at = coalesce(start_claimed_at, created_at)
  where started_at is null and status <> 'uploaded';
create index if not exists jobs_audio_path_idx on public.jobs (audio_path);
create index if not exists jobs_status_started_idx on public.jobs (status, started_at);

alter table public.usage_daily add column if not exists llm_usd numeric(10, 4) not null default 0;

alter table public.cost_daily add column if not exists audio_usd numeric(12, 4) not null default 0;
alter table public.cost_daily add column if not exists llm_usd numeric(12, 4) not null default 0;
-- Split the days booked before the pools existed (est_usd stays the total).
update public.cost_daily c set
  audio_usd = s.audio,
  llm_usd = greatest(0, c.est_usd - s.audio)
from (
  select c2.day, least(c2.est_usd, coalesce(
           (select sum(j.charged_usd) from public.jobs j
             where j.charged_at is not null and (j.charged_at at time zone 'utc')::date = c2.day), 0)) as audio
  from public.cost_daily c2
) s
where s.day = c.day and c.audio_usd = 0 and c.llm_usd = 0 and c.est_usd > 0;

alter table public.ip_daily add column if not exists usd numeric(12, 4) not null default 0;
alter table public.ip_daily drop constraint if exists ip_daily_kind_check;
alter table public.ip_daily add constraint ip_daily_kind_check
  check (kind in ('audio', 'summary', 'ask', 'llm', 'report'));

-- ---------------------------------------------------------------------------
-- Test overrides: any cap can be LOWERED (never raised) until expires_at.
-- Keys: global_audio_usd_cap, global_llm_usd_cap, global_usd_cap (total),
-- user_llm_usd_cap:<user id>, ip_llm_usd_cap:<ip hash>, report_user:<user
-- id>, report_ip:<ip hash>. Written only by psql / the service role (e2e).
-- ---------------------------------------------------------------------------
create or replace function public.ln_cap(p_key text, p_cap numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select least(p_cap, coalesce((select min(value) from ln_test_overrides
                                where key = p_key and expires_at > now()), p_cap));
$$;

-- ---------------------------------------------------------------------------
-- B1/L1: summarize + ask. Checks, in this order, and charges only if all
-- pass: user calls + user USD, IP calls + IP USD, LLM pool, total.
-- Returns {"verdict": "ok"|"user_day"|"ip_day"|"global_day", "day": date}.
-- Lock order (all functions): jobs -> usage_daily -> ip_daily -> cost_daily.
-- ---------------------------------------------------------------------------
create or replace function public.ln_reserve_llm(
  p_user uuid, p_kind text, p_est_usd numeric,
  p_user_calls integer, p_user_usd numeric,
  p_ip_hash text, p_ip_calls integer, p_ip_usd numeric,
  p_pool_usd numeric, p_total_usd numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day date := public.ln_utc_day();
  v_calls integer;
  v_uusd numeric;
  v_ipn integer;
  v_ipusd numeric;
  v_ok boolean;
  v_pool numeric := public.ln_cap('global_llm_usd_cap', p_pool_usd);
  v_total numeric := public.ln_cap('global_usd_cap', p_total_usd);
begin
  if p_kind not in ('summary', 'ask') then raise exception 'bad kind'; end if;
  if p_est_usd < 0 then raise exception 'bad estimate'; end if;

  insert into usage_daily (user_id, day) values (p_user, v_day) on conflict do nothing;
  select case when p_kind = 'summary' then summary_calls else ask_calls end, llm_usd
    into v_calls, v_uusd
    from usage_daily where user_id = p_user and day = v_day for update;
  if v_calls + 1 > p_user_calls
     or v_uusd + p_est_usd > public.ln_cap('user_llm_usd_cap:' || p_user::text, p_user_usd) then
    return jsonb_build_object('verdict', 'user_day', 'day', v_day);
  end if;

  if p_ip_hash is not null then
    insert into ip_daily (ip_hash, day, kind) values (p_ip_hash, v_day, p_kind), (p_ip_hash, v_day, 'llm')
      on conflict do nothing;
    select used into v_ipn from ip_daily where ip_hash = p_ip_hash and day = v_day and kind = p_kind for update;
    select usd into v_ipusd from ip_daily where ip_hash = p_ip_hash and day = v_day and kind = 'llm' for update;
    if v_ipn + 1 > p_ip_calls
       or v_ipusd + p_est_usd > public.ln_cap('ip_llm_usd_cap:' || p_ip_hash, p_ip_usd) then
      return jsonb_build_object('verdict', 'ip_day', 'day', v_day);
    end if;
  end if;

  insert into cost_daily (day) values (v_day) on conflict do nothing;
  update cost_daily set llm_usd = llm_usd + p_est_usd, est_usd = est_usd + p_est_usd
    where day = v_day and llm_usd + p_est_usd <= v_pool and est_usd + p_est_usd <= v_total
    returning true into v_ok;
  if v_ok is null then
    return jsonb_build_object('verdict', 'global_day', 'day', v_day);
  end if;

  update usage_daily set
      summary_calls = summary_calls + (p_kind = 'summary')::int,
      ask_calls = ask_calls + (p_kind = 'ask')::int,
      llm_usd = llm_usd + p_est_usd
    where user_id = p_user and day = v_day;
  if p_ip_hash is not null then
    update ip_daily set used = used + 1 where ip_hash = p_ip_hash and day = v_day and kind = p_kind;
    update ip_daily set usd = usd + p_est_usd where ip_hash = p_ip_hash and day = v_day and kind = 'llm';
  end if;
  return jsonb_build_object('verdict', 'ok', 'day', v_day);
end $$;

-- Move a reservation to the real cost everywhere it was charged. With
-- p_release_call the call itself is given back too (OpenAI refused it and
-- billed nothing), so a failed call costs the user and the IP nothing.
create or replace function public.ln_settle_llm(
  p_user uuid, p_kind text, p_day date, p_ip_hash text,
  p_reserved numeric, p_actual numeric, p_release_call boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  d numeric := p_actual - p_reserved;
  r integer := case when p_release_call then 1 else 0 end;
begin
  if p_kind not in ('summary', 'ask') then raise exception 'bad kind'; end if;
  update usage_daily set
      llm_usd = greatest(0, llm_usd + d),
      summary_calls = greatest(0, summary_calls - case when p_kind = 'summary' then r else 0 end),
      ask_calls = greatest(0, ask_calls - case when p_kind = 'ask' then r else 0 end)
    where user_id = p_user and day = p_day;
  if p_ip_hash is not null then
    update ip_daily set usd = greatest(0, usd + d)
      where ip_hash = p_ip_hash and day = p_day and kind = 'llm';
    if r = 1 then
      update ip_daily set used = greatest(0, used - 1)
        where ip_hash = p_ip_hash and day = p_day and kind = p_kind;
    end if;
  end if;
  update cost_daily set llm_usd = greatest(0, llm_usd + d), est_usd = greatest(0, est_usd + d)
    where day = p_day;
end $$;

-- ---------------------------------------------------------------------------
-- B1/B6: audio. User seconds (day + rolling hour), IP seconds, audio pool,
-- total; charges all of them and records the IP charge on the job so that
-- settle/refund can correct it. Returns 'ok' | 'user_day' | 'user_hour' |
-- 'ip_day' | 'global_day'.
-- ---------------------------------------------------------------------------
create or replace function public.ln_reserve_audio_v2(
  p_job uuid, p_seconds integer, p_usd numeric,
  p_day_limit integer, p_hour_limit integer,
  p_ip_hash text, p_ip_seconds integer,
  p_pool_usd numeric, p_total_usd numeric
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
  v_charged timestamptz;
  v_day date := public.ln_utc_day();
  v_used integer;
  v_hour integer;
  v_ip integer;
  v_ok boolean;
  v_pool numeric := public.ln_cap('global_audio_usd_cap', p_pool_usd);
  v_total numeric := public.ln_cap('global_usd_cap', p_total_usd);
begin
  select user_id, charged_at into v_user, v_charged from jobs where id = p_job for update;
  if v_user is null then raise exception 'job not found'; end if;
  if v_charged is not null then return 'ok'; end if;  -- already charged (retry of an unknown start)

  insert into usage_daily (user_id, day) values (v_user, v_day) on conflict do nothing;
  select audio_seconds into v_used from usage_daily where user_id = v_user and day = v_day for update;
  if v_used + p_seconds > p_day_limit then return 'user_day'; end if;

  select coalesce(sum(charged_seconds), 0) into v_hour from jobs
    where user_id = v_user and charged_at > now() - interval '1 hour';
  if v_hour + p_seconds > p_hour_limit then return 'user_hour'; end if;

  if p_ip_hash is not null then
    insert into ip_daily (ip_hash, day, kind) values (p_ip_hash, v_day, 'audio') on conflict do nothing;
    select used into v_ip from ip_daily where ip_hash = p_ip_hash and day = v_day and kind = 'audio' for update;
    if v_ip + p_seconds > p_ip_seconds then return 'ip_day'; end if;
  end if;

  insert into cost_daily (day) values (v_day) on conflict do nothing;
  update cost_daily set audio_usd = audio_usd + p_usd, est_usd = est_usd + p_usd
    where day = v_day and audio_usd + p_usd <= v_pool and est_usd + p_usd <= v_total
    returning true into v_ok;
  if v_ok is null then return 'global_day'; end if;

  update usage_daily set audio_seconds = audio_seconds + p_seconds where user_id = v_user and day = v_day;
  if p_ip_hash is not null then
    update ip_daily set used = used + p_seconds where ip_hash = p_ip_hash and day = v_day and kind = 'audio';
  end if;
  update jobs set charged_seconds = p_seconds, charged_usd = p_usd, charged_at = now(),
                  ip_hash = p_ip_hash, ip_charged_seconds = case when p_ip_hash is null then 0 else p_seconds end
    where id = p_job;
  return 'ok';
end $$;

-- Undo a job's charge (Soniox refused / failed it). Safe to call twice.
create or replace function public.ln_refund_audio(p_job uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  j record;
  v_day date;
begin
  select user_id, charged_seconds, charged_usd, charged_at, ip_hash, ip_charged_seconds into j
    from jobs where id = p_job for update;
  if j.user_id is null or j.charged_at is null then return; end if;
  v_day := (j.charged_at at time zone 'utc')::date;
  update usage_daily set audio_seconds = greatest(0, audio_seconds - j.charged_seconds)
    where user_id = j.user_id and day = v_day;
  if j.ip_hash is not null and j.ip_charged_seconds > 0 then
    update ip_daily set used = greatest(0, used - j.ip_charged_seconds)
      where ip_hash = j.ip_hash and day = v_day and kind = 'audio';
  end if;
  update cost_daily set est_usd = greatest(0, est_usd - j.charged_usd),
                        audio_usd = greatest(0, audio_usd - j.charged_usd)
    where day = v_day;
  update jobs set charged_seconds = 0, charged_usd = 0, charged_at = null, ip_charged_seconds = 0
    where id = p_job;
end $$;

-- After Soniox reports the real duration: move every charge to the real value.
create or replace function public.ln_settle_audio(p_job uuid, p_seconds integer, p_usd numeric)
returns void
language plpgsql security definer set search_path = public as $$
declare
  j record;
  v_day date;
begin
  select user_id, charged_seconds, charged_usd, charged_at, ip_hash, ip_charged_seconds into j
    from jobs where id = p_job for update;
  if j.user_id is null or j.charged_at is null then return; end if;
  v_day := (j.charged_at at time zone 'utc')::date;
  update usage_daily set audio_seconds = greatest(0, audio_seconds + (p_seconds - j.charged_seconds))
    where user_id = j.user_id and day = v_day;
  if j.ip_hash is not null and j.ip_charged_seconds > 0 then
    update ip_daily set used = greatest(0, used + (p_seconds - j.ip_charged_seconds))
      where ip_hash = j.ip_hash and day = v_day and kind = 'audio';
  end if;
  update cost_daily set est_usd = greatest(0, est_usd + (p_usd - j.charged_usd)),
                        audio_usd = greatest(0, audio_usd + (p_usd - j.charged_usd))
    where day = v_day;
  update jobs set charged_seconds = p_seconds, charged_usd = p_usd,
                  ip_charged_seconds = case when j.ip_hash is null then 0 else p_seconds end
    where id = p_job;
end $$;

-- ---------------------------------------------------------------------------
-- B2: the start claim also stamps started_at (the clock for the 30-min /
-- 6-h / 7-day / 30-day timers).
-- ---------------------------------------------------------------------------
create or replace function public.ln_claim_start(p_job uuid) returns boolean
language sql security definer set search_path = public as $$
  with c as (
    update jobs set start_claimed_at = now(), started_at = now()
    where id = p_job and status = 'uploaded'
      and (start_claimed_at is null or start_claimed_at < now() - interval '3 minutes')
    returning 1
  )
  select exists (select 1 from c);
$$;

-- ---------------------------------------------------------------------------
-- B4: at most 25 objects per user in `uploads` (each is deleted as soon as
-- its transcription ends; a real user has 1-3 waiting). Overwriting an
-- existing path (upsert / TUS resume) goes through the update policy and is
-- not counted. Size cap 100 MB (5 h at 32 kbps is ~72 MB).
-- ---------------------------------------------------------------------------
-- Counts only the caller's own folder (auth.uid()); no argument to abuse.
create or replace function public.ln_upload_count() returns integer
language sql stable security definer set search_path = public, storage as $$
  select count(*)::int from storage.objects
  where bucket_id = 'uploads' and name like (select auth.uid())::text || '/%';
$$;
revoke all on function public.ln_upload_count() from public, anon;
grant execute on function public.ln_upload_count() to authenticated, service_role;

update storage.buckets set file_size_limit = 104857600 where id = 'uploads';

drop policy if exists uploads_insert_own on storage.objects;
create policy uploads_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'uploads'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.m4a$'
    and public.ln_upload_count() < 25
  );

-- ---------------------------------------------------------------------------
-- B5: report. Count + insert under a per-user lock, in one transaction;
-- per-user and per-IP daily caps. Returns 'stored' | 'duplicate' |
-- 'user_day' | 'ip_day'.
-- ---------------------------------------------------------------------------
create or replace function public.ln_report_insert(
  p_user uuid, p_ip_hash text, p_kind text, p_digest text, p_app jsonb, p_body jsonb,
  p_user_limit integer, p_ip_limit integer
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_day date := public.ln_utc_day();
  v_n integer;
  v_ok boolean;
  v_id bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('ln_report:' || p_user::text, 0));
  select count(*) into v_n from client_reports
    where user_id = p_user and created_at > now() - interval '24 hours';
  if v_n >= public.ln_cap('report_user:' || p_user::text, p_user_limit) then return 'user_day'; end if;
  if p_ip_hash is not null then
    insert into ip_daily (ip_hash, day, kind) values (p_ip_hash, v_day, 'report') on conflict do nothing;
    update ip_daily set used = used + 1
      where ip_hash = p_ip_hash and day = v_day and kind = 'report'
        and used + 1 <= public.ln_cap('report_ip:' || p_ip_hash, p_ip_limit)
      returning true into v_ok;
    if v_ok is null then return 'ip_day'; end if;
  end if;
  insert into client_reports (user_id, kind, digest, app, body)
    values (p_user, p_kind, p_digest, p_app, p_body)
    on conflict (user_id, digest) do nothing
    returning id into v_id;
  return case when v_id is null then 'duplicate' else 'stored' end;
end $$;

-- ---------------------------------------------------------------------------
-- A5/L6: summarize idempotency cache. key = sha256(user + every input). A
-- row with value null is "being written" (claimed); a claim older than
-- 3 min is abandoned. Rows expire after the TTL the function passes
-- (default 15 min) and are deleted by ln_cleanup_db (every 15 min).
-- ---------------------------------------------------------------------------
create table if not exists public.summary_cache (
  key        text primary key check (key ~ '^[0-9a-f]{64}$'),
  user_id    uuid not null references auth.users (id) on delete cascade,
  value      jsonb,
  claimed_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists summary_cache_expires on public.summary_cache (expires_at);
alter table public.summary_cache enable row level security;
revoke all on public.summary_cache from anon, authenticated;
grant all on public.summary_cache to service_role;

-- Returns {"state": "claimed"} (caller must compute and put/release),
-- {"state": "hit", "value": ...} or {"state": "busy"} (another call is
-- computing it right now).
create or replace function public.ln_summary_claim(p_key text, p_user uuid, p_ttl_seconds integer)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_claimed boolean;
  v_value jsonb;
  v_owner uuid;
begin
  insert into summary_cache (key, user_id, value, claimed_at, expires_at)
    values (p_key, p_user, null, now(), now() + make_interval(secs => p_ttl_seconds))
    on conflict (key) do update
      set value = null, claimed_at = now(), expires_at = now() + make_interval(secs => p_ttl_seconds)
      where summary_cache.user_id = p_user
        and (summary_cache.expires_at < now()
             or (summary_cache.value is null and summary_cache.claimed_at < now() - interval '3 minutes'))
    returning true into v_claimed;
  if v_claimed then return jsonb_build_object('state', 'claimed'); end if;
  select value, user_id into v_value, v_owner from summary_cache where key = p_key;
  if v_owner is distinct from p_user then raise exception 'key owner mismatch'; end if;
  if v_value is not null then return jsonb_build_object('state', 'hit', 'value', v_value); end if;
  return jsonb_build_object('state', 'busy');
end $$;

-- ---------------------------------------------------------------------------
-- Cleanup (pg_cron every 15 min). Changes:
--  L3  a fetched transcript is kept until ack or 24 h after the first fetch.
--  B2  never-fetched results: 7 days after done (else started, else created);
--      rows: 30 days after started/created.
--  A5  expired summary cache rows.
--  L9  anonymous users with no session activity for 90 days (at most 500
--      per run); their jobs/usage rows go with them (on delete cascade).
-- ---------------------------------------------------------------------------
create or replace function public.ln_cleanup_db() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a integer; b integer; c integer; d integer; e integer; f integer;
begin
  update jobs set result = null
    where result is not null
      and ((status = 'fetched' and fetched_at < now() - interval '24 hours')
           or coalesce(done_at, started_at, created_at) < now() - interval '7 days');
  get diagnostics a = row_count;
  delete from jobs where coalesce(started_at, created_at) < now() - interval '30 days';
  get diagnostics b = row_count;
  delete from usage_daily where day < public.ln_utc_day() - 90;
  get diagnostics c = row_count;
  delete from ip_daily where day < public.ln_utc_day() - 2;
  get diagnostics d = row_count;
  delete from ln_test_overrides where expires_at < now();
  delete from summary_cache where expires_at < now();
  get diagnostics e = row_count;
  delete from auth.users u
    where u.id in (
      select x.id from auth.users x
      where x.is_anonymous
        and x.created_at < now() - interval '90 days'
        and coalesce(x.last_sign_in_at, x.created_at) < now() - interval '90 days'
        and not exists (select 1 from auth.sessions s where s.user_id = x.id
                          and coalesce(s.refreshed_at, s.updated_at, s.created_at) > now() - interval '90 days')
      limit 500);
  get diagnostics f = row_count;
  return jsonb_build_object('results_cleared', a, 'jobs_deleted', b, 'usage_rows_deleted', c,
                            'ip_rows_deleted', d, 'summary_cache_deleted', e, 'anon_users_deleted', f);
end $$;

-- Jobs still transcribing since before p_minutes ago (cleanup, B2 clock).
create or replace function public.ln_stuck_jobs(p_minutes integer, p_limit integer)
returns table (id uuid, started_at timestamptz, audio_path text, soniox_transcription_id text)
language sql stable security definer set search_path = public as $$
  select j.id, coalesce(j.started_at, j.created_at), j.audio_path, j.soniox_transcription_id
  from jobs j
  where j.status = 'transcribing'
    and coalesce(j.started_at, j.created_at) < now() - make_interval(mins => p_minutes)
  order by coalesce(j.started_at, j.created_at)
  limit p_limit;
$$;

-- ---------------------------------------------------------------------------
-- Grants: service role only (ln_upload_count above is also granted to
-- authenticated: the storage insert policy calls it as the user).
-- ---------------------------------------------------------------------------
revoke all on function
  public.ln_cap(text, numeric),
  public.ln_reserve_llm(uuid, text, numeric, integer, numeric, text, integer, numeric, numeric, numeric),
  public.ln_settle_llm(uuid, text, date, text, numeric, numeric, boolean),
  public.ln_reserve_audio_v2(uuid, integer, numeric, integer, integer, text, integer, numeric, numeric),
  public.ln_refund_audio(uuid),
  public.ln_settle_audio(uuid, integer, numeric),
  public.ln_claim_start(uuid),
  public.ln_report_insert(uuid, text, text, text, jsonb, jsonb, integer, integer),
  public.ln_summary_claim(text, uuid, integer),
  public.ln_cleanup_db(),
  public.ln_stuck_jobs(integer, integer)
  from public, anon, authenticated;

grant execute on function
  public.ln_cap(text, numeric),
  public.ln_reserve_llm(uuid, text, numeric, integer, numeric, text, integer, numeric, numeric, numeric),
  public.ln_settle_llm(uuid, text, date, text, numeric, numeric, boolean),
  public.ln_reserve_audio_v2(uuid, integer, numeric, integer, integer, text, integer, numeric, numeric),
  public.ln_refund_audio(uuid),
  public.ln_settle_audio(uuid, integer, numeric),
  public.ln_claim_start(uuid),
  public.ln_report_insert(uuid, text, text, text, jsonb, jsonb, integer, integer),
  public.ln_summary_claim(text, uuid, integer),
  public.ln_cleanup_db(),
  public.ln_stuck_jobs(integer, integer)
  to service_role;

-- client_reports (00006) had no explicit service_role grant; make it explicit.
grant all on public.client_reports to service_role;
