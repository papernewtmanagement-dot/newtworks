// =========================================================================
// parsers/comp_recap.ts
// =========================================================================
// Parses a State Farm comp recap (1H or Daily variant) into structured
// comp_recap rows. Detail-only — no GL posts. The GL Entry Writer reconciles
// comp_recap → journal_entries separately.
//
// Both 1H and Daily share the same destination shape (period_year,
// period_month, comp_type, comp_category, description, amount,
// is_aipp_eligible, is_scoreboard_eligible). The recap_variant arg is
// passed to the LLM purely for context.
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

export interface CompRecapRow {
  period_year: number;
  period_month: number;
  comp_type: string;
  comp_category: string;
  description: string;
  amount: number;
  is_aipp_eligible: boolean;
  is_scoreboard_eligible: boolean;
}

export type ParseCompRecapResult =
  | { ok: true; rows: CompRecapRow[]; written: number }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT = `
You are a parser for State Farm agent compensation recap documents.
You will be given the text of one recap (either a 1H hourly recap or a
daily/monthly recap). Extract every distinct line item.

For each line item, return:
  - period_year (integer, 4-digit, e.g. 2026)
  - period_month (integer 1-12)
  - comp_type (one of: "1H", "DAILY", "MONTHLY" — based on the document's frequency)
  - comp_category (best-fit category from this list, lowercase exact match:
      "auto_new", "auto_renewal", "fire_new", "fire_renewal",
      "life_new", "life_renewal", "health_new", "health_renewal",
      "bank_new", "annuity_new", "scoreboard_bonus", "aipp_payment",
      "service_compensation", "validation", "other")
  - description (1 sentence, verbatim from the document where possible)
  - amount (number, can be negative for adjustments)
  - is_aipp_eligible (boolean — true for new P&C lines, false otherwise)
  - is_scoreboard_eligible (boolean — true for auto/fire/L&H new business)

Return raw JSON in this exact shape — no fences, no prose:
{
  "rows": [
    { "period_year": 2026, "period_month": 5, "comp_type": "DAILY",
      "comp_category": "auto_new", "description": "...",
      "amount": 123.45, "is_aipp_eligible": true,
      "is_scoreboard_eligible": true }
  ]
}

Rules:
- Skip header/footer text, page numbers, summary totals.
- One row per distinct comp line item.
- If you can't determine eligibility, default both flags to false.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parseCompRecap(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string;
  recapVariant: "1H" | "DAILY";
  statementText: string;
}): Promise<ParseCompRecapResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT,
    userContent: `Recap variant: ${opts.recapVariant}\n\n${opts.statementText}`,
    documentId: opts.documentId,
    purpose: "parse_comp_recap",
    maxTokens: 6000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const rawRows: any[] = Array.isArray(result.json?.rows) ? result.json.rows : [];
  const rows: CompRecapRow[] = [];
  for (const r of rawRows) {
    if (typeof r?.amount !== "number") continue;
    if (typeof r?.period_year !== "number" || typeof r?.period_month !== "number") continue;
    rows.push({
      period_year: r.period_year,
      period_month: r.period_month,
      comp_type: String(r.comp_type ?? opts.recapVariant).toUpperCase(),
      comp_category: String(r.comp_category ?? "other").toLowerCase(),
      description: String(r.description ?? "").slice(0, 1000),
      amount: r.amount,
      is_aipp_eligible: !!r.is_aipp_eligible,
      is_scoreboard_eligible: !!r.is_scoreboard_eligible,
    });
  }

  if (rows.length === 0) {
    return { ok: false, queued: false, error: "LLM returned no parseable rows" };
  }

  // Idempotency: delete any existing rows for this source_document_id first,
  // then insert fresh. Allows safe re-runs without duplicating.
  await sb.from("comp_recap").delete().eq("source_document_id", opts.documentId);

  const { error } = await sb.from("comp_recap").insert(
    rows.map((r) => ({
      agency_id: opts.agencyId,
      period_year: r.period_year,
      period_month: r.period_month,
      comp_type: r.comp_type,
      comp_category: r.comp_category,
      description: r.description,
      amount: r.amount,
      is_aipp_eligible: r.is_aipp_eligible,
      is_scoreboard_eligible: r.is_scoreboard_eligible,
      source_document_id: opts.documentId,
    })),
  );
  if (error) return { ok: false, queued: false, error: `comp_recap insert failed: ${error.message}` };

  return { ok: true, rows, written: rows.length };
}
