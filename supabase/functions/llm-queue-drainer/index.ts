// llm-queue-drainer edge function
//
// Purpose: Drains pending items in public.llm_parse_queue that document-processor
// couldn't complete synchronously (transient Groq failures, JSON parse issues,
// max_tokens truncations, daily TPD exhaustion).
//
// Supported purposes:
//   - parse_bank_statement         → drainBankStatementItem  (statement_balances + statements)
//   - careerplug_applicant_extract → drainCareerplugItem     (hiring_candidates via upsert RPC)
//   - wrapup_organize              → drainWrapupOrganizeItem (weekly_cpr_team_detail.wrapup_text/_done via target_ref)
//
// Flow per item:
//   1. Call Groq direct with stored system_prompt + user_content
//   2. Parse JSON per purpose-specific shape
//   3. Purpose-specific write path
//   4. Mark queue item succeeded (or bump attempts on failure; 429 = don't burn)
//
// Invocation: POST { agency_id, shared_secret, [max_items=10, dry_run=false] }

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, jsonResponse, getSettingOrNull, stripFences } from "../_shared/supabase.ts";
import { callGroqChat } from "../_shared/llm.ts";
import { requireSharedSecret } from "../_shared/auth.ts";
import { writeParsedStatement } from "../_shared/statement_writer.ts";
import { insertAlert } from "../_shared/alerts.ts";

// llama-3.3-70b-versatile (12,000 TPM) is decommissioned by Groq 2026-08-16.
// Moved to openai/gpt-oss-120b (8,000 TPM) 2026-08-08 — less throughput, but
// the only realistic account-tier model that survives the deadline; the
// account-wide plain-model TPM ceiling is 8,000 regardless of which model is
// picked (verified live against every candidate). Large statements that
// still exceed 8,000 tokens are a known, tracked gap (see finance-rebuild
// Groq-cap blocker) — never silently plugged or hand-entered.
const BANK_STATEMENT_MODEL = "openai/gpt-oss-120b";
// Careerplug items are small (~1-2K tokens) but gpt-oss-120b is often the daily-cap
// victim (200K TPD). Draining on a different model spreads TPD load so we can drain
// backlog even when gpt-oss-120b is exhausted. Was llama-3.3-70b-versatile
// (decommissioned 2026-08-16) — no other account-tier model beats gpt-oss-120b's
// TPD headroom for this purpose, so this constant is now the same model as the
// default; kept as a separate constant for the TPD-spreading intent, not because
// it currently differs.
const CAREERPLUG_MODEL = "openai/gpt-oss-120b";
// Wrap-up organize items are small (~1-3K tokens). They queue on Friday
// afternoons, which is precisely when the whole team sends wrap-ups within the
// same hour and gpt-oss-120b is most likely to be over quota -- so drain on a
// different model for the same TPD-spreading reason as careerplug. Was
// llama-3.3-70b-versatile (decommissioned 2026-08-16); same note as above.
const WRAPUP_MODEL = "openai/gpt-oss-120b";

// Purposes this drainer currently handles. Adding a new purpose = adding a
// handler function below AND appending its key here.
const SUPPORTED_PURPOSES = ["parse_bank_statement", "careerplug_applicant_extract", "wrapup_organize"];

// Thin adapter over the shared Groq caller so the drain call sites keep their
// positional signature. temperature 0.1 preserved from the original inline copy.
// The org's Groq tier caps EVERY request (prompt + completion together) at a
// fixed token budget — currently 8000 for openai/gpt-oss-120b. A hardcoded
// maxTokens blows that ceiling the moment prompt tokens alone get close to
// it (seen live: a 13.7K-char bank statement + system prompt = ~4.2K prompt
// tokens, then maxTokens:8000 requested 11.3K total -> HTTP 413). Size the
// completion budget to what's actually left after the prompt, every call.
const GROQ_REQUEST_TOKEN_CAP = 8000;
const GROQ_SAFETY_MARGIN = 300; // token-estimate is a 4-chars/token approximation, not exact

function fitMaxTokens(systemPrompt: string, userContent: string, ceiling: number, floor: number): number {
  const promptTokensEst = Math.ceil((systemPrompt.length + userContent.length) / 4);
  const available = GROQ_REQUEST_TOKEN_CAP - promptTokensEst - GROQ_SAFETY_MARGIN;
  return Math.max(floor, Math.min(ceiling, available));
}

