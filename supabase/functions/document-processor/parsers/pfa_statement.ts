// =========================================================================
// parsers/pfa_statement.ts
// =========================================================================
// Frost Bank Premium Fund Account (PFA) statement parser.
//
// Inserts one pfa_bank_statements row per statement PDF, then auto-matches
// each statement line against uncleared pfa_transactions rows:
//   - Match on amount + direction + transaction_type + date (± 5 day window)
//   - For deposits, prefer transaction_number (check#) match if present
// Unmatched lines get NEW pfa_transactions rows inserted (imported_from_excel
// stays false, customer_name = NULL for compliance masking, notes carries the
// statement description). An alert is created listing anything unmatched.
//
// Once ingested, the pfa_monthly_nag alert auto-resolves (see pfa_monthly_nag
// RPC — it looks for a pfa_bank_statements row with statement_period_end
// matching the target month).
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";

interface PfaStatementLine {
  date: string;                         // YYYY-MM-DD
  type: "deposit" | "withdrawal";
  amount: number;                       // always positive
  description: string;
  check_number: string | null;
}

interface ParsedPfaStatement {
  statement_period_start: string;
  statement_period_end: string;
  opening_balance: number;
  closing_balance: number;
  transactions: PfaStatementLine[];
}

export interface PfaStatementProcessResult {
  statementId: string;
  totalLines: number;
  matched: number;
  inserted: number;
  unmatchedLines: PfaStatementLine[];
}

export type PfaStatementResult =
  | { ok: true; result: PfaStatementProcessResult }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT = `
You are a parser for Frost Bank Premium Fund Account (PFA) statements. Extract
the statement period, opening + closing balances, and every transaction line.

Return raw JSON only — no fences, no prose:
{
  "statement_period_start": "YYYY-MM-DD",
  "statement_period_end": "YYYY-MM-DD",
  "opening_balance": <number>,
  "closing_balance": <number>,
  "transactions": [
    {
      "date": "YYYY-MM-DD",
      "type": "deposit" | "withdrawal",
      "amount": <positive number>,
      "description": "<vendor / memo / counterparty>",
      "check_number": "<check number if the description contains one, else null>"
    }
  ]
}

Rules:
- Skip beginning/ending balance summary rows and any "Total" lines.
- Skip page headers, footers, informational marketing text.
- Use ISO dates.
- "deposit" = money into the account (credit). "withdrawal" = money out (debit).
- All amounts as positive numbers; direction is captured in "type".
- If a description contains a check number (e.g. "CHECK 593978" or "#593978"),
  extract the number into check_number (digits only, no # or "check" prefix).
- Combine multi-line transaction descriptions into a single description string.
- Output raw JSON, never wrap in code fences.
`.trim();

// Amount tolerance is EXACT — Frost doesn't round, Newtworks doesn't round.
// Any drift is real signal, not something to hide.
const DATE_WINDOW_DAYS = 5;

function isoDate(d: Date): string { return d.toISOString().slice(0, 10); }
function shiftDate(iso: string, deltaDays: number): string {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return isoDate(d);
}

// Deterministic pick of withdrawal subtype from the statement description.
function classifyWithdrawalType(description: string): string {
  const d = description.toLowerCase();
  if (/state\s*farm|sf\s*ach|preauth/.test(d)) return "State Farm EFT";
  if (/nsf|overdraft/.test(d)) return "NSF/Overdraft Fee";
  if (/service|monthly|maintenance|fee/.test(d)) return "Bank Service Fee";
  if (/return/.test(d)) return "Returned Check";
  return "Misc Withdrawal";
}

