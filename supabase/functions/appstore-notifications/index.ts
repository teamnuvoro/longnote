// appstore-notifications: App Store Server Notifications V2 (Apple calls this;
// verify_jwt OFF). Body: {"signedPayload": "<JWS>"}.
//
// 1. Verify the JWS chain up to Apple Root CA - G3 and its signature, and the
//    same for signedTransactionInfo / signedRenewalInfo (_shared/appstore_jws.ts).
//    Bad signature -> 400. Wrong bundle id / unknown environment -> 200 ignored
//    (so Apple stops retrying a notification that is not ours).
// 2. Claim the notificationUUID (idempotent; ln_appstore_claim).
// 3. Find the user (appAccountToken = the Supabase user id, else an earlier
//    notification of the same originalTransactionId), their tracking profile
//    and the stored subscription state; plan the events
//    (_shared/appstore_events.ts); store the plan and the new state.
// 4. Reply 200, THEN send to Amplitude and Meta in the background
//    (EdgeRuntime.waitUntil). One retry for 429/5xx/network; results stored
//    on the notification row; never retried after that.
// No secrets or tokens are logged. docs/BACKEND-API.md 4.6, docs/ANALYTICS.md.

import { admin, json } from "../_shared/common.ts";
import { JwsError, peekPayload, verifyAppleJws } from "../_shared/appstore_jws.ts";
import {
  type AppStoreNotification,
  type AppStoreRenewal,
  type AppStoreTransaction,
  appEventsForm,
  BUNDLE_ID,
  capiEvent,
  type MetaEvent,
  type MetaPath,
  nextState,
  plan,
  type Plan,
  type PriorState,
  type TrackingProfile,
} from "../_shared/appstore_events.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const MAX_BODY = 256_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ENVIRONMENTS = new Set(["Production", "Sandbox"]);
const AMPLITUDE_URL = "https://api2.amplitude.com/2/httpapi";
const TIMEOUT_MS = 10_000;

const getenv = (k: string) => (Deno.env.get(k) ?? "").trim();

function metaPath(): MetaPath {
  if (getenv("META_CAPI_TOKEN") && getenv("META_DATASET_ID")) return "capi";
  if (getenv("META_APP_ID") && getenv("META_APP_SECRET")) return "app_events";
  return null;
}

let warnedNoMeta = false;

function ignored(reason: string, extra: Record<string, unknown> = {}): Response {
  console.log("appstore ignored", JSON.stringify({ reason, ...extra }));
  return json(200, { ok: true, ignored: reason });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: { code: "method_not_allowed" } });
  try {
    return await handleNotification(req);
  } catch (e) {
    console.error("appstore unhandled", e instanceof Error ? e.name + ": " + e.message.slice(0, 200) : "unknown");
    // Not stored -> Apple retries later (1, 12, 24, 48, 72 h).
    return json(500, { ok: false });
  }
});