// Compact statement prompt used by drainBankStatementItem. See the long note at
// its call site for why this exists instead of the queued JSON prompt.
const BANK_STATEMENT_PROMPT_COMPACT = `You are a parser for U.S. bank and credit card statements. You will be given the
text of one statement covering a single account.

Output PLAIN TEXT LINES ONLY. No JSON, no prose, no markdown, no code fences.
Emit exactly these line types, pipe-delimited, in this order:

PERIOD|<start YYYY-MM-DD>|<end YYYY-MM-DD>
LAST4|<last 4 digits of the account, or NULL>
OPEN|<opening/beginning/previous balance as a number, or NULL>
CLOSE|<closing/ending/new balance as a number, or NULL>
TXN|<YYYY-MM-DD>|<KIND>|<payee>|<memo>|<amount>
TXN|<YYYY-MM-DD>|<KIND>|<payee>|<memo>|<amount>
...one TXN line per transaction...

KIND is exactly one letter classifying which part of the statement the line came
from. Decide this BEFORE you decide the sign — it is what keeps the sign right:
  P = purchase / charge / fee / interest charged   -> amount NEGATIVE
  Y = payment made toward the account balance      -> amount POSITIVE
  C = merchant refund, return, rebate, or credit   -> amount POSITIVE
  O = none of the above (use only if genuinely unclear)

SECTIONS ARE THE AUTHORITY ON KIND. Statements are organised under headings such
as "Payments", "Credits", "New Charges", "Purchases", "Fees", "Interest Charged".
Track which heading you are underneath as you read down, and take KIND from that
heading — NEVER from the merchant name. Every line after a heading belongs to it
until the next heading appears.

This is the single most common way this task is got wrong: a refund from a
merchant you also buy from looks exactly like a purchase. An AMAZON.COM line
sitting under "Credits" is C, even though AMAZON.COM lines under "New Charges"
are P. Same merchant, same wording, opposite sign — the heading decides. Before
you emit a line, ask which heading it is under and let that set KIND.

Rules:
- Emit PERIOD, LAST4, OPEN and CLOSE exactly once each, before any TXN line.
- Balances come from the account summary section. Credit card statements may
  call them "Previous Balance" and "New Balance". Report a credit card's
  outstanding balance as a POSITIVE number (the amount owed).
- CHECKSUM. Many statements print a "Payments and Credits Summary" giving a
  "Total Payments and Credits" figure, and often a per-cardmember breakdown. The
  magnitudes of all your Y and C lines must add up to that total. If they fall
  short, you have left a credit in the purchases — the usual culprit is a group
  of lines under "Credits" from a merchant that also appears under charges.
  A per-cardmember credit subtotal is a SUMMARY figure: use it to check your
  work, never emit it as its own TXN line.
- SELF-CHECK before you output, and fix signs if it fails: for a credit card,
  OPEN + (sum of all P amounts, as positive magnitudes) - (sum of all Y and C
  amounts, as positive magnitudes) must equal CLOSE. For a bank account,
  OPEN + (sum of every amount, with its sign) must equal CLOSE. If it does not
  tie, you have mis-signed or missed a line — re-read and correct it.
- amount: NEGATIVE for money out, POSITIVE for money in, per KIND above.
- date MUST be the TRANSACTION date — the date the purchase or payment actually
  occurred. If a line prints both a transaction date and a separate posting
  date, use the transaction date, never the posting date.
- Skip beginning-balance, ending-balance and "Total" summary lines. They belong
  in OPEN/CLOSE, not as TXN lines. Skip non-transactional informational lines.
- Combine a multi-line transaction description into the single payee/memo pair.
- If the statement prints its own notation for what kind of line this is
  (for example "CR MERCHANDISE/SERVICE RETURN", "CASH BACK REWARD", "AUTOPAY",
  "RETURNED PAYMENT"), APPEND that exact notation to memo. Never drop it — it is
  the bank's own explanation of why a line is a credit, and losing it forces
  someone to re-open the PDF later.
- If memo would be empty, leave it empty: TXN|2026-07-04|P|COSTCO||-84.12
- Never put a "|" character inside payee or memo. Replace any with a space.
- If the statement prints multiple lines with the SAME date, payee and amount,
  emit one TXN line for EACH printed line. NEVER merge, collapse or deduplicate
  repeated identical lines — repeated small identical charges (game stores, app
  stores, subscriptions) are real separate transactions and every printed line
  must appear in the output.
- ISO dates only. Amounts as bare numbers: no currency symbols, no thousands
  separators, no parentheses. Use a leading minus for money out.`;

