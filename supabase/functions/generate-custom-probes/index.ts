// deno-lint-ignore-file no-explicit-any
// Edge function: generate-custom-probes  (v9.0 — manual-grounded Trait triggers)
//
// Changes from v8.0:
//   - Trait triggers section is now grounded in the Final Interview manual
//     (Suggs pool). The edge fn loads the manual page, detects this
//     candidate's trait triggers, extracts the matching sections, and feeds
//     them to the LLM as reference material with instructions to pick the
//     best 1-2 questions per trigger and reformat them as probes
//     (question/listen_for/concern/source).
//   - Trigger detection + section extraction logic mirrored from
//     CandidateDetail.jsx (kept in lockstep on trait bands + header names).
//   - Frontend "Assessment-Triggered · From Final Interview Manual" section
//     retired in commit 56840021 — trait-trigger content is now surfaced
//     ONLY through the LLM's "Trait triggers" section, in probe format.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GROQ_MODEL_FALLBACK = "openai/gpt-oss-120b";
const GROQ_ENDPOINT       = "https://api.groq.com/openai/v1/chat/completions";
const COMPOSIO_BASE       = "https://backend.composio.dev/api/v3/tools/execute";

// Interview time budget shipped 2026-07-17. Deep-dive = 35 min, ~3-4 min per probe → cap 10, hard max 12.
const TIME_BUDGET_MINUTES = 35;
const PROBE_COUNT_TARGET  = 10;
const PROBE_COUNT_HARD_MAX = 12;

// Final Interview manual page id (Suggs pool source-of-truth for trait triggers).
const FINAL_INTERVIEW_MANUAL_ID = "d83be3b8-55c9-4d60-9303-13a1f84141a8";

// Priority order for which sections survive when total exceeds hard-max.
// Higher = kept first when trimming. Resume signals are ONLY answerable by this specific
// candidate about their specific claims — highest per-probe information leverage.
const SECTION_PRIORITY: Record<string, number> = {
  "Resume signals":                100,
  "Character floor verification":   90,
  "Trait triggers":                 80,
  "Validity follow-up":             70,
  "Archetype probes":               60,
  "Motivation probe":               50,
  "Structure fit":                  40,
};

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
  const { data } = await supa.from("settings").select("setting_value").eq("agency_id", agencyId).eq("setting_key", key).maybeSingle();
  return data?.setting_value ?? null;
}

interface ComposioCallResult { ok: boolean; data: any; error: string | null; httpStatus: number; }

async function callComposio(opts: { apiKey: string; userId: string; connectedAccountId: string; toolSlug: string; toolArguments: Record<string, any>; }): Promise<ComposioCallResult> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: opts.userId, connected_account_id: opts.connectedAccountId, arguments: opts.toolArguments }),
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok ? null : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

function extractDriveFileId(url: string): string | null {
  if (!url) return null;
  const m1 = url.match(/\/file\/d\/([a-zA-Z0-9_-]{15,})/);
  if (m1) return m1[1];
  const m2 = url.match(/[?&]id=([a-zA-Z0-9_-]{15,})/);
  if (m2) return m2[1];
  return null;
}

