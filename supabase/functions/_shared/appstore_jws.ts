// Verifies Apple's signed data (JWS, ES256 with an x5c chain) for App Store
// Server Notifications V2: the notification itself (signedPayload),
// signedTransactionInfo and signedRenewalInfo. Same checks as Apple's
// app-store-server-library (SignedDataVerifier) without OCSP:
//   1. header alg = ES256 and x5c holds exactly [leaf, intermediate, root];
//   2. the root in x5c is byte-for-byte Apple Root CA - G3 (embedded below);
//   3. leaf is signed by intermediate, intermediate by the root, each valid
//      at the effective date (the payload's signedDate, as Apple's library
//      does when online checks are off; else now);
//   4. the intermediate is a CA and carries Apple's WWDR OID
//      1.2.840.113635.100.6.2.1; the leaf carries the App Store receipt
//      signing OID 1.2.840.113635.100.6.11.1;
//   5. the JWS signature verifies with the leaf's P-256 key.
// Anything else throws JwsError. Pure (no network, no env): tested in
// appstore_jws_test.ts with a throwaway chain built by openssl.

import * as x509 from "npm:@peculiar/x509@1.12.3";

/** Apple Root CA - G3 (DER, base64), from
 * https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
 * SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
 * (checked 18 Nov 2026; valid to 30 Apr 2039). */
export const APPLE_ROOT_CA_G3_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

export const OID_LEAF = "1.2.840.113635.100.6.11.1";
export const OID_INTERMEDIATE = "1.2.840.113635.100.6.2.1";

export class JwsError extends Error {}

export interface VerifyOptions {
  /** Trusted roots (DER). Default: Apple Root CA - G3 only. Tests pass their own. */
  roots?: Uint8Array[];
  /** Effective date override (tests). Default: payload.signedDate, else now. */
  now?: Date;
}

export function b64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function b64urlToBytes(s: string): Uint8Array<ArrayBuffer> {
  const b = s.replace(/-/g, "+").replace(/_/g, "/");
  return b64ToBytes(b + "=".repeat((4 - (b.length % 4)) % 4));
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

const APPLE_ROOTS = [b64ToBytes(APPLE_ROOT_CA_G3_B64)];

/** Decodes the payload WITHOUT verifying (only for logging bad input). */
export function peekPayload(jws: string): Record<string, unknown> | null {
  try {
    return JSON.parse(new TextDecoder().decode(b64urlToBytes(jws.split(".")[1] ?? "")));
  } catch {
    return null;
  }
}

/** Verifies [jws] and returns its payload. Throws JwsError on any failure. */
export async function verifyAppleJws<T = Record<string, unknown>>(
  jws: string,
  opts: VerifyOptions = {},
): Promise<T> {
  if (typeof jws !== "string" || jws.length > 64_000) throw new JwsError("not a jws");
  const parts = jws.split(".");
  if (parts.length !== 3 || parts.some((p) => !/^[A-Za-z0-9_-]+$/.test(p))) {
    throw new JwsError("not a compact jws");
  }
  let header: { alg?: unknown; x5c?: unknown };
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  } catch {
    throw new JwsError("bad json");
  }
  if (!payload || typeof payload !== "object") throw new JwsError("bad payload");
  if (header.alg !== "ES256") throw new JwsError("alg must be ES256");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string")) {
    throw new JwsError("x5c must hold 3 certificates");
  }
  const ders = (x5c as string[]).map(b64ToBytes);
  const roots = opts.roots ?? APPLE_ROOTS;
  if (!roots.some((r) => sameBytes(r, ders[2]))) throw new JwsError("untrusted root");

  let leaf: x509.X509Certificate, mid: x509.X509Certificate, root: x509.X509Certificate;
  try {
    [leaf, mid, root] = ders.map((d) => new x509.X509Certificate(d));
  } catch {
    throw new JwsError("bad certificate");
  }

  const sd = payload.signedDate;
  const date = opts.now ?? (typeof sd === "number" && Number.isFinite(sd) ? new Date(sd) : new Date());

  // verify() with a date checks the signature AND notBefore <= date <= notAfter.
  const ok = async (c: x509.X509Certificate, issuer: x509.X509Certificate) => {
    try {
      return await c.verify({ publicKey: issuer.publicKey, date });
    } catch {
      return false;
    }
  };
  if (!(await ok(root, root))) throw new JwsError("root invalid at date");
  if (!(await ok(mid, root))) throw new JwsError("intermediate not signed by root / expired");
  if (!(await ok(leaf, mid))) throw new JwsError("leaf not signed by intermediate / expired");

  const bc = mid.getExtension(x509.BasicConstraintsExtension);
  if (!bc || !bc.ca) throw new JwsError("intermediate is not a CA");
  if (!mid.getExtension(OID_INTERMEDIATE)) throw new JwsError("intermediate lacks Apple OID");
  if (!leaf.getExtension(OID_LEAF)) throw new JwsError("leaf lacks Apple OID");

  let key: CryptoKey;
  try {
    key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  } catch {
    throw new JwsError("leaf key is not P-256");
  }
  const sig = b64urlToBytes(parts[2]);
  if (sig.length !== 64) throw new JwsError("bad signature length");
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    sig,
    new TextEncoder().encode(parts[0] + "." + parts[1]),
  );
  if (!valid) throw new JwsError("bad signature");
  return payload as T;
}
