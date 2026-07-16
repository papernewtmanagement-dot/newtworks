// deno-lint-ignore-file no-explicit-any
// Edge function: generate-custom-probes  (v7 — resume-text pipe added)
//
// v7 changes vs v6:
//   - Fetch resume text from a.resume_url when set (Drive View URL).
//   - Downloads via Composio GOOGLEDRIVE_DOWNLOAD_FILE, extracts with unpdf.
//   - Populates context.resume_text so LLM can produce resume-signal probes.
//   - Sets output.resume_source, resume_analyzed, resume_length_chars.
// v6 (prior) hardcoded resume_text=null → probes always "no_document_linked".
//
// Fallback path preserved: if agency has no composio drive account OR resume_url
// is not a recognizable Drive URL OR extraction fails, resume_text stays null
// and output.notes records why.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GROQ_MODEL_FALLBACK = "openai/gpt-oss-120b";
const GROQ_ENDPOINT       = "https://api.groq.com/openai/v1/chat/completions";
const COMPOSIO_BASE       = "https://backend.composio.dev/api/v3/tools/execute";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (o: any, s = 200) => new Response(JSON.stringify(o), {
  status: s,
  headers: { "Content-Type": "application/json", ...CORS_HEADERS },
});

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data } = await supa
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  return data?.setting_value ?? null;
}

// ---- Composio wrapper (mirrors document-processor lib/composio.ts) ----------

interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<ComposioCallResult> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: {
      "x-api-key": opts.apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      user_id: opts.userId,
      connected_account_id: opts.connectedAccountId,
      arguments: opts.toolArguments,
    }),
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok ? null : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

// ---- Resume URL → text pipe -------------------------------------------------

// Recognized Drive URL shapes:
//   https://drive.google.com/file/d/{ID}/view
//   https://drive.google.com/open?id={ID}
//   https://drive.google.com/uc?id={ID}
function extractDriveFileId(url: string): string | null {
  if (!url) return null;
  const m1 = url.match(/\/file\/d\/([a-zA-Z0-9_-]{15,})/);
  if (m1) return m1[1];
  const m2 = url.match(/[?&]id=([a-zA-Z0-9_-]{15,})/);
  if (m2) return m2[1];
  return null;
}

// Handle the response shapes Composio's Drive download returns:
//   1. { downloaded_file_content: { s3url: "..." } }  — actual shape for GOOGLEDRIVE_DOWNLOAD_FILE
//   2. { file: { s3url: "..." } }                     — Gmail attachment shape (fallback)
//   3. { file_content: "<base64>" }                   — inline for small files
//   4. { data: "<base64>" }                           — legacy inline shape
async function composioDriveBytesToB64(composioData: any): Promise<{ ok: true; b64: string } | { ok: false; error: string }> {
  const s3url = composioData?.downloaded_file_content?.s3url ?? composioData?.file?.s3url;
  if (s3url) {
    try {
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) {
        bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      }
      return { ok: true, b64: btoa(bin) };
    } catch (e) {
      return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  }
  const inline = composioData?.file_content ?? composioData?.data;
  if (typeof inline === "string" && inline.length > 0) return { ok: true, b64: inline };
  return { ok: false, error: "no s3url and no inline bytes on composio response" };
}

