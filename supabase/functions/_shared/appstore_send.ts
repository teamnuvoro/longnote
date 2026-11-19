// Sending planned App Store subscription events to Amplitude and Meta
// (shared by appstore-notifications and tracking-profile's replay).
// Never put a token into a stored or logged string.

import { admin } from "./common.ts";
import {
  appEventsForm,
  type AppStoreNotification,
  type AppStoreRenewal,
  type AppStoreTransaction,
  capiEvent,
  type MetaEvent,
  type MetaPath,
  plan,
  type Plan,
  type TrackingProfile,
} from "./appstore_events.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const AMPLITUDE_URL = "https://api2.amplitude.com/2/httpapi";
const TIMEOUT_MS = 10_000;

const getenv = (k: string) => (Deno.env.get(k) ?? "").trim();

export function metaPath(): MetaPath {
  if (getenv("META_CAPI_TOKEN") && getenv("META_DATASET_ID")) return "capi";
  if (getenv("META_APP_ID") && getenv("META_APP_SECRET")) return "app_events";
  return null;
}

export function background(p: Promise<unknown>) {
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

export async function send(uuid: string, p: Plan, environment: string): Promise<void> {
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

/**
 * Review M3 (19 Nov): Apple's first notification (trial started / subscribed)
 * can arrive before the app's tracking profile does (slow or failed POST at
 * purchase). It was then skipped forever ("skip: no_profile"). When the
 * profile lands, plan those again and send them. Only the first-purchase
 * kinds (their plan does not depend on the subscription's earlier state),
 * only for 7 days (Meta refuses older events), each claimed atomically so a
 * concurrent replay cannot send it twice.
 */
export async function replaySkipped(userId: string): Promise<number> {
  const db = admin();
  const since = new Date(Date.now() - 7 * 86_400_000).toISOString();
  const { data: rows, error } = await db.from("appstore_notifications")
    .select("notification_uuid,environment,payload")
    .eq("user_id", userId).eq("state", "done")
    .in("kind", ["trial_started", "subscribed"])
    .eq("meta_result", "skip: no_profile")
    .gte("received_at", since).limit(5);
  if (error || !rows?.length) return 0;
  const { data: profile } = await db.from("tracking_profiles")
    .select("share_analytics,att_enabled,meta_anon_id,app_version,os_version,device_model,locale,extinfo")
    .eq("user_id", userId).maybeSingle();
  if (!(profile as TrackingProfile | null)?.share_analytics) return 0;
  let sent = 0;
  for (const r of rows) {
    const pl = r.payload as {
      notification: AppStoreNotification;
      transaction: AppStoreTransaction | null;
      renewal: AppStoreRenewal | null;
    };
    const p = plan(pl.notification, pl.transaction ?? null, pl.renewal ?? null, null, userId,
      profile as TrackingProfile, {
        metaPath: metaPath(),
        metaTestCode: !!getenv("META_TEST_EVENT_CODE"),
        amplitudeConfigured: !!getenv("AMPLITUDE_API_KEY"),
        now: Date.now(),
      });
    if (!p.meta && p.amplitude.length === 0) continue;
    // Claim: only one replay moves it from the skipped "done" to "planned".
    const { data: claimed } = await db.from("appstore_notifications").update({
      state: "planned", plan: p, kind: p.kind, claimed_at: new Date().toISOString(),
      meta_result: null, amplitude_result: null, done_at: null,
    }).eq("notification_uuid", r.notification_uuid).eq("state", "done")
      .eq("meta_result", "skip: no_profile").select("notification_uuid");
    if (!claimed?.length) continue;
    await send(r.notification_uuid, p, r.environment ?? "");
    sent++;
  }
  if (sent) console.log("appstore replay", JSON.stringify({ sent }));
  return sent;
}
