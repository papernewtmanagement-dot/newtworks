// =========================================================================
// parsers/payroll.ts
// =========================================================================
// Parses ADP / Gusto / WorkforceNow payroll run notifications. Inserts one
// payroll_runs row and one payroll_detail row per employee.
//
// Detail-only — no GL posts. GL Entry Writer reconciles payroll separately.
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

export interface PayrollDetailRow {
  staff_name: string;       // used to resolve team_member_id via team table
  gross_pay: number;
  federal_tax: number;
  state_tax: number;
  social_security: number;
  medicare: number;
  other_deductions: number;
  net_pay: number;
  employment_type: string;  // "W2" | "1099" | "OWNER"
}

export interface PayrollRunHeader {
  pay_period_start: string; // YYYY-MM-DD
  pay_period_end: string;
  pay_date: string;
  payroll_provider: string; // ADP | Gusto | etc.
  gross_payroll: number;
  employer_taxes: number;
  net_payroll: number;
}

export type ParsePayrollResult =
  | { ok: true; run: PayrollRunHeader; detailCount: number }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT = `
You are a parser for U.S. payroll provider documents (ADP, Gusto,
WorkforceNow). You will be given the text of one payroll run document.
Extract the run-level header AND every employee detail line.

Return raw JSON in this exact shape — no fences, no prose:
{
  "run": {
    "pay_period_start": "YYYY-MM-DD",
    "pay_period_end": "YYYY-MM-DD",
    "pay_date": "YYYY-MM-DD",
    "payroll_provider": "ADP" | "Gusto" | "WorkforceNow" | "Other",
    "gross_payroll": <number>,
    "employer_taxes": <number>,
    "net_payroll": <number>
  },
  "details": [
    {
      "staff_name": "<First Last>",
      "gross_pay": <number>,
      "federal_tax": <number>,
      "state_tax": <number>,
      "social_security": <number>,
      "medicare": <number>,
      "other_deductions": <number>,
      "net_pay": <number>,
      "employment_type": "W2" | "1099" | "OWNER"
    }
  ]
}

Rules:
- Use ISO dates.
- All amounts positive (positive taxes mean the amount withheld).
- If a field is unclear, use 0.
- One detail row per employee, even if they got multiple line items in the document.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parsePayrollRun(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string;
  statementText: string;
}): Promise<ParsePayrollResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT,
    userContent: opts.statementText,
    documentId: opts.documentId,
    purpose: "parse_payroll_run",
    maxTokens: 6000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const run = result.json?.run;
  if (!run?.pay_period_start || !run?.pay_period_end || !run?.pay_date) {
    return { ok: false, queued: false, error: "payroll header missing required dates" };
  }

  const rawDetails: any[] = Array.isArray(result.json?.details) ? result.json.details : [];

  // Idempotency: drop any prior run AND its details for this source_document_id
  const { data: priorRuns } = await sb
    .from("payroll_runs")
    .select("id")
    .eq("source_document_id", opts.documentId);
  if (priorRuns && priorRuns.length > 0) {
    const priorIds = priorRuns.map((r: any) => r.id);
    await sb.from("payroll_detail").delete().in("payroll_run_id", priorIds);
    await sb.from("payroll_runs").delete().in("id", priorIds);
  }

  const { data: runRow, error: runErr } = await sb
    .from("payroll_runs")
    .insert({
      agency_id: opts.agencyId,
      pay_period_start: run.pay_period_start,
      pay_period_end: run.pay_period_end,
      pay_date: run.pay_date,
      payroll_provider: run.payroll_provider ?? "Unknown",
      gross_payroll: run.gross_payroll ?? 0,
      employer_taxes: run.employer_taxes ?? 0,
      net_payroll: run.net_payroll ?? 0,
      status: "imported",
      source_document_id: opts.documentId,
    })
    .select("id")
    .single();
  if (runErr || !runRow) return { ok: false, queued: false, error: `payroll_runs insert failed: ${runErr?.message ?? "unknown"}` };

  // Resolve staff names → team_member_id (best-effort, null if no match)
  const detailRows = [];
  for (const d of rawDetails) {
    const staffName = String(d?.staff_name ?? "").trim();
    if (!staffName) continue;
    let staffId: string | null = null;
    const { data: matchedStaff } = await sb
      .from("team")
      .select("id")
      .eq("agency_id", opts.agencyId)
      .ilike("name", staffName)
      .maybeSingle();
    staffId = matchedStaff?.id ?? null;

    detailRows.push({
      payroll_run_id: runRow.id,
      agency_id: opts.agencyId,
      team_member_id: staffId,
      gross_pay: Number(d?.gross_pay ?? 0),
      federal_tax: Number(d?.federal_tax ?? 0),
      state_tax: Number(d?.state_tax ?? 0),
      social_security: Number(d?.social_security ?? 0),
      medicare: Number(d?.medicare ?? 0),
      other_deductions: Number(d?.other_deductions ?? 0),
      net_pay: Number(d?.net_pay ?? 0),
      employment_type: String(d?.employment_type ?? "W2").toUpperCase(),
    });
  }

  if (detailRows.length > 0) {
    const { error: detErr } = await sb.from("payroll_detail").insert(detailRows);
    if (detErr) return { ok: false, queued: false, error: `payroll_detail insert failed: ${detErr.message}` };
  }

  return {
    ok: true,
    run: {
      pay_period_start: run.pay_period_start,
      pay_period_end: run.pay_period_end,
      pay_date: run.pay_date,
      payroll_provider: run.payroll_provider ?? "Unknown",
      gross_payroll: Number(run.gross_payroll ?? 0),
      employer_taxes: Number(run.employer_taxes ?? 0),
      net_payroll: Number(run.net_payroll ?? 0),
    },
    detailCount: detailRows.length,
  };
}
