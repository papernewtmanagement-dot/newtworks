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
// =========================================================================

// deno-lint-ignore-file no-explicit-any

/**
 * Bumped whenever the extraction rules change, so a stored row can be told
 * apart from one written by an older parser without re-reading the resume.
 */
export const PARSER_VERSION = "v3_2026_08_19";

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

export type MonthYear = { year: number; month: number };
type Tok = { kind: "date"; my: MonthYear; shortYear: boolean; yearOnly: boolean } | { kind: "present" } | null;

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
]);

// Sections that never hold paid work. Date ranges here are volunteer
// stints, project timelines, memberships — not jobs.
const EXCLUDED_HEADERS: ReadonlySet<string> = new Set([
  "references", "professional references",
  "volunteer", "volunteering", "volunteer experience", "volunteer work",
  "community service", "community involvement", "activities", "extracurricular activities",
  "extracurriculars", "school involvement", "leadership", "leadership experience",
  "projects", "interests", "hobbies", "publications", "affiliations",
  "professional affiliations", "memberships",
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
  return /^\s*(?:[•\-*●○◦▪■➢➤►›»>·‣⁃]|\d+[.)])\s+\S/.test(line);
}
// A line that is only punctuation / bullet glyphs (PDF extraction leaves
// orphan bullet markers on their own lines) — skipped, not a stop.
function isPunctOnly(line: string): boolean {
  return line.trim().length > 0 && /^[\s•·●○◦▪■➢➤►›»>‣⁃\-–—_|:.,;*]+$/.test(line);
}
// Bullet-less description lines usually open with a past-tense action verb
// ("Managed the front desk", "Handled inbound calls") or a pronoun. Job
// titles and employer names never do.
const ACTION_VERB_START_RE =
  /^(?:managed|handled|provided|delivered|built|coordinated|trained|assisted|resolved|developed|maintained|ensured|conducted|worked|collaborated|performed|created|oversaw|supported|processed|answered|greeted|operated|prepared|completed|increased|achieved|generated|recognized|recognised|selected|served|directed|recruited|improved|exceeded|surpassed|utilized|utilised|communicated|scheduled|sold|helped|responsible|responded|reviewed|analyzed|analysed|implemented|organized|organised|monitored|tracked|documented|reported|negotiated|closed|opened|drove|grew|reduced|saved|earned|won|received|awarded|promoted|hired|mentored|coached|taught|educated|advised|consulted|contacted|called|followed|met|attained|obtained|secured|established|launched|introduced|planned|designed|executed|facilitated|guided|inspected|installed|repaired|cleaned|stocked|loaded|unloaded|picked|packed|shipped|verified|audited|balanced|reconciled|entered|updated|filed|typed|dispatched|assigned|delegated|supervised|interviewed|onboarded|escalated|de-escalated|troubleshot|diagnosed|upsold|cross-sold|quoted|underwrote|adjusted|investigated|assessed|evaluated|identified|determined|calculated|collected|distributed|demonstrated|explained|presented|marketed|advertised|posted|edited|filmed|photographed|recorded|produced|wrote|drafted|translated|interpreted|counseled|counselled|cared|fed|bathed|dressed|transported|escorted|welcomed|checked|took|made|kept|ran|set|put|got|did|was|were|am|is|are|has|have|had|being|assist|assists|manage|manages|handle|handles|provide|provides|perform|performs|maintain|maintains|ensure|ensures|answer|answers|greet|greets|process|processes|serve|serves|issue|issues|collect|collects|compose|composes|revise|revises|receive|receives|operate|operates)\b\s+\S/i;
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
// Employers whose stated range spans years but whose work happens in one
// window each year. Read literally, "Sep 2016 to Nov 2025" at a Halloween
// shop becomes a 110-month job and buries every other role on the resume.
const SEASONAL_EMPLOYER_RE =
  /\b(?:spirit\s*halloween|halloween\s*(?:city|express)|h\s*&\s*r\s*block|h\s+and\s+r\s+block|hr\s+block|jackson\s+hewitt|liberty\s+tax)\b/i;
