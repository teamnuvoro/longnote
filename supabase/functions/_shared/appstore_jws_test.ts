// deno test --allow-env supabase/functions/_shared/appstore_jws_test.ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { APPLE_ROOT_CA_G3_B64, b64ToBytes, JwsError, verifyAppleJws } from "./appstore_jws.ts";
import { makeChain, signJws } from "./appstore_test_chain.ts";

const payload = { notificationType: "TEST", notificationUUID: "u-1", signedDate: Date.now() };

Deno.test("valid chain and signature -> payload", async () => {
  const c = await makeChain();
  const jws = await signJws(c, payload);
  assertEquals(await verifyAppleJws(jws, { roots: [c.rootDer] }), payload);
});

Deno.test("default trust is Apple Root CA - G3 only: a self-made root is refused", async () => {
  const c = await makeChain();
  await assertRejects(async () => verifyAppleJws(await signJws(c, payload)), JwsError, "untrusted root");
});

Deno.test("embedded Apple root parses and is the G3 root", async () => {
  const x509 = await import("npm:@peculiar/x509@1.12.3");
  const cert = new x509.X509Certificate(b64ToBytes(APPLE_ROOT_CA_G3_B64));
  assertEquals(cert.subject, "CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US");
  const fp = new Uint8Array(await crypto.subtle.digest("SHA-256", b64ToBytes(APPLE_ROOT_CA_G3_B64)));
  assertEquals([...fp].map((b) => b.toString(16).padStart(2, "0")).join(""),
    "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179");
});

Deno.test("tampered payload -> bad signature", async () => {
  const c = await makeChain();
  const [h, , s] = (await signJws(c, payload)).split(".");
  const evil = btoa(JSON.stringify({ ...payload, notificationType: "REFUND" })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  await assertRejects(() => verifyAppleJws(`${h}.${evil}.${s}`, { roots: [c.rootDer] }), JwsError, "bad signature");
});

Deno.test("signed by another key with the same chain -> bad signature", async () => {
  const c = await makeChain();
  const other = await makeChain();
  const jws = await signJws({ ...c, leafKey: other.leafKey }, payload);
  await assertRejects(() => verifyAppleJws(jws, { roots: [c.rootDer] }), JwsError, "bad signature");
});

Deno.test("leaf from another chain -> not signed by intermediate", async () => {
  const c = await makeChain();
  const other = await makeChain();
  const mixed = { ...c, x5c: [other.x5c[0], c.x5c[1], c.x5c[2]], leafKey: other.leafKey };
  await assertRejects(async () => verifyAppleJws(await signJws(mixed, payload), { roots: [c.rootDer] }), JwsError, "leaf not signed");
});

Deno.test("missing Apple OIDs / intermediate not a CA -> refused", async () => {
  for (const [opt, msg] of [
    [{ leafOid: false }, "leaf lacks Apple OID"],
    [{ midOid: false }, "intermediate lacks Apple OID"],
    [{ midIsCa: false }, "intermediate is not a CA"],
  ] as const) {
    const c = await makeChain(opt);
    await assertRejects(async () => verifyAppleJws(await signJws(c, payload), { roots: [c.rootDer] }), JwsError, msg);
  }
});

Deno.test("expired at the signed date -> refused", async () => {
  const c = await makeChain();
  const late = { ...payload, signedDate: Date.now() + 5 * 365 * 86_400_000 };
  await assertRejects(async () => verifyAppleJws(await signJws(c, late), { roots: [c.rootDer] }), JwsError);
});

Deno.test("alg other than ES256, wrong x5c length, garbage -> refused", async () => {
  const c = await makeChain();
  await assertRejects(async () => verifyAppleJws(await signJws(c, payload, { alg: "HS256" }), { roots: [c.rootDer] }), JwsError, "ES256");
  await assertRejects(async () => verifyAppleJws(await signJws(c, payload, { x5c: c.x5c.slice(0, 2) }), { roots: [c.rootDer] }), JwsError, "x5c");
  await assertRejects(() => verifyAppleJws("a.b", { roots: [c.rootDer] }), JwsError);
  await assertRejects(() => verifyAppleJws("eyJ9.e30.AAAA", { roots: [c.rootDer] }), JwsError);
});

Deno.test("a REAL Apple-signed TEST notification (sandbox, 18 Nov 2026) verifies against the embedded Apple root", async () => {
  const jws = (await Deno.readTextFile(new URL("./testdata/apple_sandbox_test_notification.jws", import.meta.url))).trim();
  const p = await verifyAppleJws<{ notificationType: string; data: { bundleId: string; environment: string } }>(jws);
  assertEquals([p.notificationType, p.data.bundleId, p.data.environment], ["TEST", "com.novaralabs.longnote", "Sandbox"]);
  // and one changed byte breaks it
  const parts = jws.split(".");
  const bad = parts[0] + "." + parts[1] + "." + (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
  await assertRejects(() => verifyAppleJws(bad), JwsError);
});
