-- Crash / error reports from the app (lib/core/diagnostics/crash_reporter.dart
-- via the `report` function). Service role only; kept 30 days.
create table if not exists public.client_reports (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  kind text not null,
  digest text not null,
  app jsonb,
  body jsonb not null,
  unique (user_id, digest)
);
create index if not exists client_reports_created on public.client_reports (created_at);
alter table public.client_reports enable row level security;
revoke all on public.client_reports from anon, authenticated;

select cron.schedule(
  'longnote-client-reports-ttl',
  '23 3 * * *',
  $$ delete from public.client_reports where created_at < now() - interval '30 days'; $$
);
