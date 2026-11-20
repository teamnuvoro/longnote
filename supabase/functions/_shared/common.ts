// Shared helpers for Longnote edge functions: CORS, JSON errors with stable
// codes, auth (real user only), service-role DB client, limits config.
// Contract: docs/BACKEND-API.md. Never log transcripts, summaries or secrets.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Stable error codes the app maps to plain-words messages. */
export type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "not_found"
  | "limit_reached"
  | "too_long"
  | "payload_too_large"
  | "upstream_failed"
  | "server_error"
  | "method_not_allowed";

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  not_found: 404,
  method_not_allowed: 405,
  payload_too_large: 413,
  too_long: 422,
  limit_reached: 429,
  server_error: 500,
  upstream_failed: 502,
};

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

export function fail(
  code: ErrorCode,
  message: string,
  detail?: Record<string, unknown>,
): Response {
  return json(STATUS[code], { error: { code, message, ...(detail ? { detail } : {}) } });
}

/** Thrown inside handlers; turned into a JSON error by `handle`. */
export class ApiError extends Error {
  constructor(
    public code: ErrorCode,
    message: string,
    public detail?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export function env(name: string, fallback?: string): string {
  const v = Deno.env.get(name);
  if (v !== undefined && v !== "") return v;
  if (fallback !== undefined) return fallback;
  throw new ApiError("server_error", `Server is not configured (${name}).`);
}

export function envNum(name: string, fallback: number): number {
  const n = Number(Deno.env.get(name));
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/**
 * Limits; every one can be overridden by a function secret of the same name.
 * Money caps are in USD and reserve-then-settle (docs/BACKEND-API.md 5):
 * audio and LLM have separate global pools, so a burst of asks cannot stop
 * transcription for everyone (review B1). Call counts stay as a second guard.
 * Per-user / per-IP defaults raised 20 Nov 2026 to anti-abuse levels a paying
 * user never meets (Fable store-readiness S1); the global caps are unchanged.
 */
export const limits = () => ({
  audioSecondsPerDay: envNum("LIMIT_AUDIO_SECONDS_PER_DAY", 16 * 3600),
  audioSecondsPerHour: envNum("LIMIT_AUDIO_SECONDS_PER_HOUR", 6 * 3600),
  // Total estimated spend per UTC day (audio + LLM), on top of the pools.
  globalUsdPerDay: envNum("LIMIT_GLOBAL_USD_PER_DAY", 20),
  globalAudioUsdPerDay: envNum("LIMIT_GLOBAL_AUDIO_USD_PER_DAY", 12),
  globalLlmUsdPerDay: envNum("LIMIT_GLOBAL_LLM_USD_PER_DAY", 8),
  // Per user per UTC day, LLM (summarize + ask) in USD. Audio per user is
  // capped in seconds above, which is dollars at a fixed price per hour.
  userLlmUsdPerDay: envNum("LIMIT_USER_LLM_USD_PER_DAY", 3),
  askPerDay: envNum("LIMIT_ASK_PER_DAY", 200),
  summaryPerDay: envNum("LIMIT_SUMMARY_PER_DAY", 100),
  // Soniox async hard limit is 300 min per file.
  maxAudioSeconds: envNum("LIMIT_MAX_AUDIO_SECONDS", 300 * 60),
  // Per client IP (IPv6: per /64) per UTC day (anti-abuse: new anonymous
  // users are free to make). Generous-ish because Indian mobile carriers put
  // many phones behind one IPv4 (CGNAT). App Attest is the real fix (open).
  ipAudioSecondsPerDay: envNum("LIMIT_IP_AUDIO_SECONDS_PER_DAY", 72 * 3600),
  ipLlmUsdPerDay: envNum("LIMIT_IP_LLM_USD_PER_DAY", 10),
  ipSummaryPerDay: envNum("LIMIT_IP_SUMMARY_PER_DAY", 600),
  ipAskPerDay: envNum("LIMIT_IP_ASK_PER_DAY", 1500),
  reportsPerUserDay: envNum("LIMIT_REPORTS_PER_USER_DAY", 50),
  reportsPerIpDay: envNum("LIMIT_REPORTS_PER_IP_DAY", 200),
});

/** Soniox async price, USD per audio hour (estimate for the global cap). */
export const SONIOX_USD_PER_HOUR = envNum("SONIOX_USD_PER_HOUR", 0.10);

let _admin: SupabaseClient | null = null;
export function admin(): SupabaseClient {
  if (!_admin) {
    _admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return _admin;
}

export interface AuthedUser {
  id: string;
  isAnonymous: boolean;
}

/**
 * The gateway (verify_jwt) already checked the JWT signature, but the anon
 * key itself is a valid JWT. Require a real signed-in user (anonymous users
 * count) by resolving the token with GoTrue.
 */
export async function requireUser(req: Request): Promise<AuthedUser> {
  const h = req.headers.get("Authorization") ?? "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : "";
  if (!token) throw new ApiError("unauthorized", "Sign-in needed.");
  const { data, error } = await admin().auth.getUser(token);
  if (error || !data?.user) throw new ApiError("unauthorized", "Sign-in needed.");
  return { id: data.user.id, isAnonymous: data.user.is_anonymous ?? false };
}

export async function readJson(req: Request, maxBytes: number): Promise<Record<string, unknown>> {
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > maxBytes) throw new ApiError("payload_too_large", "Request is too large.", { max_bytes: maxBytes });
  let text: string;
  try {
    text = await req.text();
  } catch {
    throw new ApiError("bad_request", "Could not read the request.");
  }
  if (new TextEncoder().encode(text).length > maxBytes) {
    throw new ApiError("payload_too_large", "Request is too large.", { max_bytes: maxBytes });
  }
  try {
    const v = JSON.parse(text);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch { /* fall through */ }
  throw new ApiError("bad_request", "Body must be a JSON object.");
}

export function limitError(scope: string): ApiError {
  const msg: Record<string, string> = {
    user_day: "Daily limit reached. It resets at 00:00 UTC.",
    user_hour: "Too much audio in the last hour. Try again later.",
    global_day: "The service is busy today. Try again tomorrow.",
    ip_day: "Too much use from this network today. It resets at 00:00 UTC.",
  };
  return new ApiError("limit_reached", msg[scope] ?? "Limit reached.", { scope });
}

/** Wraps a handler: CORS preflight, POST only, errors -> JSON. */
export function handle(fn: (req: Request) => Promise<Response>): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    if (req.method !== "POST") return fail("method_not_allowed", "Use POST.");
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof ApiError) return fail(e.code, e.message, e.detail);
      console.error("unhandled", e instanceof Error ? e.name + ": " + e.message.slice(0, 200) : "unknown");
      return fail("server_error", "Something went wrong on our side.");
    }
  };
}