// Parses the compact line format above into the same shape the rest of
// drainBankStatementItem already expects, so nothing downstream changes.
// Returns null when no transactions were recovered.
function parseCompactStatement(raw: string): {
  statement_period: { start: string; end: string } | null;
  account_last4: string | null;
  opening_balance: number | null;
  closing_balance: number | null;
  transactions: { date: string; payee: string; memo: string; amount: number }[];
} | null {
  const num = (s: string): number | null => {
    const t = (s ?? "").trim();
    if (!t || t.toUpperCase() === "NULL") return null;
    const v = Number(t.replace(/[$,]/g, ""));
    return Number.isFinite(v) ? v : null;
  };

  let period: { start: string; end: string } | null = null;
  let last4: string | null = null;
  let open: number | null = null;
  let close: number | null = null;
  const txns: { date: string; payee: string; memo: string; amount: number }[] = [];

  for (const line of stripFences(raw).split("\n")) {
    const t = line.trim();
    if (!t) continue;
    const parts = t.split("|");
    const tag = (parts[0] ?? "").trim().toUpperCase();

    if (tag === "PERIOD" && parts.length >= 3) {
      const s = parts[1].trim(), e = parts[2].trim();
      if (s && e && s.toUpperCase() !== "NULL" && e.toUpperCase() !== "NULL") period = { start: s, end: e };
    } else if (tag === "LAST4" && parts.length >= 2) {
      const v = parts[1].trim();
      last4 = (!v || v.toUpperCase() === "NULL") ? null : v;
    } else if (tag === "OPEN" && parts.length >= 2) {
      open = num(parts[1]);
    } else if (tag === "CLOSE" && parts.length >= 2) {
      close = num(parts[1]);
    } else if (tag === "TXN" && parts.length >= 6) {
      // amount is ALWAYS last and date ALWAYS first, so a stray "|" that slipped
      // into the memo despite the instruction gets folded back into the memo
      // rather than shifting the amount out of position.
      const date = parts[1].trim();
      const kind = (parts[2] ?? "").trim().toUpperCase().charAt(0);
      const rawAmt = num(parts[parts.length - 1]);
      const payee = parts[3].trim();
      const memo = parts.slice(4, parts.length - 1).join(" ").trim();
      if (!date || rawAmt === null || !payee) continue;

      // KIND is authoritative over the minus sign the model typed. It classifies
      // the statement SECTION, which is a much easier judgement than the sign
      // convention, and it is the whole reason KIND is asked for: on AMEX 26-08
      // an Amazon RETURN was written with a purchase's minus sign, which put the
      // statement out by twice the line. Deriving the sign from the section
      // removes that failure mode. "O" is left exactly as the model signed it —
      // an unclassified line is one for a human to look at, not to coerce.
      const mag = Math.abs(rawAmt);
      let amount: number;
      if (kind === "P") amount = -mag;
      else if (kind === "Y" || kind === "C") amount = mag;
      else amount = rawAmt;

      txns.push({ date, payee, memo, amount });
    }
  }

  if (txns.length === 0) return null;
  return {
    statement_period: period,
    account_last4: last4,
    opening_balance: open,
    closing_balance: close,
    transactions: txns,
  };
}

async function callGroq(
  apiKey: string,
  model: string,
  systemPrompt: string,
  userContent: string,
  maxTokens = 8000,
  reasoningEffort?: "none" | "low" | "medium" | "high",
): Promise<{ ok: boolean; raw: string; error?: string; finishReason?: string | null }> {
  const r = await callGroqChat({ apiKey, model, systemPrompt, userContent, maxTokens, temperature: 0.1, reasoningEffort });
  return { ok: r.ok, raw: r.raw, error: r.error ?? undefined, finishReason: r.finishReason ?? null };
}

interface QueueItem {
  id: string;
  agency_id: string;
  document_id: string | null;
  purpose: string;
  system_prompt: string;
  user_content: string;
  model: string;
  attempts: number;
  target_ref: Record<string, any> | null;
}

interface DrainResult {
  ok: boolean;
  error?: string;
  // Optional purpose-specific fields:
  wrapupDone?: boolean;           // wrapup organize
  wrapupMissingItems?: string[];  // wrapup organize
  statementBalance?: any;         // bank statements
  transactionsInserted?: number;  // bank statements
  skippedInformational?: number;  // bank statements
  skippedDuplicates?: number;     // bank statements
  skippedUntyped?: number;        // bank statements (credit accounts only — R3)
  untypedLines?: string[];        // bank statements — raw_line text for skippedUntyped rows
  docId?: string | null;          // bank statements
  applicantsUpserted?: number;    // careerplug
  applicantActions?: any[];       // careerplug
  note?: string;
}

