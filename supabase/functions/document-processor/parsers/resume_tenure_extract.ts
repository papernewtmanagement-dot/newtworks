// =========================================================================
// parsers/resume_tenure_extract.ts
// =========================================================================
// Deterministic (regex-only, no LLM) extraction of work-experience date
// ranges from resume_extracted_text, computing total months worked per job.
//
// WHY THIS EXISTS: role_fit_v5_6 (2026-08-14) softens the SJT construct's
// weight for candidates with limited documented work history, reading
// months from resume_analysis.qualifications.prior_similar_role.roles[].
// tenure_months. That field was previously populated only by a manual/
// in-chat resume-scoring workflow with incomplete coverage (see
// persistent_memory spec "SPEC — Resume scoring: deterministic
// work-experience-months extraction"). This module makes tenure_months
// populate automatically, every time, as part of resume ingest.
//
// SINGLE SOURCE OF TRUTH (Peter directive 2026-08-14): this module is the
// ONLY thing that ever writes employer/title/tenure_months into
// prior_similar_role.roles[]. There is no separate "manual" writer of that
// data — when Peter asks for a candidate's work history to be filled in or
// corrected by hand, that request should call extractAndWriteTenure() too,
// not re-derive the numbers a different way. Qualitative fields on each
// role entry (category, notes) and the top-level qualitative fields
// (highest_relevance, insurance_tenure_months, success_signals, notes) are
// NOT touched by this module — those stay owned by whatever in-chat
// scoring pass sets them, matched onto the same roles[] entries by
// employer name.
//
// DESIGN CHOICE (Peter directive 2026-08-14, confirmed after reviewing real
// resume-format diversity): pattern-matching only, no per-resume LLM call
// to associate dates with jobs. This is faster and free, and accurate
// tenure_months in every one of 23 test job entries across 6 real sampled
// resumes. Known accepted tradeoff: employer/title labeling can be wrong on
// unusual layouts (ambiguous separator conventions, stray blank lines from
// PDF extraction) — this NEVER affects tenure_months, which is derived
// independently of the label-splitting heuristic. Never guesses a date
// range that isn't in the text; a job with no parseable dates simply gets
// no tenure_months entry (matches the "never guess" principle already
// established for autonomy scoring and other resume signals).
// =========================================================================

// deno-lint-ignore-file no-explicit-any

import { sb } from "../../_shared/supabase.ts";
import { KNOWN_HEADERS } from "./resume_reformat.ts";

// -------------------------------------------------------------------------
// Date parsing
// -------------------------------------------------------------------------

const RESUME_MONTH_NAMES: Record<string, number> = {
  jan: 1, january: 1, feb: 2, february: 2, mar: 3, march: 3, apr: 4, april: 4,
  may: 5, jun: 6, june: 6, jul: 7, july: 7, aug: 8, august: 8, sep: 9, sept: 9,
  september: 9, oct: 10, october: 10, nov: 11, november: 11, dec: 12, december: 12,
};

const MONTH_NAME_RE =
  "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)";
const DATE_TOKEN_RE = `(?:${MONTH_NAME_RE}\\.?\\s+\\d{4}|\\d{1,2}\\/\\d{4}|\\d{4})`;
const PRESENT_RE = "(?:present|current|now|ongoing)";
const RANGE_RE = new RegExp(
  `(${DATE_TOKEN_RE})\\s*(?:to|thru|through|[\u2013\u2014-])\\s*(${DATE_TOKEN_RE}|${PRESENT_RE})`,
  "i",
);

type MonthYear = { year: number; month: number };
type DateTokenResult = MonthYear | "present" | null;

function parseDateToken(tok: string): DateTokenResult {
  const t = tok.trim().toLowerCase();
  if (/^(present|current|now|ongoing)$/.test(t)) return "present";
  let m = t.match(/^([a-z]+)\.?\s+(\d{4})$/);
  if (m && RESUME_MONTH_NAMES[m[1]]) return { year: parseInt(m[2], 10), month: RESUME_MONTH_NAMES[m[1]] };
  m = t.match(/^(\d{1,2})\/(\d{4})$/);
  if (m) {
    const mo = parseInt(m[1], 10);
    if (mo >= 1 && mo <= 12) return { year: parseInt(m[2], 10), month: mo };
  }
  m = t.match(/^(\d{4})$/);
  if (m) return { year: parseInt(m[1], 10), month: 1 }; // bare year, month unknown -> Jan floor
  return null;
}

function monthsBetween(start: MonthYear | null, end: DateTokenResult, asOf: MonthYear): number | null {
  if (!start || !end) return null;
  const e = end === "present" ? asOf : end;
  const months = (e.year - start.year) * 12 + (e.month - start.month);
  return Math.max(0, months);
}

// -------------------------------------------------------------------------
// Section isolation — reuses KNOWN_HEADERS from resume_reformat.ts (single
// source of truth for the header list) so the boundary detected here
// matches the divider that module already inserted.
// -------------------------------------------------------------------------