export async function processPfaStatement(opts: {
  agencyId: string;
  documentId: string;
  pdfText: string;
  composioApiKey: string;
  composioUserId: string;
}): Promise<PfaStatementResult> {
  // 1) LLM parse
  const llmResult = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT,
    userContent: opts.pdfText,
    documentId: opts.documentId,
    purpose: "parse_pfa_statement",
    maxTokens: 6000,
  });
  if (!llmResult.ok) {
    if (llmResult.queued) return { ok: false, queued: true, queueId: llmResult.queueId };
    return { ok: false, queued: false, error: llmResult.error };
  }
  const parsed = llmResult.json as ParsedPfaStatement;
  if (!parsed?.statement_period_start || !parsed?.statement_period_end) {
    return { ok: false, queued: false, error: "LLM output missing statement period" };
  }
  if (typeof parsed.opening_balance !== "number" || typeof parsed.closing_balance !== "number") {
    return { ok: false, queued: false, error: "LLM output missing opening/closing balance" };
  }

  // 2) Resolve PFA account
  const { data: pfaAccount, error: acctErr } = await sb
    .from("pfa_accounts")
    .select("id")
    .eq("agency_id", opts.agencyId)
    .eq("is_active", true)
    .maybeSingle();
  if (acctErr || !pfaAccount?.id) {
    return { ok: false, queued: false, error: "No active PFA account for agency" };
  }
  const pfaAccountId = pfaAccount.id as string;

  const txns: PfaStatementLine[] = Array.isArray(parsed.transactions) ? parsed.transactions : [];

  // 3) Idempotency: if a statement already exists for this period, wipe the
  //    downstream state so re-processing is safe.
  const { data: existingStmt } = await sb
    .from("pfa_bank_statements")
    .select("id")
    .eq("pfa_account_id", pfaAccountId)
    .eq("statement_period_end", parsed.statement_period_end)
    .maybeSingle();
  if (existingStmt?.id) {
    // Un-clear anything cleared inside this period
    await sb
      .from("pfa_transactions")
      .update({ cleared: false, cleared_date: null })
      .eq("pfa_account_id", pfaAccountId)
      .gte("cleared_date", parsed.statement_period_start)
      .lte("cleared_date", parsed.statement_period_end);
    // Delete any auto-imported rows tied to that previous statement
    await sb
      .from("pfa_transactions")
      .delete()
      .eq("pfa_account_id", pfaAccountId)
      .like("notes", `Imported from statement ${existingStmt.id}%`);
    // Delete the statement row itself
    await sb.from("pfa_bank_statements").delete().eq("id", existingStmt.id);
  }

  // 4) Insert the statement header
  const deposits = txns.filter(t => t.type === "deposit");
  const withdrawals = txns.filter(t => t.type === "withdrawal");
  const depositTotal = deposits.reduce((s, t) => s + t.amount, 0);
  const withdrawalTotal = withdrawals.reduce((s, t) => s + t.amount, 0);

  const { data: stmtRow, error: stmtErr } = await sb
    .from("pfa_bank_statements")
    .insert({
      pfa_account_id: pfaAccountId,
      statement_period_start: parsed.statement_period_start,
      statement_period_end: parsed.statement_period_end,
      opening_balance: parsed.opening_balance,
      closing_balance: parsed.closing_balance,
      deposit_count: deposits.length,
      deposit_total: depositTotal,
      withdrawal_count: withdrawals.length,
      withdrawal_total: withdrawalTotal,
      source_document_id: opts.documentId,
      imported_at: new Date().toISOString(),
    })
    .select("id")
    .single();
  if (stmtErr || !stmtRow?.id) {
    return { ok: false, queued: false, error: `pfa_bank_statements insert failed: ${stmtErr?.message}` };
  }
  const statementId = stmtRow.id as string;

  // 5) Match each statement line to an uncleared pfa_transactions row.
  //    Exact amount match; date window ± DATE_WINDOW_DAYS around the statement line date.
  let matched = 0;
  let inserted = 0;
  const unmatchedLines: PfaStatementLine[] = [];

  const depositTypes = ["Deposit", "Personal Deposit", "Other Credit"];
  const withdrawalTypes = ["State Farm EFT", "Bank Service Fee", "Personal Deposit", "Returned Check", "NSF/Overdraft Fee", "Misc Withdrawal", "Other Credit"];

  for (const line of txns) {
    const isDeposit = line.type === "deposit";
    const dateMin = shiftDate(line.date, -DATE_WINDOW_DAYS);
    const dateMax = shiftDate(line.date, +DATE_WINDOW_DAYS);
    const amountCol = isDeposit ? "credit_amount" : "debit_amount";
    const typesToTry = isDeposit ? depositTypes : withdrawalTypes;

    let matchedRowId: string | null = null;

    // Attempt A: deposit with check number → check-number-first match
    if (isDeposit && line.check_number) {
      const { data: hit } = await sb
        .from("pfa_transactions")
        .select("id")
        .eq("pfa_account_id", pfaAccountId)
        .eq("cleared", false)
        .is("voided_at", null)
        .eq("transaction_type", "Deposit")
        .eq(amountCol, line.amount)
        .eq("transaction_number", line.check_number)
        .gte("transaction_date", dateMin)
        .lte("transaction_date", dateMax)
        .order("transaction_date", { ascending: true })
        .limit(1);
      if (hit && hit.length > 0) matchedRowId = hit[0].id;
    }

    // Attempt B: amount + type + date window
    if (!matchedRowId) {
      const { data: hit } = await sb
        .from("pfa_transactions")
        .select("id")
        .eq("pfa_account_id", pfaAccountId)
        .eq("cleared", false)
        .is("voided_at", null)
        .in("transaction_type", typesToTry)
        .eq(amountCol, line.amount)
        .gte("transaction_date", dateMin)
        .lte("transaction_date", dateMax)
        .order("transaction_date", { ascending: true })
        .limit(1);
      if (hit && hit.length > 0) matchedRowId = hit[0].id;
    }

    if (matchedRowId) {
      const { error: updErr } = await sb
        .from("pfa_transactions")
        .update({ cleared: true, cleared_date: line.date })
        .eq("id", matchedRowId);
      if (!updErr) { matched++; continue; }
    }

    // Attempt C: no match — insert a new row (unattributed) so recon can balance
    const insertRow: Record<string, unknown> = {
      pfa_account_id: pfaAccountId,
      transaction_date: line.date,
      transaction_number: line.check_number ?? null,
      cleared: true,
      cleared_date: line.date,
      customer_name: null,   // constraint requires masked format if non-null
      policy_type: null,
      imported_from_excel: false,
      notes: `Imported from statement ${statementId}: ${line.description}`.slice(0, 500),
    };
    if (isDeposit) {
      insertRow.transaction_type = "Deposit";
      insertRow.credit_amount = line.amount;
      insertRow.debit_amount = null;
    } else {
      insertRow.transaction_type = classifyWithdrawalType(line.description);
      insertRow.debit_amount = line.amount;
      insertRow.credit_amount = null;
    }
    const { error: insErr } = await sb.from("pfa_transactions").insert(insertRow);
    if (insErr) {
      // Log but keep going — one bad line shouldn't kill the whole ingest.
      console.error(`pfa_statement unmatched insert failed for line ${JSON.stringify(line)}: ${insErr.message}`);
      continue;
    }
    inserted++;
    unmatchedLines.push(line);
  }

  // 6) Alert if anything was unmatched
  if (unmatchedLines.length > 0) {
    const previewLines = unmatchedLines.slice(0, 8).map(l =>
      `- $${l.amount.toFixed(2)} ${l.type} on ${l.date}` +
      (l.check_number ? ` #${l.check_number}` : "") +
      `: ${l.description.slice(0, 60)}`
    ).join("\n");
    const overflow = unmatchedLines.length > 8 ? `\n... and ${unmatchedLines.length - 8} more` : "";
    await sb.from("alerts").insert({
      agency_id: opts.agencyId,
      alert_type: "pfa_statement_unmatched",
      severity: "warning",
      title: `PFA statement ${parsed.statement_period_end}: ${unmatchedLines.length} unmatched line${unmatchedLines.length === 1 ? "" : "s"}`,
      message: `The Frost PFA statement for period ending ${parsed.statement_period_end} had ${unmatchedLines.length} transaction line(s) that couldn't be matched to existing pfa_transactions rows. New rows were auto-inserted (customer name null) so the reconciliation can balance — but you should review them in Deposits → Ledger and confirm they're right.\n\nFirst few:\n${previewLines}${overflow}`,
      module_reference: `pfa_statement_unmatched:${statementId}`,
      is_read: false,
      is_resolved: false,
      created_at: new Date().toISOString(),
    });
  }

  return {
    ok: true,
    result: {
      statementId,
      totalLines: txns.length,
      matched,
      inserted,
      unmatchedLines,
    },
  };
}
