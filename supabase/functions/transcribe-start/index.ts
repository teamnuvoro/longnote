// transcribe-start: the app has uploaded <uid>/<client_note_id>.m4a to the
// `uploads` bucket; check it, check limits, start a Soniox async job.
// Idempotent on (user, client_note_id). Contract: docs/BACKEND-API.md.

import {
  admin, ApiError, envNum, handle, ipHash, json, limitError, limits, readJson, requireUser, SONIOX_USD_PER_HOUR,
} from "../_shared/common.ts";
import { BUCKET, deleteAudio, findByReference, MAX_START_TRIES, sonioxCreate, sonioxDelete } from "../_shared/soniox.ts";

const NOTE_ID = /^[A-Za-z0-9_-]{1,64}$/;
const LANG = /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/;
/** Signed URL lifetime for Soniox to fetch the audio (queue time included). */
const SIGNED_URL_SECONDS = envNum("SIGNED_URL_SECONDS", 3 * 3600);
/**
 * Bytes per second of the app's format (AAC-LC ~32 kbps = 4,000 B/s). The
 * audio length is floored at bytes / 4000, so an understated audio_seconds
 * cannot dodge the limits.
 */
const BYTES_PER_SEC_FLOOR = 4_000;
/**
 * The too_long check on the byte floor allows 5% for container overhead and
 * encoder variance (the e2e file is 32.6 kbps), so a real 4 h 55 min file
 * is not refused. A file truly over Soniox's 300 min still fails there.
 */
