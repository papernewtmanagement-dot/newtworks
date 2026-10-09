// =========================================================================
// parsers/cts_profile.ts
// =========================================================================
// Reads a CTS Sales Profile report PDF (vendor: SalesManage Solutions,
// ctssalesprofile.com) and turns it into the payload record_cts_result()
// expects. The document arrives in the inbox as an attachment, gets filed to
// Drive by the normal attachment path, and lands here.
//
// WHY AN LLM AND NOT A REGEX
// The PDF is a laid-out form, not a text document, so the extracted text
// interleaves values and labels in an order that has nothing to do with
// reading order. The nine primary trait scores come out attached to the NEXT
// trait's label:
//
//   Deadline Motivation ?
//   81Recognition Drive ? 92Assertiveness ? 69Independent Spirit ? ...
//
// while the nine competency scores come out attached to their OWN label, and
// the reliability value is a bare word buried inside a paragraph explaining
// what the three possible words mean. A positional regex over that is a
// silent-wrong-answer machine the first time the vendor reflows the page.
// So: the LLM reads it, and then deterministic checks reject anything that
// does not look like a real report. A refused read is fine — the Record CTS
// Result form on the candidate page is the fallback, and record_cts_result()
// itself refuses a payload that is missing most of the primary traits.
//
// WHAT IS DELIBERATELY NOT READ
// Peter ruling 2026-09-16: the recommended coaching hours and the headline
// overall score (the vendor's combined CTS+LSS figure) are useless to him.
// They are not extracted and not stored. Do not add them back because the
// report prints them prominently - that is exactly why they were called out.
// The CTS-only score, ego drive and empathy are separate figures and are kept.
// =========================================================================

import { sb } from "../../_shared/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

// The vendor's own labels, in the vendor's own order, snake_cased. Order
// matters: it is what the LLM is told to read down the page, and it is the
// count the validator checks.
export const CTS_PRIMARY_TRAITS = [
  "deadline_motivation",
  "recognition_drive",
  "assertiveness",
  "independent_spirit",
  "analytical",
  "compassion",
  "self_promotion",
  "belief_in_others",
  "optimism",
] as const;

export const CTS_SALES_COMPETENCIES = [
  "maintains_high_activity",
  "handles_rejection",
  "prospects_in_community",
  "dials_cold_calls",
  "listens_discovers_needs",
  "presents_solutions",
  "gets_decisions_handles_objections_referrals",
  "receives_coaching",
  "positively_influences_team",
] as const;

const CTS_LSS_SECTIONS = ["math", "verbal", "problem_solving"] as const;

const CTS_VALIDITY_WORDS = ["low", "moderate", "high"];

export interface CtsParseInput {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string | null;
  reportText: string;
  fileName: string;
}

export interface CtsParseOk {
  ok: true;
  candidateName: string | null;
  reportDate: string | null;
  payload: Record<string, unknown>;
}
export interface CtsParseFail {
  ok: false;
  candidateName: string | null;
  error: string;
}
export type CtsParseResult = CtsParseOk | CtsParseFail;