async function drainBankStatementItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  // 1. Call Groq (force higher-TPM model for bank statements — see rate limit note above).
  //
  // Output cap raised 4000 -> 8000 on 2026-08-04. A busy card statement is 50-65
  // transactions, and at 4000 the JSON came back cut off mid-string: AMEX
  // Discretionary 26-04 failed three times with "Unterminated string in JSON at
  // position 10658" and was then dead, because a parse failure burns the attempt
  // counter. Rate limiting does NOT burn it (429 is treated as transient and
  // retried on the next tick), so trading a little more TPM pressure for no
  // truncation is strictly the better failure mode: a throttled item drains
  // later, a truncated item never drains at all.
  //
  // THINKING BUDGET, added 2026-08-19. The raise above was necessary but not
  // sufficient, because openai/gpt-oss-120b is a REASONING model and Groq bills
  // its hidden thinking against max_tokens. AMEX Discretionary 26-08 died the
  // same way 26-04 had: max_tokens computed to 2623, yet the visible answer
  // stopped after ~365 tokens (1459 chars, mid-string) — roughly 2250 tokens had
  // gone to thinking before a single transaction was written. Raising the cap
  // cannot outrun that; the thinking scales with the budget you hand it.
  // Statement parsing is mechanical transcription, so thinking buys nothing:
  // reasoning_effort "low" hands essentially the whole budget to the answer.
  //
  // ANSWER SIZE, same date. Capping the thinking was still not enough: the
  // retry produced 6931 chars and hit the wall again. The reason is the queued
  // prompt asks for pretty-printed JSON carrying "raw_line" (a verbatim echo of
  // the source line) and "section" for EVERY transaction — so the answer copies
  // the statement back out at roughly double size. Neither field is stored:
  // the statements table has no column for either, and the cleanTxns loop below
  // reads only date/payee/memo/amount. They were pure cost.
  //
  // So this path sends its OWN prompt instead of item.system_prompt, asking for
  // one compact line per transaction and only the four fields that get stored.
  // Every rule that affects STORED data is carried over verbatim in intent:
  // transaction date over posting date, the bank's own notation appended to
  // memo, repeated identical lines never merged, summary lines skipped, money
  // out negative. Roughly 17 tokens per transaction instead of ~90, which puts
  // a 60-transaction statement at about a third of the available budget.
  //
  // The drainer already overrides the queued MODEL (BANK_STATEMENT_MODEL), so
  // overriding the queued PROMPT follows the same precedent. document-processor's
  // synchronous path is untouched and still uses its own JSON prompt.
  const bankMaxTokens = fitMaxTokens(BANK_STATEMENT_PROMPT_COMPACT, item.user_content, 6000, 1200);
  const llm = await callGroq(groqKey, BANK_STATEMENT_MODEL, BANK_STATEMENT_PROMPT_COMPACT, item.user_content, bankMaxTokens, "low");
  if (!llm.ok) return { ok: false, error: llm.error };

  // 2. Check truncation FIRST — a cut-off answer is a budget problem, and
  // calling it "JSON parse failed" sent three sessions looking at the wrong
  // layer. Name it plainly so the next failure is diagnosable.
  if (llm.finishReason === "length") {
    return {
      ok: false,
      error: `answer truncated: ran out of budget at max_tokens=${bankMaxTokens} `
        + `(prompt ~${Math.ceil((BANK_STATEMENT_PROMPT_COMPACT.length + item.user_content.length) / 4)} tokens, `
        + `${llm.raw.length} chars returned). Statement is too long for one pass — split it or shrink the prompt.`,
    };
  }
  const json = parseCompactStatement(llm.raw);
  if (!json) {
    return { ok: false, error: `compact parse produced no transactions. Head: ${llm.raw.slice(0, 200)}` };
  }

  const period = json?.statement_period;
  if (!period?.start || !period?.end) {
    return { ok: false, error: "missing statement_period.start/.end in LLM response" };
  }
  const openingBalance = typeof json?.opening_balance === "number" ? json.opening_balance : null;
  const closingBalance = typeof json?.closing_balance === "number" ? json.closing_balance : null;
  const accountLast4 = json?.account_last4 ?? null;
  const rawTxns: any[] = Array.isArray(json?.transactions) ? json.transactions : [];

  // 3. Look up document → source_account_code
  if (!item.document_id) return { ok: false, error: "queue item has no document_id" };
  const { data: doc } = await sb
    .from("documents")
    .select("id, source_account_code, agency_id")
    .eq("id", item.document_id)
    .maybeSingle();
  if (!doc) return { ok: false, error: "document not found" };
  if (!doc.source_account_code) return { ok: false, error: "document.source_account_code missing" };

  // Look up chart_of_accounts row for this account_code + agency
  const { data: coa } = await sb
    .from("chart_of_accounts")
    .select("id, account_type, business_entity_id, account_name")
    .eq("agency_id", doc.agency_id)
    .eq("account_code", doc.source_account_code)
    .maybeSingle();
  if (!coa) return { ok: false, error: `chart_of_accounts row not found for account_code=${doc.source_account_code}` };

  // accounts replaces the old bank_accounts/credit_accounts pair (finance
  // rebuild, 2026-08-07). account_kind ('bank' | 'credit') is a column on
  // the row now — read it directly rather than inferring from
  // chart_of_accounts.account_type, same as document-processor does.
  const { data: acct } = await sb
    .from("accounts")
    .select("id, business_entity_id, account_kind")
    .eq("agency_id", doc.agency_id)
    .eq("chart_account_id", coa.id)
    .maybeSingle();
  if (!acct) return { ok: false, error: `accounts row not found for chart_account_id=${coa.id} (account_code=${doc.source_account_code})` };

  if (dryRun) {
    return {
      ok: true,
      statementBalance: { period, openingBalance, closingBalance, accountLast4 },
      transactionsInserted: rawTxns.length,
      docId: doc.id,
    };
  }

  // 4+5. Shared statement writer — duplicate-ingest guard, reconciliation
  // guard, statement_balances upsert, and the occurrence-counted statements
  // loop all live in _shared/statement_writer.ts (one copy for this path and
  // document-processor's handleBankStatement).
  //
  // Held outcomes are TERMINAL for the queue item: the writer has already
  // stamped the document (held_reconciliation_mismatch / duplicate_ingest)
  // and emitted the alert. Retrying a non-tying parse at temperature 0.1
  // just burns tokens repeating the same output; the alert + document status
  // are the review channel. Insert errors stay ok:false so the R2 rule holds
  // (retry, no "processed" stamp, fail after 3 attempts).
  const cleanTxns: { date: string; payee: string; memo: string; signedAmount: number }[] = [];
  for (const t of rawTxns) {
    if (!t || typeof t.amount !== "number" || !t.date) continue;
    const payee = String(t.payee ?? "").trim();
    if (!payee) continue;
    cleanTxns.push({
      date: String(t.date),
      payee,
      memo: String(t.memo ?? "").trim(),
      signedAmount: t.amount,
    });
  }

  const w = await writeParsedStatement({
    agencyId: doc.agency_id,
    documentId: doc.id,
    accountCode: doc.source_account_code,
    account: {
      id: acct.id,
      businessEntityId: acct.business_entity_id,
      accountKind: acct.account_kind,
    },
    accountLast4,
    period: { start: period.start, end: period.end },
    openingBalance,
    closingBalance,
    transactions: cleanTxns,
    source: "llm_queue_drainer",
  });

  if (!w.ok) {
    if (w.held === "reconciliation_mismatch") {
      return { ok: true, note: `held_reconciliation_mismatch: ${w.reason}`, transactionsInserted: 0, docId: doc.id };
    }
    if (w.held === "duplicate_ingest") {
      return { ok: true, note: `duplicate_ingest: ${w.reason}`, transactionsInserted: 0, docId: doc.id };
    }
    return { ok: false, error: w.error, transactionsInserted: w.inserted, docId: doc.id };
  }

  // 6. Mark doc processed — only reached when every transaction insert
  // succeeded (or the parsed list was empty).
  await sb.from("documents").update({
    processing_status: "processed",
    processed_at: new Date().toISOString(),
    notes: `${w.inserted} statement rows via llm_queue_drainer; balance ${openingBalance}→${closingBalance}`,
    tables_updated: ["statement_balances", "statements"],
    records_created: w.inserted + 1,
  }).eq("id", doc.id);

  return {
    ok: true,
    statementBalance: { period, openingBalance, closingBalance, accountLast4 },
    transactionsInserted: w.inserted,
    docId: doc.id,
  };
}

