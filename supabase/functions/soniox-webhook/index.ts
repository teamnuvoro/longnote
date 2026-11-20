// soniox-webhook: Soniox calls this when a transcription is completed or
// failed. Deployed with verify_jwt OFF; authenticated by a shared secret
// header that we set on every Soniox job (webhook_auth_header_*).
// Body: {"id": "<transcription id>", "status": "completed" | "error"}

import { admin, constantTimeEqual, env, fail, handle, json } from "../_shared/common.ts";
import { finalizeJob, sonioxDelete, sonioxGet, WEBHOOK_HEADER } from "../_shared/soniox.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** A start claim this recent may still be about to store the id. */
const CLAIM_FRESH_MS = 4 * 60_000;

Deno.serve(handle(async (req) => {
  const got = req.headers.get(WEBHOOK_HEADER) ?? "";
  if (!got || !constantTimeEqual(got, env("SONIOX_WEBHOOK_SECRET"))) {
    return fail("unauthorized", "bad webhook secret");
  }
  let body: any;
  try {
    body = await req.json();
  } catch {
    return fail("bad_request", "invalid json");
  }
  const tid = typeof body?.id === "string" ? body.id : "";
  if (!tid) return fail("bad_request", "missing id");
  // The id goes into Soniox URLs: only plain id characters.
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(tid)) return fail("bad_request", "bad id");

  const db = admin();
  let { data: job } = await db.from("jobs").select("id,status")
    .eq("soniox_transcription_id", tid).maybeSingle();
  if (!job) {
    // Not ours by id (review B3): a start whose reply was lost, or a webhook
    // that beat transcribe-start storing the id. Resolve the owner job by
    // Soniox's client_reference_id (= our job id).
    const g = await sonioxGet(tid);
    if (g.status === 0 || g.status >= 500) return json(503, { ok: false, retry: true });
    const ref = g.status === 200 ? String(g.data?.client_reference_id ?? "") : "";
    if (!UUID.test(ref)) return json(200, { ok: true, ignored: "unknown transcription" });
    const { data: owner } = await db.from("jobs").select("id,status,error,soniox_transcription_id,start_claimed_at")
      .eq("id", ref).maybeSingle();
    if (!owner) return json(200, { ok: true, ignored: "unknown job" });
    if (owner.soniox_transcription_id === tid) {
      job = { id: owner.id, status: owner.status };
    } else if (owner.start_claimed_at && Date.now() - Date.parse(owner.start_claimed_at) < CLAIM_FRESH_MS) {
      // A start is running for this job and may store this id any moment.
      return json(503, { ok: false, retry: true });
    } else if (owner.status === "uploaded" && !owner.soniox_transcription_id &&
      String(owner.error ?? "").startsWith("start_unknown")) {
      // The job is waiting for a retry of that lost start: adopt this
      // transcription (compare-and-set) instead of transcribing twice.
      const { data: adopted } = await db.from("jobs").update({
        status: "transcribing", soniox_transcription_id: tid, start_claimed_at: null, error: null, error_code: null,
      }).eq("id", owner.id).eq("status", "uploaded").is("soniox_transcription_id", null)
        .like("error", "start_unknown%").select("id");
      if (!adopted?.length) return json(503, { ok: false, retry: true });
      console.log("soniox_adopted_by_webhook");
      job = { id: owner.id, status: "transcribing" };
    } else {
      // An orphan nobody will ever fetch: delete audio + transcript at Soniox.
      const deleted = await sonioxDelete(tid);
      console.log("soniox_orphan_deleted", deleted);
      return json(200, { ok: true, deleted_orphan: deleted });
    }
  }
  await db.from("jobs").update({ webhook_received_at: new Date().toISOString() }).eq("id", job.id);
  if (job.status !== "transcribing") return json(200, { ok: true, ignored: job.status });

  // Errors here return 5xx so Soniox retries; the status fallback also covers us.
  const final = await finalizeJob(job.id, String(body.status ?? ""));
  return json(200, { ok: true, status: final ?? "in_progress" });
}));
