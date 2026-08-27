// =========================================================================
// parsers/resume_tenure_extract.ts
// =========================================================================
// Deterministic (regex-only, no LLM) extraction of work-experience entries
// from resume_extracted_text. For every job with a readable date range it
// emits the start month, the end month (or "still there"), and the months
// worked, plus a best-effort title and employer.
//
// WHY THIS EXISTS: role_fit (v5_6, 2026-08-14) softens the SJT construct's
// weight for candidates with little documented work history, and it reads
// that history from resume_analysis.qualifications.prior_similar_role.
// roles[]. This module is what fills that array in, automatically, on
// every resume ingest — no scoring session has to remember to do it.
//
// REWRITE 2026-08-18. The first version (v133, 2026-08-14) only emitted a
// month count per role. Three defects were confirmed on real resumes:
//   1. Dropped roles — a date range with only a space between the two dates
//      ("Oct 2023 Present", "2016 Present") was not recognised at all, so
//      current employers vanished; roles that landed outside the one
//      "Experience" section (two-column PDFs collapse jobs under whatever
//      header sat beside them) were never read.
//   2. Swapped title/employer — the layout convention (top line = title)
//      was applied blindly, and it is wrong about half the time.
//   3. Garbage labels — a location fragment ("Texas |") on the date line was
//      taken as the job title.
// And downstream: role_fit SUMMED the month counts, so concurrent jobs
// (a musician who also held a day job) were double-counted and a single
// forty-year gig made a 66-year "career". Month counts alone cannot be
// de-overlapped — that needs real dates, which is why every role now
// carries start/end. The overlap-aware total lives in SQL
// (public.resume_experience_months) so it is computed from the stored
// dates on read and never goes stale.
//
// SINGLE SOURCE OF TRUTH (Peter directive 2026-08-14): this module is the
// ONLY thing that writes employer / title / start / end / is_current /
// tenure_months into prior_similar_role.roles[]. Qualitative fields on each
// entry (category, notes) and the top-level qualitative fields
// (highest_relevance, insurance_tenure_months, success_signals, notes) are
// NOT touched — those stay owned by the in-chat scoring pass, and the merge
// below preserves them on any entry it can match to a parsed role.
//
// DESIGN CHOICE (Peter directive 2026-08-14, still standing): pattern
// matching only, no per-resume LLM call. Never guesses a date range that
// isn't in the text; a job with no readable dates simply gets no entry.
// Title/employer labelling is best-effort (keyword classification with a
// layout fallback) and is allowed to be imperfect on unusual layouts —
// tenure and dates are computed independently of the label heuristics and
// are what drives scoring.
//
// REWRITE 2026-08-26 (v4). Nine failure modes confirmed on the 2026-08-24/25
// intake cohort (20 of 46 candidates damaged, 49 role entries hand-repaired).
// Each fix below names the resume it was reproduced on:
//   1. Two-column collapse — skills/languages words glued onto titles ("Camp
//      Counselor English"), employers in the title field and vice versa,
//      street addresses and duty lines in the employer field. Fixes: skill-
//      phrase lines are stepped over like place lines; a trailing skill word
//      is cut off a title; a street address is never a label; a title on the
//      same line as an employer beats a lone title above it; a label that
//      ENDS in a title word is a title even when it contains an employer word
//      ("Real Estate Agent", "Insurance Agent"); "Employer/ Title" with the
//      space after the slash splits; a fused "Title Employer, City, ST" splits
//      at the last title word. (Caswell, Sanabia, Wood, Maddox, Lopez)
//   2. Season-word dates — "Summer 2026" alone is a three-month range;
//      "April–June 2026" and "June - August 2025" share the trailing year.
//      (Libson, Holzschuher)
//   3. Letter-spaced dates from PDF kerning — "J AN 2 023", "P RES EN T",
//      "MAY 2 02 2- DEC." collapse before parsing, and a range that wraps
//      AROUND the header line is rejoined. (Walsh)
//   4. Markdown asterisks stripped before anything else looks at a line.
//      (Holzschuher)
//   5. One employer header over stacked title|date lines — the second title
//      inherits the employer of the entry directly above it. (Bryant, Petco)
//   6. Two seasons of one job on one line — the second range becomes its own
//      entry that inherits the header. (Holzschuher, Araca)
//   7. Duplicated page (Canva editor screenshot) — entries with the same dates
//      and a matching label collapse to one. (Hanssen)
//   8. Prose resumes — "I worked as an Enumerator for the United States Census
//      Bureau." yields title and employer from the sentence itself, and a
//      sentence boundary inside a label cuts it. (Dunlop)
//   9. Unpaid volunteering written under EXPERIENCE — donation drives,
//      fundraisers, food/toy drives, service projects are not jobs. (Szabo)
// Also: two-column interleaving of two entries' headers above two stacked
// date lines is de-interleaved (Maddox); a title-only entry stacked under
// the previous entry's date line takes that entry's employer (Bryant); a
// scrambled "Title 2014)" / "- Employer (2013-" pair is rejoined (Jackson);
// two jobs written on one line are split (Jackson).
// MERGE: an entry whose notes carry the hand-repair marker ("by hand
// YYYY-MM-DD") is never overwritten by a reparse — the person who fixed it
// wins. This makes the resume_tenure_backfill hazard structural instead of
// procedural.
// =========================================================================

// deno-lint-ignore-file no-explicit-any

/**
 * Bumped whenever the extraction rules change, so a stored row can be told
 * apart from one written by an older parser without re-reading the resume.
 */
export const PARSER_VERSION = "v4_2026_08_26";

import { sb } from "../../_shared/supabase.ts";
import { KNOWN_HEADERS } from "./resume_reformat.ts";

// -------------------------------------------------------------------------
// Date tokens
// -------------------------------------------------------------------------

const MONTH_NUM: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
  // Spanish (bilingual applicant pool): enero, febrero, marzo, abril, mayo,
  // junio, julio, agosto, septiembre/setiembre, octubre, noviembre, diciembre
  ene: 1, abr: 4, ago: 8, set: 9, dic: 12,
  // seasons (internships etc.) — mapped to the season's start month
  spr: 3, sum: 6, fal: 9, aut: 9, win: 12,
};

const MONTH_NAME_RE =
  "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?" +
  "|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre" +
  "|spring|summer|fall|autumn|winter)";
// "Jan 2020", "January 5, 2020", "Sept. 2020", "Jan, 2020", "Summer 2021"
const MONTH_YEAR_RE = `${MONTH_NAME_RE}\\.?,?\\s*(?:\\d{1,2}(?:st|nd|rd|th)?,?\\s+)?\\d{4}`;
// "Jan '19" — month name with an apostrophe two-digit year (only accepted when both ends use it)
const MONTH_YY_RE = `${MONTH_NAME_RE}\\.?\\s*['\u2019]\\d{2}(?!\\d)`;
// "06/15/2021", "6-15-2021", "06.15.2021" (month first; day/month swap handled in parse)
const NUM_DMY_RE = `(?<!\\d)\\d{1,2}[\\/.\\-]\\d{1,2}[\\/.\\-]\\d{4}(?!\\d)`;
// "06/2021", "6.2021"
const NUM_MY_RE = `(?<!\\d)\\d{1,2}[\\/.]\\d{4}(?!\\d)`;
// "2021-06" (ISO year-month). The (?!\d) keeps "2020-2023" from matching as "2020-20".
const ISO_YM_RE = `(?<!\\d)\\d{4}-(?:0[1-9]|1[0-2])(?!\\d)`;
// "06/21" — two-digit year. Only accepted when BOTH ends of the range use it (see parse).
const NUM_MYY_RE = `(?<!\\d)\\d{1,2}\\/\\d{2}(?!\\d)`;
// bare year
const YEAR_RE = `(?<!\\d)(?:19|20)\\d{2}(?!\\d)`;

const DATE_TOKEN_RE = `(?:${MONTH_YEAR_RE}|${MONTH_YY_RE}|${NUM_DMY_RE}|${NUM_MY_RE}|${ISO_YM_RE}|${NUM_MYY_RE}|${YEAR_RE})`;
const PRESENT_RE = "(?:present|current(?:ly)?|now|ongoing|today|to\\s+date|till\\s+date|til\\s+date|presente|actualmente|actualidad|actual|hasta\\s+la\\s+fecha)";
// Separator between the two dates. Word separators, any dash-like glyph, an
// arrow, or — new in this rewrite — plain whitespace ("Oct 2023 Present").
const SEP_RE = `(?:\\s*(?:to|thru|through|until|till|[\\u2013\\u2014\\u2015\\u2010\\u2212\\-]|\\u2192)\\s*|\\s+)`;
const RANGE_RE = new RegExp(
  `(?:\\bfrom\\s+)?(${DATE_TOKEN_RE})${SEP_RE}(${DATE_TOKEN_RE}|\\b${PRESENT_RE}\\b)`,
  "i",
);
const SINCE_RE = new RegExp(`\\bsince\\s+(${DATE_TOKEN_RE})`, "i");
const DATE_ANYWHERE_RE = new RegExp(DATE_TOKEN_RE, "i");
// "April–June 2026", "June - August 2025": two month names sharing ONE trailing
// year. Neither half is a date token on its own, so RANGE_RE never saw these
// and the whole entry was dropped (Carlos Libson lost both jobs, Julia
// Holzschuher lost two of her three James Avery stints, 2026-08-26).
const SHARED_YEAR_RANGE_RE = new RegExp(
  `\\b(${MONTH_NAME_RE})\\.?\\s*(?:to|thru|through|until|till|[\\u2013\\u2014\\u2015\\u2010\\u2212\\-]|\\u2192)\\s*(${MONTH_NAME_RE})\\.?,?\\s+(\\d{4})(?!\\d)`,
  "i",
);
// "Summer 2026" with no second date: a single season is a three-month window.
const LONE_SEASON_RE = /\b(spring|summer|fall|autumn|winter)\s+(\d{4})(?!\d)/i;
const SEASON_START: Record<string, number> = { spring: 3, summer: 6, fall: 9, autumn: 9, winter: 12 };

export type MonthYear = { year: number; month: number };
type Tok = { kind: "date"; my: MonthYear; shortYear: boolean; yearOnly: boolean } | { kind: "present" } | null;

type RangeHit = { startTok: Tok; endTok: Tok; startRaw: string; endRaw: string; index: number; length: number };

/**
 * Finds the one date range on a line, trying the full two-token range first,
 * then the shared-year month pair, then a lone season, then "since <date>".
 * Returns null when the line carries no readable range.
 */
function findRangeOnLine(line: string, now: MonthYear): RangeHit | null {
  let m = line.match(RANGE_RE);
  if (m && m.index !== undefined) {
    return { startTok: parseDateToken(m[1], now), endTok: parseDateToken(m[2], now), startRaw: m[1], endRaw: m[2], index: m.index, length: m[0].length };
  }
  m = line.match(SHARED_YEAR_RANGE_RE);
  if (m && m.index !== undefined) {
    const y = parseInt(m[3], 10);
    const m1 = MONTH_NUM[m[1].toLowerCase().slice(0, 3)];
    const m2 = MONTH_NUM[m[2].toLowerCase().slice(0, 3)];
    if (m1 && m2 && plausibleYear(y, now)) {
      // "November – February 2024" wraps the new year: the start is the year before.
      const startYear = m2 >= m1 ? y : y - 1;
      return {
        startTok: { kind: "date", my: { year: startYear, month: m1 }, shortYear: false, yearOnly: false },
        endTok: { kind: "date", my: { year: y, month: m2 }, shortYear: false, yearOnly: false },
        startRaw: `${m[1]} ${startYear}`, endRaw: `${m[2]} ${y}`, index: m.index, length: m[0].length,
      };
    }
  }
  m = line.match(LONE_SEASON_RE);
  if (m && m.index !== undefined) {
    const y = parseInt(m[2], 10);
    const s = SEASON_START[m[1].toLowerCase()];
    if (s && plausibleYear(y, now)) {
      // end is exclusive, the same way "June 2024 - September 2024" counts three months
      const endMonth = s + 3;
      const end: MonthYear = endMonth > 12 ? { year: y + 1, month: endMonth - 12 } : { year: y, month: endMonth };
      return {
        startTok: { kind: "date", my: { year: y, month: s }, shortYear: false, yearOnly: false },
        endTok: { kind: "date", my: end, shortYear: false, yearOnly: false },
        startRaw: m[0], endRaw: m[0], index: m.index, length: m[0].length,
      };
    }
  }
  m = line.match(SINCE_RE);
  if (m && m.index !== undefined) {
    return { startTok: parseDateToken(m[1], now), endTok: { kind: "present" }, startRaw: m[1], endRaw: "present", index: m.index, length: m[0].length };
  }
  return null;
}
/** True when the line carries any date range this parser would read. */
function hasRange(line: string): boolean {
  return RANGE_RE.test(line) || SHARED_YEAR_RANGE_RE.test(line) || LONE_SEASON_RE.test(line) || SINCE_RE.test(line);
}

function nowMonthYear(): MonthYear {
  const d = new Date();
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
}

function plausibleYear(y: number, asOf: MonthYear): boolean {
  return y >= 1950 && y <= asOf.year + 1;
}

function parseDateToken(raw: string, asOf: MonthYear): Tok {
  const t = raw.trim().toLowerCase().replace(/\s+/g, " ");
  if (new RegExp(`^${PRESENT_RE}$`).test(t)) return { kind: "present" };

  let m = t.match(/^([a-z]+)\.?,?\s*(?:(\d{1,2})(?:st|nd|rd|th)?,?\s+)?(\d{4})$/);
  if (m) {
    const mo = MONTH_NUM[m[1].slice(0, 3)];
    const y = parseInt(m[3], 10);
    if (mo && plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: mo }, shortYear: false, yearOnly: false };
    return null;
  }
  m = t.match(/^([a-z]+)\.?\s*['\u2019](\d{2})$/);
  if (m) {
    const mo = MONTH_NUM[m[1].slice(0, 3)];
    const yy = parseInt(m[2], 10);
    const y = yy <= (asOf.year % 100) + 1 ? 2000 + yy : 1900 + yy;
    if (mo && plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: mo }, shortYear: true, yearOnly: false };
    return null;
  }
  m = t.match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})$/);
  if (m) {
    let mo = parseInt(m[1], 10);
    const other = parseInt(m[2], 10);
    // US month-first by default; if the first number can't be a month but the
    // second can, read it as day-first.
    if (mo > 12 && other >= 1 && other <= 12) mo = other;
    const y = parseInt(m[3], 10);
    if (mo >= 1 && mo <= 12 && plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: mo }, shortYear: false, yearOnly: false };
    return null;
  }
  m = t.match(/^(\d{1,2})[\/.](\d{4})$/);
  if (m) {
    const mo = parseInt(m[1], 10);
    const y = parseInt(m[2], 10);
    if (mo >= 1 && mo <= 12 && plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: mo }, shortYear: false, yearOnly: false };
    return null;
  }
  m = t.match(/^(\d{4})-(\d{2})$/);
  if (m) {
    const y = parseInt(m[1], 10);
    const mo = parseInt(m[2], 10);
    if (mo >= 1 && mo <= 12 && plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: mo }, shortYear: false, yearOnly: false };
    return null;
  }
  m = t.match(/^(\d{1,2})\/(\d{2})$/);
  if (m) {
    const mo = parseInt(m[1], 10);
    const yy = parseInt(m[2], 10);
    const y = yy <= (asOf.year % 100) + 1 ? 2000 + yy : 1900 + yy;
    if (mo >= 1 && mo <= 12 && plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: mo }, shortYear: true, yearOnly: false };
    return null;
  }
  m = t.match(/^(\d{4})$/);
  if (m) {
    const y = parseInt(m[1], 10);
    // A bare 4-digit token is the weakest signal accepted — without the year
    // guard it matches digits inside phone numbers, zip codes and IDs (real
    // incident: "(210274-1570" read as years 274 and 1570, 2026-08-14).
    if (plausibleYear(y, asOf)) return { kind: "date", my: { year: y, month: 1 }, shortYear: false, yearOnly: true };
    return null;
  }
  return null;
}

function monthsBetween(start: MonthYear, end: MonthYear): number {
  return (end.year - start.year) * 12 + (end.month - start.month);
}

function ym(my: MonthYear): string {
  return `${my.year}-${String(my.month).padStart(2, "0")}`;
}

// -------------------------------------------------------------------------
// Section labelling — every line gets a section kind based on the most
// recent header above it. Only "excluded" sections are skipped; jobs are
// read from experience sections AND from neutral/unknown sections, because
// two-column PDFs routinely drop half the work history under whatever
// header happened to sit beside it (AWARDS, CONTACT, ...).
// -------------------------------------------------------------------------

// experience: read freely. neutral (summary, awards, unknown): read freely —
// two-column PDFs drop jobs under whatever header sat beside them.
// filtered (education, skills, certifications, languages, contact): a date
// range here is only a job if it clearly reads as one (title word, no
// degree / school / licence words). excluded (volunteer, projects,
// activities, references, ...): never paid work, skipped outright.
type SectionKind = "experience" | "excluded" | "filtered" | "neutral";

const EXPERIENCE_HEADERS: ReadonlySet<string> = new Set([
  "experience", "work experience", "professional experience", "employment history",
  "relevant experience", "work history", "employment", "employment experience",
  "additional experience", "other experience", "other work experience", "career history",
  "professional history", "professional background", "work background", "job history",
  "military experience", "military service", "professional work experience",
  "work experience & achievements", "work experience and achievements",
  "experience & achievements", "previous employment", "prior experience",
  "employment record", "positions held", "career experience", "work experiences",
  "professional experiences", "experiences", "industry experience", "sales experience",
  "insurance experience", "related experience", "recent experience",
  // Spanish (bilingual applicant pool)
  "experiencia", "experiencia laboral", "experiencia profesional", "historial laboral",
  "experiencia de trabajo", "empleo", "empleos", "trayectoria laboral",
]);

// Sections that CAN hold misfiled jobs (two-column collapse) but normally
// hold degrees, certificates, skills lists or contact details. Entries here
// must pass the stricter job test in isNonJobEntry.
const FILTERED_HEADERS: ReadonlySet<string> = new Set([
  "education", "educational background", "academic background", "academic history",
  "education/professional development", "education & credentials", "education and credentials",
  "education and training", "education & training", "education & certifications",
  "education and certifications", "education & licenses", "education/certifications",
  "education and licenses", "academics", "academic",
  "certifications", "certification", "licenses", "licenses & certifications",
  "certifications & licenses", "certifications and licenses", "licenses and certifications",
  "credentials", "professional certifications", "professional development",
  "training", "courses", "coursework", "relevant coursework", "courses & skills",
  "languages", "language",
  "skills", "skills & abilities", "skills and abilities", "skills & competencies",
  "skills and competencies", "technical skills", "technical proficiencies",
  "core competencies", "core skills", "key skills", "expertise", "areas of strength",
  "key skills and characteristics", "skills summary", "computer skills", "software",
  "contact", "contacts", "contact information", "contact info", "personal information",
  "personal details",
  // Spanish
  "educación", "educacion", "formación", "formacion", "formación académica", "formacion academica",
  "habilidades", "aptitudes", "idiomas", "certificaciones", "cursos", "contacto",
]);