// -------------------------------------------------------------------------
// CareerPlug applicant drainer
// -------------------------------------------------------------------------
// Mirrors what processCareerplugMessage() does after a successful Groq call:
// parse applicants[] out of the JSON and call upsert_candidate_from_careerplug
// per applicant. Skips the resume-PDF path (queue items don't carry attachments);
// the RPC's email-based dedup layer will merge in resume data if the same
// applicant arrives cleanly later.
//
// Uses CAREERPLUG_MODEL (openai/gpt-oss-120b) instead of the queued
// model (usually gpt-oss-120b) to spread TPD load — gpt-oss-120b is the model
// that hits 200K TPD daily and drops these to the queue in the first place,
// so retrying on the same model recreates the problem.
async function drainCareerplugItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  // 1. Call Groq. Careerplug messages are small; 1500 max_tokens covers the
  // biggest daily digest we've observed.
  const careerplugMaxTokens = fitMaxTokens(item.system_prompt, item.user_content, 1500, 600);
  const llm = await callGroq(groqKey, CAREERPLUG_MODEL, item.system_prompt, item.user_content, careerplugMaxTokens);
  if (!llm.ok) return { ok: false, error: llm.error };

  // 2. Parse JSON. Expect { "applicants": [ {...}, ... ] }
  let json: any;
  try { json = JSON.parse(stripFences(llm.raw)); }
  catch (e) { return { ok: false, error: `JSON parse failed: ${e}. Head: ${llm.raw.slice(0, 200)}` }; }

  const applicants: any[] = Array.isArray(json?.applicants) ? json.applicants : [];
  if (applicants.length === 0) {
    // LLM decided this isn't an applicant notification. Treat as success — no
    // work to do, don't need to retry.
    return { ok: true, applicantsUpserted: 0, applicantActions: [], note: "LLM returned zero applicants" };
  }

  // 3. Reconstruct source-message metadata from the user_content header lines
  // (parseWithLLM stores exactly what processCareerplugMessage passed in).
  const subject = item.user_content.match(/^SUBJECT:\s*(.+)$/m)?.[1]?.trim() ?? "";
  const fromEmail = item.user_content.match(/^FROM:\s*(.+)$/m)?.[1]?.trim() ?? "";
  const receivedAtISO = item.user_content.match(/^RECEIVED_AT \(ISO\):\s*(.+)$/m)?.[1]?.trim() ?? "";

  if (dryRun) {
    return { ok: true, applicantsUpserted: applicants.length, applicantActions: [], note: "dry_run" };
  }

  // 4. Upsert each applicant via the same RPC processCareerplugMessage uses.
  // Idempotency: RPC dedups by ingestion_metadata.source_message.gmail_message_id
  // first (we don't have that; queue doesn't preserve it), then falls back to
  // lower(email). So a same-email applicant already ingested via any path gets
  // matched and updated instead of duplicated.
  const actions: any[] = [];
  let upserted = 0;
  for (let idx = 0; idx < applicants.length; idx++) {
    const a = applicants[idx];
    const payload: Record<string, unknown> = {
      first_name: a.first_name ?? null,
      last_name:  a.last_name ?? null,
      email:      a.email ?? null,
      phone:      a.phone ?? null,
      position:   a.position ?? null,
      applied_at: a.applied_at ?? (receivedAtISO || new Date().toISOString()),
      resume_url: a.resume_url ?? null,
      resume_document_id: null,  // drainer path has no Gmail attachment access
      gmail_message_id: null,    // not preserved in llm_parse_queue schema
      careerplug_metadata: {
        prescreen_score: a.prescreen_score,
        is_fast_track:   a.is_fast_track,
        source_platform: a.source_platform,
        careerplug_applicant_id: a.careerplug_applicant_id,
        raw_line: a.raw_line,
        gmail_source_message_id: null,
        gmail_from: fromEmail,
        gmail_subject: subject,
        drained_from_queue: true,
        drainer_queue_id: item.id,
        drainer_drained_at: new Date().toISOString(),
      },
    };

    const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
      p_agency_id: item.agency_id,
      p_payload:   payload,
    });
    if (rpcErr) {
      actions.push({
        email: a.email,
        name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
        action: `rpc_error: ${rpcErr.message}`,
      });
      continue;
    }
    const res = (rpcData ?? {}) as { assessment_id?: string; action?: string };
    actions.push({
      email: a.email,
      name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
      action: res.action ?? "unknown",
      assessment_id: res.assessment_id,
    });
    if (res.action === "inserted" || res.action === "updated_by_email") upserted++;
  }

  return { ok: true, applicantsUpserted: upserted, applicantActions: actions };
}

