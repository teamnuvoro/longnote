// deno test --allow-env supabase/functions/_shared/appstore_events_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  type AppStoreNotification,
  type AppStoreTransaction,
  appEventsForm,
  capiEvent,
  classify,
  extinfoFrom,
  nextState,
  plan,
  type PlanConfig,
  type PriorState,
  priceOf,
  type TrackingProfile,
} from "./appstore_events.ts";

const NOW = Date.UTC(2026, 10, 18, 12);
const DAY = 86_400_000;
const USER = "8f0f3c4e-1111-4222-8333-944445555666";
const cfg: PlanConfig = { metaPath: "capi", metaTestCode: false, amplitudeConfigured: true, now: NOW };
const profile: TrackingProfile = {
  share_analytics: true, att_enabled: false, meta_anon_id: "XZ1234-ABCD", app_version: "1.0.0",
  os_version: "18.1", device_model: "iPhone15,2", locale: "en_IN", extinfo: null,
};

const n = (type: string, subtype?: string, env = "Production"): AppStoreNotification => ({
  notificationType: type, subtype, notificationUUID: `uuid-${type}-${subtype ?? ""}`, signedDate: NOW - 60_000,
  data: { environment: env, bundleId: "com.novaralabs.longnote", status: 1 },
});
const trialTx: AppStoreTransaction = {
  transactionId: "2000000001", originalTransactionId: "2000000001", productId: "com.novaralabs.longnote.annual",
  purchaseDate: NOW - 60_000, originalPurchaseDate: NOW - 60_000, expiresDate: NOW + 3 * DAY,
  offerType: 1, offerDiscountType: "FREE_TRIAL", price: 0, currency: "INR", appAccountToken: USER,
};
const paidTx: AppStoreTransaction = {
  transactionId: "2000000002", originalTransactionId: "2000000001", productId: "com.novaralabs.longnote.annual",
  purchaseDate: NOW - 60_000, originalPurchaseDate: NOW - 3 * DAY, expiresDate: NOW + 365 * DAY,
  price: 4999000, currency: "INR", appAccountToken: USER,
};
const afterTrial: PriorState = { last_offer_type: 1, last_offer_discount_type: "FREE_TRIAL", last_price: 0, paid_count: 0 };
const afterPaid: PriorState = { last_offer_type: null, last_offer_discount_type: null, last_price: 4999, paid_count: 1 };

Deno.test("price is milliunits", () => {
  assertEquals(priceOf({ price: 4999000 }), 4999);
  assertEquals(priceOf({ price: 9990 }), 9.99);
  assertEquals(priceOf({}), null);
});

Deno.test("SUBSCRIBED with a free trial -> StartTrial, no value; Amplitude without revenue", () => {
  const p0 = plan(n("SUBSCRIBED", "INITIAL_BUY"), trialTx, null, null, USER, profile, cfg);
  const p = { ...p0, meta: capiEvent(p0.meta!) };
  assertEquals(p.kind, "trial_started");
  assertEquals(p.meta?.event_name, "StartTrial");
  assertEquals(p.meta?.action_source, "app");
  assertEquals(p.meta?.event_id, "uuid-SUBSCRIBED-INITIAL_BUY");
  assertEquals(p.meta?.event_time, Math.floor((NOW - 60_000) / 1000));
  assertEquals(p.meta?.user_data, { anon_id: "XZ1234-ABCD" });
  const cd = p.meta?.custom_data as Record<string, unknown>;
  assertEquals(cd.currency, "INR");
  assertEquals("value" in cd, false);
  const ad = p.meta?.app_data as Record<string, unknown>;
  assertEquals(ad.advertiser_tracking_enabled, 0);
  assertEquals(ad.application_tracking_enabled, 1);
  assertEquals((ad.extinfo as string[]).length, 16);
  const a = p.amplitude[0];
  assertEquals(a.event_type, "appstore_trial_started");
  assertEquals(a.user_id, USER);
  assertEquals(a.insert_id, "uuid-SUBSCRIBED-INITIAL_BUY");
  assertEquals("revenue" in a, false);
  assertEquals("ip" in a, false);
  assertEquals((a.event_properties as Record<string, unknown>).source, "server");
});

Deno.test("SUBSCRIBED paid (no trial) -> Subscribe with value; Amplitude revenue", () => {
  const p = plan(n("SUBSCRIBED", "INITIAL_BUY"), { ...paidTx, originalPurchaseDate: paidTx.purchaseDate }, null, null, USER, profile, cfg);
  assertEquals(p.kind, "subscribed");
  assertEquals(p.meta?.name, "Subscribe");
  assertEquals(p.meta?.value, 4999);
  const a = p.amplitude[0];
  assertEquals([a.event_type, a.price, a.quantity, a.revenue, a.revenueType, a.currency, a.productId],
    ["appstore_subscribed", 4999, 1, 4999, "subscription", "INR", "com.novaralabs.longnote.annual"]);
});