async function composioDriveBytesToB64(composioData: any): Promise<{ ok: true; b64: string } | { ok: false; error: string }> {
  const s3url = composioData?.downloaded_file_content?.s3url ?? composioData?.file?.s3url;
  if (s3url) {
    try {
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
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

async function fetchResumeText(agencyId: string, resumeUrl: string | null, extractedText: string | null): Promise<{ text: string | null; source: string }> {
  // Prefer already-extracted text on hiring_candidates.resume_extracted_text (v8 addition — avoids re-downloading)
  if (extractedText && extractedText.trim().length > 0) {
    const capped = extractedText.length > 12000 ? extractedText.slice(0, 12000) + "\n[...truncated at 12000 chars]" : extractedText;
    return { text: capped, source: "extracted_text_column" };
  }
  if (!resumeUrl) return { text: null, source: "no_resume_url" };
  const fileId = extractDriveFileId(resumeUrl);
  if (!fileId) return { text: null, source: `unrecognized_url_shape:${resumeUrl.slice(0, 80)}` };
  const apiKey    = await getSetting(agencyId, "composio_api_key");
  const userId    = await getSetting(agencyId, "composio_user_id");
  const driveAcct = await getSetting(agencyId, "composio_googledrive_account_id");
  if (!apiKey || !userId || !driveAcct) return { text: null, source: "composio_drive_not_configured" };
  const dl = await callComposio({ apiKey, userId, connectedAccountId: driveAcct, toolSlug: "GOOGLEDRIVE_DOWNLOAD_FILE", toolArguments: { fileId } });
  if (!dl.ok) return { text: null, source: `drive_download_failed:${(dl.error || "").slice(0, 120)}` };
  const bytes = await composioDriveBytesToB64(dl.data);
  if (!bytes.ok) return { text: null, source: `bytes_unpack_failed:${bytes.error.slice(0, 120)}` };
  const ex = await extractPdfText(bytes.b64);
  if (!ex.ok) return { text: null, source: `pdf_extract_failed:${ex.error.slice(0, 120)}` };
  const capped = ex.text.length > 12000 ? ex.text.slice(0, 12000) + "\n[...truncated at 12000 chars]" : ex.text;
  return { text: capped, source: "drive_download" };
}

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

// ─── Trigger detection (mirrors CandidateDetail.jsx) ─────────────────
// Kept in lockstep with the frontend for consistent trigger identification.
// Bands (red/yellow) map to Final Interview manual sections via triggerToHeader.

interface Trigger { trait: string; value: number | string; severity: "red" | "yellow"; }

const TRAIT_BAND: Record<string, (v: number) => "green" | "yellow" | "red" | "none"> = {
  deadline_motivation: (v) => v == null ? "none" : v >= 70 ? "green" : v >= 50 ? "yellow" : "red",
  recognition_drive:   (v) => v == null ? "none" : v >= 50 ? "green" : v >= 30 ? "yellow" : "red",
  assertiveness:       (v) => v == null ? "none" : v >= 50 ? "green" : v >= 30 ? "yellow" : "red",
  independent_spirit:  (v) => v == null ? "none" : v >= 50 ? "green" : v >= 30 ? "yellow" : "red",
  analytical:          (v) => v == null ? "none" : v <= 60 ? "green" : v <= 70 ? "yellow" : "red",
  compassion:          (v) => v == null ? "none" : (v >= 30 && v <= 70) ? "green" : (v >= 20 && v <= 80) ? "yellow" : "red",
  self_promotion:      (v) => v == null ? "none" : (v >= 10 && v <= 80) ? "green" : (v >= 5  && v <= 89) ? "yellow" : "red",
  belief_in_others:    (v) => v == null ? "none" : (v >= 20 && v <= 80) ? "green" : (v >= 10 && v <= 90) ? "yellow" : "red",
  optimism:            (v) => v == null ? "none" : (v >= 20 && v <= 80) ? "green" : (v >= 10 && v <= 90) ? "yellow" : "red",
};

function detectTriggers(a: any): Trigger[] {
  const triggers: Trigger[] = [];
  for (const [trait, evaluator] of Object.entries(TRAIT_BAND)) {
    const v = a?.[trait];
    if (v == null) continue;
    const band = evaluator(Number(v));
    if (band === "red" || band === "yellow") {
      triggers.push({ trait, value: v, severity: band });
    }
  }
  const maxSpeed = Math.max(
    Number(a?.lss_math_speed_seconds) || 0,
    Number(a?.lss_verbal_speed_seconds) || 0,
    Number(a?.lss_problem_solving_speed_seconds) || 0,
  );
  if (maxSpeed > 60) triggers.push({ trait: "lss_speed", value: `${maxSpeed}s`, severity: "red" });
  const acc = a?.lss_total_accuracy;
  if (Number.isFinite(acc) && acc < 25)      triggers.push({ trait: "lss_accuracy", value: `${acc}/35`, severity: "red" });
  else if (Number.isFinite(acc) && acc < 35) triggers.push({ trait: "lss_accuracy", value: `${acc}/35`, severity: "yellow" });
  return triggers;
}

function triggerToHeader(trait: string, value: number): string | null {
  if (trait === "deadline_motivation" && value < 70) return "Low Deadline Motivation";
  if (trait === "recognition_drive"   && value < 50) return "Low Recognition Drive";
  if (trait === "assertiveness"       && value < 50) return "Low Assertiveness";
  if (trait === "independent_spirit"  && value < 50) return "Low Independent Spirit";
  if (trait === "analytical"          && value > 60) return "High Analytical";
  if (trait === "compassion"          && value < 30) return "Low Compassion";
  if (trait === "compassion"          && value > 70) return "High Compassion";
  if (trait === "self_promotion"      && value < 10) return "Low Self-Promotion";
  if (trait === "self_promotion"      && value > 80) return "High Self-Promotion";
  if (trait === "belief_in_others"    && value < 20) return "Low Belief in Others";
  if (trait === "belief_in_others"    && value > 80) return "High Belief in Others";
  if (trait === "optimism"            && value < 20) return "Low Optimism";
  if (trait === "optimism"            && value > 80) return "High Optimism";
  if (trait === "lss_speed" || trait === "lss_accuracy") return "LSS Speed";
  return null;
}

// Extract a subsection from Final Interview manual markdown by its ### header.
// Returns the raw markdown text from that header to the next ### or ## (exclusive).
function extractManualSection(markdown: string, headerText: string): string | null {
  if (!markdown || !headerText) return null;
  const lines = markdown.split("\n");
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("### ") && lines[i].includes(headerText)) { start = i; break; }
  }
  if (start === -1) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith("### ") || lines[i].startsWith("## ")) { end = i; break; }
  }
  return lines.slice(start, end).join("\n");
}

