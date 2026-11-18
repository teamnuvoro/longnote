// Validation for the tracking-profile function (pure; tested in
// tracking_profile_test.ts). The app sends what the server needs to send
// subscription events for this user to Meta / Amplitude (docs/BACKEND-API.md 4.7).
// share_analytics=false wipes everything else: the server then stores only
// the "no" and sends nothing for this user.

export class ProfileError extends Error {}

const CODE = /^[A-Za-z0-9_.,:+\- ()]{1,64}$/;

function str(v: unknown, max: number, name: string): string | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string" || v.length > max || !CODE.test(v)) throw new ProfileError(`bad ${name}`);
  return v;
}

/** The row for tracking_profiles. `transaction_jws` (StoreKit's signed
 * current transaction) is checked here for size only and read by
 * [transactionJws]; it is not stored in the profile. */
export function transactionJws(body: Record<string, unknown>): string | null {
  return body.share_analytics === true && typeof body.transaction_jws === "string" && body.transaction_jws
    ? body.transaction_jws
    : null;
}

export function profileRow(body: Record<string, unknown>): Record<string, unknown> {
  if (typeof body.share_analytics !== "boolean") throw new ProfileError("share_analytics must be true or false");
  const now = new Date().toISOString();
  if (!body.share_analytics) {
    return {
      share_analytics: false, att_enabled: null, meta_anon_id: null, app_version: null, os_version: null,
      device_model: null, locale: null, currency: null, extinfo: null, updated_at: now,
    };
  }
  const att = body.att_enabled;
  if (att !== undefined && att !== null && typeof att !== "boolean") throw new ProfileError("bad att_enabled");
  const currency = str(body.currency, 3, "currency");
  if (currency && !/^[A-Z]{3}$/.test(currency)) throw new ProfileError("bad currency");
  let extinfo: string[] | null = null;
  if (body.extinfo !== undefined && body.extinfo !== null) {
    const e = body.extinfo;
    if (!Array.isArray(e) || e.length !== 16 || !e.every((s) => typeof s === "string" && s.length <= 64)) {
      throw new ProfileError("extinfo must be 16 strings");
    }
    extinfo = e as string[];
  }
  const jws = body.transaction_jws;
  if (jws !== undefined && jws !== null && (typeof jws !== "string" || jws.length > 16_000)) {
    throw new ProfileError("bad transaction_jws");
  }
  return {
    share_analytics: true,
    att_enabled: att ?? null,
    meta_anon_id: str(body.meta_anon_id, 100, "meta_anon_id"),
    app_version: str(body.app_version, 32, "app_version"),
    os_version: str(body.os_version, 32, "os_version"),
    device_model: str(body.device_model, 64, "device_model"),
    locale: str(body.locale, 35, "locale"),
    currency,
    extinfo,
    updated_at: now,
  };
}
