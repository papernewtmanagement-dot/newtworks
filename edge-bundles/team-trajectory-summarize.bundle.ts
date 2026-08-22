// =========================================================================
// team-trajectory-summarize bundle (auto-generated)
// Source of truth: supabase/functions/team-trajectory-summarize/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py team-trajectory-summarize`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// ==================== _shared/supabase.ts ====================
// =========================================================================
// _shared/supabase.ts
// =========================================================================
// Canonical Supabase client + settings + response helpers for ALL Newtworks
// edge functions. Source of truth for code that used to be copy-pasted into
// every function (client creation, getSetting, jsonResponse, stripFences).
//
// Edge functions deploy as single-file bundles: `scripts/bundle_edge_fn.py`
// inlines this file into each function's bundle. Never edit a bundle by hand;
// edit here and rebundle every consumer.
// =========================================================================


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
// Two variants on purpose — they preserve the two behaviors that existed in
// the wild before consolidation:
//   getSetting        — THROWS if the settings table read itself errors
//                       (infra failure ≠ missing row). Use on critical paths.
//   getSettingOrNull  — swallows read errors, returns null. Use where the
//                       caller treats "can't read" the same as "not set".
// Both return null when the row simply doesn't exist.
// -------------------------------------------------------------------------

async function getSetting(
  agencyId: string,
  key: string,
): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(
      `settings read failed for agency ${agencyId} key ${key}: ${error.message}`,
    );
  }
  return data?.setting_value ?? null;
}

async function getSettingOrNull(
  agencyId: string,
  key: string,
): Promise<string | null> {
  try {
    const { data } = await sb
      .from("settings")
      .select("setting_value")
      .eq("agency_id", agencyId)
      .eq("setting_key", key)
      .maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) {
    return null;
  }
}

// Batch read — one query for N keys. Missing keys come back as null.
async function getSettings(
  agencyId: string,
  keys: string[],
): Promise<Record<string, string | null>> {
  const out: Record<string, string | null> = {};
  for (const k of keys) out[k] = null;
  const { data, error } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", keys);
  if (error) {
    throw new Error(`settings batch read failed for agency ${agencyId}: ${error.message}`);
  }
  for (const row of data ?? []) {
    out[(row as any).setting_key] = (row as any).setting_value ?? null;
  }
  return out;
}

// -------------------------------------------------------------------------
// HTTP responses
// -------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== _shared/llm.ts ====================
// =========================================================================
// _shared/llm.ts
// =========================================================================
// Canonical Groq chat caller for ALL Newtworks edge functions. Replaces the
// seven independent reimplementations that used to live in automation-runner,
// telegram, chatbot, team-trajectory-summarize, llm-queue-drainer,
// generate-custom-probes and document-processor/lib/llm.ts.
//
// Behavior knobs cover every existing call site:
//   temperature / maxTokens — per caller
//   jsonObject              — response_format {type:"json_object"} (runner style)
//   retries                 — retry 429/5xx with 500ms*2^n backoff (runner style)
//
// Returns the RAW assistant content string. JSON parsing of the content is
// the caller's job (some callers want text, some want JSON, some strip fences
// first). stripFences lives in _shared/supabase.ts.
// =========================================================================


const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";

// Reads settings.groq_model_default for the agency; falls back to
// LLM_MODEL_FALLBACK if the row is missing OR the settings read errors.
async function getDefaultModel(agencyId: string): Promise<string> {
  const v = await getSettingOrNull(agencyId, "groq_model_default");
  return (v && v.trim()) || LLM_MODEL_FALLBACK;
}

// settings.groq_api_key, then the GROQ_API_KEY env var, then null.
async function getGroqKey(agencyId: string): Promise<string | null> {
  const fromSettings = await getSettingOrNull(agencyId, "groq_api_key");
  if (fromSettings) return fromSettings;
  return Deno.env.get("GROQ_API_KEY") ?? null;
}