const EXPERIENCE_HEADERS: ReadonlySet<string> = new Set([
  "experience", "work experience", "professional experience",
  "employment history", "relevant experience", "work history",
]);

function isBullet(line: string): boolean {
  return /^\s*[•\-*●]/.test(line);
}
function isHeaderLine(line: string): boolean {
  const clean = line.trim().replace(/:+$/, "").toLowerCase();
  return KNOWN_HEADERS.has(clean);
}

function extractExperienceSection(text: string): string[] | null {
  const lines = text.split("\n");
  let start = -1;
  let end = lines.length;
  for (let i = 0; i < lines.length; i++) {
    const clean = lines[i].trim().replace(/:+$/, "").toLowerCase();
    if (EXPERIENCE_HEADERS.has(clean)) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return null;
  for (let i = start; i < lines.length; i++) {
    if (isHeaderLine(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end);
}

// -------------------------------------------------------------------------
// Title/employer best-effort split — see module header for accepted
// limitations. Never affects tenure_months.
// -------------------------------------------------------------------------

function splitHeaderIntoTitleEmployer(headerLines: string[]): { title: string | null; employer: string | null } {
  if (headerLines.length === 0) return { title: null, employer: null };

  if (headerLines.length === 1) {
    const line = headerLines[0].replace(/[,:]\s*$/, "").trim();

    if (line.includes("|")) {
      const parts = line.split(/\s*\|\s*/).filter((p) => p.trim());
      if (parts.length >= 2) {
        return { title: parts[1]?.trim() || null, employer: parts[0]?.trim() || null };
      }
    }
    const dashMatch = line.match(/^(.*?)\s*[\u2013\u2014-]\s*(.*)$/);
    if (dashMatch && dashMatch[1].trim() && dashMatch[2].trim()) {
      return { title: dashMatch[1].trim(), employer: dashMatch[2].trim() };
    }
    const commaSplit = line.split(",").filter((p) => p.trim());
    if (commaSplit.length >= 2) {
      return { title: commaSplit[1]?.trim() || null, employer: commaSplit[0]?.trim() || null };
    }
    return { title: line || null, employer: null };
  }

  // 2 lines: top = title, bottom (nearest the date line) = employer (+location, stripped)
  const title = headerLines[0].trim() || null;
  let employerLine = headerLines[1].trim();
  employerLine = employerLine.replace(/\s*[\u2013\u2014-]\s*[A-Za-z .]+,?\s*[A-Z]{2}\s*$/, "");
  employerLine = employerLine.split(",")[0].trim();
  return { title, employer: employerLine || null };
}

// -------------------------------------------------------------------------
// Core parse
// -------------------------------------------------------------------------

export interface ParsedRole {
  title: string | null;
  employer: string | null;
  tenure_months: number;
  start_raw: string;
  end_raw: string;
}

/**
 * Pure function — no I/O. Parses every job entry with a recognizable date
 * range out of the Work Experience section of resumeText. asOf defaults to
 * the current date and governs how "Present"/"Current" resolves; pass a
 * fixed value only for testing.
 */
export function parseWorkExperienceRoles(resumeText: string, asOf?: MonthYear): ParsedRole[] {
  if (!resumeText) return [];
  const now = asOf ?? (() => {
    const d = new Date();
    return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
  })();

  const section = extractExperienceSection(resumeText);
  if (!section) return [];

  const roles: ParsedRole[] = [];
  let cursor = 0;
  while (cursor < section.length) {
    const line = section[cursor];
    const m = line.match(RANGE_RE);
    if (!m) {
      cursor++;
      continue;
    }
    const start = parseDateToken(m[1]);
    const startMY = start === "present" ? null : start;
    const end: DateTokenResult = /present|current|now|ongoing/i.test(m[2]) ? "present" : parseDateToken(m[2]);
    const before = line.slice(0, m.index).replace(/[|,\u2013\u2014-]\s*$/, "").trim();

    let headerLines: string[];
    if (before.length > 3) {
      headerLines = [before];
    } else {
      headerLines = [];
      let back = cursor - 1;
      while (back >= 0 && headerLines.length < 2) {
        const bl = section[back];
        if (bl.trim() === "" || isBullet(bl)) break;
        if (RANGE_RE.test(bl)) break;
        headerLines.unshift(bl.trim());
        back--;
      }
    }

    const { title, employer } = splitHeaderIntoTitleEmployer(headerLines);
    const tenure_months = monthsBetween(startMY, end, now);
    if (tenure_months !== null) {
      roles.push({ title, employer, tenure_months, start_raw: m[1], end_raw: m[2] });
    }
    cursor++;
  }
  return roles;
}

// -------------------------------------------------------------------------
// Merge into resume_analysis.qualifications.prior_similar_role.roles[]
// -------------------------------------------------------------------------

function normalizeEmployer(s: string | null | undefined): string {
  return (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Merges parsed roles into the existing qualifications.prior_similar_role
 * shape, OVERWRITING employer/title/tenure_months on any existing role
 * entry it can match by employer name (this module owns those three
 * fields), and preserving category/notes on matched entries untouched
 * (those are owned by qualitative scoring). Unmatched parsed roles are
 * appended as new entries with category/notes left null. Existing entries
 * with no matching parsed role (undated jobs, or jobs this parser missed)
 * are left exactly as they are.
 */
export function mergeParsedRolesIntoResumeAnalysis(
  existing: any,
  parsedRoles: ParsedRole[],
): { updated: any; changed: boolean } {
  const base = existing && typeof existing === "object" ? { ...existing } : {};
  const qualifications = { ...(base.qualifications ?? {}) };
  const priorSimilarRole = { ...(qualifications.prior_similar_role ?? {}) };
  const existingRoles: any[] = Array.isArray(priorSimilarRole.roles) ? [...priorSimilarRole.roles] : [];

  const usedExistingIdx = new Set<number>();
  const mergedRoles: any[] = [];

  for (const parsed of parsedRoles) {
    const normParsed = normalizeEmployer(parsed.employer);
    let matchIdx = -1;
    if (normParsed) {
      matchIdx = existingRoles.findIndex((r, idx) => {
        if (usedExistingIdx.has(idx)) return false;
        const normExisting = normalizeEmployer(r?.employer);
        if (!normExisting) return false;
        return normExisting === normParsed || normExisting.includes(normParsed) || normParsed.includes(normExisting);
      });
    }
    if (matchIdx >= 0) {
      usedExistingIdx.add(matchIdx);
      const existingRole = existingRoles[matchIdx];
      mergedRoles.push({
        ...existingRole,
        employer: parsed.employer ?? existingRole.employer,
        title: parsed.title ?? existingRole.title,
        tenure_months: parsed.tenure_months,
      });
    } else {
      mergedRoles.push({
        employer: parsed.employer,
        title: parsed.title,
        tenure_months: parsed.tenure_months,
        category: null,
        notes: null,
      });
    }
  }
  // Carry over any existing entries this parse run didn't touch (undated
  // jobs, or jobs on a layout this parser couldn't read) unchanged.
  existingRoles.forEach((r, idx) => {
    if (!usedExistingIdx.has(idx)) mergedRoles.push(r);
  });

  priorSimilarRole.roles = mergedRoles;
  qualifications.prior_similar_role = priorSimilarRole;
  base.qualifications = qualifications;

  const changed = JSON.stringify(existingRoles) !== JSON.stringify(mergedRoles);
  return { updated: base, changed };
}

// -------------------------------------------------------------------------
// Orchestration — call this from resume ingest.
// -------------------------------------------------------------------------

/**
 * Parses resumeText for work-experience tenure and writes the result into
 * hiring_candidates.resume_analysis for candidateId, merging (never
 * clobbering qualitative fields) into whatever is already there. Also
 * invalidates that ONE candidate's scoring cache (sets
 * cached_scoring_version to NULL) so the next page load recomputes their
 * fit score with the fresh tenure data — deliberately does NOT bump the
 * agency-wide hiregauge_scoring_version, since that would force every
 * OTHER candidate to recompute for a change that only affects this one.
 *
 * Non-fatal on any failure — logs a warning and returns ok:false. Never
 * throws; callers in the ingest pipeline should not have resume text
 * writes blocked by a tenure-parsing problem.
 */
export async function extractAndWriteWorkExperienceTenure(
  candidateId: string | null | undefined,
  resumeText: string | null | undefined,
): Promise<{ ok: boolean; rolesFound: number; changed: boolean; error?: string }> {
  if (!candidateId || !resumeText) return { ok: false, rolesFound: 0, changed: false, error: "missing candidateId or resumeText" };
  try {
    const parsedRoles = parseWorkExperienceRoles(resumeText);
    if (parsedRoles.length === 0) return { ok: true, rolesFound: 0, changed: false };

    const { data, error: fetchErr } = await sb
      .from("hiring_candidates")
      .select("resume_analysis")
      .eq("id", candidateId)
      .single();
    if (fetchErr) {
      console.warn(`extractAndWriteWorkExperienceTenure: fetch failed for ${candidateId}: ${fetchErr.message}`);
      return { ok: false, rolesFound: parsedRoles.length, changed: false, error: fetchErr.message };
    }

    const { updated, changed } = mergeParsedRolesIntoResumeAnalysis(data?.resume_analysis, parsedRoles);
    if (!changed) return { ok: true, rolesFound: parsedRoles.length, changed: false };

    const { error: writeErr } = await sb
      .from("hiring_candidates")
      .update({ resume_analysis: updated, cached_scoring_version: null })
      .eq("id", candidateId);
    if (writeErr) {
      console.warn(`extractAndWriteWorkExperienceTenure: write failed for ${candidateId}: ${writeErr.message}`);
      return { ok: false, rolesFound: parsedRoles.length, changed: false, error: writeErr.message };
    }
    return { ok: true, rolesFound: parsedRoles.length, changed: true };
  } catch (e) {
    console.warn(`extractAndWriteWorkExperienceTenure threw for ${candidateId}:`, e);
    return { ok: false, rolesFound: 0, changed: false, error: e instanceof Error ? e.message : String(e) };
  }
}
