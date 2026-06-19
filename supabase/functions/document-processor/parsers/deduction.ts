// =========================================================================
// parsers/deduction.ts (v2 — deterministic regex parser)
// =========================================================================
// Parses State Farm semi-monthly deduction statements into comp_recap rows
// with negative amounts.
//
// REPLACES the prior LLM-based parser (v1, 2026-05). Key bug it fixes:
// the LLM consistently extracted the YEAR-TO-DATE column instead of CURRENT,
// producing 22x overstatement of period deductions.
//
// VERIFIED RECONCILIATIONS:
//   - June 1-15 2026: 3 rows, total -$457.17 (matches comp PDF
//     "LESS DEDUCTIONS 457.17-").
//   - May 16-31 2026: 5 rows, total -$1,286.56 (matches comp PDF
//     "LESS DEDUCTIONS 1,286.56-").
//
// FORMAT REFERENCE (real example):
//   "1 STATEMENTS OF DEDUCTIONS AND ADDITIONS"
//   "1 MAY 31, 2026"                           <- date header
//   "1 CURRENT YEAR TO"
//   "1 AMOUNT DATE"
//   "1 CREDIT UNION 338.03 1,690.15"           <- cur=338.03 → -338.03
//   "1 ADVISORY RENEWAL FEE-AGENT 0.00 15.00"  <- cur=0, skip
//   "1 TOTAL DEDUCTIONS 1,286.56 9,969.74"     <- summary, skip
// =========================================================================

import { sb } from "../lib/supabase.ts";

export interface DeductionRow {
  period_year: number;
  period_month: number;
  period_day: number;
  comp_type: string;
  comp_category: string;
  description: string;
  amount: number;  // always negative
}

export type ParseDeductionResult =
  | { ok: true; rows: DeductionRow[]; written: number; total: number }
  | { ok: false; error: string };

const MONTHS_D: Record<string, number> = {
  JANUARY: 1, FEBRUARY: 2, MARCH: 3, APRIL: 4, MAY: 5, JUNE: 6,
  JULY: 7, AUGUST: 8, SEPTEMBER: 9, OCTOBER: 10, NOVEMBER: 11, DECEMBER: 12,
};

function parseDeductionDate(text: string): { year: number; month: number; day: number; comp_type: "1H" | "2H" } | null {
  const m = text.match(/([A-Z]+)\s+(\d{1,2}),\s*(\d{4})/i);
  if (!m) return null;
  const month = MONTHS_D[m[1].toUpperCase()];
  if (!month) return null;
  const day = parseInt(m[2], 10);
  const year = parseInt(m[3], 10);
  return { year, month, day, comp_type: day <= 15 ? "1H" : "2H" };
}

interface DCatRule { test: RegExp; category: string }
const DEDUCTION_CATEGORIES: DCatRule[] = [
  { test: /ECHO CO-OP|DIRECT MAIL|ADVERTISING/i,                      category: "deduction_advertising" },
  { test: /APPOINTMENT|LICENSE|ADVISORY RENEWAL|FINRA|EXAM FEE/i,     category: "deduction_license"     },
  { test: /AGENT EQUIPMENT|MYSFDOMAIN|TECHNOLOGY|COMPUTER|SOFTWARE/i, category: "deduction_technology"  },
];
function classifyDeduction(desc: string): string {
  for (const r of DEDUCTION_CATEGORIES) if (r.test.test(desc)) return r.category;
  return "deduction_other";
}

function parseAmt(s: string): number | null {
  const cleaned = s.replace(/,/g, "").trim();
  const negative = cleaned.endsWith("-");
  const num = parseFloat(negative ? cleaned.slice(0, -1) : cleaned);
  if (isNaN(num)) return null;
  return negative ? -num : num;
}

const DED_LINE_RE = /^1\s+(.+?)\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$/;
const DED_SKIP: RegExp[] = [
  /^1DEDUCTION/i, /^1\s+STATE FARM/i, /^1\s+SEMI MONTHLY/i,
  /^1\s+STATEMENTS OF/i, /^1\s+STATE \d/i, /^1\s+\dBDD\s/i,
  /^1\s+-+DEDUCTIONS-+/i, /^1\s+THESE AMOUNTS/i,
  /^1\s+CURRENT YEAR/i, /^1\s+AMOUNT DATE/i,
  /^1\s+TOTAL DEDUCTIONS/i,
];

export function parseDeductionText(text: string): {
  rows: DeductionRow[];
  period: { year: number; month: number; day: number; comp_type: "1H" | "2H" };
  current_total: number;
} {
  const period = parseDeductionDate(text);
  if (!period) throw new Error("Could not identify date header in deduction PDF.");
  const lines = text.split(/\r?\n|\\n/);
  const rows: DeductionRow[] = [];
  let total = 0;
  for (const raw of lines) {
    if (DED_SKIP.some((re) => re.test(raw))) continue;
    const m = raw.match(DED_LINE_RE);
    if (!m) continue;
    const description = m[1].trim();
    const current = parseAmt(m[2]);
    if (current === null || current === 0) continue;
    const amount = -Math.abs(current);  // always negative
    rows.push({
      period_year: period.year,
      period_month: period.month,
      period_day: period.day,
      comp_type: period.comp_type,
      comp_category: classifyDeduction(description),
      description,
      amount,
    });
    total += amount;
  }
  return { rows, period, current_total: total };
}

export async function parseDeductionStatement(opts: {
  agencyId: string;
  documentId: string;
  statementText: string;
}): Promise<ParseDeductionResult> {
  let parsed;
  try {
    parsed = parseDeductionText(opts.statementText);
  } catch (e) {
    return { ok: false, error: `deduction parse failed: ${e instanceof Error ? e.message : String(e)}` };
  }
  if (parsed.rows.length === 0) {
    return { ok: false, error: "Parser yielded no rows. Either no current-period deductions or PDF malformed." };
  }
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
      is_aipp_eligible: false,
      is_scorecard_eligible: false,
      source_document_id: opts.documentId,
    })),
  );
  if (error) return { ok: false, error: `comp_recap (deduction) insert failed: ${error.message}` };
  return { ok: true, rows: parsed.rows, written: parsed.rows.length, total: parsed.current_total };
}
