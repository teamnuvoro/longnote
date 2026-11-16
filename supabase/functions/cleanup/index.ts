// cleanup: called hourly by pg_cron (pg_net) with the x-cleanup-secret header.
// Deployed with verify_jwt OFF. Deletes what must not linger:
//  1. DB: results 15 min after fetch / 7 days after creation; jobs > 30 days.
//  2. Storage: every object in `uploads` older than 24 h.
//  3. Jobs still `transcribing` after 30 min: pull from Soniox (missed
//     webhook + app never polled). After 6 h: fail them and delete audio.
//  4. Final jobs whose Soniox transcription or audio was not yet deleted.

import { admin, constantTimeEqual, env, fail, handle, json } from "../_shared/common.ts";
import { BUCKET, deleteAudio, finalizeJob, sonioxDelete } from "../_shared/soniox.ts";

const BATCH = 50;

Deno.serve(handle(async (req) => {
  const got = req.headers.get("x-cleanup-secret") ?? "";
  if (!got || !constantTimeEqual(got, env("CLEANUP_SECRET"))) return fail("unauthorized", "bad secret");
  const db = admin();
  const out: Record<string, unknown> = {};

  const { data: dbRes } = await db.rpc("ln_cleanup_db");
  out.db = dbRes;

  // 2. Old storage objects.
  const { data: old } = await db.rpc("ln_old_objects", { p_bucket: BUCKET, p_hours: 24, p_limit: 500 });
  const names = ((old as { name: string }[] | null) ?? []).map((o) => o.name);
  let removed = 0;
  for (let i = 0; i < names.length; i += 100) {
    const chunk = names.slice(i, i + 100);
    const { error } = await db.storage.from(BUCKET).remove(chunk);
    if (!error) {
      removed += chunk.length;
      await db.from("jobs").update({ audio_deleted: true }).in("audio_path", chunk);
    }
  }
  out.storage_removed = removed;

  // 3. Stuck jobs.
  const now = Date.now();
  const { data: stuck } = await db.from("jobs").select("id,created_at,audio_path,soniox_transcription_id")
    .eq("status", "transcribing").lt("created_at", new Date(now - 30 * 60_000).toISOString()).limit(BATCH);
  let pulled = 0, timedOut = 0;
  for (const j of stuck ?? []) {
    try {
      const r = await finalizeJob(j.id);
      if (r === "done" || r === "failed") pulled++;
      else if (r === "transcribing" && Date.parse(j.created_at) < now - 6 * 3600_000) {
        const s = j.soniox_transcription_id ? await sonioxDelete(j.soniox_transcription_id) : true;
        const a = await deleteAudio(j.audio_path);
        await db.from("jobs").update({
          status: "failed", error_code: "upstream_failed", error: "timeout: not finished after 6 h",
          soniox_deleted: s, audio_deleted: a,
        }).eq("id", j.id).eq("status", "transcribing");
        await db.rpc("ln_refund_audio", { p_job: j.id });
        timedOut++;
      }
    } catch (_) { /* next run retries */ }
  }
  out.stuck_pulled = pulled;
  out.stuck_timed_out = timedOut;

  // 4. Leftovers at Soniox / in storage for final jobs.
  const { data: left } = await db.from("jobs").select("id,soniox_transcription_id,soniox_deleted,audio_deleted,audio_path")
    .in("status", ["done", "fetched", "failed"])
    .or("soniox_deleted.eq.false,audio_deleted.eq.false").limit(BATCH);
  let fixed = 0;
  for (const j of left ?? []) {
    const s = j.soniox_deleted || !j.soniox_transcription_id ? true : await sonioxDelete(j.soniox_transcription_id);
    const a = j.audio_deleted ? true : await deleteAudio(j.audio_path);
    await db.from("jobs").update({ soniox_deleted: s, audio_deleted: a }).eq("id", j.id);
    if (s && a) fixed++;
  }
  out.leftovers_fixed = fixed;

  console.log("cleanup", JSON.stringify(out));
  return json(200, out);
}));
