// =========================================================================
// parsers/comp_recap.ts (v2 — deterministic regex parser)
// =========================================================================
// Parses State Farm semi-monthly agency compensation recap PDFs into
// structured comp_recap rows.
//
// REPLACES the prior LLM-based parser (v1, 2026-05). Decision rationale:
//   - The SF recap format has been stable for 30+ years.
//   - The LLM-based approach produced two recurring failures:
//       (1) silent payload truncation on bigger comp PDFs (>~2K char output)
//           leaving rows missing or malformed JSON;
//       (2) wrong-column extraction on deduction docs (LLM grabbed the
//           YEAR-TO-DATE column instead of CURRENT).
//   - The format is fully mechanical: a line with ONE money number is YTD
//     only (skipped); a line with TWO money numbers is CURRENT then YTD
//     (current captured).
//
// VERIFIED RECONCILIATIONS:
//   - June 1-15 2026: 22 rows, Texas current $19,488.67,
//     total $19,677.49 (matches SF NET PAYABLE $19,220.32 after deductions).
//   - May 16-31 2026: 20 rows, Texas current $26,899.94,
//     total $26,900.75 (matches SF NET PAYABLE $25,614.19 after deductions).
//
// FORMAT REFERENCE (real example):
//   "1RECAPITULATION OF AGENCY COMPENSATION AND REIMBURSEMENTS FOR JUNE 1-15, 2026"
//   "1ARKANSAS CODE 04-1BDD"                       <- state header
//   "1COMPANY DESCRIPTION CURRENT YEAR-TO-DATE"
//   "1MUTL AUTO NEW BUSINESS .50-"                 <- YTD only, skip
//   "1 AUTO RENEWAL SERVICE .19- 200.12"           <- current=-0.19 (under MUTL)
//   "1 TOTAL MUTL ******** .19- *** 199.62"        <- subtotal, skip
//   "1SFL FIRST YEAR WRITING 3.92 23.52"            <- new company starts: SFL
//   ...repeating per state, ending with Texas (no explicit "TEXAS CODE" header)
// =========================================================================

import { sb } from "../lib/supabase.ts";

export interface CompRecapRow {
  period_year: number;
  period_month: number;
  period_day: number;
  comp_type: string;          // "1H" (days 1-15) or "2H" (days 16-EOM)
  comp_category: string;
  description: string;
  amount: number;
  is_aipp_eligible: boolean;
  is_scorecard_eligible: boolean;
}

export type ParseCompRecapResult =
  | { ok: true; rows: CompRecapRow[]; written: number; period: PeriodInfo; texas_current_total: number }
  | { ok: false; error: string };

interface PeriodInfo { year: number; month: number; day: number; comp_type: "1H" | "2H" }

// --- Period header ----------------------------------------------------------
const MONTHS: Record<string, number> = {
  JANUARY: 1, FEBRUARY: 2, MARCH: 3, APRIL: 4, MAY: 5, JUNE: 6,
  JULY: 7, AUGUST: 8, SEPTEMBER: 9, OCTOBER: 10, NOVEMBER: 11, DECEMBER: 12,
};
function parsePeriod(text: string): PeriodInfo | null {
  const m = text.match(/FOR\s+([A-Z]+)\s+(\d+)\s*-\s*(\d+),\s*(\d{4})/i);
  if (!m) return null;
  const month = MONTHS[m[1].toUpperCase()];
  if (!month) return null;
  const startDay = parseInt(m[2], 10);
  const endDay = parseInt(m[3], 10);
  const year = parseInt(m[4], 10);
  return { year, month, day: endDay, comp_type: startDay === 1 ? "1H" : "2H" };
}

// --- State header / description prefix --------------------------------------
const STATE_CODE: Record<string, string> = {
  ARKANSAS: "AR (04)", "NEW MEXICO": "NM (31)", OKLAHOMA: "OK (36)", TEXAS: "",
};
function detectStateHeader(raw: string): string | null {
  const cleaned = raw.replace(/^1\s*/, "").trim();
  for (const [name, prefix] of Object.entries(STATE_CODE)) {
    if (cleaned.startsWith(name + " CODE ")) return prefix;
  }
  return null;
}

// --- Company tracking -------------------------------------------------------
// Lines like "1MUTL AUTO NEW BUSINESS ..." start a new company section; the
// "MUTL" tag persists for subsequent continuation lines that start with "1 ".
const COMPANY_TAGS = new Set(["MUTL", "SFL", "FIRE", "LLYD", "TCM", "IPSI", "SFVC", "SFCL", "GFA"]);
const COMPANY_TAG_RE = /^1([A-Z]+)\s+/;
function detectCompany(raw: string): string | null {
  const m = raw.match(COMPANY_TAG_RE);
  if (!m) return null;
  return COMPANY_TAGS.has(m[1]) ? m[1] : null;
}

