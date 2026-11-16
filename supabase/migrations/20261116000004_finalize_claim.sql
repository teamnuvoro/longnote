-- One caller (webhook or status fallback) at a time may finalise a job.
-- A claim older than 5 min is treated as abandoned.
create or replace function public.ln_claim_finalize(p_job uuid)
returns table (id uuid, soniox_transcription_id text, audio_path text)
language sql security definer set search_path = public as $$
  update jobs j set finalizing_at = now()
  where j.id = p_job and j.status = 'transcribing'
    and j.soniox_transcription_id is not null
    and (j.finalizing_at is null or j.finalizing_at < now() - interval '5 minutes')
  returning j.id, j.soniox_transcription_id, j.audio_path;
$$;
revoke all on function public.ln_claim_finalize(uuid) from public, anon, authenticated;
grant execute on function public.ln_claim_finalize(uuid) to service_role;