const FLOOR_TOLERANCE = 1.05;

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const body = await readJson(req, 8 * 1024);
  const lim = limits();

  const cnid = body.client_note_id;
  if (typeof cnid !== "string" || !NOTE_ID.test(cnid)) {
    throw new ApiError("bad_request", "client_note_id must be 1-64 letters, digits, _ or -.");
  }
  const expectedPath = `${user.id}/${cnid}.m4a`;
  if (body.audio_path !== expectedPath) {
    throw new ApiError("bad_request", "audio_path must be <user_id>/<client_note_id>.m4a.", { expected: expectedPath });
  }
  const secs = body.audio_seconds;
  if (typeof secs !== "number" || !Number.isFinite(secs) || secs <= 0) {
    throw new ApiError("bad_request", "audio_seconds must be a positive number.");
  }
  const claimedSeconds = Math.ceil(secs);
  if (claimedSeconds > lim.maxAudioSeconds) {
    throw new ApiError("too_long", "Recording is longer than the cloud limit.", { max_seconds: lim.maxAudioSeconds });
  }
  const language = body.language ?? "auto";
  if (typeof language !== "string" || (language !== "auto" && !LANG.test(language))) {
    throw new ApiError("bad_request", "language must be 'auto' or a language code like 'en' or 'hi'.");
  }
  let hints: string[] = [];
  if (body.language_hints !== undefined && body.language_hints !== null) {
    if (!Array.isArray(body.language_hints) || body.language_hints.length > 10 ||
      !body.language_hints.every((h) => typeof h === "string" && LANG.test(h))) {
      throw new ApiError("bad_request", "language_hints must be up to 10 language codes.");
    }
    hints = body.language_hints as string[];
  }
  if (language !== "auto") hints = [language, ...hints.filter((h) => h !== language)];

  const db = admin();

  // Existing job for this note?
  const { data: existing, error: exErr } = await db.from("jobs")
    .select("id,status,tries,charged_at").eq("user_id", user.id).eq("client_note_id", cnid).maybeSingle();
  if (exErr) throw new ApiError("server_error", "db read failed");
  if (existing && (existing.status === "transcribing" || existing.status === "done")) {
    return json(200, { job_id: existing.id, client_note_id: cnid, status: existing.status });
  }

  // The object must exist and belong to this user.
  const { data: info, error: infoErr } = await db.rpc("ln_object_info", { p_bucket: BUCKET, p_name: expectedPath });
  if (infoErr) throw new ApiError("server_error", "storage lookup failed");
  const obj = (info as any[] | null)?.[0];
  if (!obj) {
    if (existing && existing.status !== "uploaded") {
      // failed / fetched with no new upload: report the job as it is.
      return json(200, { job_id: existing.id, client_note_id: cnid, status: existing.status });
    }
    // No job, or a job that never started whose audio is gone (24 h sweep).
    throw new ApiError("not_found", "Audio upload not found. Upload it again.");
  }
  if (obj.owner_id && obj.owner_id !== user.id) throw new ApiError("not_found", "Audio upload not found.");
  const bytes = Number(obj.size_bytes) || 0;
  const floorSeconds = Math.ceil(bytes / BYTES_PER_SEC_FLOOR);
  if (floorSeconds > lim.maxAudioSeconds * FLOOR_TOLERANCE) {
    throw new ApiError("too_long", "Recording is longer than the cloud limit.", { max_seconds: lim.maxAudioSeconds });
  }
  const chargeSeconds = Math.max(claimedSeconds, floorSeconds);
  const current = (status: string, id: string) => json(200, { job_id: id, client_note_id: cnid, status });

  // Create the row, or move a failed/fetched job back to `uploaded` with a
  // compare-and-set on its status (a parallel call that loses gets the job).
  const fresh = {
    language,
    language_hints: hints,
    audio_path: expectedPath,
    audio_bytes: bytes,
    audio_seconds: claimedSeconds,
  };
  let jobId: string;
  if (!existing) {
    const { data, error } = await db.from("jobs")
      .insert({ ...fresh, status: "uploaded", user_id: user.id, client_note_id: cnid })
      .select("id").single();
    if (error) {
      // Lost a race with a parallel call for the same note: carry on with
      // that row; the start claim below decides who calls Soniox.
      const { data: again } = await db.from("jobs").select("id,status")
        .eq("user_id", user.id).eq("client_note_id", cnid).maybeSingle();
      if (!again) throw new ApiError("server_error", "db write failed");
      if (again.status !== "uploaded") return current(again.status, again.id);
      jobId = again.id;
    } else {
      jobId = data.id;
    }
  } else if (existing.status === "uploaded") {
    jobId = existing.id;
  } else {
    // failed or fetched, and a new upload exists: start over.
    const { data: reset, error } = await db.from("jobs").update({
      ...fresh, status: "uploaded", error: null, error_code: null, tries: 0, result: null,
      soniox_transcription_id: null, soniox_deleted: false, audio_deleted: false,
      charged_seconds: 0, charged_usd: 0, charged_at: null, start_claimed_at: null,
      webhook_received_at: null, soniox_checked_at: null, soniox_completed_seen_at: null,
      finalizing_at: null, audio_duration_ms: null, done_at: null, fetched_at: null,
    }).eq("id", existing.id).eq("status", existing.status).select("id");
    if (error) throw new ApiError("server_error", "db write failed");
    if (!reset?.length) {
      const { data: now } = await db.from("jobs").select("id,status").eq("id", existing.id).single();
      if (now?.status !== "uploaded") return current(now?.status ?? existing.status, existing.id);
    }
    jobId = existing.id;
  }

  // Atomic claim: only one caller may charge and call Soniox for this job.
  const { data: claimed, error: claimErr } = await db.rpc("ln_claim_start", { p_job: jobId });
  if (claimErr) throw new ApiError("server_error", "db write failed");
  if (claimed !== true) {
    const { data: now } = await db.from("jobs").select("status").eq("id", jobId).single();
    return current(now?.status ?? "uploaded", jobId);
  }

  let started: { id: string } | { error: string; status: number; unknown?: boolean } | null = null;
  let tries = 0;
  try {
    const { data: row, error: rowErr } = await db.from("jobs").update(fresh).eq("id", jobId)
      .select("tries,charged_at,error").single();
    if (rowErr || !row) throw new ApiError("server_error", "db write failed");
    tries = row.tries;

    // Limits (one atomic check + charge in SQL): user day/hour, IP (IPv6
    // per /64), audio pool, total. The IP charge is stored on the job and
    // corrected with it at settle/refund (review B6).
    if (row.charged_at === null) {
      const usd = Number(((chargeSeconds / 3600) * SONIOX_USD_PER_HOUR).toFixed(4));
      const { data: verdict, error } = await db.rpc("ln_reserve_audio_v2", {
        p_job: jobId, p_seconds: chargeSeconds, p_usd: usd,
        p_day_limit: lim.audioSecondsPerDay, p_hour_limit: lim.audioSecondsPerHour,
        p_ip_hash: await ipHash(req), p_ip_seconds: lim.ipAudioSecondsPerDay,
        p_pool_usd: lim.globalAudioUsdPerDay, p_total_usd: lim.globalUsdPerDay,
      });
      if (error) throw new ApiError("server_error", "limit check failed");
      if (verdict !== "ok") {
        await db.from("jobs").update({ error_code: "limit_reached", error: String(verdict) }).eq("id", jobId);
        throw limitError(String(verdict));
      }
    }

    // The previous start got no answer from Soniox (review B3): if Soniox
    // did create that transcription, use it instead of creating a second.
    if (typeof row.error === "string" && row.error.startsWith("start_unknown")) {
      const prior = await findByReference(jobId);
      const live = prior?.find((t) => t.status !== "error");
      for (const t of prior ?? []) if (t !== live) await sonioxDelete(t.id);
      if (live) {
        console.log("soniox_adopted");
        const { error } = await db.from("jobs").update({
          status: "transcribing", soniox_transcription_id: live.id, start_claimed_at: null,
          error: null, error_code: null,
        }).eq("id", jobId);
        if (error) throw new ApiError("server_error", "db write failed");
        started = { id: live.id };
        return current("transcribing", jobId);
      }
    }

    // Short-lived signed URL for Soniox to fetch the audio.
    const { data: signed, error: signErr } = await db.storage.from(BUCKET)
      .createSignedUrl(expectedPath, SIGNED_URL_SECONDS);
    if (signErr || !signed?.signedUrl) throw new ApiError("server_error", "could not sign the audio url");

    const webhook = (Deno.env.get("SONIOX_WEBHOOKS") ?? "on") !== "off";
    started = await sonioxCreate({ audioUrl: signed.signedUrl, languageHints: hints, jobId, webhook });
    tries += 1;

    if ("id" in started) {
      const { error } = await db.from("jobs").update({
        status: "transcribing", soniox_transcription_id: started.id, tries, start_claimed_at: null,
        error: null, error_code: null,
      }).eq("id", jobId);
      if (error) throw new ApiError("server_error", "db write failed");
      return current("transcribing", jobId);
    }
  } catch (e) {
    // Not started: free the claim so a retry can start it. The charge stays
    // on the job (charged_at) and is reused by that retry, not charged twice.
    if (!(started && "id" in started)) {
      await db.from("jobs").update({ start_claimed_at: null }).eq("id", jobId);
    }
    throw e;
  }

  if (!started || "id" in started) throw new ApiError("server_error", "unexpected start state");
  console.error("soniox_create_failed", started.status);
  if (!started.unknown) {
    // Soniox refused: give the minutes back (user, IP, pool).
    await db.rpc("ln_refund_audio", { p_job: jobId });
  }
  if (tries >= MAX_START_TRIES) {
    if (started.unknown) {
      // Delete anything Soniox may have created for this job, then refund.
      for (const t of (await findByReference(jobId)) ?? []) await sonioxDelete(t.id);
      await db.rpc("ln_refund_audio", { p_job: jobId });
    }
    const deleted = await deleteAudio(expectedPath);
    await db.from("jobs").update({
      status: "failed", tries, error_code: "upstream_failed", error: started.error, audio_deleted: deleted,
      start_claimed_at: null,
    }).eq("id", jobId);
    throw new ApiError("upstream_failed", "Transcription could not start. Upload again to retry.", {
      job_id: jobId, tries_left: 0,
    });
  }
  await db.from("jobs").update({ tries, error_code: "upstream_failed", error: started.error, start_claimed_at: null })
    .eq("id", jobId);
  throw new ApiError("upstream_failed", "Transcription could not start. Try again.", {
    job_id: jobId, tries_left: MAX_START_TRIES - tries,
  });
}));
