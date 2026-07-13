// deno-lint-ignore-file no-explicit-any
// Edge function: generate-custom-probes
//
// Given a team_assessments row id, produce a structured, candidate-specific set of
// interview probe questions. Writes result to team_assessments.custom_probes +
// team_assessments.custom_probes_generated_at.
//
// Model: Groq (agency default from settings.groq_model_default, fallback openai/gpt-oss-120b)
// Key:   settings.groq_api_key (agency-scoped)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GROQ_MODEL_FALLBACK = "openai/gpt-oss-120b";
const GROQ_ENDPOINT       = "https://api.groq.com/openai/v1/chat/completions";

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

async function fetchManualSnippets(): Promise<{ videoAMA: string; finalInterview: string; hiringPrep: string }> {
  const titles = ["Video AMA (Qualified Screen)", "Final Interview", "Hiring Prep"];
  const { data } = await supa
    .from("manuals")
    .select("title, content")
    .in("title", titles)
    .eq("manual_type", "admin");
  const byTitle: Record<string, string> = Object.fromEntries(
    (data || []).map((r: any) => [r.title, r.content || ""]),
  );
  return {
    videoAMA:       (byTitle["Video AMA (Qualified Screen)"] || "").slice(0, 2500),
    finalInterview: (byTitle["Final Interview"] || "").slice(0, 3000),
    hiringPrep:     (byTitle["Hiring Prep"] || "").slice(0, 1500),
  };
}

const SYSTEM_PROMPT = `You are the intelligence layer of Newtworks, Peter Story's State Farm agency in San Antonio, TX. Your job right now is to compile CANDIDATE-SPECIFIC interview probe questions for the hiring pipeline. Peter or Marie will use these questions during Video AMA or Final Interview.

Framework context:
- The agency uses HireGauge (Suggs CTS + Story Agency calibration). CTS traits (deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism) each have ideal ranges. LSS measures problem-solving capacity. Reliability + response_distortion are validity indicators (text bands: high/moderate/low, sometimes very high/very low).
- Character floor is non-negotiable at 7/10 across Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility (measured in Video AMA + Final Interview scorecards, not CTS).
- Every hire participates in selling — even reception/retention seats.
- Every team member carries image-bearer dignity (Genesis 1:27) — probes should be direct but never demeaning.

Rules for the probes you produce:
1. Every probe must be traceable to a specific signal in the data you receive. Never invent generic screening questions. If the data doesn't support a section, omit it.
2. Group probes by focus. Suggested groupings (include only where warranted): "Resume signals", "Character floor verification", "Trait triggers", "Archetype probes", "Motivation probe", "Structure fit", "Validity follow-up".
3. Each probe object has: question (the exact question to ask), listen_for (what a genuine, encouraging answer sounds like), concern (what would signal a red flag or watch), source (a short tag pointing at the signal — e.g. "trait:analytical=75(high)", "framework:archetype:Warm Non-Starter", "validity:distortion=moderate").
4. Do NOT include Title VII protected-class questions (race, religion, national origin, marital status, family status, disability, age).
5. Do NOT include SF compliance-restricted topics (specific product names, prices, internal SF processes like Scorecard/AIPP).
6. Voice: direct, agency-style, first-person plural ("we'd like to understand..."). Never corporate HR filler.
7. If the framework returned interview_probe strings for matched rules, use them as the starting anchor for probes in the relevant section — personalize wording to this specific candidate.
8. If resume text is unavailable, do NOT invent resume-specific probes. Note it in "notes" instead.

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
  const userMsg = `CANDIDATE: ${context.candidate_name}
POSITION APPLIED FOR: ${context.position || "(not specified)"}

CTS TRAIT SCORES (ideal ranges annotated):
${context.trait_readout}

LSS (accuracy / speed sec):
  math:   ${context.a.lss_math_accuracy ?? "—"}/? / ${context.a.lss_math_speed_seconds ?? "—"}s
  verbal: ${context.a.lss_verbal_accuracy ?? "—"}/? / ${context.a.lss_verbal_speed_seconds ?? "—"}s
  ps:     ${context.a.lss_problem_solving_accuracy ?? "—"}/? / ${context.a.lss_problem_solving_speed_seconds ?? "—"}s
  total:  ${context.a.lss_total_accuracy ?? "—"}/35

VALIDITY (band labels; framework validity_rule matches will fire if concerning):
  reliability: ${context.a.reliability ?? "—"}
  response_distortion: ${context.a.response_distortion ?? "—"}

CLAUDE RESUME SUMMARY (from intake analysis):
${context.a.claude_summary || "(no resume summary on file)"}

FRAMEWORK MATCHES (from hiregauge_evaluate_candidate):
${context.framework_readout}

REFERENCE — Video AMA question skeleton (do not duplicate; layer probes on top):
${context.manuals.videoAMA}

REFERENCE — Final Interview question skeleton with trait-triggered sections:
${context.manuals.finalInterview}

REFERENCE — Hiring Prep procedures:
${context.manuals.hiringPrep}

RESUME TEXT: ${context.resume_text ? context.resume_text : "(not available in v1 — do not fabricate resume-specific probes, note this in output.notes)"}

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

    const manuals = await fetchManualSnippets();

    const context = {
      candidate_name: [a.first_name, a.last_name].filter(Boolean).join(" ") || a.candidate_name || "Candidate",
      position: a.position,
      trait_readout: traitReadout(a),
      framework_readout,
      resume_text: null,
      manuals,
      a,
    };

    const groqKey = await getSetting(a.agency_id, "groq_api_key");
    if (!groqKey) return json({ error: "settings.groq_api_key missing for agency" }, 500);
    const model = (await getSetting(a.agency_id, "groq_model_default")) || GROQ_MODEL_FALLBACK;

    const probes = await generateProbes(context, groqKey, model);

    probes.version         = 1;
    probes.model           = model;
    probes.resume_analyzed = Boolean(context.resume_text);
    probes.framework_matches_n = Array.isArray(fw) ? fw.length : 0;

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
