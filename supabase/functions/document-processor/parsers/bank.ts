// =========================================================================
// parsers/bank.ts
// =========================================================================
// Parses bank statement text into a list of normalized transactions ready
// for classification + GL posting. Uses parseWithLLM which falls back to a
// queue if the in-runner LLM call fails.
// =========================================================================

import { parseWithLLM } from "../lib/llm.ts";
import type { BankTxn } from "../classifier.ts";

export interface ParsedBankStatement {
  ok: true;
  statementPeriod: { start: string; end: string };
  accountLast4: string | null;
  openingBalance: number | null;
  closingBalance: number | null;
  transactions: Array<{ date: string; txn: BankTxn }>;
}

export type ParseBankResult =
  | ParsedBankStatement
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT = `
You are a parser for U.S. bank statements. You will be given the text of one
statement covering a single account. Extract the statement period, the
account's last 4 digits, and every transaction in this exact JSON shape — no
prose, no markdown fences, no explanation:

{
  "statement_period": { "start": "YYYY-MM-DD", "end": "YYYY-MM-DD" },
  "account_last4": "<4 digits or null>",
  "opening_balance": <number; the beginning balance for the period, null if not stated>,
  "closing_balance": <number; the ending balance for the period, null if not stated>,
  "transactions": [
    {
      "date": "YYYY-MM-DD",
      "payee": "<vendor / merchant / counterparty>",
      "memo": "<any additional description; empty string if none>",
      "amount": <number; NEGATIVE for money out, POSITIVE for money in>,
      "section": "<one of: purchase, payment, credit_refund, other>",
      "raw_line": "<the verbatim text of this transaction line from the statement, before any parsing>"
    }
  ]
}

Rules:
- Extract the beginning/opening balance and ending/closing balance from the
  account summary section. Credit card statements may call these "Previous
  Balance" and "New Balance". Report both as positive numbers for asset
  accounts; for credit-card statements, report the outstanding balance as
  a positive number (the amount owed).
- Skip beginning balance, ending balance, and "Total" summary lines in the
  transactions array — they belong in opening_balance/closing_balance, not
  as transactions.
- Skip non-transactional informational lines.
- Combine multi-line transaction descriptions into the single payee/memo pair.
- "date" MUST be the TRANSACTION date (the date the purchase/payment actually
  occurred). If the statement prints both a transaction date and a separate
  posting date for a line, use the transaction date — never the posting date.
- "section" classifies which part of the statement this line came from:
  - "purchase" — a charge / purchase / new debit on the account (credit card
    purchases, fees, interest charged).
  - "payment" — a payment made toward the account balance (includes autopay,
    "Payment - Thank You" style lines).
  - "credit_refund" — a merchant refund, rebate, or statement credit issued
    back to the account.
  - "other" — use ONLY when the line genuinely does not fit any of the above;
    do not guess — if uncertain between two categories, prefer "other".
- Combine multi-line transaction descriptions into the single payee/memo pair;
  "raw_line" is a best-effort verbatim capture of the source line(s) for that
  transaction and may include the original date/amount text as printed.
- If the statement prints multiple transaction lines with the SAME date,
  payee, and amount, output one JSON object for EACH printed line. NEVER
  merge, collapse, or deduplicate repeated identical lines — repeated small
  identical charges (game stores, app stores, subscriptions) are real
  separate transactions and every printed line must appear in the output.
- Use ISO dates only.
- All amounts as JSON numbers, never strings.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parseBankStatement(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  sourceAccountCode: string;
  statementText: string;
  documentId: string | null;
}): Promise<ParseBankResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT,
    userContent: opts.statementText,
    documentId: opts.documentId,
    purpose: "parse_bank_statement",
    maxTokens: 8000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const json = result.json;
  const period = json?.statement_period;
  if (!period?.start || !period?.end) {
    return { ok: false, queued: false, error: "LLM response missing statement_period.start or .end" };
  }

  const rawTxns: any[] = Array.isArray(json?.transactions) ? json.transactions : [];
  const transactions: Array<{ date: string; txn: BankTxn }> = [];
  for (const t of rawTxns) {
    if (!t || typeof t.amount !== "number" || !t.date) continue;
    const payee = String(t.payee ?? "").trim();
    if (!payee) continue;
    transactions.push({
      date: String(t.date),
      txn: {
        payee,
        memo: String(t.memo ?? "").trim(),
        signedAmount: t.amount,
        sourceAccountCode: opts.sourceAccountCode,
      },
    });
  }

  const openingBalance = typeof json?.opening_balance === "number" ? json.opening_balance : null;
  const closingBalance = typeof json?.closing_balance === "number" ? json.closing_balance : null;

  return {
    ok: true,
    statementPeriod: { start: period.start, end: period.end },
    accountLast4: json?.account_last4 ?? null,
    openingBalance,
    closingBalance,
    transactions,
  };
}
