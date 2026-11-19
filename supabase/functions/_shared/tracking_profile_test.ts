// deno test --allow-env supabase/functions/_shared/tracking_profile_test.ts
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { ProfileError, profileRow, transactionJws } from "./tracking_profile.ts";

const ext = ["i2", "com.novaralabs.longnote", "1.0.0", "112", "18.1", "iPhone15,2", "en_IN", "IST", "", "393", "852", "3", "6", "", "", "Asia/Kolkata"];

Deno.test("full profile is kept", () => {
  const r = profileRow({ share_analytics: true, att_enabled: false, meta_anon_id: "XZ0A1B2C3D-AAAA", app_version: "1.0.0",
    os_version: "18.1", device_model: "iPhone15,2", locale: "en_IN", currency: "INR", extinfo: ext });
  assertEquals([r.share_analytics, r.att_enabled, r.meta_anon_id, r.currency, (r.extinfo as string[]).length],
    [true, false, "XZ0A1B2C3D-AAAA", "INR", 16]);
});

Deno.test("opt-out stores only the no", () => {
  const r = profileRow({ share_analytics: false, meta_anon_id: "XZ0A1B2C3D-AAAA", extinfo: ext });
  assertEquals([r.share_analytics, r.meta_anon_id, r.extinfo, r.att_enabled], [false, null, null, null]);
});

Deno.test("bad input refused", () => {
  for (const b of [
    {},
    { share_analytics: "yes" },
    { share_analytics: true, extinfo: ext.slice(0, 15) },
    { share_analytics: true, extinfo: [...ext.slice(0, 15), 5] },
    { share_analytics: true, currency: "inr" },
    { share_analytics: true, meta_anon_id: "x".repeat(101) },
    { share_analytics: true, att_enabled: "1" },
  ]) assertThrows(() => profileRow(b as Record<string, unknown>), ProfileError);
});

Deno.test("odd descriptive fields are cleaned, not refused", () => {
  const r = profileRow({ share_analytics: true, locale: "en_US@rg=inzzzz", device_model: "<script>", os_version: "18.1" });
  assertEquals([r.locale, r.device_model, r.os_version], ["en_US", null, "18.1"]);
});

Deno.test("transaction_jws: read only when sharing, size-capped, never stored in the row", () => {
  const r = profileRow({ share_analytics: true, transaction_jws: "a.b.c" });
  assertEquals("transaction_jws" in r, false);
  assertEquals(transactionJws({ share_analytics: true, transaction_jws: "a.b.c" }), "a.b.c");
  assertEquals(transactionJws({ share_analytics: false, transaction_jws: "a.b.c" }), null);
  assertThrows(() => profileRow({ share_analytics: true, transaction_jws: "x".repeat(16_001) }), ProfileError);
});
