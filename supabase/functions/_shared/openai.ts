// OpenAI Chat Completions with Structured Outputs (json_schema, strict).
// Model chosen 16 Nov 2026 from GET /v1/models: gpt-5.4-mini (current small
// model, 400k context, structured outputs). Override with OPENAI_MODEL.

import { admin, ApiError, env, envNum, ipHash, limitError, limits } from "./common.ts";

export const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-5.4-mini";
// USD per 1M tokens (gpt-5.4-mini list price, 16 Nov 2026). Used for the
// money caps; override if the model changes.
const PRICE_IN = envNum("OPENAI_USD_PER_M_INPUT", 0.75);
const PRICE_CACHED = envNum("OPENAI_USD_PER_M_CACHED_INPUT", 0.075);
const PRICE_OUT = envNum("OPENAI_USD_PER_M_OUTPUT", 4.5);
/** Total time for one structured call incl. retries (functions stop at 150 s). */
const OPENAI_BUDGET_MS = envNum("OPENAI_TIMEOUT_MS", 110_000);

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

/** A cost reservation made before calling OpenAI (see reserveCall). */
export interface Reservation {
  day: string;
  usd: number;
  userId: string;
  kind: "summary" | "ask";
  ipHash: string | null;
}

/**
 * Upper-bound cost of one call: input at ~2.5 chars per token (conservative
 * for Devanagari; English is ~4) plus the full output budget.
 */
export function estimateUsd(messages: ChatMessage[], maxOutputTokens: number): number {
  const chars = messages.reduce((n, m) => n + m.content.length, 0);
  const usd = ((chars / 2.5) * PRICE_IN + maxOutputTokens * PRICE_OUT) / 1e6;
  return Math.ceil(usd * 1e4) / 1e4;
}

/**
 * Atomically check and charge, BEFORE calling OpenAI (ln_reserve_llm): the
 * user's call count + USD, the IP's call count + USD, the LLM pool and the
 * total cap. Nothing is charged when any of them refuses. Throws
 * limit_reached (scope user_day | ip_day | global_day).
 */
export async function reserveCall(
  req: Request, userId: string, kind: "summary" | "ask", usd: number,
): Promise<Reservation> {
  const lim = limits();
  const ip = await ipHash(req);
  const { data, error } = await admin().rpc("ln_reserve_llm", {
    p_user: userId, p_kind: kind, p_est_usd: usd,
    p_user_calls: kind === "summary" ? lim.summaryPerDay : lim.askPerDay,
    p_user_usd: lim.userLlmUsdPerDay,
    p_ip_hash: ip,
    p_ip_calls: kind === "summary" ? lim.ipSummaryPerDay : lim.ipAskPerDay,
    p_ip_usd: lim.ipLlmUsdPerDay,
    p_pool_usd: lim.globalLlmUsdPerDay,
    p_total_usd: lim.globalUsdPerDay,
  });
  if (error || !data) throw new ApiError("server_error", "limit check failed");
  const r = data as { verdict: string; day: string };
  if (r.verdict !== "ok") throw limitError(r.verdict);
  return { day: r.day, usd, userId, kind, ipHash: ip };
}

/**
 * billed: "yes" = OpenAI answered with usage (charge the real cost);
 * "no" = OpenAI refused with an HTTP error (nothing billed: give the call
 * and the money back); "unknown" = network error / timeout after the request
 * may have reached OpenAI (keep the reservation - review L5).
 */
type Billed = "yes" | "no" | "unknown";

async function settle(res: Reservation, billed: Billed, actualUsd: number): Promise<void> {
  const actual = billed === "yes" ? actualUsd : billed === "unknown" ? res.usd : 0;
  const { error } = await admin().rpc("ln_settle_llm", {
    p_user: res.userId, p_kind: res.kind, p_day: res.day, p_ip_hash: res.ipHash,
    p_reserved: res.usd, p_actual: Number(actual.toFixed(4)), p_release_call: billed === "no",
  });
  if (error) console.error("settle_failed");
}

export interface StructuredResult<T> {
  value: T;
  usd: number;
  usage: { input: number; cached: number; output: number };
}

export async function structuredChat<T>(
  messages: ChatMessage[],
  schemaName: string,
  schema: Record<string, unknown>,
  maxOutputTokens: number,
  reservation: Reservation,
): Promise<StructuredResult<T>> {
  // Settle the reservation exactly once.
  const state: { billed: Billed; usd: number } = { billed: "no", usd: 0 };
  try {
    return await chat<T>(messages, schemaName, schema, maxOutputTokens, state);
  } finally {
    await settle(reservation, state.billed, state.usd);
  }
}

async function chat<T>(
  messages: ChatMessage[],
  schemaName: string,
  schema: Record<string, unknown>,
  maxOutputTokens: number,
  state: { billed: Billed; usd: number },
): Promise<StructuredResult<T>> {
  const deadline = Date.now() + OPENAI_BUDGET_MS;
  let res: Response | null = null;
  let data: any = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const left = deadline - Date.now();
    if (left < 5_000) break;
    try {
      res = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env("OPENAI_API_KEY")}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: OPENAI_MODEL,
          messages,
          reasoning_effort: "low",
          max_completion_tokens: maxOutputTokens,
          response_format: {
            type: "json_schema",
            json_schema: { name: schemaName, strict: true, schema },
          },
        }),
        signal: AbortSignal.timeout(left),
      });
      if (res.ok) data = await res.json();
    } catch (e) {
      // Timeout or connection lost after sending: OpenAI may have billed it.
      // Do not send it again (that could bill twice).
      state.billed = "unknown";
      console.error("openai_network", e instanceof Error ? e.name : "unknown");
      throw new ApiError("upstream_failed", "The AI service did not answer in time. Try again.");
    }
    if (res.ok || (res.status !== 429 && res.status < 500)) break;
    await res.body?.cancel();
    await new Promise((r) => setTimeout(r, 800 * (attempt + 1)));
  }
  if (!res || !res.ok || !data) {
    console.error("openai_error", res?.status);
    throw new ApiError("upstream_failed", "The AI service did not answer. Try again.");
  }
  const u = data.usage ?? {};
  const cached = Number(u.prompt_tokens_details?.cached_tokens ?? 0);
  const input = Number(u.prompt_tokens ?? 0);
  const output = Number(u.completion_tokens ?? 0);
  const usd = ((input - cached) * PRICE_IN + cached * PRICE_CACHED + output * PRICE_OUT) / 1e6;
  // Count the spend even if the answer turns out unusable.
  state.billed = "yes";
  state.usd = usd;

  const choice = data.choices?.[0];
  if (choice?.message?.refusal) throw new ApiError("upstream_failed", "The AI declined this request.");
  if (choice?.finish_reason === "length") throw new ApiError("upstream_failed", "The AI answer was cut off. Try a shorter input.");
  let value: T;
  try {
    value = JSON.parse(choice?.message?.content ?? "");
  } catch {
    throw new ApiError("upstream_failed", "The AI returned an unreadable answer. Try again.");
  }
  return { value, usd, usage: { input, cached, output } };
}
