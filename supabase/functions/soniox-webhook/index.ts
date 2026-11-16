// soniox-webhook: Soniox calls this when a transcription is completed or
// failed. Deployed with verify_jwt OFF; authenticated by a shared secret
// header that we set on every Soniox job (webhook_auth_header_*).
// Body: {"id": "<transcription id>", "status": "completed" | "error"}

import { admin, constantTimeEqual, env, fail, handle, json } from "../_shared/common.ts";
import { finalizeJob, WEBHOOK_HEADER } from "../_shared/soniox.ts";

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

  const db = admin();
  const { data: job } = await db.from("jobs").select("id,status")
    .eq("soniox_transcription_id", tid).maybeSingle();
  // Unknown or already-final job: acknowledge so Soniox stops retrying.
  if (!job) return json(200, { ok: true, ignored: "unknown transcription" });
  await db.from("jobs").update({ webhook_received_at: new Date().toISOString() }).eq("id", job.id);
  if (job.status !== "transcribing") return json(200, { ok: true, ignored: job.status });

  // Errors here return 5xx so Soniox retries; the status fallback also covers us.
  const final = await finalizeJob(job.id, String(body.status ?? ""));
  return json(200, { ok: true, status: final ?? "in_progress" });
}));
