-- Longnote v1 backend schema (16 Nov 2026).
-- Tables: jobs, usage_daily, cost_daily. Re-runnable (if not exists / drop if
-- exists guards, added 16 Nov after review L8). Helper functions used only by the
-- edge functions (service role). Contract: docs/BACKEND-API.md.
--
-- Privacy: audio lives in storage bucket `uploads` for at most 24 h (deleted
-- as soon as transcription ends); jobs.result (the transcript) is cleared on
-- ack / 15 min after it is fetched / 7 days after creation (current timers:
-- 20261116000007: 24 h after fetch, 7 days after done); jobs rows are
-- deleted after 30 days. See 20261116000003_cleanup_cron.sql.

-- ---------------------------------------------------------------------------
-- jobs: one row per transcription request
-- ---------------------------------------------------------------------------
create table if not exists public.jobs (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references auth.users (id) on delete cascade,
  client_note_id            text not null check (client_note_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  status                    text not null default 'uploaded'
                              check (status in ('uploaded', 'transcribing', 'done', 'failed', 'fetched')),
  language                  text not null default 'auto',
  language_hints            text[] not null default '{}',
  audio_path                text not null,
  audio_bytes               bigint,
  audio_seconds             integer not null check (audio_seconds > 0),
  soniox_transcription_id   text unique,
  soniox_file_id            text,            -- unused in v1 (we pass a signed audio_url)
  soniox_deleted            boolean not null default false,
  audio_deleted             boolean not null default false,
  error_code                text,
  error                     text,
  tries                     integer not null default 0,
  result                    jsonb,
  -- limits bookkeeping
  charged_seconds           integer not null default 0,
  charged_usd               numeric(10, 4) not null default 0,
  charged_at                timestamptz,
  -- webhook / fallback bookkeeping
  webhook_received_at       timestamptz,
  soniox_checked_at         timestamptz,
  soniox_completed_seen_at  timestamptz,
  finalizing_at             timestamptz,
  audio_duration_ms         bigint,
  done_at                   timestamptz,
  fetched_at                timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (user_id, client_note_id)
);

create index if not exists jobs_user_charged_idx on public.jobs (user_id, charged_at);
create index if not exists jobs_status_idx on public.jobs (status, updated_at);
create index if not exists jobs_created_idx on public.jobs (created_at);

create or replace function public.ln_touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists jobs_touch on public.jobs;
create trigger jobs_touch before update on public.jobs
  for each row execute function public.ln_touch_updated_at();

-- ---------------------------------------------------------------------------
-- usage_daily (per user, UTC day) and cost_daily (global, UTC day)
-- ---------------------------------------------------------------------------
create table if not exists public.usage_daily (
  user_id        uuid not null references auth.users (id) on delete cascade,
  day            date not null,
  audio_seconds  integer not null default 0,
  summary_calls  integer not null default 0,
  ask_calls      integer not null default 0,
  primary key (user_id, day)
);

create table if not exists public.cost_daily (
  day     date primary key,
  est_usd numeric(12, 4) not null default 0
);

-- ---------------------------------------------------------------------------
-- RLS: users read only their own rows; every write goes through the edge
-- functions with the service role (which bypasses RLS).
-- ---------------------------------------------------------------------------
alter table public.jobs enable row level security;
alter table public.usage_daily enable row level security;
alter table public.cost_daily enable row level security;

drop policy if exists jobs_select_own on public.jobs;
create policy jobs_select_own on public.jobs
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists usage_select_own on public.usage_daily;
create policy usage_select_own on public.usage_daily
  for select to authenticated using (user_id = (select auth.uid()));

-- cost_daily: no policy -> no client access at all.

revoke all on public.jobs, public.usage_daily, public.cost_daily from anon, authenticated;
grant select on public.jobs, public.usage_daily to authenticated;
grant all on public.jobs, public.usage_daily, public.cost_daily to service_role;

-- ---------------------------------------------------------------------------
-- Helper functions (service role only)
-- ---------------------------------------------------------------------------
create or replace function public.ln_utc_day() returns date
language sql stable as $$ select (now() at time zone 'utc')::date $$;

-- Atomically check limits and charge audio for one job.
-- Returns 'ok' or the limit that was hit: 'user_day' | 'user_hour' | 'global_day'.
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
  if v_cost + p_usd > p_global_cap then return 'global_day'; end if;

  update usage_daily set audio_seconds = audio_seconds + p_seconds
    where user_id = v_user and day = v_day;
  update cost_daily set est_usd = est_usd + p_usd where day = v_day;
  update jobs set charged_seconds = p_seconds, charged_usd = p_usd, charged_at = now()
    where id = p_job;
  return 'ok';
end $$;

-- Undo a job's charge (Soniox refused to start it). Safe to call twice.
create or replace function public.ln_refund_audio(p_job uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  j record;
  v_day date;
begin
  select user_id, charged_seconds, charged_usd, charged_at into j
    from jobs where id = p_job for update;
  if j.user_id is null or j.charged_seconds = 0 then return; end if;
  v_day := (j.charged_at at time zone 'utc')::date;
  update usage_daily set audio_seconds = greatest(0, audio_seconds - j.charged_seconds)
    where user_id = j.user_id and day = v_day;
  update cost_daily set est_usd = greatest(0, est_usd - j.charged_usd) where day = v_day;
  update jobs set charged_seconds = 0, charged_usd = 0, charged_at = null where id = p_job;
end $$;

-- After Soniox reports the real duration: move the charge to the real value.
create or replace function public.ln_settle_audio(p_job uuid, p_seconds integer, p_usd numeric)
returns void
language plpgsql security definer set search_path = public as $$
declare
  j record;
  v_day date;
begin
  select user_id, charged_seconds, charged_usd, charged_at into j
    from jobs where id = p_job for update;
  if j.user_id is null or j.charged_at is null then return; end if;
  v_day := (j.charged_at at time zone 'utc')::date;
  update usage_daily set audio_seconds = greatest(0, audio_seconds + (p_seconds - j.charged_seconds))
    where user_id = j.user_id and day = v_day;
  update cost_daily set est_usd = greatest(0, est_usd + (p_usd - j.charged_usd)) where day = v_day;
  update jobs set charged_seconds = p_seconds, charged_usd = p_usd where id = p_job;
end $$;

-- Count one summary/ask call. Returns 'ok' | 'user_day' | 'global_day'.
create or replace function public.ln_count_call(
  p_user uuid, p_kind text, p_limit integer, p_global_cap numeric
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_day date := public.ln_utc_day();
  v_n integer;
  v_cost numeric;
begin
  if p_kind not in ('summary', 'ask') then raise exception 'bad kind'; end if;
  select coalesce((select est_usd from cost_daily where day = v_day), 0) into v_cost;
  if v_cost >= p_global_cap then return 'global_day'; end if;

  insert into usage_daily (user_id, day) values (p_user, v_day) on conflict do nothing;
  if p_kind = 'summary' then
    select summary_calls into v_n from usage_daily where user_id = p_user and day = v_day for update;
    if v_n + 1 > p_limit then return 'user_day'; end if;
    update usage_daily set summary_calls = summary_calls + 1 where user_id = p_user and day = v_day;
  else
    select ask_calls into v_n from usage_daily where user_id = p_user and day = v_day for update;
    if v_n + 1 > p_limit then return 'user_day'; end if;
    update usage_daily set ask_calls = ask_calls + 1 where user_id = p_user and day = v_day;
  end if;
  return 'ok';
end $$;

create or replace function public.ln_add_cost(p_usd numeric) returns void
language sql security definer set search_path = public as $$
  insert into cost_daily (day, est_usd) values (public.ln_utc_day(), p_usd)
  on conflict (day) do update set est_usd = cost_daily.est_usd + excluded.est_usd;
$$;

-- Storage object metadata (storage schema is not exposed over the API).
create or replace function public.ln_object_info(p_bucket text, p_name text)
returns table (owner_id text, size_bytes bigint, created_at timestamptz)
language sql security definer set search_path = public, storage as $$
  select o.owner_id, (o.metadata ->> 'size')::bigint, o.created_at
  from storage.objects o where o.bucket_id = p_bucket and o.name = p_name;
$$;

-- Objects older than p_hours in a bucket (for the cleanup function).
create or replace function public.ln_old_objects(p_bucket text, p_hours integer, p_limit integer)
returns table (name text)
language sql security definer set search_path = public, storage as $$
  select o.name from storage.objects o
  where o.bucket_id = p_bucket and o.created_at < now() - make_interval(hours => p_hours)
  order by o.created_at limit p_limit;
$$;

-- Database-only cleanup (also run by pg_cron every 15 min).
create or replace function public.ln_cleanup_db() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a integer; b integer; c integer;
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
  return jsonb_build_object('results_cleared', a, 'jobs_deleted', b, 'usage_rows_deleted', c);
end $$;

revoke all on function
  public.ln_reserve_audio(uuid, integer, numeric, integer, integer, numeric),
  public.ln_refund_audio(uuid),
  public.ln_settle_audio(uuid, integer, numeric),
  public.ln_count_call(uuid, text, integer, numeric),
  public.ln_add_cost(numeric),
  public.ln_object_info(text, text),
  public.ln_old_objects(text, integer, integer),
  public.ln_cleanup_db()
  from public, anon, authenticated;

grant execute on function
  public.ln_reserve_audio(uuid, integer, numeric, integer, integer, numeric),
  public.ln_refund_audio(uuid),
  public.ln_settle_audio(uuid, integer, numeric),
  public.ln_count_call(uuid, text, integer, numeric),
  public.ln_add_cost(numeric),
  public.ln_object_info(text, text),
  public.ln_old_objects(text, integer, integer),
  public.ln_cleanup_db()
  to service_role;
