// App Store Server Notifications V2 -> our analytics events (pure, no I/O).
// Used by functions/appstore-notifications; tested in appstore_events_test.ts.
// The table of what is sent where is in docs/ANALYTICS.md ("Server events").
//
// Money comes from Apple's signed transaction: price is in milliunits
// (price / 1000) in the storefront currency.

export const BUNDLE_ID = "com.novaralabs.longnote";

/** Decoded responseBodyV2DecodedPayload (only the fields we use). */
export interface AppStoreNotification {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  signedDate: number;
  version?: string;
  data?: {
    environment?: string;
    bundleId?: string;
    appAppleId?: number;
    bundleVersion?: string;
    status?: number;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

/** Decoded JWSTransactionDecodedPayload (fields we use). */
export interface AppStoreTransaction {
  transactionId?: string;
  originalTransactionId?: string;
  bundleId?: string;
  productId?: string;
  purchaseDate?: number;
  originalPurchaseDate?: number;
  expiresDate?: number;
  type?: string;
  offerType?: number; // 1 introductory, 2 promotional, 3 offer code, 4 win-back
  offerDiscountType?: string; // FREE_TRIAL | PAY_AS_YOU_GO | PAY_UP_FRONT
  price?: number; // milliunits
  currency?: string;
  appAccountToken?: string;
  environment?: string;
  revocationDate?: number;
  revocationReason?: number;
  transactionReason?: string;
}

/** Decoded JWSRenewalInfoDecodedPayload (fields we use). */
export interface AppStoreRenewal {
  autoRenewStatus?: number;
  autoRenewProductId?: string;
  productId?: string;
  originalTransactionId?: string;
  expirationIntent?: number;
}

/** What we stored about this subscription before this notification. */
export interface PriorState {
  last_offer_type: number | null;
  last_offer_discount_type: string | null;
  last_price: number | null;
  paid_count: number;
}

/** The user's tracking profile (table tracking_profiles). */
export interface TrackingProfile {
  share_analytics: boolean;
  att_enabled: boolean | null;
  meta_anon_id: string | null;
  app_version: string | null;
  os_version: string | null;
  device_model: string | null;
  locale: string | null;
  extinfo: string[] | null;
}

export type Kind =
  | "trial_started"
  | "subscribed"
  | "trial_converted"
  | "renewed"
  | "plan_upgraded"
  | "refunded"
  | "refund_reversed"
  | "refund_declined"
  | "expired"
  | "auto_renew_off"
  | "auto_renew_on"
  | "billing_issue"
  | "plan_change"
  | "revoked"
  | "offer_redeemed"
  | "test"
  | "other";

export const AMPLITUDE_EVENT: Record<Exclude<Kind, "test" | "other">, string> = {
  trial_started: "appstore_trial_started",
  subscribed: "appstore_subscribed",
  trial_converted: "appstore_trial_converted",
  renewed: "appstore_renewed",
  plan_upgraded: "appstore_plan_upgraded",
  refunded: "appstore_refunded",
  refund_reversed: "appstore_refund_reversed",
  refund_declined: "appstore_refund_declined",
  expired: "appstore_expired",
  auto_renew_off: "appstore_auto_renew_off",
  auto_renew_on: "appstore_auto_renew_on",
  billing_issue: "appstore_billing_issue",
  plan_change: "appstore_plan_change",
  revoked: "appstore_revoked",
  offer_redeemed: "appstore_offer_redeemed",
};

/** Meta standard event per kind; kinds not listed never go to Meta. */
export const META_EVENT: Partial<Record<Kind, "StartTrial" | "Subscribe" | "Purchase">> = {
  trial_started: "StartTrial",
  subscribed: "Subscribe",
  trial_converted: "Subscribe",
  renewed: "Purchase",
  plan_upgraded: "Purchase",
};

/** Amplitude revenueType per kind (sign of the amount below). */
const REVENUE: Partial<Record<Kind, { type: string; sign: 1 | -1 }>> = {
  subscribed: { type: "subscription", sign: 1 },
  trial_converted: { type: "subscription", sign: 1 },
  renewed: { type: "renewal", sign: 1 },
  plan_upgraded: { type: "upgrade", sign: 1 },
  refunded: { type: "refund", sign: -1 },
  refund_reversed: { type: "refund_reversed", sign: 1 },
};

export function isFreeTrial(tx: AppStoreTransaction | null): boolean {
  if (!tx || tx.offerType !== 1) return false;
  return tx.offerDiscountType === "FREE_TRIAL" || tx.price === 0;
}

/** Price in currency units (Apple sends milliunits); null when absent. */
export function priceOf(tx: AppStoreTransaction | null): number | null {
  if (!tx || typeof tx.price !== "number" || !Number.isFinite(tx.price)) return null;
  return Math.round(tx.price) / 1000;
}

const DAY = 86_400_000;

/**
 * Was the payment in this DID_RENEW the first one after a free trial?
 * Our stored state decides; without it (we missed the SUBSCRIBED, e.g. it
 * came before this endpoint existed) a production renewal less than 14
 * days after the original purchase can only be a trial ending (our trial
 * is 3 days; a paid month is >= 28 days). Sandbox time is compressed, so no
 * guess there.
 */
export function firstPaidAfterTrial(
  tx: AppStoreTransaction | null,
  prior: PriorState | null,
  environment: string,
): { yes: boolean; inferred: boolean } {
  if (prior) {
    const wasTrial = prior.last_offer_type === 1 &&
      (prior.last_offer_discount_type === "FREE_TRIAL" || prior.last_price === 0);
    return { yes: wasTrial && prior.paid_count === 0, inferred: false };
  }
  if (environment !== "Production" || !tx?.purchaseDate || !tx.originalPurchaseDate) {
    return { yes: false, inferred: false };
  }
  const gap = tx.purchaseDate - tx.originalPurchaseDate;
  return { yes: gap > 0 && gap < 14 * DAY, inferred: true };
}

export function classify(
  n: AppStoreNotification,
  tx: AppStoreTransaction | null,
  prior: PriorState | null,
): { kind: Kind; inferred: boolean } {
  const env = n.data?.environment ?? "";
  switch (n.notificationType) {
    case "SUBSCRIBED":
      return { kind: isFreeTrial(tx) ? "trial_started" : "subscribed", inferred: false };
    case "DID_RENEW": {
      const f = firstPaidAfterTrial(tx, prior, env);
      return { kind: f.yes ? "trial_converted" : "renewed", inferred: f.inferred };
    }
    case "DID_CHANGE_RENEWAL_PREF":
      return { kind: n.subtype === "UPGRADE" ? "plan_upgraded" : "plan_change", inferred: false };
    case "REFUND":
      return { kind: "refunded", inferred: false };
    case "REFUND_REVERSED":
      return { kind: "refund_reversed", inferred: false };
    case "REFUND_DECLINED":
      return { kind: "refund_declined", inferred: false };
    case "EXPIRED":
    case "GRACE_PERIOD_EXPIRED":
      return { kind: "expired", inferred: false };
    case "DID_CHANGE_RENEWAL_STATUS":
      return { kind: n.subtype === "AUTO_RENEW_ENABLED" ? "auto_renew_on" : "auto_renew_off", inferred: false };
    case "DID_FAIL_TO_RENEW":
      return { kind: "billing_issue", inferred: false };
    case "REVOKE":
      return { kind: "revoked", inferred: false };
    case "OFFER_REDEEMED":
      return { kind: "offer_redeemed", inferred: false };
    case "TEST":
      return { kind: "test", inferred: false };
    default:
      return { kind: "other", inferred: false };
  }
}

/** The subscription row after this notification (table subscriptions). */
export function nextState(
  n: AppStoreNotification,
  tx: AppStoreTransaction | null,
  renewal: AppStoreRenewal | null,
  kind: Kind,
  prior: PriorState | null,
): Record<string, unknown> | null {
  const otid = tx?.originalTransactionId ?? renewal?.originalTransactionId;
  if (!otid) return null;
  const STATUS: Record<number, string> = { 1: "active", 2: "expired", 3: "billing_retry", 4: "grace_period", 5: "revoked" };
  const paidNow = kind === "subscribed" || kind === "trial_converted" || kind === "renewed" || kind === "plan_upgraded";
  const row: Record<string, unknown> = {
    original_transaction_id: otid,
    environment: n.data?.environment ?? null,
    last_notification_type: n.notificationType,
    last_subtype: n.subtype ?? null,
    last_signed_date: new Date(n.signedDate).toISOString(),
    paid_count: (prior?.paid_count ?? 0) + (paidNow ? 1 : 0),
    updated_at: new Date().toISOString(),
  };
  if (typeof n.data?.status === "number") row.status = STATUS[n.data.status] ?? String(n.data.status);
  if (kind === "trial_started") row.status = "trial";
  if (tx) {
    // Only a newer purchase moves the "last transaction" fields (a REFUND
    // or EXPIRED carries the old transaction; keep offer info as it was).
    if (kind === "trial_started" || kind === "subscribed" || paidNow || kind === "offer_redeemed") {
      row.last_transaction_id = tx.transactionId ?? null;
      row.last_offer_type = tx.offerType ?? null;
      row.last_offer_discount_type = tx.offerDiscountType ?? null;
      row.last_price = priceOf(tx);
    }
    if (tx.productId) row.product_id = tx.productId;
    if (tx.currency) row.currency = tx.currency;
    if (tx.expiresDate) row.expires_at = new Date(tx.expiresDate).toISOString();
  }
  if (renewal && typeof renewal.autoRenewStatus === "number") row.auto_renew = renewal.autoRenewStatus === 1;
  if (renewal?.autoRenewProductId) row.auto_renew_product_id = renewal.autoRenewProductId;
  return row;
}

/** One Meta event, independent of the transport (built by plan()). */
export interface MetaEvent {
  name: "StartTrial" | "Subscribe" | "Purchase";
  /** seconds */
  time: number;
  /** = notificationUUID; Meta dedupes on event id + name */
  id: string;
  value: number | null;
  currency: string | null;
  productId: string | null;
  orderId: string | null;
  anonId: string;
  att: boolean;
  extinfo: string[];
}

export interface Plan {
  kind: Kind;
  inferred: boolean;
  meta: MetaEvent | null;
  metaSkip: string | null;
  /** Amplitude HTTP V2 events (0 or 1), or [] + reason. */
  amplitude: Record<string, unknown>[];
  amplitudeSkip: string | null;
}

/**
 * Which Meta server path is set up (chosen by the secrets that exist):
 *  - "capi": Conversions API for app events (META_CAPI_TOKEN + META_DATASET_ID)
 *  - "app_events": the older App Events API, POST /{app-id}/activities with
 *    the app access token (META_APP_ID + META_APP_SECRET)
 *  - null: Meta skipped
 */
export type MetaPath = "capi" | "app_events" | null;

export interface PlanConfig {
  metaPath: MetaPath;
  /** META_TEST_EVENT_CODE set. Sandbox events go to Meta only through CAPI
   * with this code (Events Manager > Test events); never in production. */
  metaTestCode: boolean;
  amplitudeConfigured: boolean;
  now: number;
}

function periodOf(productId: string | undefined | null): string | null {
  if (!productId) return null;
  if (productId.endsWith(".annual")) return "year";
  if (productId.endsWith(".monthly")) return "month";
  return null;
}

/** Fields Meta wants in app_data.extinfo (16 strings, '' when unknown). */
export function extinfoFrom(p: TrackingProfile): string[] {
  const e = Array.isArray(p.extinfo) && p.extinfo.length === 16 && p.extinfo.every((s) => typeof s === "string")
    ? p.extinfo.map((s) => s.slice(0, 64))
    : new Array(16).fill("");
  e[0] = "i2";
  e[1] = BUNDLE_ID;
  if (!e[2] && p.app_version) e[2] = p.app_version;
  if (!e[4] && p.os_version) e[4] = p.os_version;
  if (!e[5] && p.device_model) e[5] = p.device_model;
  if (!e[6] && p.locale) e[6] = p.locale;
  return e;
}

/** Conversions API (app events) item for POST /{dataset_id}/events `data`. */
export function capiEvent(m: MetaEvent): Record<string, unknown> {
  const custom: Record<string, unknown> = {};
  if (m.currency) custom.currency = m.currency;
  if (m.value !== null) custom.value = m.value;
  if (m.productId) {
    custom.content_ids = [m.productId];
    custom.content_type = "product";
  }
  if (m.orderId) custom.order_id = m.orderId;
  return {
    event_name: m.name,
    event_time: m.time,
    event_id: m.id,
    action_source: "app",
    user_data: { anon_id: m.anonId },
    custom_data: custom,
    app_data: {
      advertiser_tracking_enabled: m.att ? 1 : 0,
      application_tracking_enabled: 1, // share_analytics is on (plan() checked)
      extinfo: m.extinfo,
    },
  };
}

/** App Events API event names (what the Meta iOS SDK 18 logs). */
export const APP_EVENTS_NAME: Record<MetaEvent["name"], string> = {
  StartTrial: "StartTrial",
  Subscribe: "Subscribe",
  Purchase: "fb_mobile_purchase",
};

/** Form fields for POST /{app-id}/activities (App Events API), without the
 * access token. Same shape the Meta SDK sends: anon_id + extinfo as a JSON
 * array string, custom_events as a JSON array string. */
export function appEventsForm(m: MetaEvent): Record<string, string> {
  const ev: Record<string, unknown> = {
    _eventName: APP_EVENTS_NAME[m.name],
    _logTime: m.time,
    event_id: m.id,
  };
  if (m.value !== null) ev._valueToSum = m.value;
  if (m.currency) ev.fb_currency = m.currency;
  if (m.orderId) ev.fb_order_id = m.orderId;
  if (m.productId) {
    ev.fb_content_type = "product";
    ev.fb_content_id = m.productId;
  }
  return {
    event: "CUSTOM_APP_EVENTS",
    anon_id: m.anonId,
    advertiser_tracking_enabled: m.att ? "1" : "0",
    application_tracking_enabled: "1",
    extinfo: JSON.stringify(m.extinfo),
    custom_events: JSON.stringify([ev]),
  };
}

/**
 * What to send for one notification. [userId] is the Supabase user the
 * purchase belongs to (from appAccountToken or an earlier notification),
 * null if unknown. Nothing is sent without a profile that has
 * share_analytics = true (the app's "Share usage analytics" switch).
 */
export function plan(
  n: AppStoreNotification,
  tx: AppStoreTransaction | null,
  renewal: AppStoreRenewal | null,
  prior: PriorState | null,
  userId: string | null,
  profile: TrackingProfile | null,
  cfg: PlanConfig,
): Plan {
  const { kind, inferred } = classify(n, tx, prior);
  const out: Plan = { kind, inferred, meta: null, metaSkip: null, amplitude: [], amplitudeSkip: null };
  const environment = n.data?.environment ?? "";
  const sandbox = environment !== "Production";

  const gate = (): string | null => {
    if (kind === "test" || kind === "other") return "not_tracked";
    if (!userId) return "no_user";
    if (!profile) return "no_profile";
    if (!profile.share_analytics) return "opted_out";
    return null;
  };
  const why = gate();
  const price = priceOf(tx);
  const currency = tx?.currency ?? null;
  const productId = tx?.productId ?? renewal?.productId ?? null;

  // ---- Amplitude
  if (why) {
    out.amplitudeSkip = why;
  } else if (!cfg.amplitudeConfigured) {
    out.amplitudeSkip = "not_configured";
  } else {
    const props: Record<string, unknown> = {
      source: "server",
      environment,
      notification_type: n.notificationType,
      ...(n.subtype ? { subtype: n.subtype } : {}),
      ...(productId ? { product_id: productId, period: periodOf(productId) } : {}),
      ...(tx?.offerType ? { offer_type: tx.offerType } : {}),
      ...(tx?.offerDiscountType ? { offer_discount_type: tx.offerDiscountType } : {}),
      ...(price !== null ? { price } : {}),
      ...(currency ? { currency } : {}),
      ...(renewal && typeof renewal.autoRenewStatus === "number" ? { auto_renew: renewal.autoRenewStatus === 1 } : {}),
      ...(inferred ? { inferred: true } : {}),
      ...(sandbox ? { sandbox: true } : {}),
    };
    const ev: Record<string, unknown> = {
      user_id: userId,
      event_type: AMPLITUDE_EVENT[kind as keyof typeof AMPLITUDE_EVENT],
      time: n.signedDate,
      insert_id: n.notificationUUID,
      platform: "iOS",
      os_name: "ios",
      ...(profile!.app_version ? { app_version: profile!.app_version } : {}),
      event_properties: props,
      // No ip / idfa / idfv / location: same privacy settings as the app
      // (AmplitudeSink.configuration). The request comes from Supabase, so
      // the user's IP never reaches Amplitude from here.
    };
    const rev = REVENUE[kind];
    if (rev && price !== null && price !== 0) {
      ev.price = rev.sign * price;
      ev.quantity = 1;
      ev.revenue = rev.sign * price;
      ev.revenueType = rev.type;
      if (productId) ev.productId = productId;
      if (currency) ev.currency = currency;
    }
    out.amplitude.push(ev);
  }

  // ---- Meta
  const metaName = META_EVENT[kind];
  if (why) {
    out.metaSkip = why;
  } else if (!metaName) {
    out.metaSkip = "not_a_meta_event";
  } else if (!cfg.metaPath) {
    out.metaSkip = "not_configured";
  } else if (sandbox && !(cfg.metaPath === "capi" && cfg.metaTestCode)) {
    out.metaSkip = "sandbox";
  } else if (!profile!.meta_anon_id) {
    out.metaSkip = "no_meta_anon_id";
  } else if (cfg.now - n.signedDate > 7 * DAY) {
    out.metaSkip = "too_old";
  } else {
    out.meta = {
      name: metaName,
      time: Math.floor(n.signedDate / 1000),
      id: n.notificationUUID,
      // A free trial is not revenue: StartTrial carries no value (as the app did).
      value: metaName !== "StartTrial" && price !== null ? price : null,
      currency,
      productId,
      orderId: tx?.transactionId ?? null,
      anonId: profile!.meta_anon_id,
      att: profile!.att_enabled === true,
      extinfo: extinfoFrom(profile!),
    };
  }
  return out;
}