async function loadFinalInterviewManual(): Promise<string | null> {
  const { data, error } = await supa.from("manuals").select("content").eq("id", FINAL_INTERVIEW_MANUAL_ID).maybeSingle();
  if (error) { console.warn("manual load error:", error.message); return null; }
  return data?.content || null;
}

// For each trigger, look up the matching manual section. Returns array of
// { trait, value, severity, header, section_text } where section_text is the
// raw manual section (or null if not found).
function buildManualReference(triggers: Trigger[], manualMarkdown: string | null): Array<{ trait: string; value: number | string; severity: string; header: string | null; section_text: string | null }> {
  if (!manualMarkdown) return triggers.map(t => ({ ...t, header: null, section_text: null }));
  return triggers.map(t => {
    const numericValue = typeof t.value === "number" ? t.value : Number(String(t.value).replace(/[^0-9.-]/g, "")) || 0;
    const header = triggerToHeader(t.trait, numericValue);
    const section_text = header ? extractManualSection(manualMarkdown, header) : null;
    return { ...t, header, section_text };
  });
}

// Post-processing: enforce hard cap by dropping lowest-priority sections/probes first.
// Never touches question/listen_for/concern content; just trims the count.
function enforceProbeCap(probes: any): { trimmed: any; trim_note: string | null } {
  if (!Array.isArray(probes?.sections)) return { trimmed: probes, trim_note: null };
  const total = probes.sections.reduce((sum: number, s: any) => sum + (Array.isArray(s?.probes) ? s.probes.length : 0), 0);
  if (total <= PROBE_COUNT_HARD_MAX) return { trimmed: probes, trim_note: null };

  const sorted = [...probes.sections].sort((a: any, b: any) => {
    const pa = SECTION_PRIORITY[a?.focus] ?? 0;
    const pb = SECTION_PRIORITY[b?.focus] ?? 0;
    return pb - pa;
  });
  const kept: any[] = [];
  let runningCount = 0;
  const originalTotal = total;
  for (const section of sorted) {
    const probesArr = Array.isArray(section?.probes) ? section.probes : [];
    const remaining = PROBE_COUNT_HARD_MAX - runningCount;
    if (remaining <= 0) break;
    if (probesArr.length <= remaining) {
      kept.push(section);
      runningCount += probesArr.length;
    } else {
      kept.push({ ...section, probes: probesArr.slice(0, remaining) });
      runningCount = PROBE_COUNT_HARD_MAX;
      break;
    }
  }
  return {
    trimmed: { ...probes, sections: kept },
    trim_note: `trimmed from ${originalTotal} to ${runningCount} probes (hard cap ${PROBE_COUNT_HARD_MAX})`,
  };
}

