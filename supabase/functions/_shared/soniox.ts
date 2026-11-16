// Soniox async API + job finalisation shared by transcribe-start,
// soniox-webhook, transcribe-status and cleanup.
// Docs: https://docs.soniox.com/stt/async/async-transcription
//       https://docs.soniox.com/stt/async/webhooks

import { admin, ApiError, env, envNum, SONIOX_USD_PER_HOUR } from "./common.ts";

const BASE = "https://api.soniox.com";
export const SONIOX_MODEL = Deno.env.get("SONIOX_MODEL") || "stt-async-v6";
export const WEBHOOK_HEADER = "x-longnote-webhook-secret";
export const BUCKET = "uploads";
/** Start attempts allowed before a job is failed and its audio deleted. */
export const MAX_START_TRIES = 3;

/** Per-request timeout (review B3). The transcript download gets longer. */
const TIMEOUT_MS = envNum("SONIOX_TIMEOUT_MS", 30_000);
const TRANSCRIPT_TIMEOUT_MS = envNum("SONIOX_TRANSCRIPT_TIMEOUT_MS", 60_000);

/** status 0 = no answer (network error or timeout): the outcome is unknown. */
async function soniox(
  method: string, path: string, body?: unknown, timeoutMs = TIMEOUT_MS,
): Promise<{ status: number; data: any }> {
  let res: Response;
  let text: string;
  try {
    res = await fetch(BASE + path, {
      method,
      headers: {
        Authorization: `Bearer ${env("SONIOX_API_KEY")}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeoutMs),
    });
    text = await res.text();
  } catch (e) {
    console.error("soniox_network", method, path.split("/").slice(0, 3).join("/"), e instanceof Error ? e.name : "unknown");
    return { status: 0, data: null };
  }
  let data: any = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }
  return { status: res.status, data };
}

export interface StartArgs {
  audioUrl: string;
  languageHints: string[];
  jobId: string;
  webhook: boolean;
}

/**
 * `unknown: true` = no answer from Soniox: the transcription may or may not
 * exist. The caller keeps the charge and, on the next start, looks for it
 * by client_reference_id (findByReference) before creating another.
 */
export async function sonioxCreate(
  a: StartArgs,
): Promise<{ id: string } | { error: string; status: number; unknown?: boolean }> {
  const body: Record<string, unknown> = {
    model: SONIOX_MODEL,
    audio_url: a.audioUrl,
    enable_speaker_diarization: true,
    enable_language_identification: true,
    client_reference_id: a.jobId,
  };
  if (a.languageHints.length) body.language_hints = a.languageHints;
  if (a.webhook) {
    body.webhook_url = `${env("SUPABASE_URL")}/functions/v1/soniox-webhook?job=${a.jobId}`;
    body.webhook_auth_header_name = WEBHOOK_HEADER;
    body.webhook_auth_header_value = env("SONIOX_WEBHOOK_SECRET");
  }
  const r = await soniox("POST", "/v1/transcriptions", body);
  if (r.status === 201 || r.status === 200) return { id: String(r.data.id) };
  if (r.status === 0) return { status: 0, error: "start_unknown: no answer from Soniox", unknown: true };
  return { status: r.status, error: `${r.data?.error_type ?? "http_" + r.status}: ${String(r.data?.message ?? "").slice(0, 300)}` };
}

export async function sonioxGet(id: string) {
  return await soniox("GET", `/v1/transcriptions/${id}`);
}

/** Deletes the transcription at Soniox (404 = already gone = success). */
export async function sonioxDelete(id: string): Promise<boolean> {
  const r = await soniox("DELETE", `/v1/transcriptions/${id}`);
  return (r.status >= 200 && r.status < 300) || r.status === 404;
}

export interface SonioxListed {
  id: string;
  status: string;
  created_at: string;
  client_reference_id: string | null;
}

/**
 * Lists our Soniox transcriptions, newest first, up to `maxPages` pages of
 * 100. Returns null if Soniox did not answer.
 */
export async function sonioxList(maxPages = 3): Promise<SonioxListed[] | null> {
  const out: SonioxListed[] = [];
  let cursor = "";
  for (let p = 0; p < maxPages; p++) {
    const r = await soniox("GET", `/v1/transcriptions?limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
    if (r.status !== 200 || !Array.isArray(r.data?.transcriptions)) return p === 0 ? null : out;
    for (const t of r.data.transcriptions) {
      out.push({
        id: String(t.id), status: String(t.status ?? ""), created_at: String(t.created_at ?? ""),
        client_reference_id: t.client_reference_id ?? null,
      });
    }
    cursor = r.data.next_page_cursor ?? "";
    if (!cursor) break;
  }
  return out;
}

/** The transcriptions Soniox has for one job (a start whose reply was lost). */
export async function findByReference(jobId: string): Promise<SonioxListed[] | null> {
  const all = await sonioxList(3);
  return all ? all.filter((t) => t.client_reference_id === jobId) : null;
}

export async function deleteAudio(path: string): Promise<boolean> {
  const { error } = await admin().storage.from(BUCKET).remove([path]);
  return !error;
}

export interface Turn {
  speaker: string;
  start_ms: number;
  end_ms: number;
  text: string;
  language?: string;
}

interface Token {
  text: string;
  start_ms: number;
  end_ms: number;
  speaker?: string;
  language?: string;
  translation_status?: string;
  is_audio_event?: boolean;
}

const SENTENCE_END = /[.?!।॥。？！]["')\]]*\s*$/;
/** A single speaker's turn is split at a sentence end after this long... */
export const SOFT_TURN_MS = 30_000;
/** ...and at the next word boundary after this long, sentence end or not. */
export const HARD_TURN_MS = 90_000;

/** Merge Soniox tokens into speaker turns, keeping timestamps. */
export function tokensToTurns(tokens: Token[]): Turn[] {
  const turns: Turn[] = [];
  let cur: (Turn & { langs: Map<string, number> }) | null = null;
  const close = () => {
    if (!cur) return;
    const text = cur.text.replace(/\s+/g, " ").trim();
    if (text) {
      const t: Turn = { speaker: cur.speaker, start_ms: cur.start_ms, end_ms: cur.end_ms, text };
      let best = "", n = 0;
      for (const [l, c] of cur.langs) if (c > n) { best = l; n = c; }
      if (best) t.language = best;
      turns.push(t);
    }
    cur = null;
  };
  for (const tok of tokens) {
    if (tok.translation_status === "translation") continue;
    if (tok.is_audio_event) continue;
    const speaker = tok.speaker ?? "1";
    const startsWord = /^\s/.test(tok.text);
    if (cur) {
      const len = tok.start_ms - cur.start_ms;
      const split = speaker !== cur.speaker ||
        (startsWord && len >= SOFT_TURN_MS && SENTENCE_END.test(cur.text)) ||
        (startsWord && len >= HARD_TURN_MS);
      if (split) close();
    }
    if (!cur) {
      cur = { speaker, start_ms: tok.start_ms, end_ms: tok.end_ms, text: "", langs: new Map() };
    }
    cur.text += tok.text;
    cur.end_ms = Math.max(cur.end_ms, tok.end_ms);
    if (tok.language) cur.langs.set(tok.language, (cur.langs.get(tok.language) ?? 0) + 1);
  }
  close();
  return turns;
}

/**
 * Finish a job whose Soniox transcription has ended. Called by the webhook
 * and by the status fallback; only one caller wins the claim.
 * Returns the final job status, or null if another caller is finalising.
 */
export async function finalizeJob(jobId: string, sonioxStatus?: string): Promise<string | null> {
  const db = admin();
  const { data: claimed, error: claimErr } = await db.rpc("ln_claim_finalize", { p_job: jobId });
  if (claimErr) throw new ApiError("server_error", "db claim failed");
  const job = (claimed as any[] | null)?.[0];
  if (!job) return null;
  const tid: string = job.soniox_transcription_id;

  let status = sonioxStatus;
  let meta: any = null;
  const g = await sonioxGet(tid);
  if (g.status === 200) {
    meta = g.data;
    status = meta.status;
  } else if (g.status === 404) {
    status = "error";
    meta = { error_message: "transcription missing at provider" };
  } else {
    await db.from("jobs").update({ finalizing_at: null }).eq("id", jobId);
    throw new ApiError("upstream_failed", "Transcription service did not answer.");
  }

  if (status === "completed") {
    const t = await soniox("GET", `/v1/transcriptions/${tid}/transcript`, undefined, TRANSCRIPT_TIMEOUT_MS);
    if (t.status !== 200 || !Array.isArray(t.data?.tokens)) {
      await db.from("jobs").update({ finalizing_at: null }).eq("id", jobId);
      throw new ApiError("upstream_failed", "Could not fetch the transcript.");
    }
    const turns = tokensToTurns(t.data.tokens as Token[]);
    const durMs = Number(meta?.audio_duration_ms) || 0;
    const speakers = new Set(turns.map((x) => x.speaker)).size;
    const langs = [...new Set(turns.map((x) => x.language).filter(Boolean))];
    const result = { turns, audio_duration_ms: durMs, speakers, languages: langs };
    const { error } = await db.from("jobs").update({
      status: "done",
      result,
      audio_duration_ms: durMs || null,
      done_at: new Date().toISOString(),
      finalizing_at: null,
      error: null,
      error_code: null,
    }).eq("id", jobId);
    if (error) {
      await db.from("jobs").update({ finalizing_at: null }).eq("id", jobId);
      throw new ApiError("server_error", "db write failed");
    }
    if (durMs > 0) {
      const secs = Math.ceil(durMs / 1000);
      await db.rpc("ln_settle_audio", {
        p_job: jobId,
        p_seconds: secs,
        p_usd: Number(((secs / 3600) * SONIOX_USD_PER_HOUR).toFixed(4)),
      });
    }
  } else if (status === "error") {
    const msg = `${meta?.error_type ?? "error"}: ${String(meta?.error_message ?? "").slice(0, 300)}`;
    await db.from("jobs").update({
      status: "failed",
      error_code: "upstream_failed",
      error: msg,
      finalizing_at: null,
      done_at: new Date().toISOString(),
    }).eq("id", jobId);
    // Nothing was transcribed: give the audio minutes back.
    await db.rpc("ln_refund_audio", { p_job: jobId });
  } else {
    // queued / processing: not finished yet.
    await db.from("jobs").update({ finalizing_at: null }).eq("id", jobId);
    return "transcribing";
  }

  // Either way the job is final: delete audio everywhere.
  const sonDel = await sonioxDelete(tid);
  const audDel = await deleteAudio(job.audio_path);
  await db.from("jobs").update({ soniox_deleted: sonDel, audio_deleted: audDel }).eq("id", jobId);
  return status === "completed" ? "done" : "failed";
}
