// report: stores one crash / error report from the app (Dart errors and iOS
// MetricKit crash/hang diagnostics). No transcript or summary text is sent.
// Duplicates (same body) are ignored. Max 260 KB per report; per day at most
// 50 per user and 200 per IP (IPv6: per /64), checked and inserted in one
// SQL step (ln_report_insert, review B5). Over a cap: 200 {stored: false}.

import { admin, ApiError, handle, ipHash, json, limits, readJson, requireUser, sha256Hex } from "../_shared/common.ts";

const MAX_BYTES = 260_000;
const KINDS = new Set(["flutter_error", "uncaught", "metrickit"]);

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const body = await readJson(req, MAX_BYTES);
  const kind = String(body.kind ?? "");
  if (!KINDS.has(kind)) throw new ApiError("bad_request", "Unknown report kind.");
  const app = (body.app && typeof body.app === "object") ? body.app : null;
  const { app: _drop, ...rest } = body;
  const text = JSON.stringify(rest);

  // MetricKit payloads arrive as a JSON string; store them parsed.
  let stored: unknown = rest;
  if (kind === "metrickit" && typeof rest.payload === "string") {
    try { stored = { payload: JSON.parse(rest.payload as string) }; } catch { /* keep string */ }
  }
  const lim = limits();
  const { data, error } = await admin().rpc("ln_report_insert", {
    p_user: user.id, p_ip_hash: await ipHash(req), p_kind: kind, p_digest: await sha256Hex(text),
    p_app: app, p_body: stored, p_user_limit: lim.reportsPerUserDay, p_ip_limit: lim.reportsPerIpDay,
  });
  if (error) throw new ApiError("server_error", "insert failed");
  const verdict = String(data);
  if (verdict === "stored" || verdict === "duplicate") return json(200, { ok: true, stored: verdict === "stored" });
  return json(200, { ok: true, stored: false, reason: verdict });
}));