const SYSTEM_PROMPT_CTS_PROFILE = `You read one CTS Sales Profile report and return its scores as JSON.

The text you are given came out of a laid-out PDF, so values and labels are
often separated or run together out of reading order. The same report can
come out in either of two layouts, so work out which one you have before
reading any score.

1. The "Primary Traits" block has exactly nine traits, always in this order:
   Deadline Motivation, Recognition Drive, Assertiveness, Independent Spirit,
   Analytical, Compassion, Self-Promotion, Belief in Others, Optimism.
   Layout A: each score runs into the NEXT trait's label, so in
     "Deadline Motivation ? 81Recognition Drive ? 92Assertiveness ?"
     Deadline Motivation is 81 and Recognition Drive is 92.
   Layout B: the nine labels are printed together with no numbers
     ("Deadline Motivation ? Recognition Drive ? ... Optimism ?") and the nine
     scores appear somewhere else as ONE run of nine numbers in the same order,
     usually right after the coaching-hours figure. So in
     "8 - 12HRS/MONTH 9 73 52 31 94 32 100 77 78"
     Deadline Motivation is 9, Recognition Drive 73, Assertiveness 52,
     Independent Spirit 31, Analytical 94, Compassion 32, Self-Promotion 100,
     Belief in Others 77, Optimism 78. The "8 - 12" is coaching hours, not a
     trait score.

2. The "Sales Competencies" block has exactly nine competencies, always in
   this order:
   Maintains High Activity, Handles Rejection, Prospects in Community,
   Dials / Cold Calls, Listens / Discovers Needs, Presents Solutions,
   Gets Decisions / Handles Objections / Referrals (newer reports print it as
   "Handles Objections, Gets Decisions / Referrals / Reviews"),
   Receives Coaching, Positively Influences Team (sometimes misspelled
   "Posivitely").
   Layout A: each score appears right AFTER its own label, run together with
   the description that follows it.
   Layout B: the scores appear as ONE run of nine numbers in the same order,
   usually at the very end just before the copyright line, e.g.
   "35 68 60 68 52 70 71 46 78 (c) 2024 SalesManage Solutions."

The Reliability and Response Distortion results are each a single word - low,
moderate or high. The report prints them in a gutter beside the paragraph
that explains what all three words mean, so in the text each one lands as a
stray capitalised word that breaks the sentence it is sitting inside. Find
the word that does not belong to the sentence around it. Two real examples:

  "...Do not use these results. Moderate"
      -> Reliability is moderate

  "...an open and vulnerable Low  personality that usually recognizes..."
      -> Response Distortion is low

The word that opens each bullet ("Low Reliability indicates",
"Moderate Reliability suggests", "High Response Distortion Indicates") is
part of the explanation and is never the result.

In Layout B the two words usually sit right after their index names near
the top of the report, e.g. "Response Distortion Low Score 41moderate
Coaching Reliability High": Response Distortion is low, Reliability is high.
A word glued to the overall score ("Score 41moderate") belongs to that score
and is never a validity result.

The LSS tables have three numbers per row in this column order:
ideal minimum, ideal maximum, candidate. Accuracy rows are counts. Speed rows
are seconds. In Layout B the table numbers come out as one run in row order:
accuracy math, verbal, problem solving (three each), then the total (ideal
minimum such as "25+", then the candidate's total), then speed math, verbal,
problem solving (three each). So
"10 11 10 8 10 12 7 9 9 25+ 31 32 50 36 20 52 30 17 77 29" means math
accuracy 10-11 ideal, candidate 10 ... total ideal 25, candidate 31 ... problem
solving speed 17-77 ideal, candidate 29.

Return ONLY this JSON object. No prose, no markdown fences.

{
  "candidate_name": string,
  "report_date": "YYYY-MM-DD",
  "ego_drive": number,
  "empathy": number,
  "reliability": "low"|"moderate"|"high",
  "response_distortion": "low"|"moderate"|"high",
  "primary_traits": {
    "deadline_motivation": number, "recognition_drive": number,
    "assertiveness": number, "independent_spirit": number,
    "analytical": number, "compassion": number,
    "self_promotion": number, "belief_in_others": number,
    "optimism": number
  },
  "sales_competencies": {
    "maintains_high_activity": number, "handles_rejection": number,
    "prospects_in_community": number, "dials_cold_calls": number,
    "listens_discovers_needs": number, "presents_solutions": number,
    "gets_decisions_handles_objections_referrals": number,
    "receives_coaching": number, "positively_influences_team": number
  },
  "lss_accuracy": {
    "math": {"ideal_min": number, "ideal_max": number, "candidate": number},
    "verbal": {"ideal_min": number, "ideal_max": number, "candidate": number},
    "problem_solving": {"ideal_min": number, "ideal_max": number, "candidate": number},
    "total": {"ideal_min": number, "max_possible": number, "candidate": number}
  },
  "lss_speed": {
    "math": {"ideal_min": number, "ideal_max": number, "candidate": number},
    "verbal": {"ideal_min": number, "ideal_max": number, "candidate": number},
    "problem_solving": {"ideal_min": number, "ideal_max": number, "candidate": number}
  }
}

Ignore the headline overall score (the combined CTS+LSS figure) and the
recommended coaching hours. They are not wanted and have no place in the JSON.

If a value genuinely is not in the text, use null for it. Never guess a score.`;

