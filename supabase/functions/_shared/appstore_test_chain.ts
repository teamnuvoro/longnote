// Test helper: a throwaway Apple-like chain (root P-384 -> intermediate
// P-384 with the WWDR OID -> leaf P-256 with the receipt-signing OID) made
// in memory, and an ES256 JWS signer. Nothing is written to disk.
import * as x509 from "npm:@peculiar/x509@1.12.3";
import { OID_INTERMEDIATE, OID_LEAF } from "./appstore_jws.ts";

const P384 = { name: "ECDSA", namedCurve: "P-384" } as const;
const P256 = { name: "ECDSA", namedCurve: "P-256" } as const;
const SHA384 = { name: "ECDSA", hash: "SHA-384" } as const;
const NULL = new Uint8Array([5, 0]);

function b64(bytes: ArrayBuffer | Uint8Array): string {
  const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s);
}
const b64url = (u: Uint8Array | ArrayBuffer) => b64(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export interface TestChain {
  rootDer: Uint8Array;
  x5c: string[];
  leafKey: CryptoKey;
}

export interface ChainOptions {
  leafOid?: boolean;
  midOid?: boolean;
  midIsCa?: boolean;
  notAfter?: Date;
}

export async function makeChain(o: ChainOptions = {}): Promise<TestChain> {
  const now = Date.now();
  const nb = new Date(now - 86_400_000);
  const na = o.notAfter ?? new Date(now + 365 * 86_400_000);
  const rootKeys = await crypto.subtle.generateKey(P384, true, ["sign", "verify"]) as CryptoKeyPair;
  const midKeys = await crypto.subtle.generateKey(P384, true, ["sign", "verify"]) as CryptoKeyPair;
  const leafKeys = await crypto.subtle.generateKey(P256, true, ["sign", "verify"]) as CryptoKeyPair;
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01", name: "CN=Test Root CA - G3", notBefore: nb, notAfter: new Date(now + 3650 * 86_400_000),
    signingAlgorithm: SHA384, keys: rootKeys,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });
  const mid = await x509.X509CertificateGenerator.create({
    serialNumber: "02", subject: "CN=Test WWDR G6", issuer: root.subject, notBefore: nb, notAfter: na,
    signingAlgorithm: SHA384, signingKey: rootKeys.privateKey, publicKey: midKeys.publicKey,
    extensions: [
      new x509.BasicConstraintsExtension(o.midIsCa ?? true, 0, true),
      ...(o.midOid ?? true ? [new x509.Extension(OID_INTERMEDIATE, false, NULL)] : []),
    ],
  });
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03", subject: "CN=Test Prod ECC Mac App Store and iTunes Store Receipt Signing",
    issuer: mid.subject, notBefore: nb, notAfter: na,
    signingAlgorithm: SHA384, signingKey: midKeys.privateKey, publicKey: leafKeys.publicKey,
    extensions: [
      new x509.BasicConstraintsExtension(false, undefined, true),
      ...(o.leafOid ?? true ? [new x509.Extension(OID_LEAF, false, NULL)] : []),
    ],
  });
  return {
    rootDer: new Uint8Array(root.rawData),
    x5c: [leaf, mid, root].map((c) => b64(c.rawData)),
    leafKey: leafKeys.privateKey,
  };
}

/** Signs [payload] as an ES256 JWS with the chain's leaf key. */
export async function signJws(chain: TestChain, payload: unknown, header: Record<string, unknown> = {}): Promise<string> {
  const enc = new TextEncoder();
  const h = b64url(enc.encode(JSON.stringify({ alg: "ES256", x5c: chain.x5c, ...header })));
  const p = b64url(enc.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, chain.leafKey, enc.encode(h + "." + p));
  return `${h}.${p}.${b64url(sig)}`;
}
