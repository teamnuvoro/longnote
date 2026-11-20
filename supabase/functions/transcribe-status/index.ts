// transcribe-status: the app polls a job. When the transcript is ready it is
// returned and the job becomes `fetched`; the server copy is cleared on
// {"ack": true} or 24 h after the first fetch (pg_cron), whichever is first.
// Once the server copy is gone the job reads `fetched` (no result).
// If the Soniox webhook never arrives, this pulls the result itself.

import { admin, ApiError, envNum, handle, json, readJson, requireUser } from "../_shared/common.ts";
import { finalizeJob, sonioxGet } from "../_shared/soniox.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NOTE_ID = /^[A-Za-z0-9_-]{1,64}$/;
/** Ask Soniox directly at most this often per job. */
const CHECK_EVERY_S = envNum("SONIOX_CHECK_EVERY_SECONDS", 20);
/** After Soniox says finished, wait this long for the webhook before pulling. */
const WEBHOOK_GRACE_S = envNum("WEBHOOK_GRACE_SECONDS", 120);

// One literal (not joined with +), so postgrest-js can type the row.
const COLS =
  "id,client_note_id,status,language,audio_seconds,error_code,error,result,soniox_transcription_id,soniox_checked_at,soniox_completed_seen_at,fetched_at,created_at,updated_at";

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const body = await readJson(req, 4 * 1024);
  const db = admin();

  let q = db.from("jobs").select(COLS).eq("user_id", user.id);
  if (typeof body.job_id === "string" && UUID.test(body.job_id)) q = q.eq("id", body.job_id);
  else if (typeof body.client_note_id === "string" && NOTE_ID.test(body.client_note_id)) {
    q = q.eq("client_note_id", body.client_note_id);
  } else throw new ApiError("bad_request", "Send job_id or client_note_id.");
  const { data: job, error } = await q.maybeSingle();
  if (error) throw new ApiError("server_error", "db read failed");
  if (!job) throw new ApiError("not_found", "No such transcription job.");

  const base = { job_id: job.id, client_note_id: job.client_note_id, audio_seconds: job.audio_seconds };

  // The app saved the transcript: clear the server copy now.
  if (body.ack === true) {
    if (job.status === "done" || job.status === "fetched") {
      await db.from("jobs").update({
        status: "fetched", result: null, fetched_at: job.fetched_at ?? new Date().toISOString(),
      }).eq("id", job.id);
      return json(200, { ...base, status: "fetched" });
    }
    return json(200, { ...base, status: job.status });
  }

  let status: string = job.status;
  let providerStatus: string | undefined;

  if (status === "transcribing" && job.soniox_transcription_id) {
    const now = Date.now();
    const last = job.soniox_checked_at ? Date.parse(job.soniox_checked_at) : 0;
    if (now - last >= CHECK_EVERY_S * 1000) {
      await db.from("jobs").update({ soniox_checked_at: new Date(now).toISOString() }).eq("id", job.id);
      const g = await sonioxGet(job.soniox_transcription_id);
      if (g.status === 200) providerStatus = g.data?.status;
      else if (g.status === 404) providerStatus = "error";
      if (providerStatus === "completed" || providerStatus === "error") {
        const seen = job.soniox_completed_seen_at ? Date.parse(job.soniox_completed_seen_at) : 0;
        if (!seen) {
          await db.from("jobs").update({ soniox_completed_seen_at: new Date(now).toISOString() }).eq("id", job.id);
        }
        const webhooksOff = (Deno.env.get("SONIOX_WEBHOOKS") ?? "on") === "off";
        if (webhooksOff || (seen && now - seen >= WEBHOOK_GRACE_S * 1000)) {
          console.log("status_fallback_finalize");
          await finalizeJob(job.id, providerStatus);
        }
      }
    }
    // Re-read: the webhook or the fallback may have finished the job.
    const { data: again } = await db.from("jobs").select(COLS).eq("id", job.id).single();
    if (again) Object.assign(job, again);
    status = job.status;
  }

  // A finished job whose result was already cleared (7 days without a
  // fetch): say so plainly instead of `done` with no result (review L2).
  if (status === "done" && !job.result) {
    return json(200, { ...base, status: "fetched" });
  }
  if (status === "done" || (status === "fetched" && job.result)) {
    if (status === "done") {
      await db.from("jobs").update({ status: "fetched", fetched_at: new Date().toISOString() })
        .eq("id", job.id).eq("status", "done");
    }
    return json(200, { ...base, status: "done", result: job.result });
  }
  if (status === "failed") {
    return json(200, {
      ...base,
      status,
      error: { code: job.error_code ?? "upstream_failed", message: "Transcription failed. Upload the audio again to retry." },
    });
  }
  if (status === "uploaded" && job.error_code) {
    return json(200, { ...base, status, error: { code: job.error_code, message: "Not started yet. Call transcribe-start again." } });
  }
  return json(200, { ...base, status, ...(providerStatus ? { provider_status: providerStatus } : {}) });
}));
