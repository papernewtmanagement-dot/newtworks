// score-resume-rubric — Groq LLM scores a candidate's resume against
// the hiregauge_rules rubric (10 sub-signals + 5 informational screen rules).
//
// POST body:  { candidate_id: uuid, force?: boolean }
// Response:   { ok: true, composite, verdict, ... } | { ok: false, error }
//
// Idempotent: skips if res_scored_at IS NOT NULL unless force:true.
// Called by:  doc-processor (post resume_extracted_text landing) — wiring TBD
//             ad-hoc via curl / Supabase MCP for re-scoring
//
// Reuses openai/gpt-oss-120b via settings.groq_model_default (same model
// every other parser uses). Direct Groq HTTPS call, no Composio.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const MODEL_FALLBACK = "openai/gpt-oss-120b";
const MIN_RESUME_CHARS = 100;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "POST only" }, 405);
  }

  let body: { candidate_id?: string; force?: boolean } = {};
  try { body = await req.json(); } catch { /* empty body ok — will 400 below */ }

  const candidate_id = body.candidate_id;
  const force = body.force === true;

  if (!candidate_id) {
    return json({ ok: false, error: "candidate_id required in POST body" }, 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // --- 1. Load candidate + guards ---
  const { data: cand, error: candErr } = await supabase
    .from("hiring_candidates")
    .select("id, agency_id, candidate_name, resume_extracted_text, res_scored_at")
    .eq("id", candidate_id)
    .maybeSingle();

  if (candErr) return json({ ok: false, error: `candidate lookup: ${candErr.message}` }, 500);
  if (!cand)   return json({ ok: false, error: "candidate not found" }, 404);
  if (cand.agency_id !== AGENCY_ID) return json({ ok: false, error: "agency mismatch" }, 403);

  const resumeText = (cand.resume_extracted_text ?? "").trim();
  if (resumeText.length < MIN_RESUME_CHARS) {
    return json({ ok: false, error: `resume_extracted_text missing or <${MIN_RESUME_CHARS} chars` }, 400);
  }
  if (cand.res_scored_at && !force) {
    return json({
      ok: true,
      skipped: true,
      reason: "already scored; pass force:true to re-score",
      scored_at: cand.res_scored_at,
    });
  }

  // --- 2. Load rubric + screen rules + Groq config in parallel ---
  const [rubricRes, rulesRes, modelSetRes, keySetRes] = await Promise.all([
    supabase.from("hiregauge_rules")
      .select("short_label, trait_signature")
      .eq("agency_id", AGENCY_ID)
      .eq("rule_type", "resume_score_rubric"),
    supabase.from("hiregauge_rules")
      .select("short_label, description")
      .eq("agency_id", AGENCY_ID)
      .eq("rule_type", "resume_screen_signal"),
    supabase.from("settings")
      .select("setting_value")
      .eq("agency_id", AGENCY_ID)
      .eq("setting_key", "groq_model_default")
      .maybeSingle(),
    supabase.from("settings")
      .select("setting_value")
      .eq("agency_id", AGENCY_ID)
      .eq("setting_key", "groq_api_key")
      .maybeSingle(),
  ]);

  const rubricRows = rubricRes.data ?? [];
  const screenRules = rulesRes.data ?? [];
  const model = (modelSetRes.data?.setting_value ?? "").trim() || MODEL_FALLBACK;
  const groqKey = (keySetRes.data?.setting_value ?? "").trim();

  if (!groqKey) return json({ ok: false, error: "groq_api_key missing in public.settings" }, 500);

  const configRow = rubricRows.find((r: any) => r.trait_signature?.construct === "config");
  const subsignalRows = rubricRows.filter((r: any) => r.trait_signature?.construct !== "config");

  if (!configRow || subsignalRows.length === 0) {
    return json({
      ok: false,
      error: `rubric structure invalid (found ${rubricRows.length} rows, expected 1 config + N sub-signals)`,
    }, 500);
  }

  const config = configRow.trait_signature as any;
  const weights = config.construct_weights as { nature: number; nurture: number; drivers: number };
  const thresholds = config.verdict_thresholds as { pass: string; consider: string; decline: string };

  const validSubsignalLabels = new Set(subsignalRows.map((r: any) => r.short_label as string));
  const validScreenLabels = new Set(screenRules.map((r: any) => r.short_label as string));

  // --- 3. Build the Groq prompt ---
  const userPrompt = buildScoringPrompt(
    cand.candidate_name || "(name unknown)",
    resumeText,
    subsignalRows,
    screenRules,
  );

  // --- 4. Call Groq (with retry-on-429; TPM limit is 8000/min, one call is ~4200) ---
  const MAX_ATTEMPTS = 5;
  let groqRes: Response | null = null;
  let lastErrText = "";
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    groqRes = await fetch(GROQ_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${groqKey}`,
      },
      body: JSON.stringify({
        model,
        temperature: 0.1, // low variance — this is scoring, not creative
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: userPrompt },
        ],
      }),
    });
    if (groqRes.ok) break;
    lastErrText = await groqRes.text();
    if (groqRes.status !== 429 || attempt === MAX_ATTEMPTS) break;
    // Parse "try again in X.Xs" from body; default to 15s. Add 0-8s jitter to
    // avoid thundering-herd on parallel invocations sharing the same TPM bucket.
    const m = lastErrText.match(/try again in ([\d.]+)s/i);
    const retryAfterSec = m ? Math.min(60, parseFloat(m[1])) : 15;
    const jitterSec = Math.random() * 8;
    await new Promise((r) => setTimeout(r, (retryAfterSec + jitterSec) * 1000));
  }

  if (!groqRes || !groqRes.ok) {
    return json({
      ok: false,
      error: `Groq HTTP ${groqRes?.status ?? "no-response"} after retries: ${lastErrText.slice(0, 400)}`,
    }, 502);
  }

  const groqData = await groqRes.json();
  const rawContent = groqData.choices?.[0]?.message?.content ?? "";

  let parsed: any;
  try {
    parsed = JSON.parse(rawContent);
  } catch (e) {
    return json({
      ok: false,
      error: `Groq returned non-JSON: ${String(e)}`,
      raw_preview: String(rawContent).slice(0, 500),
    }, 502);
  }

  // --- 5. Validate LLM response ---
  const subsignals = parsed.subsignals as Record<string, { score: number; reasoning: string }>;
  let rules_fired = (parsed.rules_fired ?? []) as string[];

  if (!subsignals || typeof subsignals !== "object") {
    return json({ ok: false, error: "LLM response missing subsignals object" }, 502);
  }

  // Every configured sub-signal must have a valid 1-10 score
  const constructScores: Record<string, number[]> = { nature: [], nurture: [], drivers: [] };
  for (const sub of subsignalRows as any[]) {
    const label = sub.short_label as string;
    const construct = sub.trait_signature?.construct as string;
    const s = subsignals[label];
    if (!s || typeof s.score !== "number" || !Number.isFinite(s.score) || s.score < 1 || s.score > 10) {
      return json({
        ok: false,
        error: `LLM did not return a valid 1-10 score for sub-signal "${label}"`,
        got: s ?? null,
      }, 502);
    }
    if (constructScores[construct]) constructScores[construct].push(s.score);
  }

  // Drop any rules_fired the LLM invented (not in our seeded set)
  rules_fired = Array.isArray(rules_fired)
    ? rules_fired.filter((r) => typeof r === "string" && validScreenLabels.has(r))
    : [];

  // --- 6. Compute construct means + weighted composite + verdict ---
  const natureMean  = mean(constructScores.nature);
  const nurtureMean = mean(constructScores.nurture);
  const driversMean = mean(constructScores.drivers);

  const composite = round2(
    natureMean * weights.nature +
    nurtureMean * weights.nurture +
    driversMean * weights.drivers
  );

  let verdict: "pass" | "consider" | "decline";
  if (composite >= 7.0) verdict = "pass";
  else if (composite >= 5.0) verdict = "consider";
  else verdict = "decline";

  // --- 7. Write back ---
  // Also overwrite the smallint res_nature/res_nurture/res_drivers columns
  // with rounded construct means so legacy readers see the current-formula values.
  const { error: updErr } = await supabase
    .from("hiring_candidates")
    .update({
      res_composite: composite,
      res_verdict: verdict,
      res_subsignals: subsignals,
      res_rules_fired: rules_fired,
      res_scored_at: new Date().toISOString(),
      res_scored_model: model,
      res_nature:  clampSmallint(natureMean),
      res_nurture: clampSmallint(nurtureMean),
      res_drivers: clampSmallint(driversMean),
    })
    .eq("id", candidate_id);

  if (updErr) {
    return json({ ok: false, error: `DB write failed: ${updErr.message}` }, 500);
  }

  return json({
    ok: true,
    candidate_id,
    candidate_name: cand.candidate_name,
    composite,
    verdict,
    construct_means: {
      nature: round2(natureMean),
      nurture: round2(nurtureMean),
      drivers: round2(driversMean),
    },
    rules_fired,
    model,
    subsignals_count: Object.keys(subsignals).length,
    thresholds,
  });
});

// -------------- helpers --------------

function mean(nums: number[]): number {
  if (!nums.length) return 0;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

function clampSmallint(n: number): number {
  return Math.max(1, Math.min(10, Math.round(n)));
}

function json(bodyObj: unknown, status = 200): Response {
  return new Response(JSON.stringify(bodyObj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const SYSTEM_PROMPT =
  `You are a resume-screening evaluator for a State Farm insurance agency in ` +
  `San Antonio, TX. You score candidates against a fixed rubric of nine ` +
  `sub-signals across three constructs (Nature, Nurture, Drivers) to help ` +
  `decide who advances to formal personality assessment.

Hard constraints:
- You do NOT make character judgments at this layer. Character floors are ` +
  `evaluated downstream via personality assessment, interview, and reference ` +
  `check. Your job is to score the sub-signals as defined.
- Every reasoning must cite specific evidence from the resume text: a role, ` +
  `tenure length, credential, phrase, or a specific absence of expected ` +
  `evidence. No generic reasoning.
- Score each sub-signal independently. Do not average — that happens ` +
  `downstream from your output.
- Return ONLY the JSON object specified in the user prompt, nothing else.`;

function buildScoringPrompt(
  candidateName: string,
  resumeText: string,
  subsignalRows: Array<{ short_label: string; trait_signature: any }>,
  screenRules: Array<{ short_label: string; description: string }>,
): string {
  const subsigSection = subsignalRows.map((s) => {
    const ts = s.trait_signature;
    return `### ${s.short_label} (${ts.construct})
Anchor calibration:
- 1-2 (low): ${ts.anchor_low.evidence} [example candidate: ${ts.anchor_low.candidate}]
- 5 (mid): ${ts.anchor_mid.evidence} [example candidate: ${ts.anchor_mid.candidate}]
- 9-10 (high): ${ts.anchor_high.evidence} [example candidate: ${ts.anchor_high.candidate}]

Positive markers (raise score):
${(ts.markers_positive as string[]).map((m) => `- ${m}`).join("\n")}

Negative markers (lower score):
${(ts.markers_negative as string[]).map((m) => `- ${m}`).join("\n")}`;
  }).join("\n\n");

  const screenSection = screenRules.map((r) =>
    `- **${r.short_label}**: ${r.description}`
  ).join("\n");

  const jsonTemplate = subsignalRows.map((s) =>
    `    "${s.short_label}": { "score": 0, "reasoning": "one sentence citing specific resume evidence" }`
  ).join(",\n");

  return `# Candidate: ${candidateName}

## Task
Score this candidate against the rubric below using ONLY evidence in the resume text at the bottom. Every sub-signal score is an integer 1–10.

## Rubric

${subsigSection}

## Screen-signal rules (informational only, no composite effect)

For each rule below, decide whether the resume matches the pattern described. If it does, include the rule's short_label in the rules_fired array in your output. If no rules match, return an empty array.

${screenSection}

## Resume text

\`\`\`
${resumeText}
\`\`\`

## Output format

Return ONLY this JSON object — no prose, no markdown fencing:

{
  "subsignals": {
${jsonTemplate}
  },
  "rules_fired": []
}`;
}