// ── wrapup_organize ──────────────────────────────────────────────────────────
// Finishes a team wrap-up organize job that document-processor could not
// complete synchronously (almost always Groq over quota on a Friday afternoon).
//
// Requires target_ref.detail_id -- the weekly_cpr_team_detail row the organized
// text belongs to. Jobs queued before target_ref shipped (2026-08-07) have no
// pointer and cannot be completed here; they fail with a clear message rather
// than guessing at a row.
//
// STALENESS GUARD: the queued user_content embeds a <CURRENT_WRAPUP_TEXT>
// snapshot taken when the job was enqueued. If a LATER email for the same
// teammate/week was organized successfully in the meantime, the live row now
// holds strictly more content than this job's snapshot, and writing this job's
// output would DELETE that newer content. When live text and snapshot disagree,
// this handler refuses the write and raises an alert for a manual merge instead.
// Losing a teammate's words silently is worse than a visible stuck job.
//
// NOT DONE HERE: the missing-item nag email. Nagging needs Composio + the team
// roster and lives in document-processor's wrapup parser. A drained job that
// comes back incomplete records wrapup_done=false and the missing labels; the
// Friday 7 PM no-send check is what surfaces the gap to the team.
function wupExtractSnapshotFromUserContent(userContent: string): string | null {
  const m = userContent.match(/<CURRENT_WRAPUP_TEXT>\n([\s\S]*?)\n<\/CURRENT_WRAPUP_TEXT>/);
  if (!m) return null;
  const raw = m[1];
  return raw === "(none yet)" ? "" : raw;
}