async function handleNotification(req: Request): Promise<Response> {
  const text = await req.text();
  if (text.length > MAX_BODY) return json(413, { ok: false });
  let signed = "";
  try {
    signed = String(JSON.parse(text)?.signedPayload ?? "");
  } catch { /* below */ }
  if (!signed) return json(400, { ok: false, error: "signedPayload missing" });

  let n: AppStoreNotification;
  try {
    n = await verifyAppleJws<AppStoreNotification>(signed);
  } catch (e) {
    const peek = peekPayload(signed);
    console.warn("appstore bad jws", JSON.stringify({
      reason: e instanceof JwsError ? e.message : "error",
      type: peek?.notificationType ?? null,
    }));
    return json(400, { ok: false, error: "invalid signature" });
  }
  const environment = n.data?.environment ?? "";
  if (!n.notificationUUID || typeof n.notificationUUID !== "string") return ignored("no uuid");
  if (n.data?.bundleId !== (getenv("APPLE_BUNDLE_ID") || BUNDLE_ID)) {
    return ignored("bundle", { bundle: n.data?.bundleId ?? null });
  }
  if (!ENVIRONMENTS.has(environment)) return ignored("environment", { environment });
  const appleAppId = getenv("APPLE_APP_ID");
  if (environment === "Production" && appleAppId && n.data?.appAppleId !== undefined &&
    String(n.data.appAppleId) !== appleAppId) {
    return ignored("app id");
  }

  let tx: AppStoreTransaction | null = null;
  let renewal: AppStoreRenewal | null = null;
  try {
    if (n.data?.signedTransactionInfo) tx = await verifyAppleJws<AppStoreTransaction>(n.data.signedTransactionInfo);
    if (n.data?.signedRenewalInfo) renewal = await verifyAppleJws<AppStoreRenewal>(n.data.signedRenewalInfo);
  } catch (e) {
    console.warn("appstore bad inner jws", e instanceof JwsError ? e.message : "error");
    return json(400, { ok: false, error: "invalid signature" });
  }
  if (tx && tx.bundleId && tx.bundleId !== n.data?.bundleId) return ignored("tx bundle");

  const db = admin();
  const otid = tx?.originalTransactionId ?? renewal?.originalTransactionId ?? null;
  const { data: claim, error: claimErr } = await db.rpc("ln_appstore_claim", {
    p: {
      notification_uuid: n.notificationUUID,
      notification_type: n.notificationType,
      subtype: n.subtype ?? null,
      environment,
      signed_date: n.signedDate ? new Date(n.signedDate).toISOString() : null,
      original_transaction_id: otid,
      transaction_id: tx?.transactionId ?? null,
      product_id: tx?.productId ?? renewal?.productId ?? null,
      payload: { notification: { ...n, data: { ...n.data, signedTransactionInfo: undefined, signedRenewalInfo: undefined } }, transaction: tx, renewal },
    },
  });
  if (claimErr) throw new Error("claim failed: " + claimErr.code);
  if (claim === "duplicate") return json(200, { ok: true, duplicate: true });

  if (claim === "planned") {
    // An earlier delivery planned but may not have sent (it crashed before
    // replying). Send the stored plan; Amplitude insert_id and Meta event_id
    // make a repeat harmless.
    const { data: row } = await db.from("appstore_notifications").select("plan,environment")
      .eq("notification_uuid", n.notificationUUID).maybeSingle();
    const stored = row?.plan as Plan | null;
    if (stored) background(send(n.notificationUUID, stored, row?.environment ?? environment));
    return json(200, { ok: true, resent: true });
  }

  // ---- who is it?
  let userId: string | null = null;
  const token = tx?.appAccountToken;
  if (token && UUID.test(token)) userId = token.toLowerCase();
  const { data: subRow } = otid
    ? await db.from("subscriptions").select("user_id,last_offer_type,last_offer_discount_type,last_price,paid_count")
      .eq("original_transaction_id", otid).maybeSingle()
    : { data: null };
  if (!userId && subRow?.user_id) userId = subRow.user_id as string;
  const prior: PriorState | null = subRow
    ? {
      last_offer_type: subRow.last_offer_type ?? null,
      last_offer_discount_type: subRow.last_offer_discount_type ?? null,
      last_price: subRow.last_price === null || subRow.last_price === undefined ? null : Number(subRow.last_price),
      paid_count: subRow.paid_count ?? 0,
    }
    : null;
  let profile: TrackingProfile | null = null;
  if (userId) {
    const { data } = await db.from("tracking_profiles")
      .select("share_analytics,att_enabled,meta_anon_id,app_version,os_version,device_model,locale,extinfo")
      .eq("user_id", userId).maybeSingle();
    profile = (data as TrackingProfile | null) ?? null;
  }

  const path = metaPath();
  if (!path && !warnedNoMeta) {
    warnedNoMeta = true;
    console.log("appstore: Meta not configured (META_CAPI_TOKEN+META_DATASET_ID or META_APP_ID+META_APP_SECRET); skipping Meta");
  }
  const p = plan(n, tx, renewal, prior, userId, profile, {
    metaPath: path,
    metaTestCode: !!getenv("META_TEST_EVENT_CODE"),
    amplitudeConfigured: !!getenv("AMPLITUDE_API_KEY"),
    now: Date.now(),
  });
  const nothingToSend = !p.meta && p.amplitude.length === 0;

  const { error: upErr } = await db.from("appstore_notifications").update({
    user_id: userId,
    kind: p.kind,
    plan: p,
    state: nothingToSend ? "done" : "planned",
    claimed_at: new Date().toISOString(),
    meta_result: p.meta ? null : `skip: ${p.metaSkip}`,
    amplitude_result: p.amplitude.length ? null : `skip: ${p.amplitudeSkip}`,
    done_at: nothingToSend ? new Date().toISOString() : null,
  }).eq("notification_uuid", n.notificationUUID);
  if (upErr) throw new Error("plan store failed: " + upErr.code);

  const state = nextState(n, tx, renewal, p.kind, prior);
  if (state) {
    if (userId) state.user_id = userId;
    const { error } = await db.from("subscriptions").upsert(state, { onConflict: "original_transaction_id" });
    if (error) console.error("appstore subscription upsert", error.code);
  }

  console.log("appstore", JSON.stringify({
    type: n.notificationType, subtype: n.subtype ?? null, environment, kind: p.kind,
    user: userId ? "known" : "unknown", meta: p.meta ? p.meta.name : `skip:${p.metaSkip}`,
    amplitude: p.amplitude.length ? "send" : `skip:${p.amplitudeSkip}`,
  }));
  if (!nothingToSend) background(send(n.notificationUUID, p, environment));
  return json(200, { ok: true });
}

