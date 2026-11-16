// OpenAI Chat Completions with Structured Outputs (json_schema, strict).
// Model chosen 16 Nov 2026 from GET /v1/models: gpt-5.4-mini (current small
// model, 400k context, structured outputs). Override with OPENAI_MODEL.

import { admin, ApiError, env, envNum, limitError } from "./common.ts";

export const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-5.4-mini";
// USD per 1M tokens (gpt-5.4-mini list price, 16 Nov 2026). Used only for the
// global daily cost cap; override if the model changes.
const PRICE_IN = envNum("OPENAI_USD_PER_M_INPUT", 0.75);
const PRICE_CACHED = envNum("OPENAI_USD_PER_M_CACHED_INPUT", 0.075);
const PRICE_OUT = envNum("OPENAI_USD_PER_M_OUTPUT", 4.5);

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

/** A cost reservation made before calling OpenAI (see reserveCall). */
export interface Reservation {
  day: string;
  usd: number;
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
 * Atomically count the user's call and reserve `usd` against the global
 * daily cap BEFORE calling OpenAI (ln_reserve_call). Throws limit_reached.
 */
export async function reserveCall(
  userId: string, kind: "summary" | "ask", userLimit: number, globalCap: number, usd: number,
): Promise<Reservation> {
  const { data, error } = await admin().rpc("ln_reserve_call", {
    p_user: userId, p_kind: kind, p_limit: userLimit, p_global_cap: globalCap, p_est_usd: usd,
  });
  if (error || !data) throw new ApiError("server_error", "limit check failed");
  const r = data as { verdict: string; day: string };
  if (r.verdict !== "ok") throw limitError(r.verdict);
  return { day: r.day, usd };
}

async function settle(res: Reservation, actualUsd: number): Promise<void> {
  const { error } = await admin().rpc("ln_settle_cost", {
    p_day: res.day, p_reserved: res.usd, p_actual: Number(actualUsd.toFixed(4)),
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
  // Settle the reservation exactly once: to the real cost, or 0 if OpenAI
  // never answered with usage.
  let actual = 0;
  try {
    return await chat<T>(messages, schemaName, schema, maxOutputTokens, (usd) => (actual = usd));
  } finally {
    await settle(reservation, actual);
  }
}

async function chat<T>(
  messages: ChatMessage[],
  schemaName: string,
  schema: Record<string, unknown>,
  maxOutputTokens: number,
  onCost: (usd: number) => void,
): Promise<StructuredResult<T>> {
  let res: Response | null = null;
  for (let attempt = 0; attempt < 3; attempt++) {
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
    });
    if (res.status !== 429 && res.status < 500) break;
    await new Promise((r) => setTimeout(r, 800 * (attempt + 1)));
  }
  if (!res || !res.ok) {
    console.error("openai_error", res?.status);
    throw new ApiError("upstream_failed", "The AI service did not answer. Try again.");
  }
  const data = await res.json();
  const u = data.usage ?? {};
  const cached = Number(u.prompt_tokens_details?.cached_tokens ?? 0);
  const input = Number(u.prompt_tokens ?? 0);
  const output = Number(u.completion_tokens ?? 0);
  const usd = ((input - cached) * PRICE_IN + cached * PRICE_CACHED + output * PRICE_OUT) / 1e6;
  // Count the spend even if the answer turns out unusable.
  onCost(usd);

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