// An entry the resume itself marks seasonal.
const SEASONAL_WORD_RE = /\bseasonal\b/i;

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
  "solicitor", "canvasser", "promoter", "demonstrator", "brand ambassador", "receiver",
  "shipper", "expediter", "runner", "busser", "busboy", "food runner", "prep", "line cook",
  "sous", "pastry", "baker", "butcher", "florist", "stylist", "cosmetologist", "barber",
  "esthetician", "massage", "dietitian", "nutritionist", "optician", "veterinary",
  "vet tech", "groomer", "kennel", "farmhand", "ranch hand", "landscaper", "groundskeeper",
  "gardener", "conductor", "pilot", "flight attendant", "steward", "purser",
  "translator", "interpreter", "editor", "writer", "author", "journalist", "reporter",
  "dj", "performer", "actor", "model", "influencer", "creator",
  "streamer", "youtuber", "podcaster", "student worker", "work study", "resident assistant",
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
const TITLE_RE = new RegExp(`\\b(?:${TITLE_WORDS.map(escapeRe).join("|")})\\b`, "ig");
const EMPLOYER_RE = new RegExp(`(?:^|\\b|(?<=\\W))(?:${EMPLOYER_WORDS.map(escapeRe).join("|")})(?:\\b|(?=\\W)|$)`, "ig");

function titleScore(s: string): number {
  return (s.match(TITLE_RE) ?? []).length;
}
function employerScore(s: string): number {
  return (s.match(EMPLOYER_RE) ?? []).length;
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
]);
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
  let t = s.trim().replace(/[.,;|]+$/, "").trim();
  if (!t) return false;
  if (LOOSE_LOCATION_RE.test(t)) return true;
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
      if (KNOWN_CITIES.has(cand)) {
        peeled = hw.slice(0, hw.length - n).join(" ").replace(/[\s,;|\-\u2013\u2014]+$/g, "").trim();
        break;
      }
    }
    if (!peeled) return "";
    t = peeled;
  }
  t = t.replace(/[\s\-\u2013\u2014|,;:(]+$/g, "").trim();
  return t;
}