const SYSTEM_PROMPT = `You are the intelligence layer of Newtworks, Peter Story's State Farm agency in San Antonio, TX. Your job right now is to compile CANDIDATE-SPECIFIC interview probe questions for the hiring pipeline. Peter or a Unit Manager will use these questions during the Final Interview.

INTERVIEW STRUCTURE (fixed — you are ONLY producing the deep-dive middle):
- 5 min: rapport + "any burning questions before we start?" (not your job)
- 5 min: warm-up structured questions — same 3 every candidate (not your job)
- 35 min: DEEP DIVE PROBES ← this is what you produce
- 10 min: candidate's questions for us (not your job)
- 5 min: close + next steps (not your job)

HARD CONSTRAINTS on your output:
- Target ${PROBE_COUNT_TARGET} total probes across all sections. Absolute max ${PROBE_COUNT_HARD_MAX}.
- Every probe averages 3-4 min to ask + probe. 12 probes = 36-48 min. Ten is the sweet spot.
- Never produce a generic probe just to fill a slot. If the data doesn't warrant a probe, don't invent one.

Framework context:
- The agency uses HireGauge (Suggs CTS + Story Agency calibration). CTS traits (deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism) each have ideal ranges. LSS measures problem-solving capacity. Reliability + response_distortion are validity band indicators (values: very high / high / moderate / low / very low).
- Character floor is non-negotiable at 7/10 across Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility (measured in interview scorecards, not CTS).
- Every hire participates in selling — even reception/retention seats. Every team member carries image-bearer dignity (Genesis 1:27) — probes should be direct but never demeaning.

Rules for the probes you produce:
1. Every probe must be traceable to a specific signal in the data you receive. Never invent generic screening questions. If the data doesn't support a section, omit it.
2. Group probes by focus. Priority order when picking what to include (fill from top down, stop at ${PROBE_COUNT_TARGET}-${PROBE_COUNT_HARD_MAX}):
   1. "Resume signals" — specific claims on the resume that need verification (biggest-account, promotion claims, gaps, self-superiority language). Highest per-probe leverage — only this candidate can answer these. Target 3-4.
   2. "Character floor verification" — only fire for character areas the CTS or framework flagged concerning. If nothing is concerning, skip this section entirely. Target 0-3.
   3. "Trait triggers" — see the TRAIT TRIGGER MANUAL REFERENCE block in the user message. PRODUCE EXACTLY 3-4 probes for this section when 3+ triggers exist; one probe per trigger when fewer triggers exist. Prioritize red-severity triggers over yellow. For each selected trigger, pick the single BEST question from its section_text (favor CORE bullets over *(optional)* italicized ones) and reformat verbatim or with light personalization. Suggs's wording is proven — favor it strongly over invention.
   4. "Validity follow-up" — moderate/low reliability or elevated distortion. Target 0-2.
   5. "Archetype probes" — archetype rule matches with high confidence. Target 0-2.
   6. "Motivation probe" — money_motivator match. Target 0-1.
   7. "Structure fit" — strategic_seat_pattern or clear autonomy/directive mismatch. Target 0-1.
3. Each probe object has: question (the exact question to ask), listen_for (what a genuine, encouraging answer sounds like), concern (what would signal a red flag or watch), source (a short tag pointing at the signal — e.g. "trait:analytical=75(high)", "framework:archetype:Warm Non-Starter", "validity:distortion=moderate", "resume:self-superiority-language", "manual:Low Deadline Motivation" when derived from the manual). ALL FOUR FIELDS ARE REQUIRED on every probe.
4. Do NOT include Title VII protected-class questions (race, religion, national origin, marital status, family status, disability, age).
5. Do NOT include SF compliance-restricted topics (specific product names, prices, internal SF processes like Scorecard/AIPP).
6. If the framework returned interview_probe strings for matched rules, use them as the starting anchor — personalize wording to this specific candidate's actual numbers and situation.
7. If resume text IS provided: Resume signals section MUST be included AND MUST be the top-priority section. Reference the exact resume phrasing when you can. Never collapse the entire output down to only resume signals — trait triggers and character floor concerns still need to be probed.
8. If resume text is unavailable, do NOT invent resume-specific probes. Note it in "notes" instead.
9. DO NOT include warm-up questions ("tell me about your last role", "why insurance", "why our agency"). Those are asked before the deep-dive. Your output is the deep-dive only.

TRAIT-TRIGGERS SECTION — how to use the manual reference:
- The user message includes a TRAIT TRIGGER MANUAL REFERENCE block per active trigger for this candidate.
- Each entry has: trait, value, severity (red/yellow), and section_text (markdown from the Final Interview manual with the questions Suggs wrote for that trigger pattern).
- The manual has CORE questions (bulleted) and OPTIONAL questions (marked with *(optional) ... *). Prefer CORE. Skip OPTIONAL unless it adds unique signal.
- For each SELECTED trigger, pick the single BEST question from that section_text — best = most likely to reveal genuine behavior vs rehearsed answer for THIS candidate. Do not pick multiple questions from a single trigger.
- Reformat as probe objects: question (verbatim or lightly personalized), listen_for (derived from context around the question in the section_text or from your understanding of the trait), concern (specific red flag for THAT question).
- source tag: "manual:<header>" e.g. "manual:Low Deadline Motivation". If you generate a fresh question because manual had no matching section, use the standard "trait:<name>=<value>(low/high)" tag.
- Do NOT include the whole manual section verbatim. Do NOT include the question stem "###" headers. Just extract the specific 1-2 best questions per trigger, formatted as probe objects.
- Total across the section: EXACTLY 3-4 probes when 3+ triggers exist; one probe per trigger otherwise. Prioritize red-severity triggers first, then yellow.

Style directives (agency voice):
- Direct, first-person plural: "We'd like to understand...", "Walk us through...", "Tell us about a time when..."
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
  "notes": "optional string — caveats about generation, e.g. 'resume text not available so no resume-signal probes included'"
}`;