async function extractPdfText(bytesB64: string): Promise<{ ok: true; text: string } | { ok: false; error: string }> {
  try {
    const bin = atob(bytesB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const pdf = await getDocumentProxy(bytes);
    const { text } = await unpdfExtractText(pdf, { mergePages: true });
    const merged = Array.isArray(text) ? text.join("\n") : String(text ?? "");
    if (!merged.trim()) return { ok: false, error: "unpdf returned empty text (likely image-based PDF)" };
    return { ok: true, text: merged };
  } catch (e) {
    return { ok: false, error: `unpdf extraction failed: ${e instanceof Error ? e.message : String(e)}` };
  }
}

// Returns { text, source } where source describes provenance for output.notes.
// If no fetch is possible, text=null and source explains why.
async function fetchResumeText(agencyId: string, resumeUrl: string | null): Promise<{ text: string | null; source: string }> {
  if (!resumeUrl) return { text: null, source: "no_resume_url" };

  const fileId = extractDriveFileId(resumeUrl);
  if (!fileId) return { text: null, source: `unrecognized_url_shape:${resumeUrl.slice(0, 80)}` };

  const apiKey    = await getSetting(agencyId, "composio_api_key");
  const userId    = await getSetting(agencyId, "composio_user_id");
  const driveAcct = await getSetting(agencyId, "composio_googledrive_account_id");
  if (!apiKey || !userId || !driveAcct) return { text: null, source: "composio_drive_not_configured" };

  const dl = await callComposio({
    apiKey, userId, connectedAccountId: driveAcct,
    toolSlug: "GOOGLEDRIVE_DOWNLOAD_FILE",
    toolArguments: { fileId },
  });
  if (!dl.ok) return { text: null, source: `drive_download_failed:${(dl.error || "").slice(0, 120)}` };

  const bytes = await composioDriveBytesToB64(dl.data);
  if (!bytes.ok) return { text: null, source: `bytes_unpack_failed:${bytes.error.slice(0, 120)}` };

  const ex = await extractPdfText(bytes.b64);
  if (!ex.ok) return { text: null, source: `pdf_extract_failed:${ex.error.slice(0, 120)}` };

  // Cap resume text at ~12k chars to avoid blowing Groq TPM budget.
  const capped = ex.text.length > 12000 ? ex.text.slice(0, 12000) + "\n[...truncated at 12000 chars]" : ex.text;
  return { text: capped, source: "drive_download" };
}

// ---- Trait readout ---------------------------------------------------------

const TRAIT_IDEAL: Record<string, { min: number|null; max: number|null }> = {
  deadline_motivation: { min: 70,  max: null },
  recognition_drive:   { min: 50,  max: null },
  assertiveness:       { min: 50,  max: null },
  independent_spirit:  { min: 50,  max: null },
  analytical:          { min: null, max: 60 },
  compassion:          { min: 30,  max: 70 },
  self_promotion:      { min: 10,  max: 80 },
  belief_in_others:    { min: 20,  max: 80 },
  optimism:            { min: 20,  max: 80 },
};

function traitReadout(a: any): string {
  const lines: string[] = [];
  for (const [t, r] of Object.entries(TRAIT_IDEAL)) {
    const v = a?.[t];
    if (v == null) { lines.push(`  ${t}: —`); continue; }
    let flag = "in-ideal";
    if (r.min != null && v < r.min) flag = `LOW (ideal ≥${r.min})`;
    else if (r.max != null && v > r.max) flag = `HIGH (ideal ≤${r.max})`;
    lines.push(`  ${t}: ${v}  [${flag}]`);
  }
  return lines.join("\n");
}

const SYSTEM_PROMPT = `You are the intelligence layer of Newtworks, Peter Story’s State Farm agency in San Antonio, TX. Your job right now is to compile CANDIDATE-SPECIFIC interview probe questions for the hiring pipeline. Peter or Marie will use these questions during Video AMA (60-min Qualified Screen with Peter) or Final Interview (deeper dive with Unit Manager present).

Framework context:
- The agency uses HireGauge (Suggs CTS + Story Agency calibration). CTS traits (deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism) each have ideal ranges. LSS measures problem-solving capacity. Reliability + response_distortion are validity band indicators (values: very high / high / moderate / low / very low).
- Character floor is non-negotiable at 7/10 across Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility (measured in Video AMA + Final Interview scorecards, not CTS).
- Every hire participates in selling — even reception/retention seats. Every team member carries image-bearer dignity (Genesis 1:27) — probes should be direct but never demeaning.

Rules for the probes you produce:
1. Every probe must be traceable to a specific signal in the data you receive. Never invent generic screening questions. If the data doesn’t support a section, omit it.
2. Group probes by focus. Suggested groupings (include only where warranted): "Resume signals", "Character floor verification", "Trait triggers", "Archetype probes", "Motivation probe", "Structure fit", "Validity follow-up".
3. Each probe object has: question (the exact question to ask), listen_for (what a genuine, encouraging answer sounds like), concern (what would signal a red flag or watch), source (a short tag pointing at the signal — e.g. "trait:analytical=75(high)", "framework:archetype:Warm Non-Starter", "validity:distortion=moderate", "resume:self-superiority-language").
4. Do NOT include Title VII protected-class questions (race, religion, national origin, marital status, family status, disability, age).
5. Do NOT include SF compliance-restricted topics (specific product names, prices, internal SF processes like Scorecard/AIPP).
6. If the framework returned interview_probe strings for matched rules, use them as the starting anchor — personalize wording to this specific candidate’s actual numbers and situation.
7. If resume text IS provided: generate at least one "Resume signals" section with probes tied to specific claims (verifiable metric requests, scaffolded-career sourcing tests, self-superiority-language verification, gap explanation asks). Reference the exact resume phrasing when you can.
8. If resume text is unavailable, do NOT invent resume-specific probes. Note it in "notes" instead.

Style directives (agency voice):
- Direct, first-person plural: "We’d like to understand...", "Walk us through...", "Tell us about a time when..."
- Behavioral, not hypothetical: "Describe a specific instance where..." not "How would you handle..."
- Never HR-corporate filler. Bad: "At State Farm, we value teamwork — how do you demonstrate that?" Good: "Give us a recent example where a teammate got credit that could have been yours."
- Short questions. If the instinct is to compound-question, split into two probes.
- listen_for describes what a genuine answer sounds like — specifics vs. platitudes, ownership vs. blame, presence vs. rehearsed.
- concern names the specific red flag, not "poor answer".

Output requirements:
- Return ONLY valid JSON. No markdown fences, no preamble, no trailing prose.
- Match this exact shape:
{
  "sections": [
    { "focus": "string", "probes": [ { "question": "string", "listen_for": "string", "concern": "string", "source": "string" } ] }
  ],
  "notes": "optional string — caveats about generation, e.g. ‘resume text not available so no resume-signal probes included’"
}`;

async function generateProbes(context: any, groqKey: string, model: string): Promise<any> {
  const userMsg = `CANDIDATE: ${context.candidate_name}
POSITION APPLIED FOR: ${context.position || "(not specified)"}

CTS TRAIT SCORES (ideal ranges annotated):
${context.trait_readout}

LSS (accuracy / speed sec):
  math:   ${context.a.lss_math_accuracy ?? "—"} / ${context.a.lss_math_speed_seconds ?? "—"}s
  verbal: ${context.a.lss_verbal_accuracy ?? "—"} / ${context.a.lss_verbal_speed_seconds ?? "—"}s
  ps:     ${context.a.lss_problem_solving_accuracy ?? "—"} / ${context.a.lss_problem_solving_speed_seconds ?? "—"}s
  total:  ${context.a.lss_total_accuracy ?? "—"}/35

VALIDITY (band labels; framework validity_rule matches will fire if concerning):
  reliability: ${context.a.reliability ?? "—"}
  response_distortion: ${context.a.response_distortion ?? "—"}

CLAUDE RESUME SUMMARY (from intake analysis):
${context.a.claude_summary || "(no resume summary on file)"}

FRAMEWORK MATCHES (from hiregauge_evaluate_candidate):
${context.framework_readout}

RESUME TEXT: ${context.resume_text ? context.resume_text : "(not available — do not fabricate resume-specific probes, note this in output.notes)"}

Generate the JSON now. Return only the JSON object, nothing else.`;

  const resp = await fetch(GROQ_ENDPOINT, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${groqKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      temperature: 0.4,
      max_tokens: 2000,
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user",   content: userMsg },
      ],
      response_format: { type: "json_object" },
    }),
  });

  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(`Groq API ${resp.status}: ${txt.slice(0, 500)}`);
  }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (!content) throw new Error("Groq returned no content");

  let parsed: any;
  try { parsed = JSON.parse(content); }
  catch (e) { throw new Error("Groq output not valid JSON: " + (e as Error).message); }

  if (!Array.isArray(parsed?.sections)) {
    throw new Error("Groq output missing 'sections' array");
  }
  return parsed;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")    return json({ error: "POST only" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const assessmentId = body?.assessment_id;
    if (!assessmentId || typeof assessmentId !== "string") {
      return json({ error: "assessment_id required (string)" }, 400);
    }

    const { data: a, error: aErr } = await supa
      .from("team_assessments")
      .select("*")
      .eq("id", assessmentId)
      .maybeSingle();
    if (aErr) return json({ error: "load assessment: " + aErr.message }, 500);
    if (!a)   return json({ error: "assessment not found" }, 404);

    const { data: fw, error: fwErr } = await supa.rpc("hiregauge_evaluate_candidate", { p_assessment_id: assessmentId });
    if (fwErr) console.warn("framework rpc error:", fwErr.message);
    const framework_readout = (Array.isArray(fw) && fw.length > 0)
      ? fw.map((r: any) =>
          `  - [${r.out_rule_type}] ${r.out_rule_name} (${r.out_match_confidence || "?"}): ${r.out_short_label || ""}\n      probe: ${r.out_interview_probe || "(none)"}`
        ).join("\n")
      : "(no framework rules matched)";

    // v7: fetch resume text from resume_url when set (Drive View URL)
    const resumeFetch = await fetchResumeText(a.agency_id, a.resume_url);

    const context = {
      candidate_name: [a.first_name, a.last_name].filter(Boolean).join(" ") || a.candidate_name || "Candidate",
      position: a.position,
      trait_readout: traitReadout(a),
      framework_readout,
      resume_text: resumeFetch.text,
      a,
    };

    const groqKey = await getSetting(a.agency_id, "groq_api_key");
    if (!groqKey) return json({ error: "settings.groq_api_key missing for agency" }, 500);
    const model = (await getSetting(a.agency_id, "groq_model_default")) || GROQ_MODEL_FALLBACK;

    const probes = await generateProbes(context, groqKey, model);

    probes.version              = 7;
    probes.model                = model;
    probes.resume_analyzed      = Boolean(context.resume_text);
    probes.resume_source        = resumeFetch.source;
    probes.resume_length_chars  = context.resume_text?.length ?? 0;
    probes.framework_matches_n  = Array.isArray(fw) ? fw.length : 0;

    const nowIso = new Date().toISOString();
    const { error: uErr } = await supa
      .from("team_assessments")
      .update({
        custom_probes: probes,
        custom_probes_generated_at: nowIso,
      })
      .eq("id", assessmentId);
    if (uErr) return json({ error: "persist: " + uErr.message }, 500);

    return json({ ok: true, custom_probes: probes, generated_at: nowIso });
  } catch (err: any) {
    console.error("generate-custom-probes error:", err);
    return json({ error: err?.message || String(err) }, 500);
  }
});
