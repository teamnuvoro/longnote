// tracking-profile: the app's "tracking profile" for server-side subscription
// events (docs/BACKEND-API.md 4.7). One row per user (upsert). Sent by the app
// when it changes (checked once per launch, and on the analytics switch, the
// ATT answer and a purchase); share_analytics=false stores only that (the
// server then sends no events for this user).
//
// Optional `transaction_jws`: StoreKit's signed current transaction
// (Transaction.jwsRepresentation). If Apple's signature verifies and it is
// ours, its subscription (originalTransactionId) is linked to this user, so a
// reinstall (new anonymous user) still gets its renewals. A forged or foreign
// one is ignored (the profile is still stored).

import { admin, ApiError, handle, json, readJson, requireUser } from "../_shared/common.ts";
import { ProfileError, profileRow, transactionJws } from "../_shared/tracking_profile.ts";
import { verifyAppleJws } from "../_shared/appstore_jws.ts";
import { type AppStoreTransaction, BUNDLE_ID, priceOf } from "../_shared/appstore_events.ts";

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const body = await readJson(req, 24_000);
  let row: Record<string, unknown>;
  try {
    row = profileRow(body);
  } catch (e) {
    throw new ApiError("bad_request", e instanceof ProfileError ? e.message : "Bad profile.");
  }
  const db = admin();
  const { error } = await db.from("tracking_profiles")
    .upsert({ user_id: user.id, ...row }, { onConflict: "user_id" });
  if (error) throw new ApiError("server_error", "store failed");

  let linked = false;
  const jws = transactionJws(body);
  if (jws) {
    try {
      const tx = await verifyAppleJws<AppStoreTransaction>(jws);
      if (tx.bundleId === (Deno.env.get("APPLE_BUNDLE_ID") || BUNDLE_ID) && tx.originalTransactionId) {
        const otid = String(tx.originalTransactionId);
        const { data: existing } = await db.from("subscriptions").select("user_id")
          .eq("original_transaction_id", otid).maybeSingle();
        if (existing) {
          if (existing.user_id !== user.id) {
            await db.from("subscriptions").update({ user_id: user.id, updated_at: new Date().toISOString() })
              .eq("original_transaction_id", otid);
          }
        } else {
          // First sight (no notification yet): seed it from this transaction,
          // so a later DID_RENEW knows whether a free trial came before.
          await db.from("subscriptions").insert({
            original_transaction_id: otid, user_id: user.id, environment: tx.environment ?? null,
            product_id: tx.productId ?? null, currency: tx.currency ?? null,
            status: tx.offerType === 1 && (tx.offerDiscountType === "FREE_TRIAL" || tx.price === 0) ? "trial" : "active",
            last_transaction_id: tx.transactionId ?? null, last_offer_type: tx.offerType ?? null,
            last_offer_discount_type: tx.offerDiscountType ?? null, last_price: priceOf(tx),
            expires_at: tx.expiresDate ? new Date(tx.expiresDate).toISOString() : null,
          });
        }
        linked = true;
      }
    } catch (_) {
      console.warn("tracking-profile: transaction_jws not verified");
    }
  }
  return json(200, { ok: true, linked });
}));
