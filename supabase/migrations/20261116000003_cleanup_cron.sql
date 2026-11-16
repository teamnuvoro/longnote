-- Scheduled cleanup.
--  * every 15 min (SQL only): clear jobs.result 15 min after fetch or 7 days
--    after creation; delete jobs older than 30 days.
--  * hourly: call the `cleanup` edge function, which deletes storage objects
--    in `uploads` older than 24 h (storage rows can only be deleted through
--    the Storage API), deletes leftover Soniox transcriptions, and fails jobs
--    stuck for more than 6 h.
--
-- Needs two Vault secrets, created outside git (values are not in this repo):
--   project_url      e.g. https://<ref>.supabase.co
--   cleanup_secret   same value as the CLEANUP_SECRET function secret

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'longnote-cleanup-db',
  '*/15 * * * *',
  $$ select public.ln_cleanup_db(); $$
);

select cron.schedule(
  'longnote-cleanup-storage',
  '7 * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/cleanup',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cleanup-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'cleanup_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