Deno.test("first DID_RENEW after a trial -> Subscribe (trial converted)", () => {
  const p = plan(n("DID_RENEW"), paidTx, null, afterTrial, USER, profile, cfg);
  assertEquals(p.kind, "trial_converted");
  assertEquals(p.inferred, false);
  assertEquals(p.meta?.name, "Subscribe");
  assertEquals(p.meta?.value, 4999);
  assertEquals(p.amplitude[0].event_type, "appstore_trial_converted");
});

Deno.test("later DID_RENEW -> Purchase with value; Amplitude renewal revenue", () => {
  const p = plan(n("DID_RENEW"), { ...paidTx, originalPurchaseDate: NOW - 400 * DAY }, null, afterPaid, USER, profile, cfg);
  assertEquals(p.kind, "renewed");
  assertEquals(p.meta?.name, "Purchase");
  assertEquals(p.amplitude[0].revenueType, "renewal");
});

Deno.test("DID_RENEW without stored state: production < 14 days after the original purchase = trial converted (inferred)", () => {
  assertEquals(classify(n("DID_RENEW"), paidTx, null), { kind: "trial_converted", inferred: true });
  assertEquals(classify(n("DID_RENEW"), { ...paidTx, originalPurchaseDate: NOW - 30 * DAY }, null).kind, "renewed");
  assertEquals(classify(n("DID_RENEW", undefined, "Sandbox"), paidTx, null).kind, "renewed");
});

Deno.test("REFUND -> Amplitude negative revenue, nothing to Meta", () => {
  const p = plan(n("REFUND"), paidTx, null, afterPaid, USER, profile, cfg);
  assertEquals(p.kind, "refunded");
  assertEquals(p.meta, null);
  assertEquals(p.metaSkip, "not_a_meta_event");
  const a = p.amplitude[0];
  assertEquals([a.event_type, a.price, a.revenue, a.revenueType], ["appstore_refunded", -4999, -4999, "refund"]);
});

Deno.test("EXPIRED / renewal status / billing -> Amplitude only, no revenue", () => {
  for (const [t, s, ev] of [
    ["EXPIRED", "VOLUNTARY", "appstore_expired"],
    ["GRACE_PERIOD_EXPIRED", undefined, "appstore_expired"],
    ["DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED", "appstore_auto_renew_off"],
    ["DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED", "appstore_auto_renew_on"],
    ["DID_FAIL_TO_RENEW", "GRACE_PERIOD", "appstore_billing_issue"],
  ] as const) {
    const p = plan(n(t, s), paidTx, { autoRenewStatus: 0 }, afterPaid, USER, profile, cfg);
    assertEquals(p.meta, null, t);
    assertEquals(p.amplitude[0].event_type, ev);
    assertEquals("revenue" in p.amplitude[0], false);
  }
});

Deno.test("opt-out, no profile, no user -> nothing sent anywhere", () => {
  for (const [u, pr, why] of [
    [USER, { ...profile, share_analytics: false }, "opted_out"],
    [USER, null, "no_profile"],
    [null, profile, "no_user"],
  ] as const) {
    const p = plan(n("SUBSCRIBED", "INITIAL_BUY"), trialTx, null, null, u, pr, cfg);
    assertEquals([p.meta, p.amplitude.length, p.metaSkip, p.amplitudeSkip], [null, 0, why, why]);
  }
});

Deno.test("ATT allowed -> advertiser_tracking_enabled 1", () => {
  const p = plan(n("SUBSCRIBED", "INITIAL_BUY"), trialTx, null, null, USER, { ...profile, att_enabled: true }, cfg);
  assertEquals((capiEvent(p.meta!).app_data as Record<string, unknown>).advertiser_tracking_enabled, 1);
  assertEquals(appEventsForm(p.meta!).advertiser_tracking_enabled, "1");
});

Deno.test("sandbox: Amplitude flagged; Meta only with a test event code", () => {
  const sb = n("SUBSCRIBED", "INITIAL_BUY", "Sandbox");
  const p = plan(sb, trialTx, null, null, USER, profile, cfg);
  assertEquals(p.metaSkip, "sandbox");
  assertEquals((p.amplitude[0].event_properties as Record<string, unknown>).sandbox, true);
  const q = plan(sb, trialTx, null, null, USER, profile, { ...cfg, metaTestCode: true });
  assertEquals(q.meta?.name, "StartTrial");
  const r = plan(sb, trialTx, null, null, USER, profile, { ...cfg, metaPath: "app_events", metaTestCode: true });
  assertEquals(r.metaSkip, "sandbox", "App Events API has no test mode");
});

Deno.test("Meta skipped when not configured, no anon id, or older than 7 days; Amplitude still sent", () => {
  const sub = n("SUBSCRIBED", "INITIAL_BUY");
  assertEquals(plan(sub, trialTx, null, null, USER, profile, { ...cfg, metaPath: null }).metaSkip, "not_configured");
  assertEquals(plan(sub, trialTx, null, null, USER, { ...profile, meta_anon_id: null }, cfg).metaSkip, "no_meta_anon_id");
  const old = plan({ ...sub, signedDate: NOW - 8 * DAY }, trialTx, null, null, USER, profile, cfg);
  assertEquals(old.metaSkip, "too_old");
  assertEquals(old.amplitude.length, 1);
});