async function generateProbes(context: any, groqKey: string, model: string): Promise<any> {
  const triggerRefBlock = context.manual_reference.length === 0
    ? "(no active trait triggers — skip the Trait triggers section)"
    : context.manual_reference.map((m: any) => {
        const label = `${m.trait} = ${m.value} (${m.severity})`;
        const hdr = m.header ? `manual header: "${m.header}"` : `(no matching manual header — generate candidate-specific probe from scratch)`;
        const body = m.section_text ? m.section_text : "(no matching manual section — invent a candidate-specific behavioral probe)";
        return `--- TRIGGER: ${label} · ${hdr} ---\n${body}`;
      }).join("\n\n");

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

TRAIT TRIGGER MANUAL REFERENCE (Suggs pool from Final Interview manual — pick the 1-2 best questions per trigger, reformat as probes):
${triggerRefBlock}

RESUME TEXT: ${context.resume_text ? context.resume_text : "(not available — do not fabricate resume-specific probes, note this in output.notes)"}

Generate the JSON now. Target ${PROBE_COUNT_TARGET} total probes, hard cap ${PROBE_COUNT_HARD_MAX}. Return only the JSON object, nothing else.`;

  const resp = await fetch(GROQ_ENDPOINT, {
    method: "POST",
    headers: { "Authorization": `Bearer ${groqKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model, temperature: 0.4, max_tokens: 2500,
      messages: [{ role: "system", content: SYSTEM_PROMPT }, { role: "user", content: userMsg }],
      response_format: { type: "json_object" },
    }),
  });
  if (!resp.ok) { const txt = await resp.text(); throw new Error(`Groq API ${resp.status}: ${txt.slice(0, 500)}`); }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (!content) throw new Error("Groq returned no content");
  let parsed: any;
  try { parsed = JSON.parse(content); }
  catch (e) { throw new Error("Groq output not valid JSON: " + (e as Error).message); }
  if (!Array.isArray(parsed?.sections)) throw new Error("Groq output missing 'sections' array");
  return parsed;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")    return json({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const assessmentId = body?.assessment_id;
    if (!assessmentId || typeof assessmentId !== "string") return json({ error: "assessment_id required (string)" }, 400);
    const { data: a, error: aErr } = await supa.from("hiring_candidates").select("*").eq("id", assessmentId).maybeSingle();
    if (aErr) return json({ error: "load candidate: " + aErr.message }, 500);
    if (!a)   return json({ error: "candidate not found" }, 404);
    const { data: fw, error: fwErr } = await supa.rpc("hiregauge_evaluate_candidate", { p_assessment_id: assessmentId });
    if (fwErr) console.warn("framework rpc error:", fwErr.message);
    const framework_readout = (Array.isArray(fw) && fw.length > 0)
      ? fw.map((r: any) => `  - [${r.out_rule_type}] ${r.out_rule_name} (${r.out_match_confidence || "?"}): ${r.out_short_label || ""}\n      probe: ${r.out_interview_probe || "(none)"}`).join("\n")
      : "(no framework rules matched)";
    const resumeFetch = await fetchResumeText(a.agency_id, a.resume_url, a.resume_extracted_text);

    // v9.0 addition: load Final Interview manual + detect this candidate's triggers
    // + build manual reference block for the Trait triggers section.
    const manualMarkdown = await loadFinalInterviewManual();
    const triggers = detectTriggers(a);
    const manual_reference = buildManualReference(triggers, manualMarkdown);

    const context = {
      candidate_name: [a.first_name, a.last_name].filter(Boolean).join(" ") || a.candidate_name || "Candidate",
      position: a.position, trait_readout: traitReadout(a), framework_readout,
      resume_text: resumeFetch.text, manual_reference, a,
    };
    const groqKey = await getSetting(a.agency_id, "groq_api_key");
    if (!groqKey) return json({ error: "settings.groq_api_key missing for agency" }, 500);
    const model = (await getSetting(a.agency_id, "groq_model_default")) || GROQ_MODEL_FALLBACK;
    const raw = await generateProbes(context, groqKey, model);
    const capped = enforceProbeCap(raw);
    const probes = capped.trimmed;

    // Stamp metadata
    probes.version              = 9.0;
    probes.model                = model;
    probes.resume_analyzed      = Boolean(context.resume_text);
    probes.resume_source        = resumeFetch.source;
    probes.resume_length_chars  = context.resume_text?.length ?? 0;
    probes.framework_matches_n  = Array.isArray(fw) ? fw.length : 0;
    probes.time_budget_minutes  = TIME_BUDGET_MINUTES;
    probes.probe_count_target   = PROBE_COUNT_TARGET;
    probes.probe_count_hard_max = PROBE_COUNT_HARD_MAX;
    probes.probes_total_count   = (probes.sections || []).reduce((s: number, sec: any) => s + (Array.isArray(sec?.probes) ? sec.probes.length : 0), 0);
    probes.triggers_analyzed_n  = triggers.length;
    probes.manual_loaded        = Boolean(manualMarkdown);
    probes.manual_sections_matched_n = manual_reference.filter(m => m.section_text).length;
    if (capped.trim_note) probes.trim_note = capped.trim_note;
    const nowIso = new Date().toISOString();
    const { error: uErr } = await supa.from("hiring_candidates").update({ custom_probes: probes, custom_probes_generated_at: nowIso }).eq("id", assessmentId);
    if (uErr) return json({ error: "persist: " + uErr.message }, 500);
    return json({ ok: true, custom_probes: probes, generated_at: nowIso });
  } catch (err: any) {
    console.error("generate-custom-probes error:", err);
    return json({ error: err?.message || String(err) }, 500);
  }
});