// Sections that never hold paid work. Date ranges here are volunteer
// stints, project timelines, memberships — not jobs.
const EXCLUDED_HEADERS: ReadonlySet<string> = new Set([
  "references", "professional references",
  "volunteer", "volunteering", "volunteer experience", "volunteer work",
  "community service", "community involvement", "activities", "extracurricular activities",
  "extracurriculars", "school involvement", "leadership", "leadership experience",
  "projects", "interests", "hobbies", "publications", "affiliations",
  "professional affiliations", "memberships", "leadership and projects", "leadership & projects",
  "leadership and activities", "leadership & activities", "leadership & involvement",
  "leadership and involvement", "campus involvement", "student organizations", "organizations",
  "clubs", "clubs and activities", "clubs & activities", "honors and activities", "honors & activities",
  "awards and activities", "awards & activities", "activities and honors", "activities & honors",
  "extracurricular", "community engagement", "civic engagement",
  // Spanish
  "voluntariado", "referencias", "proyectos", "intereses", "actividades",
]);

// A designer template that letter-spaces its headers ("E X P E R I E N C E",
// "W O R K  E X P E R I E N C E") — collapse the spacing before matching.
function collapseLetterSpacing(s: string): string {
  const t = s.trim();
  if (/^(?:[A-Za-z&]\s){3,}[A-Za-z]$/.test(t)) return t.replace(/\s+/g, "");
  return t;
}

function normalizeHeaderText(line: string): string {
  let s = collapseLetterSpacing(line);
  s = s.replace(/[\s:|•·●\-–—_]+$/g, "").replace(/^[\s:|•·●\-–—_]+/g, "").trim();
  return s.toLowerCase().replace(/\s+/g, " ");
}

/**
 * Classifies a line as a section header. Returns null for ordinary lines.
 * Handles the two-column collapse "EXPERIENCE SKILLS" (two headers on one
 * line) by taking the leading header.
 */
function headerKindOf(s: string): SectionKind | null {
  if (EXPERIENCE_HEADERS.has(s)) return "experience";
  if (FILTERED_HEADERS.has(s)) return "filtered";
  if (EXCLUDED_HEADERS.has(s)) return "excluded";
  if (KNOWN_HEADERS.has(s)) return "neutral";
  return null;
}
// Letter-spaced templates: "W O R K  E X P E R I E N C E" collapses to
// "workexperience", so match against space-less keys too.
const NOSPACE_HEADER_KIND: ReadonlyMap<string, SectionKind> = (() => {
  const m = new Map<string, SectionKind>();
  const add = (set: ReadonlySet<string>, kind: SectionKind) => {
    for (const k of set) {
      const ns = k.replace(/[^a-z&/]/g, "");
      if (ns.length >= 5 && !m.has(ns)) m.set(ns, kind);
    }
  };
  add(EXPERIENCE_HEADERS, "experience");
  add(FILTERED_HEADERS, "filtered");
  add(EXCLUDED_HEADERS, "excluded");
  add(KNOWN_HEADERS, "neutral");
  return m;
})();
function classifyHeader(line: string): SectionKind | null {
  const raw = line.trim();
  if (!raw || raw.length > 60) return null;
  const s = normalizeHeaderText(raw);
  if (!s) return null;
  const direct = headerKindOf(s);
  if (direct) return direct;
  // Letter-spaced single or double header ("C O N T A C T S U M M A R Y")
  if (/^(?:[a-z&]\s){3,}[a-z]$/.test(s) || /^[a-z&/]+$/.test(s)) {
    const ns = s.replace(/[^a-z&/]/g, "");
    const k = NOSPACE_HEADER_KIND.get(ns);
    if (k) return k;
    // two headers letter-spaced together: try every split
    for (let cut = 5; cut <= ns.length - 5; cut++) {
      const a = NOSPACE_HEADER_KIND.get(ns.slice(0, cut));
      const b = NOSPACE_HEADER_KIND.get(ns.slice(cut));
      if (a && b) return a;
    }
  }
  // Column collapse: a header followed by another header or by a bullet
  // fragment on the same line — "experience skills", "Work History ● Cross-Functional".
  const lead = s.split(/\s*[•●·|]\s*|\s{2,}/)[0].trim();
  if (lead !== s) {
    const k = headerKindOf(lead);
    if (k) return k;
  }
  const words = s.split(" ");
  if (words.length >= 2 && words.length <= 4) {
    for (let cut = words.length - 1; cut >= 1; cut--) {
      const left = words.slice(0, cut).join(" ");
      const right = words.slice(cut).join(" ");
      if (!headerKindOf(right)) continue;
      const k = headerKindOf(left);
      if (k) return k;
    }
  }
  return null;
}

// -------------------------------------------------------------------------
// Line-level helpers
// -------------------------------------------------------------------------

const DIVIDER_RE = /^[\s\u2500\u2501\u2504\u2508\-_=]{8,}$/; // resume_reformat divider and rules
function isDivider(line: string): boolean {
  return DIVIDER_RE.test(line);
}
function isBullet(line: string): boolean {
  if (/^\s*(?:[•\-*●○◦▪■➢➤►›»>·‣⁃\uE000-\uF8FF]|\d+[.)])\s+\S/.test(line)) return true;
  // "-Customer service and communication": a dash glued straight onto the
  // first word is still a bullet (Anna Sanabia's duty lines were read as
  // job titles because of the missing space, 2026-08-26).
  return /^\s*[\-–—•*\uE000-\uF8FF](?=[A-Za-z])/.test(line);
}

// Words that live in a resume's SKILLS / LANGUAGES column. A two-column PDF
// collapses that column onto the job lines beside it ("Camp Counselor
// English", a lone "Customer Service" line between the title and the dates),
// so a line that is nothing but one of these is stepped over like a place
// line, and one trailing on a title is cut off. Deliberately excludes words
// that are also job titles on their own (cashier, caregiver, server).
const SKILL_PHRASES: ReadonlySet<string> = new Set([
  "english", "spanish", "french", "german", "bilingual", "bilingual (spanish)", "bilingual spanish",
  "communication", "communication skills", "verbal communication", "written communication",
  "leadership", "teamwork", "team player", "team work", "collaboration", "dependable", "dependability",
  "integrity", "reliable", "reliability", "punctual", "punctuality", "honest", "honesty",
  "hardworking", "hard working", "hard worker", "fast learner", "quick learner", "safe driver",
  "customer service", "customer service skills", "problem solving", "problem-solving", "problem solver",
  "time management", "multitasking", "multi-tasking", "organization", "organizational skills", "organized",
  "adaptability", "adaptable", "flexible", "flexibility", "attention to detail", "detail oriented",
  "detail-oriented", "positive attitude", "active listening", "empathy", "work ethic", "strong work ethic",
  "microsoft office", "ms office", "microsoft word", "microsoft excel", "excel", "powerpoint", "outlook",
  "google workspace", "google / microsoft", "google/microsoft", "google docs", "google sheets",
  "typing", "data entry", "cash handling", "pos", "pos systems", "pos system", "crm", "crm systems",
  "negotiation", "upselling", "closing", "objection handling", "lead conversion", "relationship building",
  "client relations", "customer retention", "phone sales", "cold calling", "computer skills",
  "computer literate", "phone etiquette", "conflict resolution", "critical thinking", "self-motivated",
  "self motivated", "motivated", "friendly", "outgoing", "energetic", "creative", "creativity",
  "stocking shelves", "stocking", "merchandising", "inventory", "scheduling", "filing", "phones",
]);
function isSkillPhrase(s: string): boolean {
  const t = s.trim().toLowerCase().replace(/[.,;:•·]+$/, "").replace(/\s+/g, " ");
  if (SKILL_PHRASES.has(t)) return true;
  // "Bilingual (English, Spanish) Phone Systems", "Microsoft Office Suite",
  // "Google Workspace (Docs, Sheets)": a skills line with trimmings
  if (/^(?:bilingual|microsoft office|ms office|google (?:workspace|suite|docs)|adobe (?:creative|photoshop|premiere)|proficient in|fluent in)\b/.test(t)) return true;
  // every comma / paren / slash chunk is itself a skill phrase
  const chunks = t.split(/\s*[(),/|&]\s*|\s{2,}/).map((x) => x.trim()).filter(Boolean);
  return chunks.length >= 2 && chunks.every((x) => SKILL_PHRASES.has(x));
}
// "Camp Counselor English", "Team Lead Worker Team Player": cut the trailing
// skills-column word(s) off a label that already carries a job-title word.
function stripTrailingSkill(s: string): string {
  let t = s.trim();
  for (let pass = 0; pass < 2; pass++) {
    const words = t.split(/\s+/);
    if (words.length < 2) break;
    let cut = false;
    for (let n = Math.min(3, words.length - 1); n >= 1; n--) {
      const tail = words.slice(words.length - n).join(" ");
      const head = words.slice(0, words.length - n).join(" ");
      if (isSkillPhrase(tail) && titleScore(head) > 0 && !/[,\-–—/&|]$/.test(head)) {
        t = head.trim();
        cut = true;
        break;
      }
    }
    if (!cut) break;
  }
  return t;
}

// A street address is never a title or an employer: "21115 US-281 Ste 1600",
// "503 Belden Ave", "19811 Sunset Meadows San Antonio", "PO Box 123".
const ADDRESS_WORD_RE =
  /\b(?:st|street|ave|avenue|blvd|boulevard|rd|road|dr|drive|ln|lane|ct|court|cir|circle|way|pkwy|parkway|hwy|highway|loop|trail|trl|pl|place|ste|suite|apt|unit|bldg|building|floor|fl|fm|us-\d+|i-\d+|ih-\d+|sh-\d+)\b\.?/i;