Deno.test("TEST notification -> recorded only", () => {
  const p = plan(n("TEST"), null, null, null, null, null, cfg);
  assertEquals([p.kind, p.meta, p.amplitude.length], ["test", null, 0]);
});

Deno.test("upgrade -> Purchase; downgrade/crossgrade pref -> Amplitude only", () => {
  assertEquals(plan(n("DID_CHANGE_RENEWAL_PREF", "UPGRADE"), paidTx, null, afterPaid, USER, profile, cfg).meta?.name, "Purchase");
  const d = plan(n("DID_CHANGE_RENEWAL_PREF", "DOWNGRADE"), paidTx, null, afterPaid, USER, profile, cfg);
  assertEquals([d.meta, d.amplitude[0].event_type], [null, "appstore_plan_change"]);
});

Deno.test("nextState: trial then renew counts paid payments; REFUND keeps the offer info", () => {
  const s1 = nextState(n("SUBSCRIBED", "INITIAL_BUY"), trialTx, { autoRenewStatus: 1 }, "trial_started", null)!;
  assertEquals([s1.status, s1.last_offer_type, s1.last_offer_discount_type, s1.paid_count, s1.auto_renew],
    ["trial", 1, "FREE_TRIAL", 0, true]);
  const s2 = nextState(n("DID_RENEW"), paidTx, null, "trial_converted", afterTrial)!;
  assertEquals([s2.status, s2.last_offer_type, s2.paid_count, s2.last_price], ["active", null, 1, 4999]);
  const s3 = nextState(n("REFUND"), paidTx, null, "refunded", afterPaid)!;
  assertEquals(["last_offer_type" in s3, s3.paid_count], [false, 1]);
  assertEquals(nextState(n("TEST"), null, null, "test", null), null);
});

Deno.test("nextState: an older notification (Apple retry) does not overwrite newer state", () => {
  const newer: PriorState = { ...afterPaid, last_signed_date: new Date(NOW).toISOString() };
  const old = nextState(n("DID_RENEW"), paidTx, { autoRenewStatus: 0 }, "renewed", newer)!;
  assertEquals(Object.keys(old).sort(), ["original_transaction_id", "paid_count", "updated_at"]);
  assertEquals(old.paid_count, 2, "its payment still counts");
  const older: PriorState = { ...afterPaid, last_signed_date: new Date(NOW - DAY).toISOString() };
  const fresh = nextState(n("DID_RENEW"), paidTx, null, "renewed", older)!;
  assertEquals([fresh.status, fresh.paid_count], ["active", 2]);
});

Deno.test("extinfo: 16 strings, i2 + bundle id, filled from the profile", () => {
  const e = extinfoFrom(profile);
  assertEquals(e.length, 16);
  assertEquals([e[0], e[1], e[2], e[4], e[5], e[6]], ["i2", "com.novaralabs.longnote", "1.0.0", "18.1", "iPhone15,2", "en_IN"]);
  const given = extinfoFrom({ ...profile, extinfo: ["x", "y", "1.0.0", "42", "18.1", "iPhone15,2", "en_IN", "IST", "", "393", "852", "3", "6", "", "", "Asia/Kolkata"] });
  assertEquals([given[0], given[1], given[3], given[15]], ["i2", "com.novaralabs.longnote", "42", "Asia/Kolkata"]);
  assert(given.every((s) => typeof s === "string"));
});

Deno.test("App Events API fallback: SDK event names, value + currency, event id, JSON strings", () => {
  const trial = plan(n("SUBSCRIBED", "INITIAL_BUY"), trialTx, null, null, USER, profile, { ...cfg, metaPath: "app_events" });
  const f = appEventsForm(trial.meta!);
  assertEquals([f.event, f.anon_id, f.advertiser_tracking_enabled, f.application_tracking_enabled],
    ["CUSTOM_APP_EVENTS", "XZ1234-ABCD", "0", "1"]);
  assertEquals(JSON.parse(f.extinfo).length, 16);
  const ev = JSON.parse(f.custom_events)[0];
  assertEquals([ev._eventName, ev.event_id, ev.fb_currency, "_valueToSum" in ev],
    ["StartTrial", "uuid-SUBSCRIBED-INITIAL_BUY", "INR", false]);
  assertEquals(ev._logTime, Math.floor((NOW - 60_000) / 1000));
  const sub = appEventsForm(plan(n("DID_RENEW"), paidTx, null, afterTrial, USER, profile, cfg).meta!);
  const se = JSON.parse(sub.custom_events)[0];
  assertEquals([se._eventName, se._valueToSum, se.fb_currency, se.fb_order_id], ["Subscribe", 4999, "INR", "2000000002"]);
  const ren = appEventsForm(plan(n("DID_RENEW"), { ...paidTx, originalPurchaseDate: NOW - 400 * DAY }, null, afterPaid, USER, profile, cfg).meta!);
  assertEquals(JSON.parse(ren.custom_events)[0]._eventName, "fb_mobile_purchase");
});
