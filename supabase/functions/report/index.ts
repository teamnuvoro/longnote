// report: stores one crash / error report from the app (Dart errors and iOS
// MetricKit crash/hang diagnostics). No transcript or summary text is sent.
// Duplicates (same body) are ignored. Max 200 KB per report, 50 per user
// per day.

import { admin, ApiError, handle, json, readJson, requireUser } from "../_shared/common.ts";

const MAX_BYTES = 260_000;
const PER_DAY = 50;
const KINDS = new Set(["flutter_error", "uncaught", "metrickit"]);

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const body = await readJson(req, MAX_BYTES);
  const kind = String(body.kind ?? "");
  if (!KINDS.has(kind)) throw new ApiError("bad_request", "Unknown report kind.");
  const app = (body.app && typeof body.app === "object") ? body.app : null;
  const { app: _drop, ...rest } = body;
  const text = JSON.stringify(rest);
  const db = admin();

  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count, error: cErr } = await db.from("client_reports")
    .select("id", { count: "exact", head: true })
    .eq("user_id", user.id).gte("created_at", since);
  if (cErr) throw new ApiError("server_error", "count failed");
  if ((count ?? 0) >= PER_DAY) return json(200, { ok: true, stored: false });

  // MetricKit payloads arrive as a JSON string; store them parsed.
  let stored: unknown = rest;
  if (kind === "metrickit" && typeof rest.payload === "string") {
    try { stored = { payload: JSON.parse(rest.payload as string) }; } catch { /* keep string */ }
  }
  const { error } = await db.from("client_reports").upsert({
    user_id: user.id, kind, digest: await sha256(text), app, body: stored,
  }, { onConflict: "user_id,digest", ignoreDuplicates: true });
  if (error) throw new ApiError("server_error", "insert failed");
  return json(200, { ok: true, stored: true });
}));