// Companies whose rows ALWAYS belong to a fixed comp_category, regardless of
// description (e.g. all IPSI/SFVC items are investment products → ips_renewal).
const COMPANY_CATEGORY: Record<string, { category: string; aipp: boolean }> = {
  IPSI: { category: "ips_renewal", aipp: false },
  SFVC: { category: "ips_renewal", aipp: false },
};

// --- Amount parser ----------------------------------------------------------
function parseAmount(s: string): number | null {
  const cleaned = s.replace(/,/g, "").trim();
  const negative = cleaned.endsWith("-");
  const num = parseFloat(negative ? cleaned.slice(0, -1) : cleaned);
  if (isNaN(num)) return null;
  return negative ? -num : num;
}

// --- Description → category mapping -----------------------------------------
interface CatRule { test: RegExp; category: string; aipp: boolean }
const CATEGORY_RULES: CatRule[] = [
  // Health
  { test: /HEALTH NEW BUSINESS/i,                category: "health_new",    aipp: false },
  { test: /HEALTH RENEWAL SERVICE/i,             category: "health_renewal",aipp: false },
  { test: /MED SUPP/i,                           category: "health_renewal",aipp: false },
  // Life (SFL — traditional life)
  { test: /FIRST YEAR WRITING/i,                 category: "life_new",      aipp: false },
  { test: /RENEWAL WRITING/i,                    category: "life_renewal",  aipp: false },
  { test: /^SERVICING$/i,                        category: "life_renewal",  aipp: false }, // SFL bare-word SERVICING
  // Fire — Lloyds + TCM-fire + generic FIRE (order matters: Lloyds first)
  { test: /LLYD NEW BUSINESS|LLOYDS NEW/i,       category: "fire_new",      aipp: true  },
  { test: /RENEWAL SERVICE - LLOYDS/i,           category: "fire_renewal",  aipp: true  },
  { test: /TCM FIRE NEW BUSINESS/i,              category: "fire_new",      aipp: true  },
  { test: /TCM FIRE RENEWAL SERVICE/i,           category: "fire_renewal",  aipp: true  },
  { test: /FIRE NEW BUSINESS/i,                  category: "fire_new",      aipp: true  },
  { test: /FIRE RENEWAL SERVICE/i,               category: "fire_renewal",  aipp: true  },
  // Auto
  { test: /TCM AUTO NEW BUSINESS/i,              category: "auto_new",      aipp: true  },
  { test: /TCM AUTO RENEWAL SERVICE/i,           category: "auto_renewal",  aipp: true  },
  { test: /AUTO NEW BUSINESS/i,                  category: "auto_new",      aipp: true  },
  { test: /AUTO NEW\s*-\s*AMD/i,                 category: "auto_new",      aipp: true  },
  { test: /AUTO RENEWAL SERVICE/i,               category: "auto_renewal",  aipp: true  },
  { test: /AUTO RENEWAL\s*-\s*AMD/i,             category: "auto_renewal",  aipp: true  },
  // SF Classic (historical classification: auto_new)
  { test: /SF CLASSIC NEW BUSINESS/i,            category: "auto_new",      aipp: false },
  // GFA — US Bank deposits (banking referral, not insurance)
  { test: /US BANK NEW DEPOSIT/i,                category: "other",         aipp: false },
];

function classifyLine(desc: string, company: string | null): { category: string; aipp: boolean } {
  // Company-context wins (covers continuation lines like "IPS BROKERAGE
  // ACCOUNTS TRAIL COMMISSIONS" under SFVC that don't carry the SFVC token).
  if (company && COMPANY_CATEGORY[company]) return COMPANY_CATEGORY[company];
  for (const rule of CATEGORY_RULES) if (rule.test.test(desc)) return { category: rule.category, aipp: rule.aipp };
  return { category: "other", aipp: false };
}

// --- Skip patterns ----------------------------------------------------------
const SKIP_RE: RegExp[] = [
  /^1RECAPS/i, /^1\s*STATE FARM INSURANCE/i, /^1\s*ONE STATE FARM/i,
  /^1\s*BLOOMINGTON/i, /^1\s*RECAPITULATION/i, /^1NAME/i, /^1\s*ASSIGNED/i,
  /^1\s*\*\s*\*\s*\*/i,                  // section dividers
  /^1[A-Z\s]+CODE \d{2}-\dBDD\s*$/i,         // state header lines (handled separately)
  /^1COMPANY DESCRIPTION/i,
  /TOTAL\s+\w+\s+\*{4,}/i,                  // "TOTAL MUTL ********" subtotals
  /^1TOTAL\s+\*{4,}/i,                       // grand totals
];

// --- Line extractor ---------------------------------------------------------
// Captures lines with one or two money columns at end of line.
//   "1 AUTO RENEWAL SERVICE .19- 200.12"     → cur=-0.19, ytd=200.12
//   "1MUTL AUTO NEW BUSINESS 1,170.06 ..."   → cur=1170.06
//   "1MUTL AUTO NEW BUSINESS .50-"           → 1 column → YTD only → skip
const LINE_RE = /^1\s*(.+?)\s+([\d,]*\.\d{2}-?)(?:\s+([\d,]*\.\d{2}-?))?\s*$/;