async function drainWrapupOrganizeItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  const detailId = item.target_ref?.detail_id as string | undefined;
  if (!detailId) {
    return { ok: false, error: "target_ref.detail_id missing — job predates target_ref (2026-08-07) or was enqueued without a write target; cannot resolve which weekly_cpr_team_detail row to write" };
  }

  const wrapupMaxTokens = fitMaxTokens(item.system_prompt, item.user_content, 2500, 800);
  const llm = await callGroq(groqKey, WRAPUP_MODEL, item.system_prompt, item.user_content, wrapupMaxTokens);
  if (!llm.ok) return { ok: false, error: llm.error ?? "groq failed" };

  let parsed: any;
  try {
    parsed = JSON.parse(stripFences(llm.raw));
  } catch (e) {
    return { ok: false, error: `JSON parse failed: ${e instanceof Error ? e.message : String(e)}` };
  }

  const organizedText: string = typeof parsed?.organized_text === "string" ? parsed.organized_text : "";
  if (!organizedText.trim()) {
    return { ok: false, error: "LLM returned empty organized_text" };
  }
  const coverage = parsed?.coverage ?? {};
  const allCovered =
    coverage.item_1 === true && coverage.item_2 === true && coverage.item_3 === true &&
    coverage.item_4 === true && coverage.item_5 === true && coverage.item_6 === true;
  const missingLabels: string[] = Array.isArray(parsed?.missing_item_labels) ? parsed.missing_item_labels : [];

  if (dryRun) {
    return { ok: true, wrapupDone: allCovered, wrapupMissingItems: missingLabels, note: `dry run — would write ${organizedText.length} chars to weekly_cpr_team_detail ${detailId}` };
  }

  const { data: liveRow, error: liveErr } = await sb
    .from("weekly_cpr_team_detail")
    .select("id, wrapup_text")
    .eq("id", detailId)
    .maybeSingle();
  if (liveErr) return { ok: false, error: `detail read failed: ${liveErr.message}` };
  if (!liveRow) return { ok: false, error: `weekly_cpr_team_detail ${detailId} no longer exists` };

  const snapshot = wupExtractSnapshotFromUserContent(item.user_content);
  const liveText = (liveRow.wrapup_text ?? "") as string;
  if (liveText.trim() && snapshot !== null && liveText.trim() !== snapshot.trim()) {
    if ((item.attempts ?? 0) === 0) {
      await sb.from("alerts").insert({
        agency_id: item.agency_id,
        alert_type: "data_conflict",
        severity: "warning",
        title: "Queued wrap-up needs a manual merge",
        message: `Queued wrap-up job ${item.id} (${item.target_ref?.sender_first_name ?? "unknown teammate"}, week ${item.target_ref?.week_ending_date ?? "unknown"}) was organized against an older copy of the wrap-up text. The stored text has changed since, so writing this result would delete newer content. Merge by hand from Gmail message ${item.target_ref?.gmail_message_id ?? "unknown"}.`,
        module_reference: "llm-queue-drainer:wrapup_stale",
        is_read: false,
        is_resolved: false,
      }).then(() => {}, () => {});
    }
    return { ok: false, error: "detail row advanced since this job was queued — refusing to overwrite newer wrap-up text; manual merge required (alert raised)" };
  }

  const { error: updErr } = await sb
    .from("weekly_cpr_team_detail")
    .update({ wrapup_text: organizedText, wrapup_done: allCovered, updated_at: new Date().toISOString() })
    .eq("id", detailId);
  if (updErr) return { ok: false, error: `detail update failed: ${updErr.message}` };

  return {
    ok: true,
    wrapupDone: allCovered,
    wrapupMissingItems: missingLabels,
    note: `wrote ${organizedText.length} chars to weekly_cpr_team_detail ${detailId}${allCovered ? "" : ` — ${missingLabels.length} item(s) still missing, no nag sent from the drainer`}`,
  };
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);

  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  const groqKey = await getSettingOrNull(agencyId, "groq_api_key");
  if (!groqKey) return jsonResponse({ ok: false, error: "groq_api_key not set" }, 400);

  const maxItems = Math.min(Math.max(parseInt(body?.max_items ?? "10", 10) || 10, 1), 50);
  const dryRun = body?.dry_run === true;

  // Pull pending items for any supported purpose. Order by created_at so
  // oldest backlog drains first (fair-queue behavior across purposes).
  const { data: items, error: qErr } = await sb
    .from("llm_parse_queue")
    .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts, target_ref")
    .eq("agency_id", agencyId)
    .eq("status", "pending")
    .in("purpose", SUPPORTED_PURPOSES)
    .lt("attempts", 3)
    .order("created_at", { ascending: true })
    .limit(maxItems);

  if (qErr) return jsonResponse({ ok: false, error: `queue read failed: ${qErr.message}` }, 500);
  if (!items || items.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "no pending items" });
  }

  const results: any[] = [];
  let totalTxns = 0;
  let totalApplicants = 0;
  let successes = 0;
  let failures = 0;
  let byPurpose: Record<string, { drained: number; ok: number; err: number }> = {};

  for (const item of items as QueueItem[]) {
    const purposeStats = byPurpose[item.purpose] ??= { drained: 0, ok: 0, err: 0 };
    purposeStats.drained += 1;

    let r: DrainResult;
    if (item.purpose === "parse_bank_statement") {
      r = await drainBankStatementItem(item, groqKey, dryRun);
    } else if (item.purpose === "careerplug_applicant_extract") {
      r = await drainCareerplugItem(item, groqKey, dryRun);
    } else if (item.purpose === "wrapup_organize") {
      r = await drainWrapupOrganizeItem(item, groqKey, dryRun);
    } else {
      // Shouldn't happen — SUPPORTED_PURPOSES filter guards this. Skip defensively.
      r = { ok: false, error: `unsupported purpose: ${item.purpose}` };
    }

    if (!dryRun) {
      // Bump attempts + record result. Rate limit (429) = transient, don't count as an attempt.
      const isRateLimit = !r.ok && /Groq HTTP 429/.test(r.error ?? "");
      if (r.ok) {
        await sb.from("llm_parse_queue").update({
          status: "succeeded",
          attempts: (item.attempts ?? 0) + 1,
          last_attempt_at: new Date().toISOString(),
          completed_at: new Date().toISOString(),
          result_raw: null,
          last_error: r.error ?? null,
        }).eq("id", item.id);
      } else if (isRateLimit) {
        // Transient rate limit — don't burn the attempts counter; cron will retry.
        await sb.from("llm_parse_queue").update({
          status: "pending",
          last_attempt_at: new Date().toISOString(),
          last_error: r.error ?? "rate limited",
        }).eq("id", item.id);
      } else {
        const newAttempts = (item.attempts ?? 0) + 1;
        const nowDead = newAttempts >= 3;
        await sb.from("llm_parse_queue").update({
          status: nowDead ? "failed" : "pending",
          attempts: newAttempts,
          last_attempt_at: new Date().toISOString(),
          last_error: r.error ?? "unknown",
        }).eq("id", item.id);

        // An item that exhausts its attempts is DEAD: nothing retries it, because
        // the claim query only reads status="pending". Until 2026-08-19 that
        // happened in total silence — this runner keeps reporting success (the
        // RUNNER worked; the ITEM failed), so no automation_failure alert ever
        // fired. AMEX Discretionary 26-08 went dead five minutes after arriving
        // and was only noticed two days later because the email was still sitting
        // unread in the inbox. Never rely on that again.
        if (nowDead) {
          let label = item.purpose;
          if (item.document_id) {
            const { data: deadDoc } = await sb
              .from("documents")
              .select("file_name")
              .eq("id", item.document_id)
              .maybeSingle();
            if (deadDoc?.file_name) label = deadDoc.file_name;
          }
          await insertAlert({
            agencyId: item.agency_id,
            alertType: "llm_parse_item_dead",
            severity: "warning",
            title: `Parse gave up after 3 tries: ${label}`,
            message: `Queue item ${item.id} (${item.purpose}) failed 3 attempts and will not be retried `
              + `automatically. Nothing downstream of it has been written. Last error: ${r.error ?? "unknown"}`,
            moduleReference: item.purpose === "parse_bank_statement" ? "financials" : "automations",
            relatedId: item.document_id ?? null,
          });
        }
      }
    }

    if (r.ok) {
      successes += 1;
      purposeStats.ok += 1;
      totalTxns += r.transactionsInserted ?? 0;
      totalApplicants += r.applicantsUpserted ?? 0;
    } else {
      failures += 1;
      purposeStats.err += 1;
    }

    results.push({
      queue_id: item.id,
      purpose: item.purpose,
      document_id: item.document_id,
      ok: r.ok,
      // Bank statement fields (undefined for careerplug):
      transactions_inserted: r.transactionsInserted,
      skipped_informational: r.skippedInformational,
      skipped_duplicates: r.skippedDuplicates,
      skipped_untyped: r.skippedUntyped,
      untyped_lines: r.untypedLines,
      statement_balance: r.statementBalance,
      // Careerplug fields (undefined for bank statements):
      applicants_upserted: r.applicantsUpserted,
      applicant_actions: r.applicantActions,
      // Wrap-up fields (undefined for other purposes):
      wrapup_done: r.wrapupDone,
      wrapup_missing_items: r.wrapupMissingItems,
      note: r.note,
      error: r.error,
    });
  }

  return jsonResponse({
    ok: true,
    drained: items.length,
    successes,
    failures,
    total_transactions_inserted: totalTxns,
    total_applicants_upserted: totalApplicants,
    by_purpose: byPurpose,
    dry_run: dryRun,
    items: results,
  });
});
