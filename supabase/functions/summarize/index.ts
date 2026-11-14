// Longnote cloud summary - Supabase Edge Function (Deno).
//
// NOT DEPLOYED. Deploy only after review:
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...   (server-side secret)
//   supabase functions deploy summarize
// The app sends transcript TEXT only (never audio). Nothing is stored here.
//
// Request:  POST {"transcript": string, "part"?: number, "parts"?: number}
// Response: 200 {"summary": {key_points, decisions, action_items, numbers_and_dates, open_questions}}
//
// TODO before launch: abuse protection (Apple App Attest / DeviceCheck token,
// per-device rate limit). The Supabase anon key in the app is public by design.

import Anthropic from "npm:@anthropic-ai/sdk";

const MODEL = "claude-haiku-5-5";
const MAX_TRANSCRIPT_CHARS = 120_000; // the app chunks at 100k

// Keep in sync with lib/core/summary/summarizer.dart (summaryInstructions).
const SYSTEM_PROMPT = `You turn a meeting, lecture or talk transcript into notes.
Return ONLY a JSON object with exactly these keys:
{"key_points": [string], "decisions": [string],
 "action_items": [{"task": string, "owner": string or null, "due": string or null}],
 "numbers_and_dates": [string], "open_questions": [string]}
Rules:
- Keep people's names, numbers, amounts, dates, deadlines, votes and motions exactly as said.
- A decision is something the group agreed, approved, voted or settled. Include who moved or seconded a motion and the vote result when stated.
- Only fill "owner" when the transcript says who will do it. Only fill "due" when a date or deadline is said. Otherwise use null. Never invent an owner or a date.
- Do not add facts that are not in the transcript. If a list has nothing, return [].
- Write short, plain sentences in the language of the transcript.
- The transcript may come from speech recognition and contain errors; do not "fix" names or numbers by guessing.`;

// Structured output: the API constrains the reply to this schema.
const SUMMARY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["key_points", "decisions", "action_items", "numbers_and_dates", "open_questions"],
  properties: {
    key_points: { type: "array", items: { type: "string" } },
    decisions: { type: "array", items: { type: "string" } },
    action_items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["task", "owner", "due"],
        properties: {
          task: { type: "string" },
          owner: { type: ["string", "null"] },
          due: { type: ["string", "null"] },
        },
      },
    },
    numbers_and_dates: { type: "array", items: { type: "string" } },
    open_questions: { type: "array", items: { type: "string" } },
  },
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
const client = apiKey ? new Anthropic({ apiKey, maxRetries: 2 }) : null;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!client) return json(500, { error: "server_not_configured" });

  let body: { transcript?: unknown; part?: unknown; parts?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  const transcript = typeof body.transcript === "string" ? body.transcript : "";
  if (!transcript.trim()) return json(400, { error: "empty_transcript" });
  if (transcript.length > MAX_TRANSCRIPT_CHARS) return json(413, { error: "transcript_too_long" });
  const part = Number.isInteger(body.part) ? (body.part as number) : 1;
  const parts = Number.isInteger(body.parts) ? (body.parts as number) : 1;

  const header = parts > 1
    ? `This is part ${part} of ${parts} of a long transcript. Summarize only this part.\n\n`
    : "";

  try {
    const msg = await client.messages.create({
      model: MODEL,
      max_tokens: 8000,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: `${header}Transcript:\n${transcript}` }],
      output_config: {
        effort: "low",
        format: { type: "json_schema", schema: SUMMARY_SCHEMA },
      },
    });

    if (msg.stop_reason === "refusal") return json(422, { error: "refused" });
    if (msg.stop_reason === "max_tokens") return json(502, { error: "summary_too_long" });

    const text = msg.content
      .filter((b) => b.type === "text")
      .map((b) => (b as { text: string }).text)
      .join("");
    let summary: unknown;
    try {
      summary = JSON.parse(text);
    } catch {
      // The app parses defensively; pass the raw text through.
      summary = text;
    }
    // Do not log the transcript or the summary (privacy promise).
    return json(200, { summary });
  } catch (err) {
    if (err instanceof Anthropic.RateLimitError) return json(429, { error: "rate_limited" });
    if (err instanceof Anthropic.APIError) {
      console.error("anthropic_api_error", err.status);
      return json(502, { error: "upstream_error", status: err.status });
    }
    console.error("unexpected_error");
    return json(500, { error: "internal_error" });
  }
});
