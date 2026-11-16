// cleanup: called hourly by pg_cron (pg_net) with the x-cleanup-secret header.
// Deployed with verify_jwt OFF. Deletes what must not linger:
//  1. DB (ln_cleanup_db): results 24 h after fetch / 7 days after done; jobs
//     > 30 days; expired summary cache; stale anonymous users.
//  2. Storage: every object in `uploads` older than 24 h, in batches until
//     none are left (bounded by time; review B4).
//  3. Jobs still `transcribing` 30 min after their start (started_at, review
//     B2): pull from Soniox (missed webhook + app never polled). After 6 h:
//     fail them, delete audio, refund (only if this run failed it, L4).
//  4. Final jobs whose Soniox transcription or audio was not yet deleted.
//  5. Orphan Soniox transcriptions of our jobs that no job points to (a start
//     whose reply was lost, review B3).
// Every step stops when the time budget is used up; the next run continues.

import { admin, constantTimeEqual, env, envNum, fail, handle, json } from "../_shared/common.ts";
import { BUCKET, deleteAudio, finalizeJob, sonioxDelete, sonioxList } from "../_shared/soniox.ts";

/** pg_net waits 60 s for the reply; stay inside it. */
const BUDGET_MS = envNum("CLEANUP_BUDGET_MS", 45_000);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(handle(async (req) => {
  const got = req.headers.get("x-cleanup-secret") ?? "";
  if (!got || !constantTimeEqual(got, env("CLEANUP_SECRET"))) return fail("unauthorized", "bad secret");
  const db = admin();
  const out: Record<string, unknown> = {};
  const t0 = Date.now();
  const timeLeft = () => BUDGET_MS - (Date.now() - t0);

  const { data: dbRes } = await db.rpc("ln_cleanup_db");
  out.db = dbRes;

  // 2. Old storage objects, until none are left.
  let removed = 0;
  while (timeLeft() > 5_000) {
    const { data: old } = await db.rpc("ln_old_objects", { p_bucket: BUCKET, p_hours: 24, p_limit: 500 });
    const names = ((old as { name: string }[] | null) ?? []).map((o) => o.name);
    if (!names.length) break;
    let progress = 0;
    for (let i = 0; i < names.length && timeLeft() > 2_000; i += 100) {
      const chunk = names.slice(i, i + 100);
      const { error } = await db.storage.from(BUCKET).remove(chunk);
      if (!error) {
        removed += chunk.length;
        progress += chunk.length;
        await db.from("jobs").update({ audio_deleted: true }).in("audio_path", chunk);
      }
    }
    if (!progress) break; // storage refused; retry next run
  }
  out.storage_removed = removed;

  // 3. Stuck jobs (clock = started_at, so a job started late is not killed).
  const now = Date.now();
  const { data: stuck } = await db.rpc("ln_stuck_jobs", { p_minutes: 30, p_limit: 200 });
  let pulled = 0, timedOut = 0;
  for (const j of (stuck as any[] | null) ?? []) {
    if (timeLeft() < 5_000) break;
    try {
      const r = await finalizeJob(j.id);
      if (r === "done" || r === "failed") pulled++;
      else if (r === "transcribing" && Date.parse(j.started_at) < now - 6 * 3600_000) {
        // Fail it first (compare-and-set); only the run that failed it
        // deletes and refunds (a webhook may have finished it meanwhile).
        const { data: failed } = await db.from("jobs").update({
          status: "failed", error_code: "upstream_failed", error: "timeout: not finished after 6 h",
        }).eq("id", j.id).eq("status", "transcribing").select("id");
        if (failed?.length) {
          const s = j.soniox_transcription_id ? await sonioxDelete(j.soniox_transcription_id) : true;
          const a = await deleteAudio(j.audio_path);
          await db.from("jobs").update({ soniox_deleted: s, audio_deleted: a }).eq("id", j.id);
          await db.rpc("ln_refund_audio", { p_job: j.id });
          timedOut++;
        }
      }
    } catch (_) { /* next run retries */ }
  }
  out.stuck_pulled = pulled;
  out.stuck_timed_out = timedOut;

  // 4. Leftovers at Soniox / in storage for final jobs.
  let fixed = 0;
  for (let pass = 0; pass < 5 && timeLeft() > 5_000; pass++) {
    const { data: left } = await db.from("jobs")
      .select("id,soniox_transcription_id,soniox_deleted,audio_deleted,audio_path")
      .in("status", ["done", "fetched", "failed"])
      .or("soniox_deleted.eq.false,audio_deleted.eq.false").limit(100);
    if (!left?.length) break;
    let progress = 0;
    for (const j of left) {
      if (timeLeft() < 3_000) break;
      const s = j.soniox_deleted || !j.soniox_transcription_id ? true : await sonioxDelete(j.soniox_transcription_id);
      const a = j.audio_deleted ? true : await deleteAudio(j.audio_path);
      await db.from("jobs").update({ soniox_deleted: s, audio_deleted: a }).eq("id", j.id);
      if (s && a) {
        fixed++;
        progress++;
      }
    }
    if (!progress) break; // the rest keep failing; next run
  }
  out.leftovers_fixed = fixed;

  // 5. Orphans at Soniox: transcriptions whose client_reference_id is one of
  // our jobs but which that job does not point to. Only ones older than
  // 10 min, and never while a start for that job is running.
  let orphans = 0;
  if (timeLeft() > 10_000) {
    const list = await sonioxList(5);
    const cutoff = Date.now() - 10 * 60_000;
    const cand = (list ?? []).filter((t) =>
      t.client_reference_id && UUID.test(t.client_reference_id) && Date.parse(t.created_at) < cutoff
    );
    const ids = [...new Set(cand.map((t) => t.client_reference_id!))];
    const jobs = new Map<string, { soniox_transcription_id: string | null; start_claimed_at: string | null }>();
    for (let i = 0; i < ids.length; i += 100) {
      const { data } = await db.from("jobs").select("id,soniox_transcription_id,start_claimed_at")
        .in("id", ids.slice(i, i + 100));
      for (const r of data ?? []) jobs.set(r.id, r);
    }
    for (const t of cand) {
      if (timeLeft() < 3_000) break;
      const j = jobs.get(t.client_reference_id!);
      if (!j || j.soniox_transcription_id === t.id) continue; // not ours / handled by step 4
      if (j.start_claimed_at && Date.now() - Date.parse(j.start_claimed_at) < 5 * 60_000) continue;
      if (await sonioxDelete(t.id)) orphans++;
    }
  }
  out.soniox_orphans_deleted = orphans;
  out.ms = Date.now() - t0;

  console.log("cleanup", JSON.stringify(out));
  return json(200, out);
}));