/**
 * Candidate name straight out of the report header, before the LLM runs.
 * Three shapes, in order of trust:
 *   "Sales Profile Report for <Name> Jul, 14 2026"
 *   "Sales Profile Report Sep, 19 2026 for <Name>"  (date first, added 2026-09-26)
 *   filename "CTS Profile - <Name> - 20260714.pdf"
 * Used to cross-check whatever the LLM says the name is, so a hallucinated
 * name cannot quietly attach a report to the wrong person.
 */
export function ctsNameFromReport(text: string, fileName: string): string | null {
  const m = text.match(
    /Sales Profile Report for\s+([A-Za-z][A-Za-z'.\-]*(?:\s+[A-Za-z][A-Za-z'.\-]*){0,3})\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/i,
  );
  if (m) return m[1].trim();

  // Date printed BEFORE the name: "Sales Profile Report ... Sep, 19 2026 for
  // Gamliela Tolbert Score SF Sales (Likert)". Some PDF text readers lay the
  // vendor header out in this order. Name words must start with a capital, and
  // the first word of the form's next line ends the name.
  const d = text.match(
    /Sales Profile Report[\s\S]{0,60}?(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?,?\s+\d{1,2},?\s+\d{4}\s+for\s+((?:(?!Score\b|Learning\b|Supplemental\b|The\b)[A-Z][A-Za-z'.\-]*[ \t]*){1,4})/,
  );
  if (d) return d[1].trim();

  const f = ctsFileBase(fileName).match(
    /^(?:CTS\s*Profile|Sales\s*Profile(?:\s*Report)?)\s*-\s*(.+?)\s*-\s*\d{6,8}/i,
  );
  if (f) return f[1].trim();
  return null;
}

function ctsFileBase(p: string): string {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
}

function ctsNum(v: unknown): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(String(v).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(n) ? n : null;
}

function ctsScore0to100(v: unknown): number | null {
  const n = ctsNum(v);
  if (n === null) return null;
  return n >= 0 && n <= 100 ? n : null;
}

/**
 * Pull the Reliability / Response Distortion result out of the report text
 * directly.
 *
 * Both are printed in a gutter next to the paragraph explaining what the
 * three possible words mean, so the extracted text carries the result as a
 * stray word wedged into a sentence it does not belong to, surrounded by
 * three decoy uses of the same vocabulary. The decoys are identifiable: every
 * one of them is immediately followed by the name of the index it explains
 * ("Low Reliability indicates...", "High Response Distortion Indicates...").
 * Anything else is the result.
 *
 * This is a backstop, not the primary read - the model gets asked first. It
 * exists because these two fields sit behind the same prose in every report,
 * so a model that misses them once will miss them every time, and a validity
 * index that silently reads null is worse than useless: low reliability means
 * the vendor's own instruction is to throw the results away.
 */
export function ctsValidityFromText(text: string, index: "Reliability" | "Response Distortion"): string | null {
  const start = text.search(new RegExp(`The\\s+${index}\\s+Index`, "i"));
  if (start < 0) return null;
  // The reliability block runs until the distortion block starts; the
  // distortion block runs to the end of that section of the page.
  const rest = text.slice(start);
  const end = index === "Reliability"
    ? rest.search(/The\s+Response\s+Distortion\s+Index/i)
    : -1;
  const block = end > 0 ? rest.slice(0, end) : rest;

  const re = /\b(Low|Moderate|High)\b(?!\s+(?:Reliability|Response\s+Distortion))/g;
  const m = re.exec(block);
  return m ? m[1].toLowerCase() : null;
}

/**
 * Validity word printed right after its index name, the way Layout B reports
 * put it near the top: "Response Distortion Low ... Reliability High"
 * (Gamliela Tolbert's report, 2026-09-26). The explanation bullets never match
 * this - they read "Low Reliability indicates", word BEFORE the name - so this
 * only fires on the real result. Checked BEFORE the model's answer because it
 * is an exact label-and-word read, and "Score 41moderate" sitting between the
 * two is exactly the kind of decoy a model can grab.
 */
export function ctsValidityFromHeader(text: string, index: "Reliability" | "Response Distortion"): string | null {
  const name = index === "Reliability" ? "Reliability" : "Response\\s+Distortion";
  const m = text.match(new RegExp(`\\b${name}\\s+(Low|Moderate|High)\\b`, "i"));
  return m ? m[1].toLowerCase() : null;
}

/**
 * Layout B prints all nine scores of a block as one run of nine numbers
 * (see the prompt). When that run is in the text it is used to CROSS-CHECK the
 * model's read - never as the read itself. A read that disagrees with the
 * report's own run is refused, so a mis-assigned score cannot reach a
 * candidate. No run found (Layout A) means no check.
 */
export function ctsScoreRun(text: string, block: "traits" | "competencies"): number[] | null {
  const run = "((?:\\d{1,3}\\s+){8}\\d{1,3})(?!\\s*\\d)";
  const re = block === "traits"
    ? new RegExp(`HRS\\s*/\\s*MONTH\\s*${run}`, "i")
    : new RegExp(`${run}\\s*(?:\\u00a9|\\(c\\))\\s*\\d{4}\\s*SalesManage`, "i");
  const m = text.match(re);
  if (!m) return null;
  const nums = m[1].trim().split(/\s+/).map(Number);
  return nums.length === 9 && nums.every((n) => Number.isInteger(n) && n >= 0 && n <= 100) ? nums : null;
}

function ctsRunMismatch(
  text: string, block: "traits" | "competencies",
  keys: readonly string[], got: Record<string, number | null>,
): string | null {
  const run = ctsScoreRun(text, block);
  if (!run) return null;
  if (keys.every((k, i) => got[k] === run[i])) return null;
  return `${block} read ${keys.map((k) => got[k] ?? "-").join(" ")} does not match the report's own run ${run.join(" ")}`;
}

function ctsValidityWord(v: unknown): string | null {
  const s = String(v ?? "").trim().toLowerCase();
  return CTS_VALIDITY_WORDS.includes(s) ? s : null;
}

function ctsMapScores(
  raw: unknown, keys: readonly string[],
): { values: Record<string, number | null>; found: number } {
  const src = (raw && typeof raw === "object") ? raw as Record<string, unknown> : {};
  const values: Record<string, number | null> = {};
  let found = 0;
  for (const k of keys) {
    const v = ctsScore0to100(src[k]);
    values[k] = v;
    if (v !== null) found += 1;
  }
  return { values, found };
}

function ctsMapLssRow(raw: unknown): Record<string, number | null> | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const out: Record<string, number | null> = {
    ideal_min: ctsNum(r.ideal_min),
    ideal_max: ctsNum(r.ideal_max ?? r.max_possible),
    candidate: ctsNum(r.candidate),
  };
  return out.candidate === null ? null : out;
}

/**
 * Parse one report. Returns the payload record_cts_result() takes, or a
 * refusal with a reason a human can act on.
 */
export async function parseCtsProfile(input: CtsParseInput): Promise<CtsParseResult> {
  const headerName = ctsNameFromReport(input.reportText, input.fileName);

  if (!/CTS|Sales Profile|Learning Style Survey/i.test(input.reportText)) {
    return { ok: false, candidateName: headerName, error: "does not look like a CTS Sales Profile report" };
  }

  const llm = await parseWithLLM({
    agencyId: input.agencyId,
    composioApiKey: input.composioApiKey,
    composioUserId: input.composioUserId,
    systemPrompt: SYSTEM_PROMPT_CTS_PROFILE,
    // The report is a few thousand characters. Send it whole — the scores sit
    // in three separate blocks and trimming to "the useful part" is how a
    // section gets silently dropped when the vendor reorders pages.
    userContent: input.reportText.slice(0, 40000),
    documentId: input.documentId,
    purpose: "cts_profile_extract",
    // gpt-oss spends part of this on reasoning before it writes the JSON. At
    // 2500 Heather Jackman's read (2026-09-26) was cut off mid-object twice.
    // fitMaxTokens trims this to what the 8,000-token request cap leaves.
    maxTokens: 4200,
    // The manual form is the fallback, so a parked queue row would be a second
    // path nobody drains.
    skipQueueOnFailure: true,
  });

  if (!llm.ok) {
    const why = "queued" in llm && llm.queued
      ? `parked in the LLM queue (${llm.queueId})`
      : (llm as { error: string }).error;
    return { ok: false, candidateName: headerName, error: `LLM read failed: ${why}` };
  }

  const j = llm.json ?? {};

  const traits = ctsMapScores(j.primary_traits, CTS_PRIMARY_TRAITS);
  const comps = ctsMapScores(j.sales_competencies, CTS_SALES_COMPETENCIES);

  // A real report has all nine of each. Fewer than seven means the read lost a
  // block, not that the vendor left scores off the page.
  if (traits.found < 7 || comps.found < 7) {
    return {
      ok: false,
      candidateName: headerName,
      error: `read is incomplete: ${traits.found}/9 primary traits and ${comps.found}/9 sales competencies`,
    };
  }

  // Layout B cross-check (2026-09-26): when the report prints a block's nine
  // scores as one run, the model's read has to match that run exactly.
  const mismatch =
    ctsRunMismatch(input.reportText, "traits", CTS_PRIMARY_TRAITS, traits.values) ??
    ctsRunMismatch(input.reportText, "competencies", CTS_SALES_COMPETENCIES, comps.values);
  if (mismatch) {
    return { ok: false, candidateName: headerName, error: mismatch };
  }

  // The LLM's name has to agree with the name printed in the header. A
  // disagreement means the read drifted, and attaching a profile to the wrong
  // candidate is the one mistake worth refusing the whole document over.
  const llmName = typeof j.candidate_name === "string" ? j.candidate_name.trim() : null;
  const resolvedName = headerName ?? llmName;
  if (headerName && llmName && !ctsNamesAgree(headerName, llmName)) {
    return {
      ok: false,
      candidateName: headerName,
      error: `name mismatch: header says "${headerName}", read says "${llmName}"`,
    };
  }

  const lssAccuracy: Record<string, unknown> = {};
  const lssSpeed: Record<string, unknown> = {};
  for (const s of CTS_LSS_SECTIONS) {
    const a = ctsMapLssRow((j.lss_accuracy ?? {})[s]);
    if (a) lssAccuracy[s] = a;
    const sp = ctsMapLssRow((j.lss_speed ?? {})[s]);
    if (sp) lssSpeed[s] = sp;
  }
  const total = ctsMapLssRow((j.lss_accuracy ?? {}).total);
  if (total) lssAccuracy.total = total;

  const payload: Record<string, unknown> = {
    ego_drive: ctsScore0to100(j.ego_drive),
    empathy: ctsScore0to100(j.empathy),
    reliability: ctsValidityFromHeader(input.reportText, "Reliability")
      ?? ctsValidityWord(j.reliability)
      ?? ctsValidityFromText(input.reportText, "Reliability"),
    response_distortion: ctsValidityFromHeader(input.reportText, "Response Distortion")
      ?? ctsValidityWord(j.response_distortion)
      ?? ctsValidityFromText(input.reportText, "Response Distortion"),
    primary_traits: traits.values,
    sales_competencies: comps.values,
    lss_accuracy: lssAccuracy,
    lss_speed: lssSpeed,
    report_date: typeof j.report_date === "string" ? j.report_date : null,
    candidate_name_on_report: resolvedName,
    source_file_name: ctsFileBase(input.fileName),
    parsed_at: new Date().toISOString(),
  };

  return {
    ok: true,
    candidateName: resolvedName,
    reportDate: typeof j.report_date === "string" ? j.report_date : null,
    payload,
  };
}

/**
 * Same person? Compares first and last token, case- and punctuation-blind.
 * Deliberately strict everywhere else: middle names, suffixes and the order
 * the vendor prints them in are allowed to differ, nothing else is.
 */
export function ctsNamesAgree(a: string, b: string): boolean {
  const norm = (s: string) =>
    s.toLowerCase().replace(/[^a-z\s]/g, " ").split(/\s+/).filter(Boolean);
  const x = norm(a), y = norm(b);
  if (!x.length || !y.length) return false;
  if (x[0] !== y[0]) return false;
  if (x.length > 1 && y.length > 1 && x[x.length - 1] !== y[y.length - 1]) return false;
  return true;
}

export interface CtsMatchResult {
  candidateId: string | null;
  matchCount: number;
}

/**
 * Find the one candidate this report belongs to.
 *
 * Same posture as the reference ingest: no fuzzy matching. Anything other
 * than exactly one hit stays unlinked and gets a loud alert, because writing
 * a sales profile onto the wrong candidate is worse than a human doing it by
 * hand from the form.
 *
 * Preference order matters when two people share a name: someone who was
 * actually sent the CTS wins over someone who was not.
 */
export async function matchCtsCandidate(
  agencyId: string, candidateName: string, email?: string | null,
): Promise<CtsMatchResult> {
  // Email first when the source carries one (the CTS site pull does). It is
  // the address the candidate gave both systems, so it survives a nickname
  // ("Nate" on the record, "Nathaniel" on CTS) that an exact-name match
  // cannot. Still exactly-one-or-nothing; no fuzzy matching.
  if (email && email.includes("@")) {
    const { data: byEmail } = await sb
      .from("hiring_candidates")
      .select("id, cts_invite_sent_at, cts_completed_at")
      .eq("agency_id", agencyId)
      // ilike for case only: escape its wildcards so an "_" in an address is literal.
      .ilike("email", email.trim().replace(/[\\%_]/g, (ch) => "\\" + ch));
    const hits = byEmail ?? [];
    if (hits.length === 1) return { candidateId: hits[0].id, matchCount: 1 };
    if (hits.length > 1) {
      const invited = hits.filter((c: any) => c.cts_invite_sent_at && !c.cts_completed_at);
      if (invited.length === 1) return { candidateId: invited[0].id, matchCount: 1 };
      return { candidateId: null, matchCount: hits.length };
    }
  }

  const { data } = await sb
    .from("hiring_candidates")
    .select("id, cts_invite_sent_at, cts_completed_at, status")
    .eq("agency_id", agencyId)
    .ilike("candidate_name", candidateName);

  const all = data ?? [];
  if (all.length === 1) return { candidateId: all[0].id, matchCount: 1 };
  if (all.length === 0) return { candidateId: null, matchCount: 0 };

  const invited = all.filter((c: any) => c.cts_invite_sent_at && !c.cts_completed_at);
  if (invited.length === 1) return { candidateId: invited[0].id, matchCount: 1 };

  return { candidateId: null, matchCount: all.length };
}
