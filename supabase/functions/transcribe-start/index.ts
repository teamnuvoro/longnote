// transcribe-start: the app has uploaded <uid>/<client_note_id>.m4a to the
// `uploads` bucket; check it, check limits, start a Soniox async job.
// Idempotent on (user, client_note_id). Contract: docs/BACKEND-API.md.

import {
  admin, ApiError, envNum, handle, json, limitError, limits, readJson, requireUser,
  SONIOX_USD_PER_HOUR,
} from "../_shared/common.ts";
import { BUCKET, deleteAudio, MAX_START_TRIES, sonioxCreate } from "../_shared/soniox.ts";

const NOTE_ID = /^[A-Za-z0-9_-]{1,64}$/;
const LANG = /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/;
/** Signed URL lifetime for Soniox to fetch the audio (queue time included). */
const SIGNED_URL_SECONDS = envNum("SIGNED_URL_SECONDS", 3 * 3600);
/** Lowest bytes/second we believe; guards against an understated audio_seconds. */
const MIN_BYTES_PER_SEC_FLOOR = 12_000; // 96 kbps

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
    if (existing) {
      // failed / fetched with no new upload: report the job as it is.
      return json(200, { job_id: existing.id, client_note_id: cnid, status: existing.status });
    }
    throw new ApiError("not_found", "Audio upload not found. Upload it again.");
  }
  if (obj.owner_id && obj.owner_id !== user.id) throw new ApiError("not_found", "Audio upload not found.");
  const bytes = Number(obj.size_bytes) || 0;
  const chargeSeconds = Math.max(claimedSeconds, Math.ceil(bytes / MIN_BYTES_PER_SEC_FLOOR));
  if (chargeSeconds > lim.maxAudioSeconds) {
    throw new ApiError("too_long", "Recording is longer than the cloud limit.", { max_seconds: lim.maxAudioSeconds });
  }

  // Create, or reset for a new attempt.
  const fresh = {
    status: "uploaded",
    language,
    language_hints: hints,
    audio_path: expectedPath,
    audio_bytes: bytes,
    audio_seconds: claimedSeconds,
    error: null,
    error_code: null,
  };
  let jobId: string;
  let tries: number;
  let charged: boolean;
  if (!existing) {
    const { data, error } = await db.from("jobs").insert({ ...fresh, user_id: user.id, client_note_id: cnid })
      .select("id").single();
    if (error) {
      // Lost a race with a parallel call for the same note: return that job.
      const { data: again } = await db.from("jobs").select("id,status")
        .eq("user_id", user.id).eq("client_note_id", cnid).maybeSingle();
      if (again) return json(200, { job_id: again.id, client_note_id: cnid, status: again.status });
      throw new ApiError("server_error", "db write failed");
    }
    jobId = data.id;
    tries = 0;
    charged = false;
  } else if (existing.status === "uploaded") {
    jobId = existing.id;
    tries = existing.tries;
    charged = existing.charged_at !== null;
    await db.from("jobs").update(fresh).eq("id", jobId);
  } else {
    // failed or fetched, and a new upload exists: start over.
    jobId = existing.id;
    tries = 0;
    charged = false;
    await db.from("jobs").update({
      ...fresh, tries: 0, result: null, soniox_transcription_id: null, soniox_deleted: false,
      audio_deleted: false, charged_seconds: 0, charged_usd: 0, charged_at: null,
      webhook_received_at: null, soniox_checked_at: null, soniox_completed_seen_at: null,
      finalizing_at: null, audio_duration_ms: null, done_at: null, fetched_at: null,
    }).eq("id", jobId);
  }

  // Limits (atomic check + charge).
  if (!charged) {
    const usd = Number(((chargeSeconds / 3600) * SONIOX_USD_PER_HOUR).toFixed(4));
    const { data: verdict, error } = await db.rpc("ln_reserve_audio", {
      p_job: jobId, p_seconds: chargeSeconds, p_usd: usd,
      p_day_limit: lim.audioSecondsPerDay, p_hour_limit: lim.audioSecondsPerHour,
      p_global_cap: lim.globalUsdPerDay,
    });
    if (error) throw new ApiError("server_error", "limit check failed");
    if (verdict !== "ok") {
      await db.from("jobs").update({ error_code: "limit_reached", error: String(verdict) }).eq("id", jobId);
      throw limitError(String(verdict));
    }
  }

  // Short-lived signed URL for Soniox to fetch the audio.
  const { data: signed, error: signErr } = await db.storage.from(BUCKET)
    .createSignedUrl(expectedPath, SIGNED_URL_SECONDS);
  if (signErr || !signed?.signedUrl) throw new ApiError("server_error", "could not sign the audio url");

  const webhook = (Deno.env.get("SONIOX_WEBHOOKS") ?? "on") !== "off";
  const started = await sonioxCreate({ audioUrl: signed.signedUrl, languageHints: hints, jobId, webhook });
  tries += 1;

  if ("id" in started) {
    const { error } = await db.from("jobs").update({
      status: "transcribing", soniox_transcription_id: started.id, tries,
    }).eq("id", jobId);
    if (error) throw new ApiError("server_error", "db write failed");
    return json(200, { job_id: jobId, client_note_id: cnid, status: "transcribing" });
  }

  // Soniox refused. Give the minutes back; fail for good after MAX_START_TRIES.
  console.error("soniox_create_failed", started.status);
  await db.rpc("ln_refund_audio", { p_job: jobId });
  if (tries >= MAX_START_TRIES) {
    const deleted = await deleteAudio(expectedPath);
    await db.from("jobs").update({
      status: "failed", tries, error_code: "upstream_failed", error: started.error, audio_deleted: deleted,
    }).eq("id", jobId);
    throw new ApiError("upstream_failed", "Transcription could not start. Upload again to retry.", {
      job_id: jobId, tries_left: 0,
    });
  }
  await db.from("jobs").update({ tries, error_code: "upstream_failed", error: started.error }).eq("id", jobId);
  throw new ApiError("upstream_failed", "Transcription could not start. Try again.", {
    job_id: jobId, tries_left: MAX_START_TRIES - tries,
  });
}));