function isStreetAddress(s: string): boolean {
  const t = s.trim();
  if (/^p\.?\s*o\.?\s*box\b/i.test(t)) return true;
  if (!/^\d{1,6}\s+\S/.test(t)) return false;
  if (ADDRESS_WORD_RE.test(t)) return true;
  // Three or more leading digits followed by capitalised words and no job
  // word: "19811 Sunset Meadows". Employers rarely start with a house number.
  if (/^\d{3,6}\s+[A-Z][A-Za-z.'-]*(?:\s+[A-Z][A-Za-z.'-]*){0,4}$/.test(t) && titleScore(t) === 0 && employerScore(t) === 0) return true;
  return false;
}
// Cuts an address that a two-column collapse glued into the MIDDLE of a
// label: "Assist Customers successfully 19811 Sunset Meadows San Antonio
// Business Owner in Mexico" -> "Business Owner in Mexico".
function stripEmbeddedAddress(s: string): string {
  const m = s.match(/^(.+?)\s+\b(\d{3,6})\s+([A-Z][A-Za-z.'-]*(?:\s+\S+){0,8})$/);
  if (!m) return s;
  const words = m[3].split(/\s+/);
  let cityEnd = -1;
  outer: for (let i = 0; i < Math.min(words.length, 6); i++) {
    for (let n = 3; n >= 1; n--) {
      if (i + n <= words.length && isKnownCity(words.slice(i, i + n).join(" "))) { cityEnd = i + n; break outer; }
    }
  }
  const hasAddrWord = ADDRESS_WORD_RE.test(words.slice(0, 4).join(" "));
  if (cityEnd < 0 && !hasAddrWord) return s;
  const tail = cityEnd > 0 ? words.slice(cityEnd).join(" ") : "";
  if (tail && (titleScore(tail) > 0 || employerScore(tail) > 0)) return tail;
  return s;
}
// A line that is only punctuation / bullet glyphs (PDF extraction leaves
// orphan bullet markers on their own lines) — skipped, not a stop.
function isPunctOnly(line: string): boolean {
  return line.trim().length > 0 && /^[\s•·●○◦▪■➢➤►›»>‣⁃\-–—―_|:.,;*\uE000-\uF8FF]+$/.test(line);
}
// Bullet-less description lines usually open with a past-tense action verb
// ("Managed the front desk", "Handled inbound calls") or a pronoun. Job
// titles and employer names never do.
const ACTION_VERB_START_RE =
  /^(?:managed|handled|provided|delivered|built|coordinated|trained|assisted|resolved|developed|maintained|ensured|conducted|worked|collaborated|performed|created|oversaw|supported|processed|answered|greeted|operated|prepared|completed|increased|achieved|generated|recognized|recognised|selected|served|directed|recruited|improved|exceeded|surpassed|utilized|utilised|communicated|scheduled|sold|helped|responsible|responded|reviewed|analyzed|analysed|implemented|organized|organised|monitored|tracked|documented|reported|negotiated|closed|opened|drove|grew|reduced|saved|earned|won|received|awarded|promoted|hired|mentored|coached|taught|educated|advised|consulted|contacted|called|followed|met|attained|obtained|secured|established|launched|introduced|planned|designed|executed|facilitated|guided|inspected|installed|repaired|cleaned|stocked|loaded|unloaded|picked|packed|shipped|verified|audited|balanced|reconciled|entered|updated|filed|typed|dispatched|assigned|delegated|supervised|interviewed|onboarded|escalated|de-escalated|troubleshot|diagnosed|upsold|cross-sold|quoted|underwrote|adjusted|investigated|assessed|evaluated|identified|determined|calculated|collected|distributed|demonstrated|explained|presented|marketed|advertised|posted|edited|filmed|photographed|recorded|produced|wrote|drafted|translated|interpreted|counseled|counselled|cared|fed|bathed|dressed|transported|escorted|welcomed|checked|took|made|kept|ran|set|put|got|did|was|were|am|is|are|has|have|had|being|assist|assists|manage|manages|handle|handles|provide|provides|perform|performs|maintain|maintains|ensure|ensures|answer|answers|greet|greets|process|processes|serve|serves|issue|issues|collect|collects|compose|composes|revise|revises|receive|receives|operate|operates|hire|hires|help|helps|organize|organise|organizes|train|trains|deliver|delivers|build|builds|create|creates|develop|develops|design|designs|oversee|oversees|stock|stocks|clean|cleans|count|counts|cook|cooks|sell|sells|support|supports|track|tracks|monitor|monitors|update|updates|coordinate|coordinates|communicate|communicates|resolve|resolves|respond|responds|schedule|schedules|complete|completes|prepare|prepares|verify|verifies|review|reviews|enter|enters|load|loads|unload|unloads|sort|sorts|pack|packs|ship|ships|pick|picks|wash|washes|fold|folds|sweep|sweeps|mop|mops|restock|restocks|upsell|upsells|dispatch|dispatches|assign|assigns|supervise|supervises|mentor|mentors|coach|coaches|teach|teaches|educate|educates|advise|advises|negotiate|negotiates|quote|quotes|implement|implements|execute|executes|plan|plans|report|reports|document|documents|record|records|audit|audits|reconcile|reconciles|balance|balances|distribute|distributes|present|presents|demonstrate|demonstrates|explain|explains|translate|translates|interpret|interprets|transport|transports|escort|escorts|welcome|welcomes|seat|seats|utilize|utilizes|generate|generates|increase|increases|improve|improves|reduce|reduces|achieve|achieves|exceed|exceeds|drive|drives|promote|promotes|recruit|recruits|interview|interviews|onboard|onboards|escalate|escalates|troubleshoot|troubleshoots|diagnose|diagnoses|inspect|inspects|install|installs|repair|repairs|analyze|analyzes|evaluate|evaluates|identify|identifies|calculate|calculates|file|files|type|types|lift|lifts|move|moves|check|checks|open|opens|close|closes|run|runs|keep|keeps|set|sets|take|takes|make|makes|write|writes|read|reads|call|calls|contact|contacts|follow|follows|meet|meets|attend|attends|participate|participates|lead|leads)\b\s+\S/i;
// Prose, not a header: starts lowercase, ends a sentence, opens with a verb
// or pronoun, or is simply long.
function looksLikeProse(s: string): boolean {
  const t = s.trim();
  if (!t) return true;
  if (/^[a-z]/.test(t)) return true;
  if (/[a-z][.!?]\s*$/.test(t)) return true;
  if (/^(?:I|We|My|Our|This|These|The|A|An|In|On|At|As|To|For|With|While|During|Also|Currently|Responsible for)\b\s+[a-z]/.test(t)) return true;
  // an action verb followed by a lowercase word reads as a sentence
  if (ACTION_VERB_START_RE.test(t) && /^\S+\s+[a-z]/.test(t)) return true;
  // "Hire new employees", "Assist Customers successfully": a verb-led line of
  // three or more words with no job-title or employer word in it is a duty,
  // whatever the capitalisation. "Lead Sales Associate" keeps its title word
  // and survives.
  if (ACTION_VERB_START_RE.test(t) && wordCount(t) >= 3 && titleScore(t) === 0 && employerScore(t) === 0) return true;
  // "More Projects professional, energetic and passionate, very goal oriented,"
  // — text after a comma that starts lowercase is a clause, not a label.
  // "Manager, Customer Service" and "Walmart, Fort Stockton, TX" keep their
  // capitals. An employment-type tail ("Server, part-time") is not prose.
  // Only when there are TWO such clauses, or one clause plus a trailing
  // comma: "Construction Framer, los duques" is a title and a lowercase
  // employer name, not a sentence (margarita rodriguez, 2026-08-26).
  {
    const noType = t.replace(EMPLOYMENT_TYPE_ALL_RE, " ").replace(/\s+/g, " ");
    const lowerClauses = (noType.match(/,\s+(?!(?:and|&|of|de|the|la|el|los|las|y)\b)[a-z]/g) ?? []).length;
    if (lowerClauses >= 2) return true;
    if (lowerClauses === 1 && /,\s*$/.test(noType)) return true;
  }
  if (t.length > 110) return true;
  if (wordCount(t) > 14) return true;
  // An ALL-CAPS resume defeats every test above: nothing starts lowercase, so
  // whole sentences of duty text read as headers. Judge those on shape instead
  // — a long all-caps line, or one ending in a comma or full stop, is prose.
  // Job titles and employer names are rarely seven words and almost never end
  // with punctuation. ("INTELLIGENCE SPECIALIST,U.S. NAVY RESERVE FORCE" is
  // six words and ends on a word, so it survives as the header it is.)
  // Judge an ALL-CAPS line only on trailing punctuation. Length is NOT safe
  // evidence: plenty of all-caps resumes put the whole job on one long line
  // ("US & TEXAS HISTORY TEACHER/HERITAGE MIDDLE SCHOOL EAST CENTRAL ISD"),
  // and a word-count rule threw four real jobs away (Tabitha Graciano).
  if (!/[a-z]/.test(t) && /[A-Z]/.test(t) && /[,.]$/.test(t)) return true;
  return false;
}
// Counts word tokens that carry letters ("&", "|", "-" are not words).
function wordCount(s: string): number {
  return s.trim().split(/\s+/).filter((w) => /[A-Za-z]/.test(w)).length;
}

// -------------------------------------------------------------------------
// Title / employer classification
// -------------------------------------------------------------------------

const US_STATE_NAMES =
  "alabama|alaska|arizona|arkansas|california|colorado|connecticut|delaware|florida|georgia|hawaii|idaho|illinois|indiana|iowa|kansas|kentucky|louisiana|maine|maryland|massachusetts|michigan|minnesota|mississippi|missouri|montana|nebraska|nevada|new hampshire|new jersey|new mexico|new york|north carolina|north dakota|ohio|oklahoma|oregon|pennsylvania|rhode island|south carolina|south dakota|tennessee|texas|utah|vermont|virginia|washington|west virginia|wisconsin|wyoming|district of columbia|puerto rico";
const US_STATE_ABBR =
  "AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC|PR";

const EMPLOYMENT_TYPE_RE =
  /\b(?:full[- ]?time|part[- ]?time|contract(?:or)?|seasonal|temporary|temp|internship|intern|remote|hybrid|on[- ]?site|per diem|prn|freelance|self[- ]employed|volunteer)\b/i;
// Global twin of the above, for stripping every occurrence rather than testing.
const EMPLOYMENT_TYPE_ALL_RE = new RegExp(EMPLOYMENT_TYPE_RE.source, "gi");
// A label that is only an employment status — the employer slot for an owner
// or freelancer ("Owner — Self-Employed", "Pet & House Sitter / Self-employed").
const SELF_EMPLOYED_RE = /^(?:self[\s\-]?employed|self[\s\-]?employment|freelance(?:r)?|independent contractor|sole proprietor|entrepreneur|owner[\s\-]?operator|private practice|independent)$/i;
// Employers whose stated range spans years but whose work happens in one
// window each year. Read literally, "Sep 2016 to Nov 2025" at a Halloween
// shop becomes a 110-month job and buries every other role on the resume.
const SEASONAL_EMPLOYER_RE =
  /\b(?:spirit\s*halloween|halloween\s*(?:city|express)|h\s*&\s*r\s*block|h\s+and\s+r\s+block|hr\s+block|jackson\s+hewitt|liberty\s+tax)\b/i;
// NOTE: the word "seasonal" appearing anywhere in an entry is NOT a usable
// trigger and was removed after it produced two false positives on the first
// full pass. A Starbucks shift supervisor of nine years mentioned "seasonal"
// in her duties and was cut to ten months; a kitchen job was cut in half the
// same way. Erasing real experience is far worse than missing a seasonal
// employer, so only the curated employer list flags a role now.

const TITLE_WORDS = [
  "manager", "management", "representative", "rep", "reps", "associate", "specialist", "assistant",
  "director", "technician", "tech", "agent", "consultant", "coordinator", "clerk", "cashier",
  "driver", "sales", "salesman", "salesperson", "owner", "lead", "leader", "supervisor",
  "intern", "analyst", "engineer", "teacher", "educator", "instructor", "professor", "tutor",
  "nurse", "cna", "lvn", "lpn", "rn", "server", "waiter", "waitress", "bartender", "barista",
  "host", "hostess", "receptionist", "secretary", "administrator", "admin", "officer", "sergeant",
  "corporal", "private", "operator", "mechanic", "installer", "worker", "laborer",
  "labourer", "crew", "member", "teller", "banker", "underwriter", "adjuster", "appraiser",
  "producer", "csr", "account", "executive", "president", "vp", "founder", "co-founder",
  "partner", "principal", "apprentice", "trainee", "musician", "photographer", "videographer",
  "artist", "designer", "developer", "programmer", "cook", "chef", "dishwasher", "stocker",
  "picker", "packer", "courier", "dispatcher", "planner", "buyer", "purchasing", "recruiter",
  "trainer", "coach", "therapist", "counselor", "advisor", "adviser", "broker", "realtor", "keeper", "zookeeper",
  "processor", "examiner", "inspector", "auditor", "bookkeeper", "accountant", "controller",
  "paralegal", "attorney", "pharmacist", "phlebotomist", "hygienist", "aide", "caregiver",
  "nanny", "professional", "contractor", "freelance", "freelancer", "self-employed",
  "entrepreneur", "staff", "generalist", "liaison", "ambassador", "greeter", "attendant",
  "guard", "security", "custodian", "janitor", "housekeeper", "housekeeping", "maintenance",
  "welder", "electrician", "plumber", "carpenter", "painter", "roofer", "foreman",
  "superintendent", "machinist", "assembler", "fabricator", "loader", "unloader", "forklift",
  "warehouse", "merchandiser", "team", "expert", "concierge", "porter",
  "valet", "usher", "lifeguard", "sitter", "babysitter", "helper", "handler", "librarian",
  "medic", "emt", "paramedic", "firefighter", "police", "deputy", "detective", "investigator",
  "notary", "closer", "opener", "keyholder", "key holder", "shift", "captain",
  "lieutenant", "commander", "airman", "seaman", "soldier", "marine", "scheduler",
  "biller", "coder", "collector", "collections", "loan", "mortgage", "originator", "telemarketer",
  "solicitor", "canvasser", "enumerator", "surveyor", "promoter", "demonstrator", "brand ambassador", "receiver",
  "shipper", "expediter", "runner", "busser", "busboy", "food runner", "prep", "line cook",
  "sous", "pastry", "baker", "butcher", "florist", "stylist", "cosmetologist", "barber",
  "esthetician", "massage", "dietitian", "nutritionist", "optician", "veterinary",
  "vet tech", "groomer", "kennel", "farmhand", "ranch hand", "landscaper", "groundskeeper",
  "gardener", "conductor", "pilot", "flight attendant", "steward", "purser",
  "translator", "interpreter", "editor", "writer", "author", "journalist", "reporter",
  "dj", "performer", "actor", "model", "influencer", "creator",
  "streamer", "youtuber", "podcaster", "student worker", "work study", "resident assistant",
  // Spanish titles (bilingual applicant pool)
  "cajero", "cajera", "vendedor", "vendedora", "gerente", "asistente", "recepcionista", "mesero", "mesera",
  "cocinero", "cocinera", "chofer", "agente", "representante", "asesor", "asesora", "administrador",
  "administradora", "técnico", "tecnico", "operador", "operadora", "ayudante", "auxiliar", "empleado",
  "empleada", "encargado", "encargada", "dependiente", "obrero", "contador", "contadora", "secretaria",
  "secretario", "maestro", "maestra", "profesor", "profesora", "enfermero", "enfermera", "cuidador",
  "cuidadora", "niñera", "jardinero", "mecánico", "mecanico", "soldador", "promotor", "promotora",
  "telefonista", "repartidor", "repartidora", "limpieza", "coordinador", "coordinadora",
  "graduate assistant", "research assistant", "lab assistant", "office assistant",
  "administrative assistant", "executive assistant", "personal assistant", "virtual assistant",
];
const EMPLOYER_WORDS = [
  "inc", "llc", "ltd", "corp", "corporation", "company", "co", "group", "agency", "agencies",
  "insurance", "bank", "credit union", "financial", "hospital", "clinic",
  "health", "healthcare", "medical center", "medical", "dental", "university", "college",
  "school", "schools", "district", "isd", "academy", "institute", "church", "ministries",
  "restaurant", "cafe", "café", "grill", "bar & grill", "bistro", "diner", "pizza", "burger",
  "tacos", "taqueria", "kitchen", "cantina", "steakhouse", "bbq", "hotel", "inn", "resort",
  "motel", "suites", "store", "stores", "market", "mart", "depot", "center", "centre",
  "services", "service", "solutions", "systems", "technologies", "enterprises", "industries",
  "partners", "associates", "foundation", "city of", "county", "state of", "department of",
  "dept of", "u.s.", "us army", "army", "navy", "air force", "marines", "marine corps",
  "coast guard", "national guard", "government", "federal", "township", "village of",
  "town of", "library", "museum", "theatre", "theater", "studio", "studios", "salon", "spa",
  "gym", "fitness", "club", "country club", "golf", "aquarium", "zoo", "park", "parks",
  "logistics", "trucking", "transport", "transportation", "freight", "shipping", "supply",
  "distribution", "wholesale", "retail", "outlet", "boutique", "pharmacy", "drug", "auto",
  "automotive", "motors", "toyota", "ford", "chevrolet", "honda", "nissan", "dealership",
  "realty", "real estate", "properties", "homes", "construction", "builders", "roofing",
  "plumbing", "electric", "hvac", "landscaping", "cleaning", "janitorial", "staffing",
  "consulting", "marketing", "media", "productions", "entertainment", "communications",
  "wireless", "cable", "network", "networks", "energy", "oil", "gas", "utilities",
  "walmart", "target", "amazon", "costco", "kroger", "heb", "h-e-b", "home depot", "lowe's",
  "lowes", "best buy", "starbucks", "mcdonald's", "mcdonalds", "chick-fil-a", "whataburger",
  "sonic", "wendy's", "taco bell", "subway", "domino's", "pizza hut", "papa john's",
  "raising cane's", "chipotle", "panera", "olive garden", "applebee's", "chili's", "ihop",
  "denny's", "waffle house", "cracker barrel", "texas roadhouse", "buffalo wild wings",
  "usaa", "state farm", "allstate", "geico", "progressive", "farmers", "liberty mutual",
  "nationwide", "travelers", "aflac", "humana", "aetna", "cigna", "unitedhealthcare",
  "unitedhealth", "wellmed", "spectrum", "at&t", "verizon", "t-mobile", "comcast", "xfinity",
  "frontier", "cvs", "walgreens", "dollar general", "dollar tree", "family dollar", "kohl's",
  "macy's", "jcpenney", "dillard's", "ross", "tj maxx", "marshalls", "old navy", "gap",
  "nike", "academy sports", "dick's", "bass pro", "cabela's", "petsmart", "petco",
  "chase", "wells fargo", "bank of america", "citi", "capital one", "frost", "broadway bank",
  "randolph-brooks", "rbfcu", "security service", "ssfcu", "navy federal", "pnc", "truist",
  "regions", "fedex", "ups", "usps", "postal", "dhl", "uber", "lyft", "doordash", "instacart",
  "favor", "grubhub", "six flags", "seaworld", "fiesta texas", "aquatica", "schlitterbahn",
  "methodist", "baptist", "christus", "university health", "veterans affairs",
  "kindred", "encompass", "dialysis", "davita", "fresenius", "quest", "labcorp",
];

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
// Plurals count too: "Sales Representatives 2022-2024" carried no title
// signal at all because only the singular was listed (Reyna Hanssen).
const TITLE_RE = new RegExp(`\\b(?:${TITLE_WORDS.map(escapeRe).join("|")})(?:s|es)?\\b`, "ig");
const EMPLOYER_RE = new RegExp(`(?:^|\\b|(?<=\\W))(?:${EMPLOYER_WORDS.map(escapeRe).join("|")})(?:\\b|(?=\\W)|$)`, "ig");
// Title words that also live inside employer names and department names
// ("Cellular Sales", "Account Services", "Team Fusion"). They count for the
// score, but never on their own make a label a title when a proper title
// word sits on the other side of a separator.
const WEAK_TITLE_WORDS: ReadonlySet<string> = new Set(["sales", "account", "team", "staff", "professional", "expert", "security", "maintenance", "crew", "warehouse", "shift", "loan", "mortgage", "collections", "prep"]);
// "Porter's", "Chili's", "Denny's": a possessive is a business name, so the
// word inside it ("porter") must not score as a job title (Ashley Caswell's
// employer became her title, 2026-08-26).
function withoutPossessives(s: string): string {
  return s.replace(/\b[A-Za-z]+['\u2019]s\b/g, " ");
}

function titleScore(s: string): number {
  return (withoutPossessives(s).match(TITLE_RE) ?? []).length;
}
function strongTitleScore(s: string): number {
  return (withoutPossessives(s).match(TITLE_RE) ?? []).filter((w) => {
    const lw = w.toLowerCase();
    return !(WEAK_TITLE_WORDS.has(lw) || WEAK_TITLE_WORDS.has(lw.replace(/s$/, "")) || WEAK_TITLE_WORDS.has(lw.replace(/es$/, "")));
  }).length;
}
function employerScore(s: string): number {
  return (s.match(EMPLOYER_RE) ?? []).length;
}
/** The last real word of a label, ignoring "(BDC)", "II", "Level 3", punctuation. */
function lastWord(s: string): string {
  const t = s.replace(/\([^)]*\)\s*$/, "").replace(/[\s.,;:|\-–—]+$/, "").trim();
  const words = t.split(/\s+/).filter((w) => /[A-Za-z]/.test(w));
  for (let i = words.length - 1; i >= 0; i--) {
    const w = words[i].toLowerCase().replace(/[^a-z'’-]/g, "");
    if (/^(?:i|ii|iii|iv|v|jr|sr|level|lvl|l\d)$/.test(w)) continue;
    return w;
  }
  return "";
}
const TITLE_WORD_EXACT_RE = new RegExp(`^(?:${TITLE_WORDS.map(escapeRe).join("|")})(?:s|es)?$`, "i");
const EMPLOYER_WORD_EXACT_RE = new RegExp(`^(?:${EMPLOYER_WORDS.map(escapeRe).join("|")})$`, "i");
function lastWordIsTitle(s: string): boolean {
  const w = lastWord(s);
  if (!w || WEAK_TITLE_WORDS.has(w)) return false;
  return TITLE_WORD_EXACT_RE.test(w) && !/['’]s$/.test(w);
}
function lastWordIsEmployer(s: string): boolean {
  const w = lastWord(s);
  if (!w) return false;
  return EMPLOYER_WORD_EXACT_RE.test(w);
}

// A location is a state (name or CODE), optionally preceded by a KNOWN city
// or a directional ("Southern California"). Unknown words before a state are
// NOT assumed to be a city — "Acme Widgets TX" would otherwise be thrown away
// as a location. Two-letter codes are matched CASE-SENSITIVELY as uppercase
// (except "Tx"-style, handled in the trailing strip) so that "Handshake Al"
// is not read as Alabama.
const KNOWN_CITIES: ReadonlySet<string> = new Set([
  // Texas
  "san antonio", "austin", "houston", "dallas", "fort worth", "el paso", "arlington", "corpus christi",
  "plano", "laredo", "lubbock", "garland", "irving", "amarillo", "grand prairie", "brownsville",
  "mckinney", "frisco", "pasadena", "killeen", "mesquite", "mcallen", "denton", "waco", "carrollton",
  "round rock", "abilene", "pearland", "richardson", "midland", "odessa", "college station",
  "san marcos", "new braunfels", "boerne", "helotes", "schertz", "cibolo", "seguin", "converse",
  "live oak", "universal city", "leon valley", "kirby", "alamo heights", "castle hills",
  "hollywood park", "shavano park", "selma", "pleasanton", "floresville", "kerrville",
  "fredericksburg", "bandera", "castroville", "hondo", "uvalde", "del rio", "eagle pass",
  "victoria", "beeville", "temple", "belton", "harker heights", "georgetown", "cedar park",
  "leander", "pflugerville", "kyle", "buda", "lockhart", "bastrop", "elgin", "taylor", "hutto",
  "sugar land", "katy", "spring", "the woodlands", "conroe", "humble", "baytown", "league city",
  "missouri city", "cypress", "tomball", "beaumont", "port arthur", "tyler", "longview",
  "texarkana", "sherman", "wichita falls", "san angelo", "bryan", "huntsville", "nacogdoches",
  "lufkin", "galveston", "texas city", "friendswood", "rosenberg", "richmond",
  "aubrey", "prosper", "allen", "wylie", "rockwall", "rowlett", "lewisville", "flower mound",
  "grapevine", "euless", "bedford", "hurst", "keller", "southlake", "coppell", "mansfield",
  "burleson", "cleburne", "weatherford", "granbury", "stephenville", "brownwood", "marble falls",
  "burnet", "llano", "junction", "fort stockton", "alpine", "pecos", "big spring", "snyder",
  "sweetwater", "mineral wells", "decatur", "gainesville", "bonham", "paris", "sulphur springs",
  "greenville", "mount pleasant", "marshall", "henderson", "jacksonville", "palestine", "athens",
  "corsicana", "waxahachie", "ennis", "hillsboro", "gatesville", "copperas cove", "lampasas",
  "kingsland", "horseshoe bay", "wimberley", "dripping springs", "bee cave", "lakeway", "manor",
  // Small Bexar-county-and-adjacent towns that show up as job locations in
  // this applicant pool. Without them "Von Ormy, TX" is not recognised as a
  // place and survives as a label, which cost Sarah Patlan both her titles.
  "von ormy", "china grove", "elmendorf", "macdona", "atascosa", "lytle", "natalia", "devine",
  "poteet", "jourdanton", "adkins", "saint hedwig", "st. hedwig", "la vernia", "marion",
  "new berlin", "sutherland springs", "bulverde", "spring branch", "garden ridge",
  "fair oaks ranch", "timberwood park", "stone oak", "somerset", "sabinal", "comfort",
  "blanco", "johnson city", "dilley", "pearsall", "cotulla", "canyon lake", "bigfoot",
  "charlotte", "falls city", "kenedy", "karnes city", "runge", "nixon", "smiley",
  "fort hood", "fort cavazos", "fort sam houston", "lackland", "randolph", "fort bliss",
  // other US
  "los angeles", "san diego", "san francisco", "san jose", "sacramento", "oakland", "fresno",
  "long beach", "anaheim", "riverside", "moreno valley", "bakersfield", "stockton", "irvine",
  "santa ana", "chula vista", "upland", "ontario", "rancho cucamonga", "fontana", "corona",
  "temecula", "murrieta", "escondido", "oceanside", "phoenix", "tucson", "mesa", "chandler",
  "scottsdale", "glendale", "gilbert", "tempe", "peoria", "las vegas", "reno",
  "north las vegas", "denver", "colorado springs", "aurora", "albuquerque", "santa fe",
  "las cruces", "oklahoma city", "tulsa", "norman", "lawton", "kansas city", "st. louis",
  "st louis", "wichita", "omaha", "lincoln", "des moines", "chicago", "indianapolis", "columbus",
  "cleveland", "cincinnati", "detroit", "milwaukee", "minneapolis", "st. paul", "st paul",
  "atlanta", "charlotte", "raleigh", "durham", "greensboro", "fayetteville", "hope mills",
  "wilmington", "nashville", "memphis", "knoxville", "chattanooga", "louisville", "lexington",
  "orlando", "tampa", "miami", "fort lauderdale", "st. petersburg", "tallahassee",
  "pensacola", "new york", "brooklyn", "queens", "bronx", "manhattan", "buffalo", "rochester",
  "albany", "white plains", "pine island", "philadelphia", "pittsburgh", "harrisburg", "baltimore",
  "washington", "boston", "seattle", "tacoma", "spokane", "portland", "salt lake city", "provo",
  "birmingham", "montgomery", "mobile", "new orleans", "baton rouge", "shreveport",
  "lafayette", "lake charles", "little rock", "fort smith", "jackson", "biloxi", "gulfport",
  "virginia beach", "norfolk", "alexandria", "charleston", "columbia",
  "savannah", "augusta", "macon", "boise", "billings", "cheyenne", "fargo",
  "sioux falls", "anchorage", "honolulu", "hartford", "providence", "newark", "jersey city",
  "trenton", "dover", "manchester", "burlington", "skokie", "niles",
  "lynchburg", "overland park", "saratoga springs", "greenwich",
  "zillah", "sunnyside", "yakima", "toppenish", "grandview", "prosser", "wapato",
  // 2026-08-26 cohort: places that survived as labels because they were missing
  "fort davis", "fort stockton", "san angelo", "mount pleasant", "deland", "new york city",
  "pittsburgh", "omaha", "bellevue", "cedar hill", "mission", "edinburg", "pharr", "harlingen",
  "weslaco", "alice", "kingsville", "portland", "wimberley", "canyon lake", "port lavaca",
]);
// "Fort Davis", "Port Arthur", "Mount Pleasant", "Lake Jackson": a place
// pattern for towns not in the list, only ever tested in a city position.
const CITY_PATTERN_RE = /^(?:fort|ft\.?|port|mount|mt\.?|lake|saint|st\.?)\s+[a-z][a-z.'-]+$/i;
function isKnownCity(s: string): boolean {
  const t = s.trim().toLowerCase().replace(/[.,;]+$/, "");
  return KNOWN_CITIES.has(t) || CITY_PATTERN_RE.test(t);
}
// For a label standing ALONE: only a multi-word city or a Fort/Port/Mount
// pattern is safely a place. A single word that happens to be a city name
// is just as likely an employer — Burlington (the store), Target, Frost,
// Marion — and reading it as a place erased Anna Sanabia's employer.
function isKnownCityAlone(s: string): boolean {
  const t = s.trim().toLowerCase().replace(/[.,;]+$/, "");
  return (KNOWN_CITIES.has(t) && /\s/.test(t)) || CITY_PATTERN_RE.test(t);
}
const STATE_NAME_RE = new RegExp(`^(?:${US_STATE_NAMES})$`, "i");
const STATE_CODE_RE = new RegExp(`^(?:${US_STATE_ABBR})$`); // case-sensitive: uppercase only
function isStateToken(tok: string): boolean {
  const t = tok.trim().replace(/\.$/, "");
  return STATE_CODE_RE.test(t) || STATE_NAME_RE.test(t);
}
function isStateTokenLoose(tok: string): boolean {
  // "Tx" / "tx" — only trusted in the trailing-strip position after a comma
  const t = tok.trim().replace(/\.$/, "");
  return isStateToken(t) || (t.length === 2 && STATE_CODE_RE.test(t.toUpperCase()));
}
const DIRECTIONAL_RE = /^(?:greater|north(?:ern)?|south(?:ern)?|east(?:ern)?|west(?:ern)?|central|downtown|metro|the)$/i;
const LOOSE_LOCATION_RE = new RegExp(
  `^(?:remote|hybrid|on[- ]?site|nationwide|usa|u\\.s\\.a?\\.?|united states|various locations|multiple locations|home[- ]based|work from home|wfh|worldwide|online|virtual)$`,
  "i",
);

/**
 * True when the whole segment is a place, not a title or employer:
 * "San Antonio, TX", "San Antonio TX 78250", "Moreno Valley, California",
 * "Texas", "TX", "Southern California", "Remote", "USA".
 */
function isLocation(s: string): boolean {
  let t = s.trim().replace(/[.,;|&]+$/, "").trim();
  if (!t) return false;
  if (LOOSE_LOCATION_RE.test(t)) return true;
  // a bare multi-word city ("San Angelo", "Fort Davis") with nothing else is a place
  if (isKnownCityAlone(t)) return true;
  if (isCityList(t)) return true;
  // drop trailing zip / country
  t = t.replace(/\s*\d{5}(?:-\d{4})?$/, "").replace(/,?\s*\(?(?:usa|us|united states)\)?$/i, "").trim();
  if (isStateToken(t)) return true;
  // "<city>, <state>" or "<city> <state>"
  const m = t.match(/^(.*?)[,\s]+([A-Za-z.]{2,20}(?:\s[A-Za-z]{4,9})?)$/);
  if (!m) return false;
  const cityPart = m[1].trim().replace(/,$/, "").trim();
  const st = m[2].trim();
  if (!isStateToken(st)) return false;
  if (!cityPart) return true;
  const cityLower = cityPart.toLowerCase();
  if (KNOWN_CITIES.has(cityLower)) return true;
  if (DIRECTIONAL_RE.test(cityLower)) return true;
  // "Weirdville, TX" — one unknown word, comma, state, no job words
  const words = cityLower.split(/\s+/);
  if (words.length === 1 && /,/.test(t) && titleScore(cityPart) === 0 && employerScore(cityPart) === 0) return true;
  return false;
}

/**
 * Strips a trailing "- City, ST" / ", City, ST" / " City, ST" / "| City ST"
 * (KNOWN city, or bare state) plus zip / country off a segment. Unknown
 * words are left in place — better a slightly long employer name than a
 * lost one.
 */
function stripTrailingLocation(s: string): string {
  let t = s.trim();
  t = t.replace(/[\s\-\u2013\u2014|,;:(]+$/g, "").trim();
  t = t.replace(/\s*\d{5}(?:-\d{4})?$/, "").replace(/,?\s*\(?(?:usa|us|united states)\)?$/i, "").trim();
  for (let pass = 0; pass < 2; pass++) {
    const m = t.match(/^(.*?)([,;|]\s*|\s+[\-\u2013\u2014]\s*|\s+)([A-Za-z.]{2,20}(?:\s[A-Za-z]{4,9})?)$/);
    if (!m) break;
    const head = m[1];
    const sep = m[2];
    const st = m[3].trim();
    const commaBefore = /^[,;|]/.test(sep);
    if (!(isStateToken(st) || (commaBefore && isStateTokenLoose(st)))) break;
    let peeled = head.replace(/[\s,;|\-\u2013\u2014]+$/g, "").trim();
    if (!peeled) return "";
    // peel a known city (up to 3 words) off the end
    const hw = peeled.split(/\s+/);
    for (let n = Math.min(3, hw.length - 1); n >= 1; n--) {
      const cand = hw.slice(hw.length - n).join(" ").toLowerCase().replace(/,/g, "");
      if (isKnownCity(cand)) {
        peeled = hw.slice(0, hw.length - n).join(" ").replace(/[\s,;|\-\u2013\u2014]+$/g, "").trim();
        break;
      }
    }
    if (!peeled) return "";
    t = peeled;
  }
  t = t.replace(/[\s\-\u2013\u2014|,;:(&]+$/g, "").replace(/\s+\band\s*$/i, "").trim();
  // "Cibolo & San Antonio, TX" peeled to "Cibolo": what is left after the
  // state is only ever a place when it was joined to the peeled city by
  // "&" / "and", so it goes too (Clara Bryant's Petco header).
  if (t !== s.trim() && (isCityList(t) || (KNOWN_CITIES.has(t.toLowerCase()) && /[&]|\band\b/i.test(s)))) return "";
  return t;
}

/** Cleans a raw header piece into a label, or returns null if it is junk. */
// Common abbreviations that end in a period without ending a sentence.
const ABBREV_BEFORE_PERIOD_RE = /\b(?:st|mt|ft|dr|mr|mrs|ms|jr|sr|inc|co|corp|ltd|llc|no|vs|dept|univ|assoc|bros|mfg|intl|natl|ave|blvd|rd|u\.s|u\.s\.a|d\.c|e\.g|i\.e|etc|approx)\.$/i;
/**
 * "Census Bureau. My job description included going to civilian homes" —
 * a sentence boundary inside a label means the label ended at the period.
 * Keeps the part before the boundary when it is a plausible name and the
 * part after reads as a sentence (Max Dunlop, 2026-08-26).
 */
function cutAtSentenceBoundary(s: string): string {
  const m = s.match(/^(.+?[a-z])\.\s+([A-Z][a-z].*)$/);
  if (!m) return s;
  const head = m[1].trim();
  const tail = m[2].trim();
  if (ABBREV_BEFORE_PERIOD_RE.test(head + ".")) return s;
  if (wordCount(tail) < 3) return s;
  return head;
}

function cleanSegment(raw: string): string | null {
  let s = raw.replace(/\s+/g, " ").trim();
  // markdown remnants: "** Sales Associate**", "__Cashier__", "# Manager"
  s = s.replace(/\*{1,3}|_{2,3}|^#{1,6}\s+/g, "").trim();
  s = s.replace(/^[\s•·●○◦▪■\-–—|:;,.&]+/, "").replace(/[\s•·●○◦▪■\-–—|:;,&]+$/, "").replace(/\s+\band\s*$/i, "").trim();
  if (isStreetAddress(s)) return null;
  s = stripEmbeddedAddress(s);
  s = cutAtSentenceBoundary(s);
  // parenthesised employment type: "(Part-time)", "(Remote)"
  s = s.replace(/\((?:full[- ]?time|part[- ]?time|contract(?:or)?|seasonal|temporary|temp|remote|hybrid|on[- ]?site|per diem)\)/gi, "").trim();
  s = s.replace(/[·|]\s*(?:full[- ]?time|part[- ]?time|contract|seasonal|temporary|internship|remote|hybrid)\s*$/i, "").trim();
  if (!s) return null;
  if (s.length < 2) return null;
  if (isPunctOnly(s)) return null;
  if (isLocation(s)) return null;
  // Drop a segment only when it is NOTHING BUT employment-type words
  // ("Part-time", "Seasonal", "Contract"). The old rule dropped any short
  // segment CONTAINING one, which silently deleted real employer names:
  // "ADECCO Temp.Svc" matched \btemp\b, the job lost its employer entirely,
  // and the forward-look then stole the NEXT entry's title (Dogan, 2026-08-19).
  if (titleScore(s) === 0 && s.replace(EMPLOYMENT_TYPE_ALL_RE, " ").replace(/[^A-Za-z0-9]/g, "") === "") return null;
  if (/^(?:dates?|duration|period|role|position|title|company|employer|responsibilities|duties|professional|experience|summary|objective|description|achievements|accomplishments|highlights|overview|profile|details|key responsibilities|responsibilities:|skills|education|references|present|current)$/i.test(s)) return null;
  s = stripTrailingLocation(s);
  if (!s || s.length < 2) return null;
  // a skills-column word on its own ("Customer Service", "English") is glue
  if (isSkillPhrase(s) && titleScore(s) === 0 && employerScore(s) === 0) return null;
  s = stripTrailingSkill(s);
  if (looksLikeProse(s)) return null;
  // Not a label if it has no letters at all
  if (!/[A-Za-z]/.test(s)) return null;
  return s;
}

/** "San Angelo and San Antonio", "Cibolo & San Antonio": every part is a known place. */
function isCityList(s: string): boolean {
  const parts = s.split(/\s+(?:and|&)\s+|\s*\/\s*/i).map((x) => x.trim()).filter(Boolean);
  return parts.length >= 2 && parts.every((x) => isKnownCity(x) || isLocation(x));
}

/**
 * "Customer Support Specialist Conduent", "Customer Service Representative
 * Circle K": a title with the employer fused straight after it. Only tried
 * on a piece that HAD a trailing location ("..., San Antonio, TX") — that is
 * the layout where the employer precedes the place — and only when what
 * follows the last title word is one to three capitalised words with no job
 * word, employment-type word or skill word among them (Tatyana Wood).
 */
function splitFusedTitleEmployer(s: string): string[] {
  const words = s.split(/\s+/);
  if (words.length < 3) return [s];
  let lastTitleIdx = -1;
  for (let i = 0; i < words.length; i++) {
    const w = words[i].replace(/[^A-Za-z'’-]/g, "");
    if (w && TITLE_WORD_EXACT_RE.test(w) && !/['’]s$/.test(w)) lastTitleIdx = i;
  }
  if (lastTitleIdx < 1 || lastTitleIdx >= words.length - 1) return [s];
  const tailWords = words.slice(lastTitleIdx + 1);
  if (tailWords.length > 3) return [s];
  const tail = tailWords.join(" ");
  const head = words.slice(0, lastTitleIdx + 1).join(" ");
  if (!tailWords.every((w) => /^(?:[A-Z][A-Za-z.'’&-]*|[A-Z0-9&.'’-]+)$/.test(w))) return [s];
  if (titleScore(tail) > 0 || EMPLOYMENT_TYPE_RE.test(tail) || isSkillPhrase(tail)) return [s];
  if (/^(?:I|II|III|IV|Jr|Sr|Pro|Plus|Bilingual|Remote|Lead|Senior|Junior)\b/.test(tail)) return [s];
  if (strongTitleScore(head) === 0) return [s];
  return [head, tail];
}

/**
 * Splits a header line into candidate label pieces on strong separators
 * (pipe, em/en dash, spaced hyphen, middle dot, semicolon, tab). Commas are
 * handled more carefully: ", Inc." style suffixes stay attached and a
 * trailing "City, ST" is stripped rather than split.
 */
function splitHeaderLine(line: string): string[] {
  let s = line.replace(/\s+/g, " ").trim();
  // keep corporate suffixes attached
  s = s.replace(/,\s*(inc|llc|l\.l\.c|ltd|co|corp|pllc|pc|lp|llp|plc)\b\.?/gi, " $1");
  // "TX- Title" (state code glued to a hyphen) is a separator
  s = s.replace(new RegExp(`\\b(${US_STATE_ABBR})\\s*-\\s+`, "g"), "$1 - ");
  let pieces = s.split(/\s*(?:\||\u2013|\u2014|\u2015|\u2192|\t|;|\s-\s|\s\u00b7\s|\s\u2022\s|\s\/\/\s)\s*/).map((p) => p.trim()).filter(Boolean);
  // "Burlington/ Associate", "Walmart/ Maintenance": a slash with a space
  // AFTER it and none before is a separator between employer and title.
  // "Cashier/Customer Service" and "Barista/Shift Supervisor" have no such
  // space and stay one label (Anna Sanabia, 2026-08-26).
  pieces = pieces.flatMap((p) => {
    const m = p.match(/^(\S.*?\S)\/\s+(\S.*)$/);
    if (!m) return [p];
    const a = m[1].trim();
    const b = m[2].trim();
    const aT = titleScore(a) > 0;
    const bT = titleScore(b) > 0;
    if (aT !== bT && wordCount(a) <= 4 && wordCount(b) <= 6) return [a, b];
    return [p];
  });
  const out: string[] = [];
  for (const p0 of pieces) {
    // a piece that is only a place ("San Antonio, TX", "Texas") is dropped whole
    if (isLocation(p0)) continue;
    let p = p0;
    // "Dispatcher Sicola's Florist": a possessive business name glued straight
    // onto a title. Split where the possessive starts (Rosalie Jackson).
    const poss = p.match(/^(.+?\S)\s+((?:[A-Z][A-Za-z]*['\u2019]s)\b.*)$/);
    if (poss && titleScore(poss[1]) > 0 && wordCount(poss[2]) <= 3 && !/[,\-–—/&|]$/.test(poss[1]) && !/\b(?:at|for|with|of|the|and)$/i.test(poss[1])) {
      out.push(poss[1].trim());
      p = poss[2].trim();
    }
    // "Cashier at Walmart" / "Server @ Chili's" -> two pieces
    const atSplit = p.match(/^(.+?)\s+(?:at|@)\s+(.+)$/i);
    if (atSplit && titleScore(atSplit[1]) > 0 && !/\bat\b/i.test(atSplit[2])) {
      out.push(atSplit[1].trim());
      p = atSplit[2].trim();
      if (isLocation(p)) continue;
    }
    // location glued into the middle: "Tifton, GA Store Manager",
    // "Valdosta, GA Lead Sales Associate" -> drop the place, keep the title.
    const mid = p.match(new RegExp(`^(.+?),\\s*(${US_STATE_ABBR})\\.?\\s+([A-Z][^,]*)$`));
    if (mid) {
      const leftPart = mid[1].trim();
      const rest = mid[3].trim();
      const leftIsCity = KNOWN_CITIES.has(leftPart.toLowerCase()) ||
        (wordCount(leftPart) === 1 && titleScore(leftPart) === 0 && employerScore(leftPart) === 0);
      if (!leftIsCity) out.push(leftPart);
      if (rest) out.push(rest);
      continue;
    }
    // trailing location by comma: "Best Buy, Round Rock, TX" -> "Best Buy"
    const stripped = stripTrailingLocation(p);
    if (stripped !== p && stripped) {
      // if what remains still has commas, treat them as separators
      if (stripped.includes(",")) out.push(...stripped.split(",").map((x) => x.trim()).filter(Boolean));
      else out.push(...splitFusedTitleEmployer(stripped));
      continue;
    }
    if (p.includes(",")) {
      let parts = p.split(",").map((x) => x.trim()).filter(Boolean);
      // "Academy Sports and Outdoors, San Angelo and San Antonio, Supervising
      // cashiers": drop the parts that are places or skills-column glue, and
      // if one real label is left that is the label (Ashley Caswell).
      if (parts.length >= 2) {
        const kept = parts.filter((x) => !isLocation(x) && !(isSkillPhrase(x) && titleScore(x) === 0 && employerScore(x) === 0) && !isCityList(x) && !/^[A-Z][a-z]+ing\s+[a-z]/.test(x));
        if (kept.length === 1) { out.push(kept[0]); continue; }
        if (kept.length >= 1 && kept.length < parts.length) parts = kept;
      }
      // A comma list where at least one part is employer-ish and another
      // title-ish is "Title, Employer" — split. A list of title-ish words
      // ("Keyboardist, Vocalist, Music Director") stays one label.
      const anyEmp = parts.some((x) => employerScore(x) > 0 && titleScore(x) === 0);
      const anyTitle = parts.some((x) => titleScore(x) > 0);
      if (parts.length <= 3 && anyEmp && anyTitle) out.push(...parts);
      else if (parts.length === 2 && anyEmp !== anyTitle) out.push(...parts);
      else out.push(p);
      continue;
    }
    out.push(p);
  }
  return out;
}

// -------------------------------------------------------------------------
// Seasonal roles
// -------------------------------------------------------------------------

/**
 * Decides whether a role is seasonal and, if so, which months of the year it
 * actually covers.
 *
 * The season window is derived from the range the resume itself gives rather
 * than from a hardcoded calendar: a Halloween shop written "September 2016 to
 * November 2025" tells us the season runs month 9 through month 11, and a tax
 * office written "January 2018 to April 2024" tells us months 1 through 4.
 * That is both more accurate than a fixed guess and self-correcting for
 * employers not on the list, so long as something flags the role as seasonal.
 *
 * Returns null for ordinary roles, which keep the plain span.
 */
function seasonalProfile(
  title: string | null,
  employer: string | null,
  headerText: string,
  dateLineText: string,
  start: MonthYear,
  end: MonthYear,
  isCurrent: boolean,
): { seasonMonths: number[]; months: number } | null {
  if (isCurrent) return null; // an open-ended role has no closing season month
  const hay = `${title ?? ""} ${employer ?? ""} ${headerText} ${dateLineText}`;
  if (!SEASONAL_EMPLOYER_RE.test(hay)) return null;
  // Only meaningful when the stated range spans more than one year — a single
  // genuine season ("Sep 2024 to Nov 2024") is already correct as written.
  if (end.year <= start.year) return null;
  if (monthsBetween(start, end) < 13) return null;
  const seasonMonths: number[] = [];
  if (start.month <= end.month) {
    for (let m = start.month; m <= end.month; m++) seasonMonths.push(m);
  } else {
    // season wraps the new year (a holiday-retail "November to February")
    for (let m = start.month; m <= 12; m++) seasonMonths.push(m);
    for (let m = 1; m <= end.month; m++) seasonMonths.push(m);
  }
  // Sanity-check the derived window. A one-month "season" is almost always a
  // coincidence — a multi-year job that happens to start and end in the same
  // month of the year — and treating it as seasonal destroys the tenure. A
  // window of nine months or more is not a season either.
  if (seasonMonths.length < 2 || seasonMonths.length > 8) return null;
  const seasons = end.year - start.year + (start.month <= end.month ? 1 : 0);
  const months = Math.max(seasonMonths.length, seasons * seasonMonths.length);
  return { seasonMonths, months };
}

// -------------------------------------------------------------------------
// Layout voting
// -------------------------------------------------------------------------

type Layout = "title-first" | "employer-first";

// A label that ENDS in a job-title word is a title even when an employer
// word sits inside it: "Real Estate Agent", "Licensed Health & Life
// Insurance Agent", "Finance & Logistics Analyst Intern". Before this rule
// those scored as neither, the layout vote had nothing to go on, and Ruben
// Lopez's whole resume came out reversed (2026-08-26). Symmetrically a label
// ending in an employer word with no title word at its end is an employer
// ("Keller Williams Realty", "Unimex Logistics").
function isStrongTitle(s: string): boolean {
  if (SELF_EMPLOYED_RE.test(s)) return false;
  if (/^[A-Z][A-Za-z]*['\u2019]s\b/.test(s)) return false;
  if (strongTitleScore(s) > 0 && employerScore(s) === 0) return true;
  return lastWordIsTitle(s);
}
function isStrongEmployer(s: string): boolean {
  if (employerScore(s) > 0 && titleScore(s) === 0) return true;
  return lastWordIsEmployer(s) && !lastWordIsTitle(s) && strongTitleScore(s) === 0;
}

/**
 * Works out whether THIS resume writes the job title above the employer or
 * the other way round, by looking only at the entries where the keyword lists
 * are unambiguous (one line clearly a title, another clearly an employer).
 *
 * WHY: the keyword lists cannot settle every entry on their own. "Health Care
 * Provider" is a job title that contains an employer word ("health"); "Parts
 * and Service" is a job title that contains an employer word ("service");
 * "Aim Care", "Kent Powersports" and "Circle K" are employers that contain no
 * employer word at all. Judged entry-by-entry those come out backwards. But a
 * resume is internally consistent: whichever way round the entries WE CAN
 * read are written, the rest are written the same way. Voting once per
 * document and applying the result fixed eight confirmed swaps.
 *
 * Only multi-line entries vote. Two labels split off a single line carry no
 * line-order information.
 */
function voteLayout(entriesLabels: string[][][]): Layout {
  let titleFirst = 0;
  let employerFirst = 0;
  for (const lines of entriesLabels) {
    if (lines.length < 2) continue;
    const firstLine = lines[0];
    const lastLine = lines[lines.length - 1];
    const fT = firstLine.some(isStrongTitle);
    const fE = firstLine.some(isStrongEmployer);
    const lT = lastLine.some(isStrongTitle);
    const lE = lastLine.some(isStrongEmployer);
    if (fT && !fE && lE && !lT) titleFirst++;
    else if (fE && !fT && lT && !lE) employerFirst++;
  }
  if (employerFirst > titleFirst) return "employer-first";
  // Ties and no-evidence default to title-first, the more common convention
  // and the same default the previous version used.
  return "title-first";
}

/** Joins one line's labels back into a single readable label. */
function joinLine(labels: string[]): string | null {
  const uniq = labels.filter((l, i) => labels.findIndex((x) => x.toLowerCase() === l.toLowerCase()) === i);
  if (uniq.length === 0) return null;
  return uniq.join(" - ");
}

/**
 * Decides title and employer for one entry, using keyword evidence first and
 * the document's layout convention only where the keywords cannot separate
 * the two.
 */
function assignTitleEmployerFromLines(
  labelsPerLine: string[][],
  layout: Layout,
): { title: string | null; employer: string | null } {
  const lines = labelsPerLine.filter((g) => g.length > 0);
  if (lines.length === 0) return { title: null, employer: null };
  const flat = lines.flatMap((g, li) => g.map((s) => ({ s, li })));

  // 1. Unambiguous keyword evidence wins outright, on one line or across two.
  const strongT = flat.filter((x) => isStrongTitle(x.s));
  const strongE = flat.filter((x) => isStrongEmployer(x.s));
  if (strongT.length > 0 && strongE.length > 0) {
    // A line that carries BOTH a strong title and a strong employer is a
    // complete header ("Walmart, Fort Stockton, TX — Team Lead"). A lone
    // title on the line above it is column glue from the skills list
    // ("Cashier"), not this job — take the title from the complete line.
    const completeLine = lines.findIndex((g) => g.some(isStrongTitle) && g.some(isStrongEmployer) && g.length >= 2);
    const t = completeLine >= 0 ? strongT.find((x) => x.li === completeLine)! : strongT[0];
    // Prefer an employer on a DIFFERENT line to the title. "Manager, Customer
    // Service" puts an employer-looking piece ("Service" is an employer word)
    // on the very same line as the title, and taking it left the real employer
    // one line below unread (Abraham Ochoa's current role).
    // Failing that, a line with no title word at all ("Aim Care") is the
    // employer rather than an employer-looking piece on the title's own line
    // ("Customer Service" in "Manager, Customer Service").
    const otherLine = lines.findIndex((g, li) => li !== t.li && g.every((x) => titleScore(x) === 0));
    const e = strongE.find((x) => x.li !== t.li)
      ?? (otherLine >= 0 ? { s: joinLine(lines[otherLine]) ?? lines[otherLine][0], li: otherLine } : undefined)
      ?? strongE.find((x) => x.s !== t.s) ?? strongE[0];
    if (e.s !== t.s) {
      // With the employer on its own line, everything on the title's line
      // belongs to the title, and vice versa.
      const tLabel = t.li !== e.li ? joinLine(lines[t.li]) : t.s;
      const eLabel = t.li !== e.li && lines[e.li].every((x) => !isStrongTitle(x))
        ? joinLine(lines[e.li]) : e.s;
      return { title: tLabel ?? t.s, employer: eLabel ?? e.s };
    }
  }

  // 1b. One line carries a strong title and another line carries no title
  //     word at all: that other line is the employer, whatever the layout
  //     ("Skyplace FBO" over "CSR - Customer Service Representative",
  //     "TX Dot" over "Civil Engineering Intern"). Symmetrically a strong
  //     employer over a line with a title word and no employer word.
  if (lines.length >= 2) {
    const tLines = lines.map((g) => g.some(isStrongTitle));
    const noTitleLines = lines.map((g) => g.every((x) => titleScore(x) === 0));
    const tIdx = tLines.findIndex(Boolean);
    if (tIdx >= 0 && tLines.filter(Boolean).length === 1) {
      const eIdx = noTitleLines.findIndex((v, li) => v && li !== tIdx);
      if (eIdx >= 0) return { title: joinLine(lines[tIdx]), employer: joinLine(lines[eIdx]) };
    }
    const eLines = lines.map((g) => g.some(isStrongEmployer));
    const eIdx2 = eLines.findIndex(Boolean);
    if (eIdx2 >= 0 && eLines.filter(Boolean).length === 1) {
      const tIdx2 = lines.findIndex((g, li) => li !== eIdx2 && g.some((x) => titleScore(x) > 0) && g.every((x) => employerScore(x) === 0));
      if (tIdx2 >= 0) return { title: joinLine(lines[tIdx2]), employer: joinLine(lines[eIdx2]) };
    }
  }

  // 2. Keywords could not separate them. If the entry spans two or more
  //    lines, the document's layout decides — this is the case the old
  //    coin-flip got wrong roughly half the time.
  if (lines.length >= 2) {
    const firstLabel = joinLine(lines[0]);
    const lastLabel = joinLine(lines[lines.length - 1]);
    if (firstLabel && lastLabel && firstLabel !== lastLabel) {
      return layout === "employer-first"
        ? { title: lastLabel, employer: firstLabel }
        : { title: firstLabel, employer: lastLabel };
    }
  }

  // 3. Everything came off ONE line, so there is no line order to appeal to.
  //    Fall back to keyword scoring — but only when SOMETHING on the line
  //    carries title evidence at all. "H-E-B - Customer Service Associate" has
  //    a real title in it even though that title also contains employer words,
  //    whereas "CoreCivic - T. Don Hutto Residential Center" is one employer
  //    written two ways and must not have a title invented for it.
  const single = lines[0];
  if (!single.some((x) => titleScore(x) > 0)) {
    return { title: null, employer: joinLine(single) };
  }
  return assignTitleEmployer(single);
}

/**
 * Given the cleaned candidate labels for one job (in reading order),
 * decides which is the title and which is the employer.
 */
function assignTitleEmployer(labels: string[]): { title: string | null; employer: string | null } {
  const segs = labels.filter((s): s is string => !!s);
  if (segs.length === 0) return { title: null, employer: null };
  if (segs.length === 1) {
    const s = segs[0];
    const ts = titleScore(s);
    const es = employerScore(s);
    if (ts > 0 && es === 0) return { title: s, employer: null };
    if (es > 0 && ts === 0) return { title: null, employer: s };
    if (ts > 0 && es > 0) {
      // "Comcast Sales Representative" — a fused label. Read as a title (the
      // employer word is usually a brand name inside the title) but do not
      // try to split; splitting guesses wrong more often than not.
      return { title: s, employer: null };
    }
    // no signal either way: a lone label with no job word is far more often
    // an employer ("Handshake Al", "Lucasfilm THX") than a title
    return { title: null, employer: s };
  }
  // "Owner / Lash Extension Business — Self-Employed": an employment-status
  // word paired with a real title is the employer slot, not a second title.
  if (segs.length === 2) {
    const selfIdx = segs.findIndex((x) => SELF_EMPLOYED_RE.test(x));
    if (selfIdx >= 0 && titleScore(segs[1 - selfIdx]) > 0 && !SELF_EMPLOYED_RE.test(segs[1 - selfIdx])) {
      return { title: segs[1 - selfIdx], employer: segs[selfIdx] };
    }
  }
  // Two or more: score every segment, pick the strongest title and the
  // strongest employer among the rest. A segment whose only title words are
  // weak ones ("Cellular Sales", "Account Services") scores as an employer
  // when another segment carries a proper title word — that is what left
  // Robert Garrison with "Cellular Sales - Sales Representative" as a title
  // and no employer (2026-08-26).
  const anyProperTitle = segs.some((x) => strongTitleScore(x) > 0);
  const scored = segs.map((s, i) => {
    const weakOnly = anyProperTitle && titleScore(s) > 0 && strongTitleScore(s) === 0;
    // a possessive business name ("Sicola's Florist", "Denny's") is an employer
    // whatever job words follow it
    const possessive = /^[A-Z][A-Za-z]*['\u2019]s\b/.test(s);
    const asEmployer = weakOnly || possessive;
    return { s, i, ts: asEmployer ? 0 : titleScore(s), es: asEmployer ? Math.max(1, employerScore(s)) : employerScore(s) };
  });
  // A segment with any title word outranks one with none, then net score, then reading order.
  const byTitle = [...scored].sort((a, b) => (b.ts > 0 ? 1 : 0) - (a.ts > 0 ? 1 : 0) || (b.ts - b.es) - (a.ts - a.es) || a.i - b.i);
  const byEmp = [...scored].sort((a, b) => (b.es > 0 ? 1 : 0) - (a.es > 0 ? 1 : 0) || (b.es - b.ts) - (a.es - a.ts) || a.i - b.i);
  const anyTitleSignal = scored.some((x) => x.ts > 0);
  const anyEmpSignal = scored.some((x) => x.es > 0);
  let title: string | null = null;
  let employer: string | null = null;
  if (anyTitleSignal || anyEmpSignal) {
    if (anyTitleSignal) title = byTitle[0].s;
    if (anyEmpSignal) {
      const empPick = byEmp.find((x) => x.s !== title);
      if (empPick) employer = empPick.s;
    }
    if (title && !employer) {
      // the other segment(s): if none has employer signal, still take the
      // best remaining one as employer unless it also reads as a title
      const rest = scored.filter((x) => x.s !== title);
      const cand = rest.find((x) => x.ts === 0);
      if (cand) employer = cand.s;
      else if (rest.length > 0) {
        // all remaining are title-ish too: it is one compound title
        title = segs.join(" - ");
        employer = null;
      }
    } else if (employer && !title) {
      const rest = scored.filter((x) => x.s !== employer);
      const cand = rest.find((x) => x.es === 0);
      if (cand) title = cand.s;
    }
    return { title, employer };
  }
  // No keyword signal at all — fall back to reading order: first = title,
  // second = employer (the more common template convention).
  return { title: segs[0], employer: segs[1] };
}

// -------------------------------------------------------------------------
// Entry filters — things that carry a date range but are not paid work.
// -------------------------------------------------------------------------

const NOT_A_JOB_RE =
  /\b(?:awards?\s*\/\s*activities\s*:|activities\s*\/\s*awards?\s*:|honors?\s*(?:&|and)\s*awards?\s*:|awards?\s*(?:&|and)\s*honors?\s*:|unemploy(?:ed|ment)|stay[- ]at[- ]home|homemaker|started a family|maternity|paternity|attended (?:college|school|university)|full[- ]time student|career break|sabbatical|gap year|medical leave|caregiver for|caring for my|raising my|took time off|hiatus|between jobs|job search)\b/i;
const DEGREE_RE =
  /\b(?:bachelor(?:'?s)?|associate(?:'?s)? (?:of|in|degree)|master(?:'?s)? (?:of|in|degree)|mba|b\.?[as]\.?(?:\s|$|,)|a\.?[as]\.?(?:\s|$|,)|m\.?[as]\.?(?:\s|$|,)|b\.?s\.?n\.?|ph\.?d\.?|doctorate|high school(?: diploma)?|\bged\b|diploma|coursework|dean'?s list|undergraduate|graduate student|studying|major(?:ing)? in|degree in|semester|gpa)\b/i;
const CERT_RE = /\b(?:certif(?:icate|ication|ied)|licen[sc]e[sd]?|credential|training program|bootcamp|course)\b/i;
// Unpaid work written under EXPERIENCE. The word "volunteer" was the only
// trigger until Emma Szabo's "Any Baby Can Donation Drive & Fundraiser"
// counted as three months of employment (2026-08-26). A drive, a fundraiser,
// a service project, a club or a scout rank is not a job.
const VOLUNTEER_RE =
  /\b(?:volunteer(?:ing|ed|s)?|unpaid|pro bono|altar (?:boy|server)|knights of columbus|church member|youth group|mission trip|donation drive|food drive|toy drive|coat drive|blood drive|book drive|supply drive|charity (?:event|drive|work)|service project|community service|service hours|student council|honor society|key club|beta club|boy scouts?|girl scouts?|cub scouts?|eagle scout|class president|class officer|j?rotc|cadet corps)\b/i;
// NOTE (2026-08-26): organisation names (Salvation Army, Red Cross, Goodwill)
// and club acronyms (DECA, FFA) were tried as triggers and removed the same
// day — a paid job at a Salvation Army thrift store and a DECA Commissary
// bagger were both thrown away. Only words that describe the WORK as unpaid
// belong here.
// "JROTC Instructor" and "Color Guard Technician" at a school district are
// paid staff, not cadets — the title words below keep such entries.
const VOLUNTEER_JOB_RE = /\b(?:coordinator|manager|director|specialist|supervisor|paid|instructor|technician|teacher)\b/i;

const INSTITUTION_RE =
  /\b(?:university|univ\.?|college|school|academy|institute|instituto|universidad|escuela|colegio|program|studies|campus|seminary|conservatory)\b/i;
// A parenthesised award marker — "(Associate)", "(Certificate)", "(Bachelor of
// Science)" — is Indeed's education format, never a job title. Needed because
// the word "associate" is also a legitimate job title, so scoring alone let
// "Music Literacy (Associate) / Texas Southern Univ" through as a job
// (Jennifer Dogan, 2026-08-19).
const PARENTHESISED_AWARD_RE =
  /\((?:\s*(?:associate|bachelor|master|doctor(?:ate)?|certificate|certification|diploma|high school(?: diploma)?|ged|some college|licence|license)[^)]*)\)/i;

/**
 * True while it is worth reading one more line above the date line.
 *
 * Counts LINES that produced labels, not labels. Judging by label content
 * fails on the exact entries that need help: "Manager, Customer Service"
 * splits into a title-looking piece and an employer-looking piece, so any
 * content test concludes the header is complete and never reads the line above
 * where the actual employer sits. Two lines is what the layout vote needs, so
 * two lines is what we go and get.
 */
function needMoreLines(linesWithLabels: number): boolean {
  return linesWithLabels < 2;
}

function isNonJobEntry(headerText: string, dateLineText: string, sectionKind: SectionKind = "neutral"): boolean {
  const all = `${headerText} ${dateLineText}`;
  if (NOT_A_JOB_RE.test(all)) return true;
  // "Student Tutor / Del Valle High School" under WORK EXPERIENCE is a job
  // whose employer happens to be a school. Only "high school" matching, plus
  // a proper title word, keeps the entry (Hailley Hernandez, 2026-08-26);
  // any real degree word still rejects it.
  if (DEGREE_RE.test(headerText)) {
    const withoutSchool = headerText.replace(/\bhigh school(?: diploma)?\b/gi, " ");
    const onlySchoolMatched = !DEGREE_RE.test(withoutSchool) && !/\bdiploma\b/i.test(headerText);
    if (!(onlySchoolMatched && strongTitleScore(headerText) > 0)) return true;
  }
  if (PARENTHESISED_AWARD_RE.test(headerText)) return true;
  if (sectionKind === "filtered") {
    // Under an EDUCATION / SKILLS / CERTIFICATIONS / CONTACT header, only an
    // entry that clearly reads as a job survives: a title word, and no
    // school or licence words.
    if (titleScore(headerText) === 0) return true;
    if (INSTITUTION_RE.test(headerText)) return true;
    if (CERT_RE.test(headerText)) return true;
  }
  // A certificate / licence line with dates anywhere ("Insurance Producer
  // License 2021 - Present") — no job title word means it is not a job.
  if (CERT_RE.test(headerText) && titleScore(headerText) === 0) return true;
  if (VOLUNTEER_RE.test(headerText) && !VOLUNTEER_JOB_RE.test(headerText)) return true;
  // certification / license lines with dates ("EKG Technician Certification 12/2025-12/2026")
  if (CERT_RE.test(headerText) && /\b(?:certif(?:icate|ication)|licen[sc]e|credential|course|bootcamp)\b\s*$/i.test(headerText.trim())) return true;
  return false;
}

// -------------------------------------------------------------------------
// Core parse
// -------------------------------------------------------------------------

export interface ParsedRole {
  title: string | null;
  employer: string | null;
  /** "YYYY-MM" */
  start: string;
  /** "YYYY-MM", or null while the candidate is still in the role */
  end: string | null;
  is_current: boolean;
  tenure_months: number;
  start_raw: string;
  end_raw: string;
  /** Present and true only for roles judged seasonal (see seasonalProfile). */
  is_seasonal?: boolean;
  /**
   * Which months of the year a seasonal role actually covers, e.g. [9,10,11].
   * public.resume_experience_months counts ONLY these months inside the span,
   * instead of every month between start and end — keep the two in sync.
   */
  season_months?: number[];
}

// A line whose LAST thing is a date followed by a dangling range separator:
// "Allstate / National General - Customer Service Representative | 2025 -"
// — or by a separator and a bare month name whose year wrapped: "MAY 2022- DEC."
const DANGLING_RANGE_END_RE = new RegExp(
  `(?:${DATE_TOKEN_RE})\\s*(?:to|thru|through|until|till|[\\u2013\\u2014\\u2015\\u2010\\u2212\\-]|\\u2192)\\s*(?:${MONTH_NAME_RE}\\.?\\s*)?$`,
  "i",
);
// The continuation: a line that OPENS with the closing date and nothing else
// of substance.
const LEADING_DATE_ONLY_RE = new RegExp(
  `^\\s*(${DATE_TOKEN_RE}|${PRESENT_RE})\\s*[.,;)|]*\\s*$`,
  "i",
);
// A whole line that is nothing but a date range (plus stray punctuation).
const DATE_ONLY_LINE_RE = new RegExp(
  `^\\s*[(\\[]?\\s*(?:\\bfrom\\s+)?(?:${DATE_TOKEN_RE})${SEP_RE}(?:${DATE_TOKEN_RE}|\\b${PRESENT_RE}\\b)\\s*[)\\].,;|]*\\s*$`,
  "i",
);

/**
 * Rejoins a date range that a PDF broke across two lines, in place.
 *
 * A narrow column wraps "... | 2025 - 2026" so the closing year lands alone on
 * the next line. RANGE_RE only ever looks at one line, so the whole entry was
 * dropped without trace — Josh Olivas lost both of his insurance jobs this
 * way, the two most relevant roles on the resume.
 *
 * Deliberately narrow: the first line must END with a date plus a separator
 * and the second must consist of NOTHING BUT the closing date. That keeps a
 * bullet like "2021 - revenue grew 14%" from being welded onto the line above.
 *
 * 2026-08-26: the closing date may also sit TWO lines down, with the job's
 * header line in between — a left-column date range collapsed around the
 * right-column header ("JAN 2023 –" / "FINANCE ADMINISTRATOR, GRACE POINT" /
 * "PRESENT", McKenna Walsh). The header stays where it is; only the date
 * fragment moves up.
 */
function joinWrappedDateRanges(lines: string[]): void {
  for (let i = 0; i < lines.length - 1; i++) {
    const cur = lines[i];
    if (!cur.trim()) continue;
    if (!DANGLING_RANGE_END_RE.test(cur)) continue;
    // look past a single blank line, which column wrapping also produces
    let j = i + 1;
    if (!lines[j].trim() && j + 1 < lines.length) j++;
    const nxt = lines[j];
    if (!nxt || !nxt.trim()) continue;
    if (LEADING_DATE_ONLY_RE.test(nxt)) {
      lines[i] = `${cur} ${nxt.trim()}`;
      lines[j] = "";
      continue;
    }
    // wrapped AROUND one header line: the line between must carry no date
    // and read as a label, and the closer must be nothing but a date
    const k = j + 1;
    if (k >= lines.length) continue;
    const between = nxt.trim();
    if (isBullet(nxt) || isDivider(nxt) || DATE_ANYWHERE_RE.test(between) || looksLikeProse(between)) continue;
    const closer = lines[k];
    if (!closer || !closer.trim() || !LEADING_DATE_ONLY_RE.test(closer)) continue;
    lines[i] = `${cur} ${closer.trim()}`;
    lines[k] = "";
  }
}

/**
 * Undoes the kerning damage a PDF extractor leaves on dates: "J AN 2 023",
 * "P RES EN T", "MAY 2 02 2- DEC." (McKenna Walsh, 2026-08-26). Digit groups
 * separated by single spaces that join to one plausible year become that
 * year; runs of short upper-case tokens that join to a month name or a
 * present-word become that word. Nothing else on the line is touched.
 */
const KERNED_DIGITS_RE = /(?<!\d)(?<!\d )(\d{1,3}(?: \d{1,3})+)(?!\d)(?! \d)/g;
const KERNED_LETTERS_RE = /\b([A-Z]{1,4}\.?(?: [A-Z]{1,4}\.?)+)\b/g;
const MONTH_OR_PRESENT_WORD_RE = new RegExp(`^(?:${MONTH_NAME_RE}|${PRESENT_RE})$`, "i");
function collapseKernedDates(line: string): string {
  if (!/\d \d|[A-Z] [A-Z]/.test(line)) return line;
  let out = line.replace(KERNED_DIGITS_RE, (run) => {
    const joined = run.replace(/ /g, "");
    return joined.length === 4 && /^(?:19|20)\d{2}$/.test(joined) ? joined : run;
  });
  out = out.replace(KERNED_LETTERS_RE, (run) => {
    const joined = run.replace(/[ .]/g, "");
    if (joined.length < 3 || !MONTH_OR_PRESENT_WORD_RE.test(joined)) return run;
    return joined + (run.endsWith(".") ? "." : "");
  });
  return out;
}

/** Markdown remnants from a converted document: "** Sales Associate**", "## Experience". */
function stripMarkdown(line: string): string {
  let t = line.replace(/^(\s*)\*\s+(?=\S)/, "$1• ");
  t = t.replace(/\*{1,3}/g, "").replace(/_{2,3}/g, "").replace(/^\s*#{1,6}\s+/, "");
  return t;
}

/**
 * A scrambled two-column PDF can print "Assistant Manager / Loan Processor
 * 2014)" on one line and "- Texas Car Title & Payday Loan Services (2013-"
 * a few lines below it — the range's two halves in the wrong order, with
 * the header split across them (Rosalie Jackson, 2026-08-26). Rejoined as
 * "<title> - <employer> (2013-2014)". Narrow on purpose: a lone closing
 * year with a bracket, then within four lines a line ending in an opening
 * bracket, year and dash, with only blank or punctuation lines between.
 */
function rejoinScrambledParenRanges(lines: string[]): void {
  for (let i = 0; i < lines.length; i++) {
    const a = lines[i].match(/^(.*\S)\s+((?:19|20)\d{2})\)\s*$/);
    if (!a) continue;
    if (DATE_ANYWHERE_RE.test(a[1]) || looksLikeProse(a[1])) continue;
    for (let j = i + 1; j <= Math.min(i + 4, lines.length - 1); j++) {
      const t = lines[j];
      if (!t.trim() || isPunctOnly(t)) continue;
      const b = t.match(/^\s*[\-–—•·]?\s*(.*?)\s*\(\s*((?:19|20)\d{2})\s*[\-–—]\s*$/);
      if (b && parseInt(b[2], 10) <= parseInt(a[2], 10) && !DATE_ANYWHERE_RE.test(b[1])) {
        const head = b[1].trim() ? `${a[1].trim()} - ${b[1].trim()}` : a[1].trim();
        lines[i] = `${head} (${b[2]}-${a[2]})`;
        lines[j] = "";
      }
      break;
    }
  }
}

/**
 * Two entries on one line, or two seasons of one job on one line.
 *
 * "Marketing Assistant - Fix-It Guys (2019-Present) Operations Manager
 * Assistant - Rain for Rent (2019)" is two jobs; the text after the first
 * range was being read as the first job's employer (Rosalie Jackson). It is
 * cut into its own line. "October 2022 - January 2023 And October
 * 2023-January 2024" is one job worked twice (Julia Holzschuher, Araca): the
 * second range becomes its own line, marked as a CONTINUATION so it inherits
 * the header of the entry above instead of hunting for one.
 */
function splitMultiRangeLines(lines: string[], now: MonthYear): { lines: string[]; continuation: boolean[] } {
  const out: string[] = [];
  const cont: boolean[] = [];
  for (const line of lines) {
    const hit = findRangeOnLine(line, now);
    if (!hit) { out.push(line); cont.push(false); continue; }
    const head = line.slice(0, hit.index + hit.length);
    let rest = line.slice(hit.index + hit.length);
    // keep a closing bracket with the range it closes
    const closeParen = rest.match(/^\s*[)\]]/);
    let headFull = head;
    if (closeParen) { headFull = head + closeParen[0]; rest = rest.slice(closeParen[0].length); }
    if (!DATE_ANYWHERE_RE.test(rest)) { out.push(line); cont.push(false); continue; }
    const restHit = findRangeOnLine(rest, now);
    // "Awards/Activities: Senior Class President - X (2022-2023), Founder of
    // Y (2023-Present)": the lead-in label applies to every item on the line
    const leadIn = head.match(/^\s*((?:awards?\s*\/\s*activities|activities\s*\/\s*awards?|honors?\s*(?:&|and)\s*awards?|awards?\s*(?:&|and)\s*honors?)\s*:)\s*/i);
    const stripped = (leadIn ? leadIn[1] + " " : "") + rest.replace(/^\s*(?:and|&|also|then|,|;|\/|\|)?\s*/i, "");
    if (restHit) {
      // a second full range: continuation of the same job when nothing but the
      // conjunction sits between the two ranges, otherwise a second entry
      const gap = rest.slice(0, restHit.index).replace(/^\s*(?:and|&|also|then|,|;|\/|\|)?\s*/i, "").trim();
      out.push(headFull.replace(/\s+$/, "")); cont.push(false);
      out.push(stripped.trim()); cont.push(gap === "");
      continue;
    }
    // a lone date token after the range ("... (2019)"): a second entry
    out.push(headFull.replace(/\s+$/, "")); cont.push(false);
    out.push(stripped.trim()); cont.push(false);
  }
  return { lines: out, continuation: cont };
}

/**
 * Two jobs laid out side by side collapse into interleaved lines:
 *
 *   Sales & Retention Specialist — Charter      <- job A, line 1
 *   Owner / Lash Extension Business —           <- job B, line 1
 *   Communications                              <- job A, line 2
 *   Self-Employed                               <- job B, line 2
 *   October 2024 – Present                      <- job A dates
 *   2020 – 2024                                 <- job B dates
 *
 * The give-away is two (or more) date-only lines stacked directly on top of
 * each other. The header lines above them are dealt out in turn, and each
 * job is rewritten as its own block (Allana Maddox, 2026-08-26). When the
 * header lines above look like ONE complete header (one title, one
 * employer) the stacked dates are two stints of the same job and every
 * stint gets the whole header.
 */
function deinterleaveStackedDates(lines: string[], continuation: boolean[]): void {
  let i = 0;
  while (i < lines.length) {
    if (!DATE_ONLY_LINE_RE.test(lines[i]) || continuation[i]) { i++; continue; }
    let n = 1;
    while (i + n < lines.length && DATE_ONLY_LINE_RE.test(lines[i + n]) && !continuation[i + n]) n++;
    if (n < 2) { i++; continue; }
    // collect header candidates above, up to 2n lines
    const hdr: number[] = [];
    let k = i - 1;
    while (k >= 0 && hdr.length < 2 * n) {
      const t = lines[k].trim();
      if (!t || isPunctOnly(lines[k]) || isBullet(lines[k]) || isDivider(lines[k])) break;
      if (classifyHeader(lines[k]) !== null) break;
      if (DATE_ANYWHERE_RE.test(lines[k]) || looksLikeProse(t) || isLocation(t)) break;
      hdr.unshift(k);
      k--;
    }
    if (hdr.length < n) { i += n; continue; }
    const hdrText = hdr.map((x) => lines[x]);
    const pieces = hdrText.flatMap(splitHeaderLine).map(cleanSegment).filter((x): x is string => !!x);
    const strongTitles = pieces.filter(isStrongTitle).length;
    const strongEmployers = pieces.filter(isStrongEmployer).length;
    const groups: string[][] = Array.from({ length: n }, () => []);
    if (hdr.length <= 3 && strongTitles <= 1 && strongEmployers <= 1 && !(hdr.length === n && n >= 2 && strongTitles === 1 && strongEmployers === 0 && pieces.length === n)) {
      // one header shared by every stint
      for (const g of groups) g.push(...hdrText);
    } else {
      hdrText.forEach((t, idx) => groups[idx % n].push(t));
    }
    // join a dangling-dash line onto its continuation, and a single trailing
    // no-signal word onto the single no-signal label after it ("Charter" +
    // "Communications")
    const joined = groups.map((g) => {
      const outG: string[] = [];
      for (const t of g) {
        const prev = outG[outG.length - 1];
        if (prev !== undefined) {
          if (/[\-–—]\s*$/.test(prev)) { outG[outG.length - 1] = `${prev} ${t}`; continue; }
          const prevLast = prev.split(/\s*(?:\||\u2013|\u2014|\s-\s)\s*/).pop() ?? "";
          if (wordCount(prevLast) === 1 && titleScore(prevLast) === 0 && employerScore(prevLast) === 0 &&
              wordCount(t) <= 2 && titleScore(t) === 0 && !/[,\-–—|]/.test(t)) {
            outG[outG.length - 1] = `${prev} ${t}`; continue;
          }
        }
        outG.push(t);
      }
      return outG;
    });
    // rewrite: blank the old header lines, then lay out block per stint
    const dateLines = Array.from({ length: n }, (_, d) => lines[i + d]);
    const block: string[] = [];
    for (let d = 0; d < n; d++) { block.push(...joined[d], dateLines[d]); if (d < n - 1) block.push(""); }
    const firstHdr = hdr.length > 0 ? hdr[0] : i;
    const removeCount = (i + n) - firstHdr;
    const pad: string[] = [];
    while (block.length + pad.length < removeCount) pad.push("");
    lines.splice(firstHdr, removeCount, ...block, ...pad);
    continuation.splice(firstHdr, removeCount, ...new Array(block.length + pad.length).fill(false));
    i = firstHdr + block.length + pad.length;
  }
}

/**
 * Prose resumes: "(August 10, 2020 - September 10, 2020) I worked as an
 * Enumerator for the United States Census Bureau." The title and employer
 * are in the sentence, not on header lines (Max Dunlop, 2026-08-26). The
 * employer may wrap onto the next line, which is read up to its first period.
 */
const SENTENCE_ROLE_RE =
  /\b(?:(I|we)\s+)?(?:(?:currently|now|previously|also|then)\s+)?((?:(?:was|am|were|have\s+been|had\s+been)\s+)?(?:work(?:ed|ing|s)?|serv(?:ed|ing|es)?|employed|hired|(?:was|am|were))\s+)?(?:as\s+)?(?:an?|the)\s+([A-Z][A-Za-z&/'’\- ]{2,60}?)\s+(?:for|at|with)\s+(?:the\s+)?([A-Z][A-Za-z0-9&.,'’\- ]*?)(?=\s*(?:\.|,|;|:|\s+(?:where|in|on|from|and|since|located|which|that)\b|$))/;
function sentenceRole(text: string, nextLine: string | undefined): { title: string; employer: string } | null {
  const m = text.match(SENTENCE_ROLE_RE);
  if (!m) return null;
  const title = m[3].trim().replace(/\s+/g, " ");
  let employer = m[4].trim().replace(/[.,;:\s]+$/, "");
  // Either the sentence says it is a job ("worked as a", "was the") or the
  // phrase carries a title word; a bare "a letter for the Director" is neither.
  const verbLed = !!m[2];
  if (!verbLed && titleScore(title) === 0) return null;
  if (titleScore(title) === 0 && wordCount(title) > 4) return null;
  // the employer wrapped: continue onto the next line up to its first sentence end
  const endedCleanly = /[.,;:]/.test(text.slice((m.index ?? 0) + m[0].length, (m.index ?? 0) + m[0].length + 1));
  if (!endedCleanly && nextLine && !hasRange(nextLine)) {
    const cont = nextLine.trim().match(/^([A-Z][A-Za-z0-9&'’\-]*(?:\s+[A-Z][A-Za-z0-9&'’\-]*){0,4})\.?(?=\s|$|[,;])/);
    if (cont) employer = `${employer} ${cont[1]}`.trim();
  }
  employer = cutAtSentenceBoundary(employer);
  if (wordCount(employer) > 6 || wordCount(title) > 6) return null;
  return { title, employer };
}

/**
 * Pure function — no I/O. Reads every job entry with a recognisable date
 * range out of resumeText. asOf governs how "Present" resolves; pass a
 * fixed value only for testing.
 */
export function parseWorkExperienceRoles(resumeText: string, asOf?: MonthYear): ParsedRole[] {
  if (!resumeText) return [];
  const now = asOf ?? nowMonthYear();
  const rawLines = resumeText.replace(/\\n/g, "\n").split(/\r?\n|\r/);
  // Pass 0: line repair. Order matters — markdown and kerning first so the
  // date regexes see clean text, then rejoin ranges the PDF split, then split
  // lines that carry two ranges, then untangle two-column interleaving.
  const lines0 = rawLines.map((l) => collapseKernedDates(stripMarkdown(l.replace(/\s+$/g, ""))));
  joinWrappedDateRanges(lines0);
  rejoinScrambledParenRanges(lines0);
  const split = splitMultiRangeLines(lines0, now);
  const lines = split.lines;
  const continuation = split.continuation;
  deinterleaveStackedDates(lines, continuation);

  // Pass 1: section kinds
  const kinds: SectionKind[] = new Array(lines.length);
  let current: SectionKind = "neutral";
  const headerAt: boolean[] = new Array(lines.length).fill(false);
  for (let i = 0; i < lines.length; i++) {
    const k = classifyHeader(lines[i]);
    if (k) {
      current = k;
      headerAt[i] = true;
    }
    kinds[i] = current;
  }

  // Pass 2 collects entries WITHOUT labelling them. Labelling waits until
  // every entry is known, because the title/employer decision for the hard
  // entries depends on how the easy ones are laid out (see voteLayout).
  type RawEntry = {
    labelsPerLine: string[][];
    headerText: string;
    dateLineText: string;
    startMY: MonthYear;
    endMY: MonthYear;
    isCurrent: boolean;
    months: number;
    startRaw: string;
    endRaw: string;
    /** line index of the date line, and of the first header line read above it */
    dateLineIdx: number;
    firstHeaderIdx: number;
    /** title and employer read straight out of a sentence — no label vote needed */
    fixed?: { title: string; employer: string };
  };
  const entries: RawEntry[] = [];

  for (let i = 0; i < lines.length; i++) {
    if (kinds[i] === "excluded") continue;
    if (headerAt[i]) continue;
    const line = lines[i];
    if (!line.trim()) continue;

    const hit = findRangeOnLine(line, now);
    if (!hit) continue;
    const { startTok, endTok, startRaw, endRaw } = hit;
    const matchIndex = hit.index;
    const matchLen = hit.length;
    if (!startTok || startTok.kind !== "date") continue;
    if (!endTok) continue;
    // Two-digit years only when both ends use them (a lone "06/21" is too ambiguous)
    if (startTok.shortYear && (endTok.kind === "date" && !endTok.shortYear)) continue;
    if (endTok.kind === "date" && endTok.shortYear && !startTok.shortYear) continue;

    const startMY = startTok.my;
    const isCurrent = endTok.kind === "present";
    let endMY: MonthYear = isCurrent ? now : (endTok as any).my;
    // "2020 - 2020": some part of one year — count as one month, not zero
    if (!isCurrent && startTok.yearOnly && (endTok as any).yearOnly && endMY.year === startMY.year) {
      endMY = { year: startMY.year, month: 2 };
    }
    let months = monthsBetween(startMY, endMY);
    if (months < 0) continue; // typo like 08/2010 to 05/2010 — do not guess
    // Hard backstop: no single job runs 50 years. Discard rather than trust.
    if (months > 600) continue;
    if (isCurrent && months < 0) months = 0;

    // A second range of the same job ("... And October 2023-January 2024")
    // borrows the header of the entry it was split from.
    if (continuation[i] && entries.length > 0) {
      const prev = entries[entries.length - 1];
      entries.push({ ...prev, startMY, endMY, isCurrent, months, startRaw, endRaw, dateLineIdx: i, firstHeaderIdx: i });
      continue;
    }

    // ---- header assembly ----
    const before = line.slice(0, matchIndex).replace(/[\s\-–—|,;:(]+$/g, "").trim();
    // Text AFTER the dates on the same line is a header candidate too:
    // "July 2025 - July 2026 | State Farm, Flower Mound, TX - Account Manager".
    const after = line.slice(matchIndex + matchLen).replace(/^[\s\-–—|,;:)•·●]+/g, "").trim();
    const dateLineText = `${before} ${after}`;

    // A sentence that names the job outright ("I worked as an Enumerator for
    // the United States Census Bureau") settles the labels on its own.
    const fixed = sentenceRole(after, lines[i + 1]) ?? sentenceRole(before, undefined) ?? sentenceRole(line, lines[i + 1]);
    if (fixed) {
      const headerText = `${fixed.title} | ${fixed.employer}`;
      if (isNonJobEntry(headerText, dateLineText, kinds[i])) continue;
      entries.push({
        labelsPerLine: [[fixed.title], [fixed.employer]], headerText, dateLineText,
        startMY, endMY, isCurrent, months, startRaw, endRaw, dateLineIdx: i, firstHeaderIdx: i, fixed,
      });
      continue;
    }

    const piecesOf = (hl: string[]) => hl.flatMap(splitHeaderLine).map(cleanSegment).filter((x): x is string => !!x);
    const headerLines: string[] = [];
    let beforeUsed = false;
    if (before.length >= 2 && cleanSegment(before) !== null) {
      headerLines.push(before);
      beforeUsed = true;
      // "MI VISION Eye Care Sales Representatives 2022-2024" with "MI VISION
      // Eye Care" printed on its own a couple of lines up (a duplicated page,
      // Reyna Hanssen): the repeated line is an exact prefix of the fused
      // label, so the label splits there into employer and title.
      for (let up = i - 1; up >= Math.max(0, i - 3); up--) {
        const t = lines[up].trim();
        if (!t || wordCount(t) < 2 || t.length >= before.length - 2) continue;
        if (!before.toLowerCase().startsWith(t.toLowerCase())) continue;
        const rest = before.slice(t.length).replace(/^[\s,\-–—:|/]+/, "").trim();
        if (titleScore(rest) === 0 || cleanSegment(rest) === null || cleanSegment(t) === null) continue;
        headerLines.length = 0;
        headerLines.push(t, rest);
        break;
      }
    }
    if (after.length >= 2 && !looksLikeProse(after) && piecesOf([after]).length > 0) {
      headerLines.push(after);
    }
    // Look back for header lines above the date line. Stop as soon as the
    // collected lines yield two labels (title + employer) — anything above
    // that is the previous entry.
    const backLimit = beforeUsed ? 1 : 3;
    // Is there a plausible header on the line just BELOW the dates? That is a
    // dates-first layout, and in one the blank line above the date line is the
    // gap BETWEEN entries, not a gap inside this one. Stepping over it climbs
    // into the previous job's duty text (Robyn Vasquez, all-caps dates-first).
    const forwardHeaderBelow = (() => {
      const fl = lines[i + 1];
      if (fl === undefined) return false;
      const t = fl.trim();
      if (!t || isBullet(fl) || isDivider(fl) || headerAt[i + 1]) return false;
      if (hasRange(fl) || DATE_ANYWHERE_RE.test(fl)) return false;
      if (looksLikeProse(t) || isLocation(t)) return false;
      return piecesOf([t]).length > 0;
    })();
    let back = i - 1;
    let collected = 0;
    let blanksSkipped = 0;
    let firstHeaderIdx = i;
    // Budget on lines LOOKED AT, not just lines kept. Description text is
    // stepped over rather than stopped on, so without a budget the search
    // walks up through a dozen duty lines and lands on the PREVIOUS job's
    // header. Three lines of real header is the most any layout needs.
    let scanned = 0;
    // Keep looking until we have BOTH a title-ish and an employer-ish label,
    // not merely two labels. A single line that splits into two title-ish
    // pieces ("CSR - Customer Service Representative", "Manager, Customer
    // Service") used to satisfy the old count and the employer line one row
    // further up was never read at all — that is what lost Skyplace FBO and
    // Mesilla Valley Transportation.
    while (
      back >= 0 && collected < backLimit && headerLines.length < 3 &&
      // The budget applies ONLY to a dates-first layout, where the header is
      // below and a long climb upward is always wrong. When the header is
      // above, a scrambled PDF can legitimately bury the dates ten lines under
      // it behind bullets and duty text (Megan Buentello), so let it climb.
      (!forwardHeaderBelow || scanned < 6) &&
      needMoreLines(headerLines.filter((hl) => piecesOf([hl]).length > 0).length)
    ) {
      scanned++;
      const bl = lines[back];
      const t = bl.trim();
      if (isDivider(bl) || headerAt[back] || kinds[back] === "excluded") break;
      if (t === "") {
        // Column wrapping sometimes leaves ONE blank line between an entry's
        // employer line and its date line (Cynthia Martinez's concurrent SA
        // Youth role was dropped entirely because of this). Step over a single
        // blank, but never a second — two blanks is a real break between
        // entries.
        if (blanksSkipped >= 1 || collected >= 2 || forwardHeaderBelow) break;
        blanksSkipped++;
        back--;
        continue;
      }
      if (isBullet(bl)) break;
      if (isPunctOnly(bl)) { back--; continue; }
      // a bare place line ("San Antonio, TX") is neither a header nor a stop
      if (isLocation(t)) { back--; continue; }
      // a skills-column word that collapsed between the title and the dates
      // ("Customer Service", "English") is neither a header nor a stop
      if (isSkillPhrase(t)) { back--; continue; }
      // another entry's date line, or a dated education/award line
      if (hasRange(bl) || DATE_ANYWHERE_RE.test(bl)) break;
      if (looksLikeProse(t)) {
        // In a dates-first layout the header sits BELOW the dates, so duty
        // text directly above them belongs to the previous entry; climbing
        // past it steals that entry's header (a stacked all-caps resume).
        if (forwardHeaderBelow && headerLines.length === 0) break;
        back--;
        if (beforeUsed) break;
        continue;
      }
      headerLines.unshift(t);
      firstHeaderIdx = back;
      collected++;
      back--;
    }
    // Look forward for header lines BELOW the date line — dates-first
    // layouts ("APRIL 2022 – CURRENT" / "HILTON HILL COUNTRY RESORT, LEAD LINE
    // COOK") and title-only lines whose employer sits on the next line
    // ("COMMUNICATION SPECIALIST  May 2020 - Aug 2025" / "H.J.H. Consulting").
    // Accepted lines are short, are not themselves a complete header of the
    // next entry (title AND employer), and complement what we already have.
    {
      let piecesSoFar = piecesOf(headerLines);
      let haveTitle = piecesSoFar.length === 1 && isStrongTitle(piecesSoFar[0]);
      let haveEmployer = piecesSoFar.length === 1 && isStrongEmployer(piecesSoFar[0]);
      let fwd = i + 1;
      let taken = 0;
      let glueSkipped = 0;
      while (piecesSoFar.length < 2 && taken < 2 && fwd < lines.length && fwd <= i + 5) {
        const fl = lines[fwd];
        const t = fl.trim();
        if (t === "" || isDivider(fl) || headerAt[fwd] || kinds[fwd] === "excluded") break;
        if (isPunctOnly(fl)) { fwd++; continue; }
        if (isLocation(t)) { fwd++; continue; }
        if (isSkillPhrase(t)) { fwd++; continue; }
        if (isBullet(fl)) {
          // A skills-column bullet that collapsed between the dates and the
          // header ("• Retail store support" / "Customer Support Specialist
          // Conduent, San Antonio, TX", Tatyana Wood): short, no job word,
          // nothing collected yet — step over it, at most twice.
          const bt = t.replace(/^[•\-*●○◦▪■➢➤►›»>·‣⁃\uE000-\uF8FF]+\s*/, "");
          if (headerLines.length === 0 && glueSkipped < 2 && wordCount(bt) <= 4 && strongTitleScore(bt) === 0 && !looksLikeProse(bt)) {
            glueSkipped++;
            fwd++;
            continue;
          }
          break;
        }
        if (hasRange(fl) || DATE_ANYWHERE_RE.test(fl)) break;
        if (looksLikeProse(t) || wordCount(t) > 14) break;
        const fp = piecesOf([t]);
        if (fp.length === 0) { fwd++; continue; } // junk word like "Professional"
        if (piecesSoFar.length === 1 && fp.length > 1) break; // that is the next entry's header
        if (fp.length === 1) {
          if (haveTitle && isStrongTitle(fp[0])) break;
          if (haveEmployer && isStrongEmployer(fp[0])) break;
        }
        headerLines.push(t);
        taken++;
        fwd++;
        piecesSoFar = piecesOf(headerLines);
        haveTitle = piecesSoFar.length === 1 && isStrongTitle(piecesSoFar[0]);
        haveEmployer = piecesSoFar.length === 1 && isStrongEmployer(piecesSoFar[0]);
      }
    }

    const headerText = headerLines.join(" | ");
    if (isNonJobEntry(headerText, dateLineText, kinds[i])) continue;

    // Labels are kept PER LINE so pass 3 can use line order.
    const seenLabel = new Set<string>();
    const labelsPerLine = headerLines
      .map((hl) =>
        splitHeaderLine(hl)
          .map(cleanSegment)
          .filter((x): x is string => !!x)
          .filter((x) => {
            const k = x.toLowerCase();
            if (seenLabel.has(k)) return false;
            seenLabel.add(k);
            return true;
          })
      )
      .filter((g) => g.length > 0);
    // A stray date range in prose with no label at all is not a job — unless
    // it sits directly under the previous entry's date line, in which case it
    // is a second stint of that job (handled below by inheritance).
    if (labelsPerLine.length === 0) continue;

    entries.push({ labelsPerLine, headerText, dateLineText, startMY, endMY, isCurrent, months, startRaw, endRaw, dateLineIdx: i, firstHeaderIdx });
  }

  // ---- Pass 3: learn the layout once, then label and emit every entry ----
  const layout = voteLayout(entries.filter((e) => !e.fixed).map((e) => e.labelsPerLine));
  const roles: ParsedRole[] = [];
  const emitted: { title: string | null; employer: string | null }[] = [];
  let prevLabels: { title: string | null; employer: string | null; dateLineIdx: number; selfContained: boolean } | null = null;
  for (const e of entries) {
    let { title, employer } = e.fixed ? e.fixed : assignTitleEmployerFromLines(e.labelsPerLine, layout);
    // A title with no employer, stacked directly under the previous entry's
    // date line, is a second position at the same employer ("Merchandise
    // Operations Leader | Mar 2021 – Aug 2022" / "Guest Advisor | Mar 2020 –
    // Mar 2021" under one "Petco" header, Clara Bryant 2026-08-26).
    if (title && !employer && prevLabels && prevLabels.employer && !prevLabels.selfContained &&
        e.firstHeaderIdx === e.dateLineIdx && e.firstHeaderIdx === prevLabels.dateLineIdx + 1) {
      employer = prevLabels.employer;
    }
    if (title && title.length > 120) title = title.slice(0, 120);
    if (employer && employer.length > 120) employer = employer.slice(0, 120);
    prevLabels = { title, employer, dateLineIdx: e.dateLineIdx, selfContained: e.firstHeaderIdx === e.dateLineIdx };
    if (!title && !employer) continue;

    // Duplicates: the same dates with a matching label. A duplicated page (a
    // Canva editor screenshot, Reyna Hanssen) yields the same job twice with
    // slightly different garble each time; the exact key used before let
    // both through.
    const start = ym(e.startMY);
    const end = e.isCurrent ? null : ym(e.endMY);
    const dup = roles.findIndex((r, idx) => {
      if (r.start !== start || r.end !== end) return false;
      const prev = emitted[idx];
      const tSim = nameSimilarity(prev.title, title);
      const eSim = nameSimilarity(prev.employer, employer);
      if (tSim >= 0.8 || eSim >= 0.8) return true;
      if ((!prev.employer || !employer) && tSim >= 0.5) return true;
      if ((!prev.title || !title) && eSim >= 0.5) return true;
      return false;
    });
    if (dup >= 0) {
      // keep the earlier row, but fill a label it was missing
      if (!roles[dup].employer && employer) { roles[dup].employer = employer; emitted[dup].employer = employer; }
      if (!roles[dup].title && title) { roles[dup].title = title; emitted[dup].title = title; }
      continue;
    }

    const seasonal = seasonalProfile(title, employer, e.headerText, e.dateLineText, e.startMY, e.endMY, e.isCurrent);
    roles.push({
      title,
      employer,
      start,
      end,
      is_current: e.isCurrent,
      tenure_months: seasonal ? seasonal.months : e.months,
      start_raw: e.startRaw,
      end_raw: e.endRaw,
      ...(seasonal ? { is_seasonal: true, season_months: seasonal.seasonMonths } : {}),
    });
    emitted.push({ title, employer });
  }
  return roles;
}

/**
 * Overlap-aware total: the number of distinct calendar months covered by
 * any role. Concurrent jobs count once. Roles lacking a start date (older
 * hand-written entries) contribute their tenure_months additively, since
 * they cannot be placed on the timeline. Mirrors public.resume_experience_months
 * in SQL — keep the two in sync.
 */
export function totalWorkMonths(roles: any[], asOf?: MonthYear): number | null {
  const now = asOf ?? nowMonthYear();
  const months = new Set<number>();
  let undated = 0;
  let any = false;
  for (const r of roles ?? []) {
    const s = typeof r?.start === "string" ? r.start.match(/^(\d{4})-(\d{2})$/) : null;
    if (s) {
      any = true;
      const sIdx = parseInt(s[1], 10) * 12 + (parseInt(s[2], 10) - 1);
      const e = typeof r?.end === "string" ? r.end.match(/^(\d{4})-(\d{2})$/) : null;
      const eIdx = e ? parseInt(e[1], 10) * 12 + (parseInt(e[2], 10) - 1) : now.year * 12 + (now.month - 1);
      // A seasonal role covers only its own months of the year inside the span.
      const season: number[] | null = Array.isArray(r?.season_months) && r.season_months.length > 0
        ? r.season_months.map((x: any) => Number(x)).filter((x: number) => x >= 1 && x <= 12)
        : null;
      for (let k = sIdx; k < eIdx; k++) {
        if (season && season.length > 0 && !season.includes((k % 12) + 1)) continue;
        months.add(k);
      }
    } else if (typeof r?.tenure_months === "number" && Number.isFinite(r.tenure_months)) {
      any = true;
      undated += Math.max(0, r.tenure_months);
    }
  }
  if (!any) return null;
  return months.size + undated;
}

// -------------------------------------------------------------------------
// Merge into resume_analysis.qualifications.prior_similar_role.roles[]
// -------------------------------------------------------------------------

const NAME_STOPWORDS = new Set(["the", "of", "and", "for", "a", "an", "at", "in", "inc", "llc", "ltd", "co", "corp", "company", "group", "tpa", "aka"]);
function normalizeName(s: string | null | undefined): string {
  return (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
}
function nameTokens(s: string | null | undefined): Set<string> {
  const out = new Set<string>();
  for (const w of (s ?? "").toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/)) {
    if (w.length >= 2 && !NAME_STOPWORDS.has(w)) out.add(w);
  }
  return out;
}
function nameSimilarity(a: string | null | undefined, b: string | null | undefined): number {
  const na = normalizeName(a);
  const nb = normalizeName(b);
  if (!na || !nb) return 0;
  if (na === nb) return 1;
  if (na.length >= 4 && nb.length >= 4 && (na.includes(nb) || nb.includes(na))) return 0.9;
  const ta = nameTokens(a);
  const tb = nameTokens(b);
  if (ta.size === 0 || tb.size === 0) return 0;
  let inter = 0;
  for (const t of ta) if (tb.has(t)) inter++;
  return inter / Math.min(ta.size, tb.size);
}

/**
 * A parsed label that is really a sentence of duty text rather than a name.
 * Used ONLY to decide whose labels win when a row is absorbed — never to
 * decide whether two rows match, and never in the parse step. A wrong answer
 * here costs a label, not a job.
 */
function isJunkLabel(s: string | null | undefined): boolean {
  const t = (s ?? "").trim();
  if (!t) return false;
  if (looksLikeProse(t)) return true;
  // An ALL-CAPS resume defeats looksLikeProse unless the line ends in
  // punctuation. Eight or more words, all caps, no lowercase anywhere is a
  // duty sentence rather than a job title. The threshold sits far above any
  // real title on purpose: a word-count test like this one inside the PARSE
  // step threw four real jobs away on 2026-08-19 (Tabitha Graciano). Here the
  // fallback is keeping the STORED label, so the downside is bounded.
  if (!/[a-z]/.test(t) && /[A-Z]/.test(t) && wordCount(t) >= 8) return true;
  return false;
}

/**
 * The date range a stored row's own notes text describes, if any. Reuses this
 * module's range regexes and token parser rather than adding a second date
 * parser — the two would drift.
 */
function notesDateRange(existing: any, asOf: MonthYear): { start: string; end: string | null } | null {
  const notes = typeof existing?.notes === "string" ? existing.notes : "";
  if (!notes.trim()) return null;
  let startTok: Tok = null;
  let endTok: Tok = null;
  let m = notes.match(RANGE_RE);
  if (m) {
    startTok = parseDateToken(m[1], asOf);
    endTok = parseDateToken(m[2], asOf);
  } else {
    m = notes.match(SINCE_RE);
    if (m) {
      startTok = parseDateToken(m[1], asOf);
      endTok = { kind: "present" };
    }
  }
  if (!startTok || startTok.kind !== "date" || !endTok) return null;
  return {
    start: ym(startTok.my),
    end: endTok.kind === "present" ? null : ym((endTok as any).my),
  };
}

/**
 * Fires when the stored row holds the SWAPPED labels this parser corrects:
 * the parsed title looks like the stored employer, or vice versa.
 */
function swapSignature(parsed: ParsedRole, existing: any): number {
  return Math.max(
    nameSimilarity(parsed.title, existing?.employer),
    nameSimilarity(parsed.employer, existing?.title),
  );
}

/**
 * How much the LABELS say these are the same job. Employer agreement is
 * strongest (checked against both stored fields, since the previous parser
 * swapped them). A swap signature is next. A title alone matches many jobs
 * ("Manager"), so it only counts when one side names no employer at all —
 * two named employers that disagree still mean different jobs, whatever the
 * titles say (Karen Garza's Harlandale row versus her Comal ISD row).
 */
function labelEvidence(parsed: ParsedRole, existing: any): number {
  const empSim = Math.max(
    nameSimilarity(parsed.employer, existing?.employer),
    nameSimilarity(parsed.employer, existing?.title),
  );
  if (empSim >= 0.5) return empSim;
  if (swapSignature(parsed, existing) >= 0.8) return 0.7;
  const bothHaveEmployer = !!normalizeName(parsed.employer) && !!normalizeName(existing?.employer);
  if (bothHaveEmployer) return 0;
  const titleSim = Math.max(
    nameSimilarity(parsed.title, existing?.title),
    nameSimilarity(parsed.title, existing?.employer),
  );
  if (titleSim >= 0.9) return nameTokens(parsed.title).size >= 2 ? 0.55 : 0.30;
  return 0;
}

/**
 * How much the DATES say these are the same job. Added to the label evidence.
 * Same start month is the strongest signal there is that two differently
 * labelled rows are one job; different start months are strong evidence they
 * are not. An undated stored row has no start to compare, so its own notes
 * text and its recorded tenure stand in.
 */
function dateAgreement(parsed: ParsedRole, existing: any, asOf: MonthYear): number {
  const eStart = typeof existing?.start === "string" && existing.start ? existing.start : null;
  if (eStart) {
    if (eStart !== parsed.start) return -0.40;
    const eEnd = typeof existing?.end === "string" && existing.end ? existing.end : null;
    return eEnd === parsed.end ? 0.50 : 0.25;
  }
  const fromNotes = notesDateRange(existing, asOf);
  if (fromNotes && fromNotes.start === parsed.start && fromNotes.end === parsed.end) return 0.50;
  if (typeof existing?.tenure_months === "number" && existing.tenure_months === parsed.tenure_months) return 0.35;
  return 0;
}

/**
 * How well a parsed role matches an existing entry: label evidence plus date
 * agreement, threshold 0.5 in the caller.
 *
 * HARD RULE — a pair with no label evidence at all never matches, however
 * well the dates line up. The parser's labels are sometimes the WRONG ones,
 * and absorbing on dates alone would overwrite a correct stored label with a
 * wrong parsed one. Jonathan Kelley is the reference case: 2011-02 to
 * 2014-05, parser says "Chief of Police @ Achille Police Department", stored
 * says "Sergeant @ Fannin County Sheriffs Office", and the STORED row is the
 * correct one. That duplicate is left visible on purpose.
 */
function roleMatchScore(parsed: ParsedRole, existing: any, asOf: MonthYear): number {
  const label = labelEvidence(parsed, existing);
  if (label <= 0) return 0;
  return label + dateAgreement(parsed, existing, asOf);
}

/**
 * Copies the seasonal verdict onto a merged entry, and CLEARS it when the role
 * is no longer judged seasonal so a stale flag cannot survive a reparse.
 *
 * This module owns these two fields the same way it owns start/end/tenure.
 * Leaving them out of the merge is exactly what broke the first backfill
 * attempt: the seasonal correction was computed and then silently discarded,
 * the merged entry came out identical to what was stored, and so nothing was
 * written at all (Steven Valdez stayed at an inflated 117 months).
 */
function withSeasonalFields(entry: any, parsed: ParsedRole): any {
  const out = { ...entry };
  if (parsed.is_seasonal && Array.isArray(parsed.season_months) && parsed.season_months.length > 0) {
    out.is_seasonal = true;
    out.season_months = parsed.season_months;
  } else {
    delete out.is_seasonal;
    delete out.season_months;
  }
  return out;
}

function hasQualitativeContent(entry: any): boolean {
  const cat = entry?.category;
  const notes = entry?.notes;
  return (typeof cat === "string" && cat.trim() !== "") || (typeof notes === "string" && notes.trim() !== "");
}

/**
 * The hand-repair marker (op-rule amendment 2026-08-26): a person corrected
 * this entry and tagged it "[... by hand YYYY-MM-DD - ...]". The parser never
 * overwrites such an entry — not its labels, not its dates, not its tenure.
 * Before this guard, mode=resume_tenure_backfill would have rebuilt 49
 * corrections out of existence.
 */
const HAND_REPAIR_MARKER_RE = /\bby hand \d{4}-\d{2}-\d{2}\b/i;
function isHandRepaired(entry: any): boolean {
  return typeof entry?.notes === "string" && HAND_REPAIR_MARKER_RE.test(entry.notes);
}

/**
 * A stored label that a person has annotated, which the parsed label merely
 * EXTENDS ("Billing Assistant" versus "Billing Assistant South Texas Foot &
 * Ankle Specialist"): the shorter, human-trimmed one wins. Older repairs
 * (pre-2026-08-26) carry notes but no marker, and this is what protects them.
 */
function storedLabelIsTrimmedForm(parsedLabel: string | null, storedLabel: string | null): boolean {
  const p = normalizeName(parsedLabel);
  const e = normalizeName(storedLabel);
  if (!p || !e || p === e) return false;
  return e.length >= 4 && p.includes(e) && p.length > e.length + 2;
}

/**
 * Merges parsed roles into the existing qualifications.prior_similar_role
 * shape. This module owns employer / title / start / end / is_current /
 * tenure_months on every entry it can match, and preserves category / notes
 * (and any other key) on matched entries. Unmatched parsed roles are added
 * with category/notes null.
 *
 * Existing entries that match nothing are kept ONLY if a person wrote
 * something on them (category or notes) — those are real jobs recorded by
 * hand (often undated on the resume). Entries with no qualitative content
 * are the previous parser's own output and are replaced wholesale, which
 * is what stops the old swapped/duplicated labels from surviving next to
 * the corrected ones and double-counting tenure.
 */
export function mergeParsedRolesIntoResumeAnalysis(
  existing: any,
  parsedRoles: ParsedRole[],
  asOf?: MonthYear,
): { updated: any; changed: boolean } {
  const now = asOf ?? nowMonthYear();
  const base = existing && typeof existing === "object" ? { ...existing } : {};
  const qualifications = { ...(base.qualifications ?? {}) };
  const priorSimilarRole = { ...(qualifications.prior_similar_role ?? {}) };
  const existingRoles: any[] = Array.isArray(priorSimilarRole.roles) ? [...priorSimilarRole.roles] : [];

  const usedExistingIdx = new Set<number>();
  const mergedRoles: any[] = [];

  for (const parsed of parsedRoles) {
    let bestIdx = -1;
    let bestScore = 0;
    existingRoles.forEach((r, idx) => {
      if (usedExistingIdx.has(idx)) return;
      const sc = roleMatchScore(parsed, r, now);
      if (sc > bestScore) { bestScore = sc; bestIdx = idx; }
    });
    if (bestIdx >= 0 && bestScore >= 0.5) {
      usedExistingIdx.add(bestIdx);
      const existingRole = existingRoles[bestIdx];
      // A hand-repaired entry is kept exactly as the person left it. The
      // parsed twin is consumed (so it is not added beside it) and discarded.
      if (isHandRepaired(existingRole)) {
        mergedRoles.push({ ...existingRole });
        continue;
      }
      // Whose labels win. 1) The swap signature fired, so the stored row IS
      // the swapped one — take the parsed labels. 2) Someone wrote a category
      // or a note on this row and the parsed label is duty-sentence junk, or
      // merely a longer form of the stored label — keep the stored label and
      // take only the dates. 3) Otherwise the parsed labels, as before.
      // Category and notes always survive either way.
      const annotated = hasQualitativeContent(existingRole);
      // A parsed label that contains the stored title AND the stored employer
      // is fused, not swapped — the swap signature fires on it by accident.
      const titleFused = annotated && storedLabelIsTrimmedForm(parsed.title, existingRole.title);
      const employerFused = annotated && storedLabelIsTrimmedForm(parsed.employer, existingRole.employer);
      const swapFired = swapSignature(parsed, existingRole) >= 0.8 && !titleFused && !employerFused;
      const keepStoredLabels = !swapFired && annotated
        && (isJunkLabel(parsed.title) || isJunkLabel(parsed.employer));
      const keepStoredTitle = keepStoredLabels || titleFused;
      const keepStoredEmployer = keepStoredLabels || employerFused;
      mergedRoles.push(withSeasonalFields({
        ...existingRole,
        employer: keepStoredEmployer
          ? (existingRole.employer ?? parsed.employer ?? null)
          : (parsed.employer ?? existingRole.employer ?? null),
        title: keepStoredTitle
          ? (existingRole.title ?? parsed.title ?? null)
          : (parsed.title ?? existingRole.title ?? null),
        start: parsed.start,
        end: parsed.end,
        is_current: parsed.is_current,
        tenure_months: parsed.tenure_months,
      }, parsed));
    } else {
      mergedRoles.push(withSeasonalFields({
        employer: parsed.employer,
        title: parsed.title,
        start: parsed.start,
        end: parsed.end,
        is_current: parsed.is_current,
        tenure_months: parsed.tenure_months,
        category: null,
        notes: null,
      }, parsed));
    }
  }
  // Carry over entries this parse did not touch, folding in the ones that are
  // really a merged row wearing older labels.
  //
  // WHY A SECOND PASS EXISTS. The loop above can never reach these. By the
  // time a reparse runs, the stored list already holds a merged twin of every
  // row the parser produces, and best-match always scores the twin higher
  // (same employer 1.0 plus same dates 0.50) than the stale duplicate beside
  // it. The duplicate lost that comparison once and loses it again, whatever
  // the score function does — verified across all 53 affected candidates on
  // 2026-08-20, zero absorbed. So the leftovers are compared against the
  // MERGED ROWS instead, reusing the same score with the merged row standing
  // in for the parsed one.
  //
  // Only rows already claimed by this parse are eligible targets: a leftover
  // may not fold onto another leftover.
  const parsedTargets = mergedRoles.length;
  existingRoles.forEach((r, idx) => {
    if (usedExistingIdx.has(idx)) return;
    if (!hasQualitativeContent(r)) return;

    let bestIdx = -1;
    let bestScore = 0;
    for (let i = 0; i < parsedTargets; i++) {
      const target = mergedRoles[i];
      // Never fold two noted rows together — that would force a choice
      // between two sets of written notes. Leave the duplicate visible and
      // let a person decide.
      if (hasQualitativeContent(target)) continue;
      const asParsed: ParsedRole = {
        title: target.title ?? null,
        employer: target.employer ?? null,
        start: target.start,
        end: target.end ?? null,
        is_current: !!target.is_current,
        tenure_months: target.tenure_months,
        start_raw: "",
        end_raw: "",
      };
      const sc = roleMatchScore(asParsed, r, now);
      if (sc > bestScore) { bestScore = sc; bestIdx = i; }
    }

    if (bestIdx >= 0 && bestScore >= 0.5) {
      const target = mergedRoles[bestIdx];
      // A hand-repaired leftover is the person's version of this job: it
      // replaces the parser's twin outright rather than folding under it.
      if (isHandRepaired(r)) {
        mergedRoles[bestIdx] = { ...r };
        return;
      }
      // The merged row owns employer / title / dates / tenure — those came
      // from the corrected parse. The leftover contributes what only it has.
      const { employer: _e, title: _t, start: _s, end: _x, is_current: _c,
              tenure_months: _m, ...carried } = r;
      // target wins on every field it owns, but an unmatched parsed row
      // carries category:null / notes:null EXPLICITLY, and a plain spread
      // would let those nulls erase the very notes this fold exists to save.
      const folded: any = { ...carried, ...target };
      folded.category = target.category ?? r.category ?? null;
      folded.notes = target.notes ?? r.notes ?? null;
      mergedRoles[bestIdx] = folded;
      return;
    }
    mergedRoles.push(r);
  });

  priorSimilarRole.roles = mergedRoles;
  qualifications.prior_similar_role = priorSimilarRole;
  base.qualifications = qualifications;

  // A resume the parser could read nothing out of still gets a row. Before,
  // an empty parse of an untouched candidate compared empty-to-empty, reported
  // no change, and wrote NOTHING — so resume_analysis stayed NULL and the
  // candidate fell out of every queue that looks for missing signals rather
  // than for a null row (Kersten Smith's resume carries no dates anywhere).
  // The stub says "this was parsed and came back empty", which is a different
  // fact from "never parsed".
  const hadAnalysis = existing && typeof existing === "object";
  base.tenure_parser = {
    version: PARSER_VERSION,
    roles_found: parsedRoles.length,
    dates_found: parsedRoles.length > 0,
  };
  const changed = JSON.stringify(existingRoles) !== JSON.stringify(mergedRoles) || !hadAnalysis;
  return { updated: base, changed };
}

// -------------------------------------------------------------------------
// Orchestration — called from resume ingest and from the
// resume_tenure_backfill mode in index.ts.
// -------------------------------------------------------------------------

/**
 * Parses resumeText for work-experience entries and writes the result into
 * hiring_candidates.resume_analysis for candidateId, merging (never
 * clobbering qualitative fields) into whatever is already there. Also
 * invalidates that ONE candidate's scoring cache (cached_scoring_version =
 * NULL) so the next page load recomputes their fit with the fresh data —
 * deliberately does NOT bump the agency-wide hiregauge_scoring_version.
 *
 * Non-fatal on any failure — logs a warning and returns ok:false. Never
 * throws; the ingest pipeline must not have resume-text writes blocked by a
 * tenure-parsing problem.
 */
export async function extractAndWriteWorkExperienceTenure(
  candidateId: string | null | undefined,
  resumeText: string | null | undefined,
  opts?: { dryRun?: boolean; existingResumeAnalysis?: any },
): Promise<{ ok: boolean; rolesFound: number; totalMonths: number | null; changed: boolean; error?: string; roles?: ParsedRole[] }> {
  if (!candidateId || !resumeText) return { ok: false, rolesFound: 0, totalMonths: null, changed: false, error: "missing candidateId or resumeText" };
  try {
    const parsedRoles = parseWorkExperienceRoles(resumeText);

    let existing: any = opts?.existingResumeAnalysis;
    if (existing === undefined) {
      const { data, error: fetchErr } = await sb
        .from("hiring_candidates")
        .select("resume_analysis")
        .eq("id", candidateId)
        .single();
      if (fetchErr) {
        console.warn(`extractAndWriteWorkExperienceTenure: fetch failed for ${candidateId}: ${fetchErr.message}`);
        return { ok: false, rolesFound: parsedRoles.length, totalMonths: null, changed: false, error: fetchErr.message };
      }
      existing = data?.resume_analysis;
    }

    const { updated, changed } = mergeParsedRolesIntoResumeAnalysis(existing, parsedRoles);
    const totalMonths = totalWorkMonths(updated?.qualifications?.prior_similar_role?.roles ?? []);
    if (!changed || opts?.dryRun) return { ok: true, rolesFound: parsedRoles.length, totalMonths, changed, roles: parsedRoles };

    const { error: writeErr } = await sb
      .from("hiring_candidates")
      .update({ resume_analysis: updated, cached_scoring_version: null })
      .eq("id", candidateId);
    if (writeErr) {
      console.warn(`extractAndWriteWorkExperienceTenure: write failed for ${candidateId}: ${writeErr.message}`);
      return { ok: false, rolesFound: parsedRoles.length, totalMonths, changed: false, error: writeErr.message };
    }
    return { ok: true, rolesFound: parsedRoles.length, totalMonths, changed: true, roles: parsedRoles };
  } catch (e) {
    console.warn(`extractAndWriteWorkExperienceTenure threw for ${candidateId}:`, e);
    return { ok: false, rolesFound: 0, totalMonths: null, changed: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * Re-runs the extractor over stored resume text for many candidates at
 * once. Used by index.ts mode "resume_tenure_backfill" (one-time backfill
 * after a parser change, or a targeted re-run for named candidates).
 * Body options: candidate_ids (array) OR limit/offset paging over every
 * candidate with resume text, plus dry_run to preview without writing.
 * Does NOT bump hiregauge_scoring_version — the caller does that once at
 * the end of a full backfill (see operational rule on cache invalidation).
 */
export async function backfillWorkExperienceTenure(args: {
  agencyId: string;
  candidateIds?: string[];
  limit?: number;
  offset?: number;
  dryRun?: boolean;
  includeRoles?: boolean;
}): Promise<{ scanned: number; changed: number; failed: number; results: any[] }> {
  const limit = Math.max(1, Math.min(args.limit ?? 50, 200));
  const offset = Math.max(0, args.offset ?? 0);
  let q = sb
    .from("hiring_candidates")
    .select("id, first_name, last_name, resume_extracted_text, resume_analysis")
    .eq("agency_id", args.agencyId)
    .not("resume_extracted_text", "is", null)
    .order("applied_at", { ascending: true, nullsFirst: false })
    .order("id", { ascending: true });
  if (args.candidateIds && args.candidateIds.length > 0) {
    q = q.in("id", args.candidateIds);
  } else {
    q = q.range(offset, offset + limit - 1);
  }
  const { data, error } = await q;
  if (error) throw new Error(`backfill fetch failed: ${error.message}`);

  const results: any[] = [];
  let changed = 0;
  let failed = 0;
  for (const row of data ?? []) {
    const r = await extractAndWriteWorkExperienceTenure(row.id, row.resume_extracted_text, {
      dryRun: !!args.dryRun,
      existingResumeAnalysis: row.resume_analysis,
    });
    if (!r.ok) failed++;
    if (r.ok && r.changed && !args.dryRun) changed++;
    results.push({
      id: row.id,
      name: `${row.first_name ?? ""} ${row.last_name ?? ""}`.trim(),
      ok: r.ok,
      roles_found: r.rolesFound,
      total_months: r.totalMonths,
      changed: r.changed,
      error: r.error ?? null,
      ...(args.includeRoles ? { roles: r.roles ?? [] } : {}),
    });
  }
  return { scanned: (data ?? []).length, changed, failed, results };
}
