// =========================================================================
// parsers/production.ts
// =========================================================================
// Parses TWO related document types into the same destination table:
//   - commission_report: per-producer commission summary (monthly)
//   - team_production:   monthly producer × LOB premium issued
// Both feed producer_production, which drives the Performance tab and AIPP
// pace tracking. Detail-only — no GL posts.
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

export interface ProductionRow {
  staff_name: string;     // resolved against staff.name
  period_year: number;
  period_month: number;
  line_of_business: string; // canonical: auto, fire, life, health, bank, annuity, other
  policies_issued: number;
  premium_issued: number;
  notes: string | null;
}

export type ParseProductionResult =
  | { ok: true; rows: ProductionRow[]; written: number; unmatchedStaff: string[] }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT = `
You are a parser for State Farm producer production / commission reports.
Extract every producer × line-of-business × month row.

For each row, return:
  - staff_name (full name, "First Last", as it appears in the document)
  - period_year (integer, 4-digit)
  - period_month (integer 1-12)
  - line_of_business (one of, lowercase exact: "auto", "fire", "life", "health", "bank", "annuity", "other")
  - policies_issued (integer; if not reported, use 0)
  - premium_issued (number; new premium dollars issued)
  - notes (optional 1-line context, or empty string)

Return raw JSON only:
{
  "rows": [
    { "staff_name": "Jane Doe", "period_year": 2026, "period_month": 5,
      "line_of_business": "auto", "policies_issued": 12,
      "premium_issued": 18450.00, "notes": "" }
  ]
}

Rules:
- Skip headers, totals, page footers.
- One row per (producer, line_of_business, month) combo.
- If a producer has multiple LOBs, return multiple rows (do not aggregate).
- Use integer policy counts.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parseProductionReport(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string;
  reportVariant: "commission_report" | "team_production";
  statementText: string;
}): Promise<ParseProductionResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT,
    userContent: `Report variant: ${opts.reportVariant}\n\n${opts.statementText}`,
    documentId: opts.documentId,
    purpose: `parse_${opts.reportVariant}`,
    maxTokens: 6000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const rawRows: any[] = Array.isArray(result.json?.rows) ? result.json.rows : [];
  const rows: ProductionRow[] = [];
  for (const r of rawRows) {
    if (typeof r?.premium_issued !== "number") continue;
    if (typeof r?.period_year !== "number" || typeof r?.period_month !== "number") continue;
    const name = String(r?.staff_name ?? "").trim();
    if (!name) continue;
    rows.push({
      staff_name: name,
      period_year: r.period_year,
      period_month: r.period_month,
      line_of_business: String(r.line_of_business ?? "other").toLowerCase(),
      policies_issued: Number.isFinite(r.policies_issued) ? Math.trunc(r.policies_issued) : 0,
      premium_issued: r.premium_issued,
      notes: r.notes ? String(r.notes).slice(0, 500) : null,
    });
  }

  if (rows.length === 0) {
    return { ok: false, queued: false, error: "LLM returned no parseable rows" };
  }

  // Resolve staff names → staff_id. Producer_production REQUIRES staff_id (NOT NULL).
  // Rows for unmatched producers are skipped and reported back.
  const unmatched: string[] = [];
  const insertRows = [];
  for (const r of rows) {
    const { data: matched } = await sb
      .from("staff")
      .select("id")
      .eq("agency_id", opts.agencyId)
      .ilike("name", r.staff_name)
      .maybeSingle();
    if (!matched?.id) {
      unmatched.push(r.staff_name);
      continue;
    }
    insertRows.push({
      agency_id: opts.agencyId,
      staff_id: matched.id,
      period_year: r.period_year,
      period_month: r.period_month,
      line_of_business: r.line_of_business,
      policies_issued: r.policies_issued,
      premium_issued: r.premium_issued,
      notes: r.notes,
      source_document_id: opts.documentId,
    });
  }

  // Idempotency: delete any existing rows from this source document first
  await sb.from("producer_production").delete().eq("source_document_id", opts.documentId);

  if (insertRows.length > 0) {
    const { error } = await sb.from("producer_production").insert(insertRows);
    if (error) return { ok: false, queued: false, error: `producer_production insert failed: ${error.message}` };
  }

  return { ok: true, rows, written: insertRows.length, unmatchedStaff: unmatched };
}