/** Cleans a raw header piece into a label, or returns null if it is junk. */
function cleanSegment(raw: string): string | null {
  let s = raw.replace(/\s+/g, " ").trim();
  s = s.replace(/^[\s•·●○◦▪■\-–—|:;,.]+/, "").replace(/[\s•·●○◦▪■\-–—|:;,]+$/, "").trim();
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
  if (looksLikeProse(s)) return null;
  // Not a label if it has no letters at all
  if (!/[A-Za-z]/.test(s)) return null;
  return s;
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
  const pieces = s.split(/\s*(?:\||\u2013|\u2014|\u2015|\u2192|\t|;|\s-\s|\s\u00b7\s|\s\u2022\s|\s\/\/\s)\s*/).map((p) => p.trim()).filter(Boolean);
  const out: string[] = [];
  for (const p0 of pieces) {
    // a piece that is only a place ("San Antonio, TX", "Texas") is dropped whole
    if (isLocation(p0)) continue;
    let p = p0;
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
      else out.push(stripped);
      continue;
    }
    if (p.includes(",")) {
      const parts = p.split(",").map((x) => x.trim()).filter(Boolean);
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
  const flagged = SEASONAL_EMPLOYER_RE.test(hay) || SEASONAL_WORD_RE.test(hay);
  if (!flagged) return null;
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
  if (seasonMonths.length === 0 || seasonMonths.length >= 12) return null;
  const seasons = end.year - start.year + (start.month <= end.month ? 1 : 0);
  const months = Math.max(seasonMonths.length, seasons * seasonMonths.length);
  return { seasonMonths, months };
}

// -------------------------------------------------------------------------
// Layout voting
// -------------------------------------------------------------------------

type Layout = "title-first" | "employer-first";

function isStrongTitle(s: string): boolean {
  return titleScore(s) > 0 && employerScore(s) === 0;
}
function isStrongEmployer(s: string): boolean {
  return employerScore(s) > 0 && titleScore(s) === 0;
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
    const t = strongT[0];
    // Prefer an employer on a DIFFERENT line to the title. "Manager, Customer
    // Service" puts an employer-looking piece ("Service" is an employer word)
    // on the very same line as the title, and taking it left the real employer
    // one line below unread (Abraham Ochoa's current role).
    const e = strongE.find((x) => x.li !== t.li) ?? strongE.find((x) => x.s !== t.s) ?? strongE[0];
    if (e.s !== t.s) {
      // With the employer on its own line, everything on the title's line
      // belongs to the title, and vice versa.
      const tLabel = t.li !== e.li ? joinLine(lines[t.li]) : t.s;
      const eLabel = t.li !== e.li && lines[e.li].every((x) => !isStrongTitle(x))
        ? joinLine(lines[e.li]) : e.s;
      return { title: tLabel ?? t.s, employer: eLabel ?? e.s };
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
  // Two or more: score every segment, pick the strongest title and the
  // strongest employer among the rest.
  const scored = segs.map((s, i) => ({ s, i, ts: titleScore(s), es: employerScore(s) }));
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
  /\b(?:unemploy(?:ed|ment)|stay[- ]at[- ]home|homemaker|started a family|maternity|paternity|attended (?:college|school|university)|full[- ]time student|career break|sabbatical|gap year|medical leave|caregiver for|caring for my|raising my|took time off|hiatus|between jobs|job search)\b/i;
const DEGREE_RE =
  /\b(?:bachelor(?:'?s)?|associate(?:'?s)? (?:of|in|degree)|master(?:'?s)? (?:of|in|degree)|mba|b\.?[as]\.?(?:\s|$|,)|a\.?[as]\.?(?:\s|$|,)|m\.?[as]\.?(?:\s|$|,)|b\.?s\.?n\.?|ph\.?d\.?|doctorate|high school(?: diploma)?|\bged\b|diploma|coursework|dean'?s list|undergraduate|graduate student|studying|major(?:ing)? in|degree in|semester|gpa)\b/i;
const CERT_RE = /\b(?:certif(?:icate|ication|ied)|licen[sc]e[sd]?|credential|training program|bootcamp|course)\b/i;
const VOLUNTEER_RE = /\b(?:volunteer|altar (?:boy|server)|knights of columbus|church member|youth group|mission trip|habitat for humanity)\b/i;
const VOLUNTEER_JOB_RE = /\b(?:coordinator|manager|director|specialist|supervisor|paid)\b/i;

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
  if (DEGREE_RE.test(headerText)) return true;
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
const DANGLING_RANGE_END_RE = new RegExp(
  `(?:${DATE_TOKEN_RE})\\s*(?:to|thru|through|until|till|[\\u2013\\u2014\\u2015\\u2010\\u2212\\-]|\\u2192)\\s*$`,
  "i",
);
// The continuation: a line that OPENS with the closing date and nothing else
// of substance.
const LEADING_DATE_ONLY_RE = new RegExp(
  `^\\s*(${DATE_TOKEN_RE}|${PRESENT_RE})\\s*[.,;)|]*\\s*$`,
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
    if (!LEADING_DATE_ONLY_RE.test(nxt)) continue;
    lines[i] = `${cur} ${nxt.trim()}`;
    lines[j] = "";
  }
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
  const lines = rawLines.map((l) => l.replace(/\s+$/g, ""));
  joinWrappedDateRanges(lines);

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
  };
  const entries: RawEntry[] = [];

  for (let i = 0; i < lines.length; i++) {
    if (kinds[i] === "excluded") continue;
    if (headerAt[i]) continue;
    const line = lines[i];
    if (!line.trim()) continue;

    let m = line.match(RANGE_RE);
    let startTok: Tok = null;
    let endTok: Tok = null;
    let startRaw = "";
    let endRaw = "";
    let matchIndex = -1;
    let matchLen = 0;
    if (m && m.index !== undefined) {
      startTok = parseDateToken(m[1], now);
      endTok = parseDateToken(m[2], now);
      startRaw = m[1];
      endRaw = m[2];
      matchIndex = m.index;
      matchLen = m[0].length;
    } else {
      m = line.match(SINCE_RE);
      if (m && m.index !== undefined) {
        startTok = parseDateToken(m[1], now);
        endTok = { kind: "present" };
        startRaw = m[1];
        endRaw = "present";
        matchIndex = m.index;
        matchLen = m[0].length;
      }
    }
    if (!m || matchIndex < 0) continue;
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

    // ---- header assembly ----
    const before = line.slice(0, matchIndex).replace(/[\s\-–—|,;:(]+$/g, "").trim();
    // Text AFTER the dates on the same line is a header candidate too:
    // "July 2025 - July 2026 | State Farm, Flower Mound, TX - Account Manager".
    const after = line.slice(matchIndex + matchLen).replace(/^[\s\-–—|,;:)•·●]+/g, "").trim();
    const dateLineText = `${before} ${after}`;

    const piecesOf = (hl: string[]) => hl.flatMap(splitHeaderLine).map(cleanSegment).filter((x): x is string => !!x);
    const headerLines: string[] = [];
    let beforeUsed = false;
    if (before.length >= 2 && cleanSegment(before) !== null) {
      headerLines.push(before);
      beforeUsed = true;
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
      if (RANGE_RE.test(fl) || SINCE_RE.test(fl) || DATE_ANYWHERE_RE.test(fl)) return false;
      if (looksLikeProse(t) || isLocation(t)) return false;
      return piecesOf([t]).length > 0;
    })();
    let back = i - 1;
    let collected = 0;
    let blanksSkipped = 0;
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
      // another entry's date line, or a dated education/award line
      if (RANGE_RE.test(bl) || SINCE_RE.test(bl) || DATE_ANYWHERE_RE.test(bl)) break;
      if (looksLikeProse(t)) { back--; if (beforeUsed) break; continue; }
      headerLines.unshift(t);
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
      let haveTitle = piecesSoFar.length === 1 && titleScore(piecesSoFar[0]) > 0 && employerScore(piecesSoFar[0]) === 0;
      let haveEmployer = piecesSoFar.length === 1 && employerScore(piecesSoFar[0]) > 0 && titleScore(piecesSoFar[0]) === 0;
      let fwd = i + 1;
      let taken = 0;
      while (piecesSoFar.length < 2 && taken < 2 && fwd < lines.length && fwd <= i + 4) {
        const fl = lines[fwd];
        const t = fl.trim();
        if (t === "" || isDivider(fl) || headerAt[fwd] || kinds[fwd] === "excluded") break;
        if (isPunctOnly(fl)) { fwd++; continue; }
        if (isLocation(t)) { fwd++; continue; }
        if (isBullet(fl)) break;
        if (RANGE_RE.test(fl) || SINCE_RE.test(fl) || DATE_ANYWHERE_RE.test(fl)) break;
        if (looksLikeProse(t) || wordCount(t) > 14) break;
        const fp = piecesOf([t]);
        if (fp.length === 0) { fwd++; continue; } // junk word like "Professional"
        if (piecesSoFar.length === 1 && fp.length > 1) break; // that is the next entry's header
        if (fp.length === 1) {
          const fts = titleScore(fp[0]);
          const fes = employerScore(fp[0]);
          if (haveTitle && fts > 0 && fes === 0) break;
          if (haveEmployer && fes > 0 && fts === 0) break;
        }
        headerLines.push(t);
        taken++;
        fwd++;
        piecesSoFar = piecesOf(headerLines);
        haveTitle = piecesSoFar.length === 1 && titleScore(piecesSoFar[0]) > 0 && employerScore(piecesSoFar[0]) === 0;
        haveEmployer = piecesSoFar.length === 1 && employerScore(piecesSoFar[0]) > 0 && titleScore(piecesSoFar[0]) === 0;
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
    // A stray date range in prose with no label at all is not a job.
    if (labelsPerLine.length === 0) continue;

    entries.push({ labelsPerLine, headerText, dateLineText, startMY, endMY, isCurrent, months, startRaw, endRaw });
  }

  // ---- Pass 3: learn the layout once, then label and emit every entry ----
  const layout = voteLayout(entries.map((e) => e.labelsPerLine));
  const roles: ParsedRole[] = [];
  const seen = new Set<string>();
  for (const e of entries) {
    let { title, employer } = assignTitleEmployerFromLines(e.labelsPerLine, layout);
    if (title && title.length > 120) title = title.slice(0, 120);
    if (employer && employer.length > 120) employer = employer.slice(0, 120);
    if (!title && !employer) continue;

    const key = `${normalizeName(employer)}|${normalizeName(title)}|${ym(e.startMY)}`;
    if (seen.has(key)) continue;
    seen.add(key);

    const seasonal = seasonalProfile(title, employer, e.headerText, e.dateLineText, e.startMY, e.endMY, e.isCurrent);
    roles.push({
      title,
      employer,
      start: ym(e.startMY),
      end: e.isCurrent ? null : ym(e.endMY),
      is_current: e.isCurrent,
      tenure_months: seasonal ? seasonal.months : e.months,
      start_raw: e.startRaw,
      end_raw: e.endRaw,
      ...(seasonal ? { is_seasonal: true, season_months: seasonal.seasonMonths } : {}),
    });
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
 * How well a parsed role matches an existing entry. Employer agreement is
 * decisive (checked against BOTH fields, since the previous parser swapped
 * them). A title alone matches many jobs ("Manager"), so it only counts when
 * there is no employer on one side to disagree, and only when it is a
 * near-exact, multi-word title.
 */
function roleMatchScore(parsed: ParsedRole, existing: any): number {
  const empSim = Math.max(nameSimilarity(parsed.employer, existing?.employer), nameSimilarity(parsed.employer, existing?.title));
  if (empSim >= 0.5) return empSim;
  const bothHaveEmployer = !!normalizeName(parsed.employer) && !!normalizeName(existing?.employer);
  if (bothHaveEmployer) return 0; // two named employers that disagree = different jobs
  const titleSim = Math.max(nameSimilarity(parsed.title, existing?.title), nameSimilarity(parsed.title, existing?.employer));
  if (titleSim >= 0.9 && nameTokens(parsed.title).size >= 2) return 0.8;
  return 0;
}

function hasQualitativeContent(entry: any): boolean {
  const cat = entry?.category;
  const notes = entry?.notes;
  return (typeof cat === "string" && cat.trim() !== "") || (typeof notes === "string" && notes.trim() !== "");
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
): { updated: any; changed: boolean } {
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
      const sc = roleMatchScore(parsed, r);
      if (sc > bestScore) { bestScore = sc; bestIdx = idx; }
    });
    if (bestIdx >= 0 && bestScore >= 0.5) {
      usedExistingIdx.add(bestIdx);
      const existingRole = existingRoles[bestIdx];
      mergedRoles.push({
        ...existingRole,
        employer: parsed.employer ?? existingRole.employer ?? null,
        title: parsed.title ?? existingRole.title ?? null,
        start: parsed.start,
        end: parsed.end,
        is_current: parsed.is_current,
        tenure_months: parsed.tenure_months,
      });
    } else {
      mergedRoles.push({
        employer: parsed.employer,
        title: parsed.title,
        start: parsed.start,
        end: parsed.end,
        is_current: parsed.is_current,
        tenure_months: parsed.tenure_months,
        category: null,
        notes: null,
      });
    }
  }
  // Carry over hand-written entries this parse did not touch (undated jobs).
  existingRoles.forEach((r, idx) => {
    if (usedExistingIdx.has(idx)) return;
    if (hasQualitativeContent(r)) mergedRoles.push(r);
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