interface GroqChatResult {
  ok: boolean;
  raw: string;            // assistant content when ok, "" otherwise
  error: string | null;
  httpStatus: number;     // 0 on network failure
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function callGroqChat(opts: {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userContent: string;
  maxTokens?: number;      // default 4000
  temperature?: number;    // default 0.1
  jsonObject?: boolean;    // request response_format json_object
  retries?: number;        // extra attempts on 429/5xx; default 0
}): Promise<GroqChatResult> {
  const body: Record<string, unknown> = {
    model: opts.model,
    messages: [
      { role: "system", content: opts.systemPrompt },
      { role: "user", content: opts.userContent },
    ],
    temperature: opts.temperature ?? 0.1,
    max_tokens: opts.maxTokens ?? 4000,
  };
  if (opts.jsonObject) body.response_format = { type: "json_object" };

  const attempts = 1 + Math.max(0, opts.retries ?? 0);
  let lastErr = "unknown";
  let lastStatus = 0;

  for (let attempt = 0; attempt < attempts; attempt++) {
    let res: Response;
    try {
      res = await fetch(GROQ_ENDPOINT, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${opts.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
    } catch (e) {
      return { ok: false, raw: "", error: `Groq fetch failed: ${(e as Error).message}`, httpStatus: 0 };
    }
    lastStatus = res.status;

    if ((res.status === 429 || res.status >= 500) && attempt < attempts - 1) {
      lastErr = `Groq HTTP ${res.status}`;
      await sleep(500 * Math.pow(2, attempt));
      continue;
    }

    const text = await res.text();
    if (!res.ok) {
      return { ok: false, raw: "", error: `Groq HTTP ${res.status}: ${text.slice(0, 400)}`, httpStatus: res.status };
    }
    let parsed: any;
    try { parsed = JSON.parse(text); }
    catch (e) {
      return { ok: false, raw: text, error: `Groq returned non-JSON envelope: ${String(e)}`, httpStatus: res.status };
    }
    const content = parsed?.choices?.[0]?.message?.content ?? "";
    if (!content || typeof content !== "string") {
      return { ok: false, raw: "", error: "Groq returned empty content", httpStatus: res.status };
    }
    return { ok: true, raw: content, error: null, httpStatus: res.status };
  }

  return { ok: false, raw: "", error: `Groq exhausted retries: ${lastErr}`, httpStatus: lastStatus };
}

// ==================== _shared/auth.ts ====================
// =========================================================================
// _shared/auth.ts
// =========================================================================
// Canonical shared-secret gate for cron/internally-dispatched edge functions.
// The dispatch side (_dispatch_edge_fn, run_automation_recipe, automation-
// runner INTERNAL handlers) POSTs { agency_id, shared_secret } in the body;
// the secret must match settings.automation_runner_cron_secret.
//
// Usage in a handler:
//   const denied = await requireSharedSecret(agencyId, body.shared_secret);
//   if (denied) return denied;
// =========================================================================


async function requireSharedSecret(
  agencyId: string,
  provided: string | undefined | null,
): Promise<Response | null> {
  if (!provided) {
    return jsonResponse({ ok: false, error: "missing shared_secret" }, 401);
  }
  const expected = await getSettingOrNull(agencyId, "automation_runner_cron_secret");
  if (!expected || provided !== expected) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }
  return null;
}

// ==================== team-trajectory-summarize/index.ts ====================
// =========================================================================
// team-trajectory-summarize edge function (v2 — max_tokens 700)
// =========================================================================
// Reads the last 90 days of team_profile.behavioral_log for a team member, feeds
// them plus assessment context to Groq (openai/gpt-oss-120b), stores the
// 2-3 sentence synthesized "recent behavioral trajectory" summary in
// team_profile.trajectory_summary. Displayed in the Team/Members expanded row.
//
// v2 change: max_tokens raised from 400 to 700 after Peter's summary
// truncated mid-word on v1.
//
// AUTH: POST body must include shared_secret matching the agency's
// automation_runner_cron_secret setting.
//
// BODY:
//   Single member:  { agency_id, team_member_id, shared_secret }
//   Batch:          { agency_id, all_active: true, shared_secret }
// =========================================================================


const NOTES_LOOKBACK_DAYS = 90;
const LLM_MAX_TOKENS = 700;

interface PersonCtx {
  name: string;
  role: string | null;
  role_level: string | null;
  role_category: string | null;
  start_date: string | null;
  is_active: boolean;
}
interface AssessmentCtx {
  overall_score: number | null;
  reliability: string | null;
  notes: string | null;
  traits: Record<string, number | null>;
}
interface NoteCtx {
  observation_date: string;
  pattern_type: string | null;
  observation_text: string;
}

function monthsBetween(iso: string | null): number | null {
  if (!iso) return null;
  const t = new Date(iso + (iso.length === 10 ? "T00:00:00Z" : ""));
  if (!Number.isFinite(t.getTime())) return null;
  const diffMs = Date.now() - t.getTime();
  return Math.max(0, Math.floor(diffMs / (1000 * 60 * 60 * 24 * 30.42)));
}

function buildPrompt(p: PersonCtx, a: AssessmentCtx | null, notes: NoteCtx[]): { system: string; user: string } {
  const system = [
    "You are a management coach at an insurance agency, summarizing recent behavioral observations about one team member.",
    "Return exactly 2-3 sentences in plain prose. No markdown. No headers. No bullets. No lead-in like \"Based on the notes\".",
    "Synthesize the pattern — do not restate individual notes verbatim.",
    "Focus on: what's changing, what's stuck, and if warranted, one actionable note.",
    "Be direct and specific. Use the person's first name at most once.",
    "Do NOT invent specific timelines or policies (e.g. do NOT propose \"60-day PIP\" unless the notes explicitly reference one).",
  ].join(" ");

  const tenure = monthsBetween(p.start_date);
  const traitLines: string[] = [];
  if (a && a.traits) {
    for (const [k, v] of Object.entries(a.traits)) {
      if (v == null) continue;
      traitLines.push(`  ${k}: ${v}`);
    }
  }

  const rows: string[] = [];
  rows.push(`Person: ${p.name} — ${p.role_level ?? ""} ${p.role ?? ""} (${p.role_category ?? "?"} category)${tenure != null ? `, ~${tenure} months at agency.` : "."}`);
  if (a) {
    if (a.overall_score != null) {
      rows.push(`Assessment: overall ${a.overall_score}/100.`);
    }
    if (a.reliability) {
      rows.push(`Assessment meta: reliability=${a.reliability}.`);
    }
    if (traitLines.length > 0) {
      rows.push(`Trait scores (out of 100):\n${traitLines.join("\n")}`);
    }
    if (a.notes) {
      rows.push(`Assessment interpretation (context, do NOT quote): ${a.notes.slice(0, 800).replace(/\s+/g, " ").trim()}`);
    }
  }
  rows.push("");
  rows.push(`Recent behavioral observations, newest first (last ${NOTES_LOOKBACK_DAYS} days, ${notes.length} total):`);
  if (notes.length === 0) {
    rows.push("  (none recorded)");
  } else {
    for (const n of notes) {
      const text = (n.observation_text || "").replace(/\s+/g, " ").trim();
      rows.push(`- ${n.observation_date} [${n.pattern_type ?? "note"}] ${text}`);
    }
  }
  rows.push("");
  rows.push("Write the 2-3 sentence trajectory summary now.");

  return { system, user: rows.join("\n") };
}

async function callGroq(agencyId: string, systemPrompt: string, userContent: string): Promise<{ text: string; model: string } | { error: string }> {
  const groqKey = await getSettingOrNull(agencyId, "groq_api_key");
  if (!groqKey) return { error: "groq_api_key setting missing" };
  const model = await getDefaultModel(agencyId);
  const llm = await callGroqChat({
    apiKey: groqKey, model, systemPrompt, userContent,
    temperature: 0.2, maxTokens: LLM_MAX_TOKENS,
  });
  if (!llm.ok) return { error: llm.error ?? "Groq call failed" };
  const text = llm.raw.trim();
  if (!text) return { error: "Groq returned empty content" };
  return { text, model };
}

async function processMember(agencyId: string, teamMemberId: string): Promise<{ ok: true; upserted: any } | { ok: false; error: string }> {
  const { data: teamRow, error: teamErr } = await sb.from("team")
    .select("id, first_name, last_name, role, role_level, role_category, category, start_date, is_active, is_admin_backoffice, archived_at")
    .eq("id", teamMemberId).maybeSingle();
  if (teamErr || !teamRow) return { ok: false, error: `team fetch failed: ${teamErr?.message ?? "not found"}` };
  if (teamRow.is_admin_backoffice) return { ok: false, error: "team member is admin_backoffice — excluded" };
  if (!teamRow.is_active || teamRow.archived_at) return { ok: false, error: "team member not active" };

  const person: PersonCtx = {
    name: `${teamRow.first_name ?? ""} ${teamRow.last_name ?? ""}`.trim(),
    role: teamRow.role,
    role_level: teamRow.role_level,
    role_category: teamRow.role_category,
    start_date: teamRow.start_date,
    is_active: teamRow.is_active,
  };

  const { data: asmt } = await sb.from("hiring_candidates")
    .select("*").eq("agency_id", agencyId).eq("team_member_id", teamMemberId)
    .order("assessment_date", { ascending: false }).limit(1).maybeSingle();
  let assessment: AssessmentCtx | null = null;
  if (asmt) {
    assessment = {
      overall_score: asmt.overall_score,
      reliability: asmt.reliability,
      notes: asmt.notes,
      // Pruned 2026-08-06: the other seven trait columns were dropped from
      // hiring_candidates (migration 20260806170033), so only these two remain.
      // response_distortion dropped 2026-08-13 (dead legacy CTS field, never
      // populated by the current v2 ingestion path).
      traits: {
        assertiveness: asmt.assertiveness,
        compassion: asmt.compassion,
      },
    };
  }

  // Read behavioral_log from team_profile (folded from team_behavioral_notes on 2026-07-16).
  // Log is markdown, newest-first, with `## YYYY-MM-DD · pattern` headers.
  const { data: profile, error: profileErr } = await sb.from("team_profile")
    .select("behavioral_log")
    .eq("agency_id", agencyId).eq("team_member_id", teamMemberId).maybeSingle();
  if (profileErr) return { ok: false, error: `team_profile fetch failed: ${profileErr.message}` };

  // Parse markdown log into structured notes for the prompt. Header format:
  //   `## YYYY-MM-DD · pattern_type[ · source: X][ · **RESOLVED** date]\n<body>`
  // Entries separated by `\n\n---\n\n`.
  const cutoff = new Date(Date.now() - NOTES_LOOKBACK_DAYS * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const notes: NoteCtx[] = [];
  const logMd = (profile?.behavioral_log ?? "").trim();
  if (logMd) {
    for (const entry of logMd.split(/\n\n---\n\n/)) {
      const m = entry.match(/^## (\d{4}-\d{2}-\d{2}) · ([^\n·]+?)(?:\s*·[^\n]*)?\n([\s\S]*)$/);
      if (!m) continue;
      const [, date, pattern, body] = m;
      if (date < cutoff) continue;
      if (pattern.trim() === "termination") continue;
      notes.push({ observation_date: date, pattern_type: pattern.trim(), observation_text: body.trim() });
      if (notes.length >= 30) break;
    }
  }

  if (notes.length === 0 && !assessment) {
    return { ok: false, error: "no notes and no assessment — nothing to summarize" };
  }

  const { system, user } = buildPrompt(person, assessment, notes);
  const llm = await callGroq(agencyId, system, user);
  if ("error" in llm) return { ok: false, error: llm.error };

  const rangeStart = notes.length > 0 ? notes[notes.length - 1].observation_date : null;
  const rangeEnd   = notes.length > 0 ? notes[0].observation_date : null;

  // Write trajectory fields onto team_profile (row must exist; upsert on conflict for safety)
  const { data: upserted, error: upErr } = await sb.from("team_profile")
    .upsert({
      agency_id: agencyId,
      team_member_id: teamMemberId,
      trajectory_summary: llm.text,
      trajectory_notes_analyzed_count: notes.length,
      trajectory_notes_range_start: rangeStart,
      trajectory_notes_range_end: rangeEnd,
      trajectory_model_used: llm.model,
      trajectory_updated_at: new Date().toISOString(),
    }, { onConflict: "team_member_id" })
    .select().single();
  if (upErr) return { ok: false, error: `upsert failed: ${upErr.message}` };

  return { ok: true, upserted };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return jsonResponse({ error: "POST required" }, 405);

  let body: any;
  try { body = await req.json(); }
  catch { return jsonResponse({ error: "invalid JSON body" }, 400); }

  const agencyId: string | undefined = body?.agency_id;
  const teamMemberId: string | undefined = body?.team_member_id;
  const allActive: boolean = !!body?.all_active;
  const providedSecret: string | undefined = body?.shared_secret;

  if (!agencyId) return jsonResponse({ error: "agency_id required" }, 400);
  const denied = await requireSharedSecret(agencyId, providedSecret);
  if (denied) return denied;

  if (!teamMemberId && !allActive) {
    return jsonResponse({ error: "team_member_id or all_active=true required" }, 400);
  }

  if (allActive) {
    const { data: members, error: memErr } = await sb.from("team")
      .select("id").eq("agency_id", agencyId).eq("is_active", true)
      .eq("is_admin_backoffice", false).is("archived_at", null);
    if (memErr) return jsonResponse({ error: `member list failed: ${memErr.message}` }, 500);
    const results: any[] = [];
    for (const m of (members ?? [])) {
      const r = await processMember(agencyId, m.id as string);
      results.push({ team_member_id: m.id, ...r });
    }
    return jsonResponse({ mode: "all_active", count: results.length, results });
  }

  const r = await processMember(agencyId, teamMemberId!);
  return jsonResponse(r, "ok" in r && r.ok ? 200 : 500);
});