export function constantTimeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

/**
 * Client IP as set by the edge in front of the functions. cf-connecting-ip
 * and x-real-ip are overwritten by the proxy (a client cannot spoof them);
 * x-forwarded-for is the last resort (its first hop is client-controlled).
 */
export function clientIp(req: Request): string | null {
  const v = req.headers.get("cf-connecting-ip")?.trim() || req.headers.get("x-real-ip")?.trim() ||
    req.headers.get("x-forwarded-for")?.split(",").map((s) => s.trim()).filter(Boolean).pop();
  return v || null;
}

/**
 * The unit an IP cap applies to: an IPv4 address as is; for IPv6 the /64
 * prefix (one phone or home usually gets a whole /64, so the exact address
 * is trivially rotated - review B6). IPv4-mapped IPv6 counts as IPv4.
 */
export function ipBucket(ip: string): string {
  let s = ip.trim();
  if (s.startsWith("[")) s = s.slice(1, s.indexOf("]") > 0 ? s.indexOf("]") : undefined);
  const zone = s.indexOf("%");
  if (zone >= 0) s = s.slice(0, zone);
  if (!s.includes(":")) return s;
  const v4 = s.match(/(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (v4 && /^(::ffff:|::ffff:0:|::)$/i.test(s.slice(0, s.length - v4[1].length))) return v4[1];
  let head = s;
  if (v4) head = s.slice(0, s.length - v4[1].length) + "0:0";
  const halves = head.split("::");
  if (halves.length > 2) return s.toLowerCase();
  const left = halves[0] ? halves[0].split(":") : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const fill = halves.length === 2 ? 8 - left.length - right.length : 0;
  if (fill < 0) return s.toLowerCase();
  const groups = [...left, ...Array(fill).fill("0"), ...right];
  if (groups.length !== 8 || groups.some((g) => !/^[0-9a-f]{1,4}$/i.test(g))) return s.toLowerCase();
  return groups.slice(0, 4).map((g) => parseInt(g, 16).toString(16)).join(":") + "::/64";
}

/** HMAC-SHA256(server secret, ip bucket) as hex. The raw IP is never stored. */
export async function ipHash(req: Request): Promise<string | null> {
  const ip = clientIp(req);
  if (!ip) {
    console.error("no_client_ip");
    return null;
  }
  const secret = Deno.env.get("IP_HASH_SECRET") || env("CLEANUP_SECRET");
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ipBucket(ip)));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