interface ProdLine { description: string; current: number; ytd: number | null }
function parseProductionLine(raw: string): ProdLine | null {
  for (const re of SKIP_RE) if (re.test(raw)) return null;
  const m = raw.match(LINE_RE);
  if (!m) return null;
  if (!m[3]) return null;  // one-number line = YTD only, skip
  const current = parseAmount(m[2]);
  const ytd = parseAmount(m[3]);
  if (current === null || ytd === null) return null;
  return { description: m[1].trim(), current, ytd };
}

// "TCM TCM AUTO NEW BUSINESS" → "TCM AUTO NEW BUSINESS"
// First two whitespace-separated tokens identical → drop one.
function dedupeLeadingWords(desc: string): string {
  const parts = desc.split(/\s+/);
  if (parts.length >= 2 && parts[0] === parts[1]) return parts.slice(1).join(" ");
  return desc;
}

// --- Main parser ------------------------------------------------------------
export function parseCompRecapText(text: string): {
  rows: CompRecapRow[];
  period: PeriodInfo;
  texas_current_total: number;
} {
  const period = parsePeriod(text);
  if (!period) throw new Error("Could not identify period header (FOR <MONTH> X-Y, YYYY) in PDF text.");

  // PDFs include literal "\n" sequences AND real newlines after smart_file_extract.
  const lines = text.split(/\r?\n|\\n/);
  let statePrefix = "";        // empty = Texas default
  let currentCompany: string | null = null;
  let inPaymentSection = false;
  const rows: CompRecapRow[] = [];
  let texasTotal = 0;

  for (const raw of lines) {
    // *** PRODUCTION *** boundary resets state (Texas section has no explicit
    // state header) and clears company context.
    if (/\*\s*P\s*R\s*O\s*D\s*U\s*C\s*T\s*I\s*O\s*N/i.test(raw)) {
      inPaymentSection = false; statePrefix = ""; currentCompany = null; continue;
    }
    if (/\*\s*P\s*A\s*Y\s*M\s*E\s*N\s*T\s+S\s*E\s*C\s*T\s*I\s*O\s*N/i.test(raw)) {
      inPaymentSection = true; currentCompany = null; continue;
    }
    if (/\*\s*I\s*N\s*F\s*O\s*R\s*M\s*A\s*T\s*I\s*O\s*N/i.test(raw)) {
      inPaymentSection = true; currentCompany = null; continue;
    }
    if (inPaymentSection) continue;

    const sp = detectStateHeader(raw);
    if (sp !== null) { statePrefix = sp; currentCompany = null; continue; }

    // Update company context if the line starts a new company section
    const newCo = detectCompany(raw);
    if (newCo) currentCompany = newCo;

    const line = parseProductionLine(raw);
    if (!line) continue;
    if (line.current === 0) continue;

    const desc = dedupeLeadingWords(line.description);
    const description = statePrefix ? `${statePrefix} ${desc}` : desc;
    const { category, aipp } = classifyLine(desc, currentCompany);
    rows.push({
      period_year: period.year,
      period_month: period.month,
      period_day: period.day,
      comp_type: period.comp_type,
      comp_category: category,
      description,
      amount: line.current,
      is_aipp_eligible: aipp,
      is_scorecard_eligible: false,
    });
    if (statePrefix === "") texasTotal += line.current;
  }

  return { rows, period, texas_current_total: texasTotal };
}

// --- DB-writing wrapper -----------------------------------------------------
export async function parseCompRecap(opts: {
  agencyId: string;
  documentId: string;
  statementText: string;
}): Promise<ParseCompRecapResult> {
  let parsed;
  try {
    parsed = parseCompRecapText(opts.statementText);
  } catch (e) {
    return { ok: false, error: `comp_recap parse failed: ${e instanceof Error ? e.message : String(e)}` };
  }
  if (parsed.rows.length === 0) {
    return { ok: false, error: "Parser yielded no rows (PDF malformed or no current-period activity)." };
  }
  // Idempotency: clear any prior rows from this source_document_id, then insert.
  await sb.from("comp_recap").delete().eq("source_document_id", opts.documentId);
  const { error } = await sb.from("comp_recap").insert(
    parsed.rows.map((r) => ({
      agency_id: opts.agencyId,
      period_year: r.period_year,
      period_month: r.period_month,
      period_day: r.period_day,
      comp_type: r.comp_type,
      comp_category: r.comp_category,
      description: r.description,
      amount: r.amount,
      is_aipp_eligible: r.is_aipp_eligible,
      is_scorecard_eligible: r.is_scorecard_eligible,
      source_document_id: opts.documentId,
    })),
  );
  if (error) return { ok: false, error: `comp_recap insert failed: ${error.message}` };

  return { ok: true, rows: parsed.rows, written: parsed.rows.length,
           period: parsed.period, texas_current_total: parsed.texas_current_total };
}