function background(p: Promise<unknown>) {
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(p);
  else p.catch(() => {});
}

/** fetch with a timeout and one retry for 429 / 5xx / network errors. */
async function post(url: string, init: RequestInit): Promise<{ status: number; body: string }> {
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
      const body = (await r.text()).slice(0, 500);
      if ((r.status === 429 || r.status >= 500) && attempt === 0) {
        await new Promise((res) => setTimeout(res, 2000));
        continue;
      }
      return { status: r.status, body };
    } catch (e) {
      if (attempt === 0) {
        await new Promise((res) => setTimeout(res, 2000));
        continue;
      }
      return { status: 0, body: e instanceof Error ? e.name : "error" };
    }
  }
}

/** Never put a token into a stored or logged string. */
function scrub(s: string): string {
  let out = s;
  for (const k of ["META_CAPI_TOKEN", "META_APP_SECRET", "AMPLITUDE_API_KEY"]) {
    const v = getenv(k);
    if (v) out = out.split(v).join("***");
  }
  return out.replace(/access_token=[^&\s"]+/g, "access_token=***");
}

async function sendAmplitude(events: Record<string, unknown>[]): Promise<string> {
  const r = await post(AMPLITUDE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "*/*" },
    body: JSON.stringify({ api_key: getenv("AMPLITUDE_API_KEY"), events }),
  });
  return r.status === 200 ? "ok 200" : `http ${r.status}: ${scrub(r.body).slice(0, 300)}`;
}

async function sendMeta(m: MetaEvent, environment: string): Promise<string> {
  const ver = getenv("META_GRAPH_VERSION") || "v24.0";
  const path = metaPath();
  if (path === "capi") {
    const body: Record<string, unknown> = { data: [capiEvent(m)], access_token: getenv("META_CAPI_TOKEN") };
    // Test code only for sandbox (TestFlight) events: a production event
    // with a test code would never count.
    const test = getenv("META_TEST_EVENT_CODE");
    if (test && environment !== "Production") body.test_event_code = test;
    const r = await post(`https://graph.facebook.com/${ver}/${getenv("META_DATASET_ID")}/events`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return (r.status === 200 ? "capi ok 200: " : `capi http ${r.status}: `) + scrub(r.body).slice(0, 300);
  }
  if (path === "app_events") {
    const appId = getenv("META_APP_ID");
    const form = new URLSearchParams({ ...appEventsForm(m), access_token: `${appId}|${getenv("META_APP_SECRET")}` });
    const r = await post(`https://graph.facebook.com/${ver}/${appId}/activities`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    return (r.status === 200 ? "app_events ok 200: " : `app_events http ${r.status}: `) + scrub(r.body).slice(0, 300);
  }
  return "skip: not_configured";
}

async function send(uuid: string, p: Plan, environment: string): Promise<void> {
  const db = admin();
  await db.from("appstore_notifications").update({ state: "sending", claimed_at: new Date().toISOString() })
    .eq("notification_uuid", uuid);
  const [amp, meta] = await Promise.all([
    p.amplitude.length ? sendAmplitude(p.amplitude) : Promise.resolve(`skip: ${p.amplitudeSkip}`),
    p.meta ? sendMeta(p.meta, environment) : Promise.resolve(`skip: ${p.metaSkip}`),
  ]);
  console.log("appstore sent", JSON.stringify({ kind: p.kind, amplitude: amp.slice(0, 120), meta: meta.slice(0, 120) }));
  const { error } = await db.from("appstore_notifications").update({
    state: "done",
    amplitude_result: amp,
    meta_result: meta,
    done_at: new Date().toISOString(),
  }).eq("notification_uuid", uuid);
  if (error) console.error("appstore result store", error.code);
}
