// =========================================================================
// parsers/production.ts
// =========================================================================
// Parses TWO related document types into the same destination table:
//   - commission_report: per-producer commission summary (monthly)
//   - team_production:   monthly producer × LOB premium issued
// Both feed producer_production, which drives the Performance tab and AIPP
// pace tracking. Detail-only — no GL posts.
//
// GRAIN: one row per (staff_id, period_year, period_month, line_of_business),
// enforced by a UNIQUE constraint. This table tracks NEW production issued
// (premium_type is always "new"); renewal premium is modeled downstream via
// the lapse rate, not stored here. Do not split new/renewal into separate
// rows — that would violate the unique constraint.
//
// AIPP qualification is derived in code, never trusted to the LLM:
//   is_aipp_qualifying = LOB in (auto, fire)   [new P&C]
// (AIPP = 5% of qualifying NEW P&C production.)
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

const CANONICAL_LOB = ["auto", "fire", "life", "health", "bank", "annuity", "other"] as const;
type Lob = (typeof CANONICAL_LOB)[number];
const AIPP_QUALIFYING_LOB = new Set<Lob>(["auto", "fire"]);

export interface ProductionRow {
  staff_name: string;        // as it appears in the document
  period_year: number;
  period_month: number;
  line_of_business: Lob;
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
  - staff_name (full name as it appears in the document; keep the document's spelling)
  - period_year (integer, 4-digit)
  - period_month (integer 1-12)
  - line_of_business (one of, lowercase exact: "auto", "fire", "life", "health", "bank", "annuity", "other")
  - policies_issued (integer; if not reported, use 0)
  - premium_issued (number; NEW premium dollars issued for this row)
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
- Extract NEW production only. Ignore renewal / in-force premium columns.
- Skip headers, totals, page footers, and any "agency total" / "office total" rows.
- One row per (producer, line_of_business, month) combo.
- If a producer has multiple LOBs, return multiple rows (do not aggregate).
- Use integer policy counts.
- Output raw JSON, never wrap it in code fences.
`.trim();

function canonicalLob(raw: unknown): Lob {
  const v = String(raw ?? "").trim().toLowerCase();
  if ((CANONICAL_LOB as readonly string[]).includes(v)) return v as Lob;
  // common aliases
  if (["p&c", "pc", "property", "homeowners", "home", "renters"].includes(v)) return "fire";
  if (["vehicle", "car", "automobile"].includes(v)) return "auto";
  return "other";
}

// Build a normalized name → staff_id index for the agency's active staff.
// Handles "First Last", "Last, First", case, and extra whitespace.
function normName(s: string): string {
  return s.toLowerCase().replace(/[.,]/g, " ").replace(/\s+/g, " ").trim();
}

async function buildStaffIndex(agencyId: string): Promise<Map<string, string>> {
  const { data, error } = await sb
    .from("staff")
    .select("id, first_name, last_name")
    .eq("agency_id", agencyId)
    .eq("is_active", true);
  if (error) throw new Error(`staff lookup failed: ${error.message}`);

  const idx = new Map<string, string>();
  for (const s of data ?? []) {
    const first = String(s.first_name ?? "").trim();
    const last = String(s.last_name ?? "").trim();
    if (!s.id) continue;
    const keys = [
      `${first} ${last}`,   // First Last
      `${last} ${first}`,   // Last First  (covers "Last, First" after normalization)
      `${last}`,            // surname-only fallback (last resort)
    ];
    for (const k of keys) {
      const nk = normName(k);
      if (nk && !idx.has(nk)) idx.set(nk, s.id as string);
    }
  }
  return idx;
}

function resolveStaffId(idx: Map<string, string>, docName: string): string | null {
  const n = normName(docName);
  if (idx.has(n)) return idx.get(n)!;
  // try reversed token order (handles "Last First" vs "First Last")
  const parts = n.split(" ");
  if (parts.length >= 2) {
    const rev = normName(parts.slice().reverse().join(" "));
    if (idx.has(rev)) return idx.get(rev)!;
    // first + last only, dropping any middle token
    const fl = normName(`${parts[0]} ${parts[parts.length - 1]}`);
    if (idx.has(fl)) return idx.get(fl)!;
  }
  return null;
}

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
    const year = Math.trunc(r.period_year);
    const month = Math.trunc(r.period_month);
    if (year < 2000 || year > 2100) continue;
    if (month < 1 || month > 12) continue;
    const name = String(r?.staff_name ?? "").trim();
    if (!name) continue;
    rows.push({
      staff_name: name,
      period_year: year,
      period_month: month,
      line_of_business: canonicalLob(r.line_of_business),
      policies_issued: Number.isFinite(r.policies_issued) ? Math.trunc(r.policies_issued) : 0,
      premium_issued: r.premium_issued,
      notes: r.notes ? String(r.notes).slice(0, 500) : null,
    });
  }

  if (rows.length === 0) {
    return { ok: false, queued: false, error: "LLM returned no parseable rows" };
  }

  // Resolve staff names → staff_id. producer_production REQUIRES staff_id (NOT NULL).
  // Rows for unmatched producers are skipped and reported back.
  const staffIdx = await buildStaffIndex(opts.agencyId);
  const unmatched: string[] = [];
  const insertRows = [];
  for (const r of rows) {
    const staffId = resolveStaffId(staffIdx, r.staff_name);
    if (!staffId) {
      if (!unmatched.includes(r.staff_name)) unmatched.push(r.staff_name);
      continue;
    }
    const isAipp = AIPP_QUALIFYING_LOB.has(r.line_of_business);
    insertRows.push({
      agency_id: opts.agencyId,
      staff_id: staffId,
      period_year: r.period_year,
      period_month: r.period_month,
      line_of_business: r.line_of_business,
      policies_issued: r.policies_issued,
      premium_issued: r.premium_issued,
      premium_type: "new",
      is_aipp_qualifying: isAipp,
      source: "auto_parsed",
      notes: r.notes,
      source_document_id: opts.documentId,
    });
  }

  // Idempotency:
  //  - delete prior rows from THIS source document (handles row removal on re-parse)
  //  - upsert on the unique business key so a corrected report from a DIFFERENT
  //    document updates the existing producer/month/LOB row instead of erroring
  await sb.from("producer_production").delete().eq("source_document_id", opts.documentId);

  if (insertRows.length > 0) {
    const { error } = await sb
      .from("producer_production")
      .upsert(insertRows, {
        onConflict: "agency_id,staff_id,period_year,period_month,line_of_business",
      });
    if (error) return { ok: false, queued: false, error: `producer_production upsert failed: ${error.message}` };
  }

  return { ok: true, rows, written: insertRows.length, unmatchedStaff: unmatched };
}
