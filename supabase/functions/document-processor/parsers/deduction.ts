// =========================================================================
// parsers/deduction.ts
// =========================================================================
// Parses State Farm deduction statements. Deductions are amounts SF withholds
// from comp (E&O, license fees, advertising, etc.). They land in the same
// comp_recap table with NEGATIVE amounts and comp_category="deduction_*".
// Detail-only — no GL posts. GL Entry Writer reconciles separately.
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

export interface DeductionRow {
  period_year: number;
  period_month: number;
  comp_category: string;
  description: string;
  amount: number; // always negative (or zero)
}

export type ParseDeductionResult =
  | { ok: true; rows: DeductionRow[]; written: number }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT = `
You are a parser for State Farm agent deduction statements. These document
amounts that SF withholds from the agent's compensation each period (E&O
insurance, license fees, advertising co-ops, technology fees, etc.).

For each deduction line item, return:
  - period_year (integer, 4-digit)
  - period_month (integer 1-12)
  - comp_category (lowercase, from this list:
      "deduction_eo", "deduction_license", "deduction_advertising",
      "deduction_technology", "deduction_supplies", "deduction_misc")
  - description (1 sentence, verbatim where possible)
  - amount (number, ALWAYS NEGATIVE — these are withholdings)

Return raw JSON only:
{
  "rows": [
    { "period_year": 2026, "period_month": 5,
      "comp_category": "deduction_eo",
      "description": "...", "amount": -45.00 }
  ]
}

Rules:
- Skip headers, summary totals, page footers.
- One row per distinct deduction line.
- Amount is always negative. If the document shows positive numbers, negate them.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parseDeductionStatement(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string;
  statementText: string;
}): Promise<ParseDeductionResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT,
    userContent: opts.statementText,
    documentId: opts.documentId,
    purpose: "parse_deduction_statement",
    maxTokens: 4000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const rawRows: any[] = Array.isArray(result.json?.rows) ? result.json.rows : [];
  const rows: DeductionRow[] = [];
  for (const r of rawRows) {
    if (typeof r?.amount !== "number") continue;
    if (typeof r?.period_year !== "number" || typeof r?.period_month !== "number") continue;
    // Force negative (defensive — LLMs sometimes forget the sign rule)
    const amt = r.amount > 0 ? -r.amount : r.amount;
    rows.push({
      period_year: r.period_year,
      period_month: r.period_month,
      comp_category: String(r.comp_category ?? "deduction_misc").toLowerCase(),
      description: String(r.description ?? "").slice(0, 1000),
      amount: amt,
    });
  }

  if (rows.length === 0) {
    return { ok: false, queued: false, error: "LLM returned no parseable rows" };
  }

  // Idempotency
  await sb.from("comp_recap").delete().eq("source_document_id", opts.documentId);

  const { error } = await sb.from("comp_recap").insert(
    rows.map((r) => ({
      agency_id: opts.agencyId,
      period_year: r.period_year,
      period_month: r.period_month,
      comp_type: "DEDUCTION",
      comp_category: r.comp_category,
      description: r.description,
      amount: r.amount,
      is_aipp_eligible: false,
      is_scoreboard_eligible: false,
      source_document_id: opts.documentId,
    })),
  );
  if (error) return { ok: false, queued: false, error: `comp_recap (deduction) insert failed: ${error.message}` };

  return { ok: true, rows, written: rows.length };
}
