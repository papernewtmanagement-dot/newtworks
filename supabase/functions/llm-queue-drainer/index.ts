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
// Bank, card and investment statements: since 2026-09-26 this is the ONLY
// statement reader. document-processor queues every statement rather than
// reading it, so the fine-print trimming, sign repairs, period check and the
// health-savings summary in ./statement_reader.ts apply to all of them.
//
// Invocation: POST { agency_id, shared_secret, [max_items=10, dry_run=false] }
//             POST { ..., dry_run: true, queue_ids: [...] } re-reads named rows
//             without writing anything (testing the reader on real statements).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, jsonResponse, getSettingOrNull, stripFences } from "../_shared/supabase.ts";
import { callGroqChat } from "../_shared/llm.ts";
import { requireSharedSecret } from "../_shared/auth.ts";
import { writeParsedStatement } from "../_shared/statement_writer.ts";
import { ensureWatcherTask } from "../_shared/watchers.ts";
import {
  prepareStatementText,
  BANK_STATEMENT_PROMPT_COMPACT,
  parseCompactStatement,
  reclassifyCreditsFromText,
  resignFromTrailingMinus,
  checkStatementPeriod,
  INVESTMENT_SUMMARY_PROMPT,
  investmentWindow,
  investmentSummaryFromText,
  parseInvestmentSummary,
  investmentSummaryToLines,
  balancesFromText,
  type ReaderTxn,
} from "./statement_reader.ts";

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

// 4 chars/token is the usual rule of thumb for prose, but statement text is
// dense with digits, currency symbols and punctuation, which tokenize far
// worse. Measured on AMEX 26-08 after boilerplate trimming: ~13,400 chars came
// in at 3,619 real tokens, i.e. 3.70 chars/token. At the 4.0 estimate the
// request was sized at 8,319 against a hard 8,000 cap and Groq rejected the
// whole call with HTTP 413 — which, unlike a 429, burns an attempt. Estimate
// low so the sizing errs toward a slightly smaller answer budget instead of a
// rejected request.
const CHARS_PER_TOKEN_EST = 3.4;

function fitMaxTokens(systemPrompt: string, userContent: string, ceiling: number, floor: number): number {
  const promptTokensEst = Math.ceil((systemPrompt.length + userContent.length) / CHARS_PER_TOKEN_EST);
  const available = GROQ_REQUEST_TOKEN_CAP - promptTokensEst - GROQ_SAFETY_MARGIN;
  return Math.max(floor, Math.min(ceiling, available));
}

// Statement text handling, prompts, sign repairs and checks live in
// ./statement_reader.ts (pure functions, testable against real statements).

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

// Which reader runs depends on the account, so the account is resolved FIRST
// (moved ahead of the model call 2026-09-26; it used to be looked up after).
//   investment accounts (health savings) -> summary only: money added,
//                                           growth or loss, balance
//   bank and card accounts               -> every transaction line
// Every statement comes through here: since 2026-09-26 document-processor
// queues statements instead of reading them itself, so there is one reader.
async function drainBankStatementItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  if (!item.document_id) return { ok: false, error: "queue item has no document_id" };
  const { data: doc } = await sb
    .from("documents")
    .select("id, source_account_code, agency_id")
    .eq("id", item.document_id)
    .maybeSingle();
  if (!doc) return { ok: false, error: "document not found" };
  if (!doc.source_account_code) return { ok: false, error: "document.source_account_code missing" };

  const { data: coa } = await sb
    .from("chart_of_accounts")
    .select("id, account_type, business_entity_id, account_name")
    .eq("agency_id", doc.agency_id)
    .eq("account_code", doc.source_account_code)
    .maybeSingle();
  if (!coa) return { ok: false, error: `chart_of_accounts row not found for account_code=${doc.source_account_code}` };

  // accounts replaces the old bank_accounts/credit_accounts pair (finance
  // rebuild, 2026-08-07). account_kind is 'bank' | 'credit' | 'investment'.
  const { data: acct } = await sb
    .from("accounts")
    .select("id, business_entity_id, account_kind, account_number_last4, account_name, institution")
    .eq("agency_id", doc.agency_id)
    .eq("chart_account_id", coa.id)
    .maybeSingle();
  if (!acct) return { ok: false, error: `accounts row not found for chart_account_id=${coa.id} (account_code=${doc.source_account_code})` };

  const read = acct.account_kind === "investment"
    ? await readInvestmentStatement(item.user_content, acct.account_number_last4 ?? null,
        (acct.institution && !String(acct.account_name ?? "").includes(acct.institution)
          ? `${acct.institution} ${acct.account_name ?? ""}` : String(acct.account_name ?? "")).trim(), groqKey)
    : await readBankOrCardStatement(item.user_content, acct.account_kind, groqKey);
  if (!read.ok) return { ok: false, error: read.error };

  const { period, openingBalance, closingBalance, txns, controlNote } = read;
  // The account's own last four win over what the model read off the page
  // (a September test read 0353 as "5353").
  const accountLast4 = acct.account_number_last4 ?? read.accountLast4;
  const periodProblem = checkStatementPeriod(period, txns, new Date().toISOString().slice(0, 10));
  if (periodProblem) return { ok: false, error: periodProblem };

  if (dryRun) {
    return {
      ok: true,
      statementBalance: { period, openingBalance, closingBalance, accountLast4 },
      transactionsInserted: txns.length,
      docId: doc.id,
      note: controlNote || "control check: nothing to report",
    };
  }

  // Shared statement writer — duplicate-ingest guard, reconciliation guard,
  // statement_balances upsert and the occurrence-counted statements loop all
  // live in _shared/statement_writer.ts.
  //
  // Held outcomes are TERMINAL for the queue item: the writer has already
  // stamped the document (held_reconciliation_mismatch / duplicate_ingest)
  // and emitted the alert. Insert errors stay ok:false so the item retries.
  const cleanTxns = txns
    .filter((t) => t && typeof t.amount === "number" && t.date && String(t.payee ?? "").trim())
    .map((t) => ({ date: String(t.date), payee: String(t.payee).trim(), memo: String(t.memo ?? "").trim(), signedAmount: t.amount }));

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
      return {
        ok: true,
        note: `held_reconciliation_mismatch: ${w.reason}${controlNote ? ` | ${controlNote}` : ""}`,
        transactionsInserted: 0,
        docId: doc.id,
      };
    }
    if (w.held === "duplicate_ingest") {
      return { ok: true, note: `duplicate_ingest: ${w.reason}`, transactionsInserted: 0, docId: doc.id };
    }
    return { ok: false, error: w.error, transactionsInserted: w.inserted, docId: doc.id };
  }

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
    note: controlNote || undefined,
  };
}

type StatementRead =
  | {
      ok: true;
      period: { start: string; end: string };
      openingBalance: number | null;
      closingBalance: number | null;
      accountLast4: string | null;
      txns: ReaderTxn[];
      controlNote: string;
    }
  | { ok: false; error: string };

// Health savings and other investment accounts: summary only (Peter,
// 2026-09-26). Three figures and the balance, checked to the cent.
async function readInvestmentStatement(
  rawText: string, last4: string | null, label: string, groqKey: string,
): Promise<StatementRead> {
  // Read by position first; the model is only asked when that does not tie.
  const fromText = investmentSummaryFromText(rawText, last4);
  const textLines = investmentSummaryToLines(fromText, label || "Investment account");
  if (textLines.ok && fromText.period) {
    return {
      ok: true,
      period: fromText.period,
      openingBalance: fromText.open,
      closingBalance: fromText.close,
      accountLast4: last4,
      txns: textLines.txns,
      controlNote: `${textLines.note} (read from the statement text)`,
    };
  }
  const window = investmentWindow(rawText, last4);
  const userContent = `ACCOUNT NUMBER ENDS IN: ${last4 ?? "unknown"}\n\n${window}`;
  const maxTokens = fitMaxTokens(INVESTMENT_SUMMARY_PROMPT, userContent, 1500, 600);
  const llm = await callGroq(groqKey, BANK_STATEMENT_MODEL, INVESTMENT_SUMMARY_PROMPT, userContent, maxTokens, "low");
  if (!llm.ok) return { ok: false, error: llm.error ?? "groq failed" };
  const s = parseInvestmentSummary(llm.raw);
  const lines = investmentSummaryToLines(s, label || "Investment account");
  if (!lines.ok) return { ok: false, error: `${lines.error}. Answer head: ${llm.raw.slice(0, 200)}` };
  return {
    ok: true,
    period: s.period!,
    openingBalance: s.open,
    closingBalance: s.close,
    accountLast4: last4,
    txns: lines.txns,
    controlNote: lines.note,
  };
}

// Bank and card statements: every transaction line, then the control checks.
//
// Why this path sends its OWN compact prompt instead of item.system_prompt,
// and why reasoning_effort is "low" (measured 2026-08-19 on AMEX 26-08):
// openai/gpt-oss-120b bills hidden thinking against max_tokens, so "medium"
// returned an EMPTY answer and a verbose prompt dropped lines. One compact line
// per transaction is ~17 tokens instead of ~90.
async function readBankOrCardStatement(rawText: string, accountKind: string, groqKey: string): Promise<StatementRead> {
  const prepared = prepareStatementText(rawText);
  const statementText = prepared.text;
  if (prepared.removed > 0) {
    console.log(`[drainer] trimmed ${prepared.removed} chars of fine print (${rawText.length} -> ${statementText.length})`);
  }
  const bankMaxTokens = fitMaxTokens(BANK_STATEMENT_PROMPT_COMPACT, statementText, 6000, 1200);
  const llm = await callGroq(groqKey, BANK_STATEMENT_MODEL, BANK_STATEMENT_PROMPT_COMPACT, statementText, bankMaxTokens, "low");
  if (!llm.ok) return { ok: false, error: llm.error ?? "groq failed" };

  // A cut-off answer is a budget problem; name it plainly.
  if (llm.finishReason === "length") {
    return {
      ok: false,
      error: `answer truncated: ran out of budget at max_tokens=${bankMaxTokens} `
        + `(prompt ~${Math.ceil((BANK_STATEMENT_PROMPT_COMPACT.length + statementText.length) / 4)} tokens, `
        + `${llm.raw.length} chars returned).`,
    };
  }
  const json = parseCompactStatement(llm.raw);
  if (!json) return { ok: false, error: `compact parse produced no transactions. Head: ${llm.raw.slice(0, 200)}` };

  // CONTROL CHECK. Two independent checks on the lines the model read:
  //   balances  opening + lines = closing, to the cent. Opening and closing
  //             come from the model AND, as a second opinion, straight from the
  //             statement text (balancesFromText); a pair is used only if the
  //             lines tie to it exactly.
  //   totals    the Account Summary totals of charges and of payments/credits.
  // A tie on balances is what the statement writer requires, so it decides.
  // When nothing ties, the text-driven sign repairs are tried one at a time and
  // a repair is kept ONLY if the lines then tie (balances, or failing those the
  // totals). Otherwise the parse goes on unchanged and the writer holds it — a
  // partial guess on money is worse than a clean stop.
  //   repair 1  card refunds misread as charges (the statement's credits blocks)
  //   repair 2  deposit-account withdrawals misread as deposits (trailing minus)
  let controlNote = "";
  let openingBalance: number | null = typeof json.opening_balance === "number" ? json.opening_balance : null;
  let closingBalance: number | null = typeof json.closing_balance === "number" ? json.closing_balance : null;
  {
    const sumOf = (ts: ReaderTxn[]) => ({
      charges: ts.filter((t) => t.amount < 0).reduce((a, t) => a + Math.abs(t.amount), 0),
      credits: ts.filter((t) => t.amount > 0).reduce((a, t) => a + t.amount, 0),
    });
    // Card balances are amounts owed: money in lowers them. Deposit and
    // investment balances rise with money in.
    const dir = accountKind === "credit" ? -1 : 1;
    // Read from the untrimmed text, so no trimming can hide the summary.
    const fromText = balancesFromText(rawText);
    const pairs: { open: number; close: number; label: string }[] = [];
    const addPair = (o: number | null, c: number | null, label: string) => {
      if (typeof o === "number" && typeof c === "number" && !pairs.some((p) => p.open === o && p.close === c)) {
        pairs.push({ open: o, close: c, label });
      }
    };
    addPair(openingBalance, closingBalance, "the balances the model read");
    addPair(openingBalance ?? fromText.open, closingBalance ?? fromText.close, "the balances, gaps filled from the statement text");
    addPair(fromText.open, fromText.close, "the balances printed in the statement text");
    const tiedPair = (ts: ReaderTxn[]) => {
      const net = ts.reduce((a, t) => a + t.amount, 0);
      return pairs.find((p) => Math.abs(p.open + dir * net - p.close) <= 0.01) ?? null;
    };
    const haveDeclared = json.declared_charges !== null || json.declared_credits !== null;
    const offDeclared = (ts: ReaderTxn[]) => {
      const s = sumOf(ts);
      return Math.round((Math.abs(s.charges - (json.declared_charges ?? s.charges))
        + Math.abs(s.credits - (json.declared_credits ?? s.credits))) * 100) / 100;
    };
    const ties = (ts: ReaderTxn[]) => pairs.length > 0 ? tiedPair(ts) !== null : (haveDeclared && offDeclared(ts) <= 0.01);

    const before = sumOf(json.transactions);
    console.log(`[drainer] control inputs: declared_charges=${json.declared_charges ?? "n/a"} `
      + `declared_credits=${json.declared_credits ?? "n/a"} parsed_charges=${before.charges.toFixed(2)} `
      + `parsed_credits=${before.credits.toFixed(2)} model_open=${openingBalance ?? "n/a"} model_close=${closingBalance ?? "n/a"} `
      + `text_open=${fromText.open ?? "n/a"} text_close=${fromText.close ?? "n/a"}`);

    if (pairs.length === 0 && !haveDeclared) {
      controlNote = "no balances or summary totals could be read, so nothing to check against";
    } else if (ties(json.transactions)) {
      const p = tiedPair(json.transactions);
      controlNote = p
        ? `lines tie to ${p.label}: ${p.open} -> ${p.close}`
        : `lines tie to the Account Summary totals: charges ${before.charges.toFixed(2)}, credits ${before.credits.toFixed(2)}`;
    } else {
      const repairs: { name: string; run: () => { count: number; txns: ReaderTxn[] } }[] = [
        {
          name: "refunds misread as charges, fixed from the statement's credits block(s)",
          run: () => { const r = reclassifyCreditsFromText(statementText, json.transactions); return { count: r.flipped, txns: r.txns }; },
        },
        {
          name: "money in/out misread, fixed from the trailing minus the bank prints on withdrawals",
          run: () => { const r = resignFromTrailingMinus(statementText, json.transactions); return { count: r.changed, txns: r.txns }; },
        },
      ];
      const tried: string[] = [];
      let fixed = false;
      for (const rep of repairs) {
        const r = rep.run();
        tried.push(`${r.count} line(s) changed`);
        if (r.count > 0 && ties(r.txns)) {
          json.transactions = r.txns;
          const p = tiedPair(r.txns);
          controlNote = `repaired ${r.count} line(s): ${rep.name}; lines now tie to `
            + (p ? `${p.label}: ${p.open} -> ${p.close}` : "the Account Summary totals");
          fixed = true;
          break;
        }
      }
      if (!fixed) {
        controlNote = `lines DO NOT tie: parsed charges ${before.charges.toFixed(2)} vs declared `
          + `${json.declared_charges ?? "n/a"}, parsed credits ${before.credits.toFixed(2)} vs declared `
          + `${json.declared_credits ?? "n/a"}, balances tried ${pairs.map((p) => `${p.open}->${p.close}`).join(", ") || "none"}. `
          + `Repairs tried: ${tried.join("; ")} — none applied.`;
      }
    }
    // Whichever balance pair the lines tie to is the one written.
    const p = tiedPair(json.transactions);
    if (p) { openingBalance = p.open; closingBalance = p.close; }
    console.log(`[drainer] ${controlNote}`);
  }

  const period = json.statement_period;
  if (!period?.start || !period?.end) return { ok: false, error: "missing statement period in the answer" };
  return {
    ok: true,
    period,
    openingBalance,
    closingBalance,
    accountLast4: json.account_last4 ?? null,
    txns: json.transactions,
    controlNote: prepared.removed > 0
      ? `${controlNote}${controlNote ? " | " : ""}fine print trimmed: ${rawText.length} -> ${statementText.length} chars`
      : controlNote,
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
      await ensureWatcherTask({
        agencyId: item.agency_id,
        source: `wrapup_stale:${item.id}`,
        relatedId: null,
        title: "Queued wrap-up needs a manual merge",
        description: `Queued wrap-up job ${item.id} (${item.target_ref?.sender_first_name ?? "unknown teammate"}, week ${item.target_ref?.week_ending_date ?? "unknown"}) was organized against an older copy of the wrap-up text. The stored text has changed since, so writing this result would delete newer content. Merge by hand from Gmail message ${item.target_ref?.gmail_message_id ?? "unknown"}.`,
        priority: "medium",
        category: "processes",
      });
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

  // DRY-RUN BY ID (added 2026-09-26): re-read specific queue rows, whatever
  // their status, and report what the reader WOULD write — nothing is written
  // and nothing is claimed. Used to test the reader on real statements before
  // trusting a change. Refused without dry_run, so it can never bypass the
  // claim that stops two runs from writing the same statement.
  const queueIds: string[] = Array.isArray(body?.queue_ids) ? body.queue_ids.map(String).slice(0, 10) : [];
  if (queueIds.length > 0) {
    if (!dryRun) return jsonResponse({ ok: false, error: "queue_ids is only allowed with dry_run: true" }, 400);
    const { data: picked, error: pErr } = await sb
      .from("llm_parse_queue")
      .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts, target_ref")
      .eq("agency_id", agencyId)
      .in("id", queueIds)
      .in("purpose", SUPPORTED_PURPOSES);
    if (pErr) return jsonResponse({ ok: false, error: `queue read failed: ${pErr.message}` }, 500);
    const results: any[] = [];
    for (const item of (picked ?? []) as QueueItem[]) {
      const r = item.purpose === "parse_bank_statement"
        ? await drainBankStatementItem(item, groqKey, true)
        : item.purpose === "careerplug_applicant_extract"
          ? await drainCareerplugItem(item, groqKey, true)
          : await drainWrapupOrganizeItem(item, groqKey, true);
      results.push({ queue_id: item.id, ok: r.ok, error: r.error, note: r.note,
        statement_balance: r.statementBalance, transactions: r.transactionsInserted });
    }
    return jsonResponse({ ok: true, dry_run: true, by_id: true, items: results });
  }

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

  // Rows stuck in "processing" belong to a run that died without finishing
  // (crash, platform kill). Offer them back after a generous timeout — a live
  // statement run takes 2-3 minutes, so 10 is safely past any honest run.
  const STALE_PROCESSING_MINUTES = 10;
  const staleCutoff = new Date(Date.now() - STALE_PROCESSING_MINUTES * 60 * 1000).toISOString();
  const { data: staleItems } = await sb
    .from("llm_parse_queue")
    .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts, target_ref")
    .eq("agency_id", agencyId)
    .eq("status", "processing")
    .lt("last_attempt_at", staleCutoff)
    .in("purpose", SUPPORTED_PURPOSES)
    .lt("attempts", 3)
    .order("created_at", { ascending: true })
    .limit(maxItems);

  const pool = [...(items ?? []), ...(staleItems ?? [])];
  if (pool.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "no pending items" });
  }

  // ATOMIC CLAIM — added 2026-08-19 after the duplicate storm.
  //
  // A row used to stay "pending" the whole time it was being worked, so every
  // overlapping invocation — the 2-minute cron, a manual dispatch, or simply a
  // run that outlives one cron interval — claimed the SAME row and processed it
  // again. On AMEX 26-08 that wrote 66 statements rows in four minutes
  // (05:48–05:52) and the GL writer posted 63 of them to the ledger before it
  // was caught; every row had to be hand-deleted.
  //
  // Each row is now taken with one conditional update: pending -> processing.
  // Whoever flips it first owns it; every other run matches zero rows and moves
  // on. Dry runs never claim, so they cannot strand a row in "processing".
  const claimed: QueueItem[] = [];
  if (dryRun) {
    claimed.push(...(pool as QueueItem[]));
  } else {
    for (const cand of pool as QueueItem[]) {
      const fromStale = (staleItems ?? []).some((s) => s.id === cand.id);
      let claimQ = sb
        .from("llm_parse_queue")
        .update({ status: "processing", last_attempt_at: new Date().toISOString() })
        .eq("id", cand.id);
      claimQ = fromStale
        ? claimQ.eq("status", "processing").lt("last_attempt_at", staleCutoff)
        : claimQ.eq("status", "pending");
      const { data: got } = await claimQ.select("id");
      if ((got?.length ?? 0) === 1) claimed.push(cand);
    }
  }
  if (claimed.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "all candidates claimed by another run" });
  }

  const results: any[] = [];
  let totalTxns = 0;
  let totalApplicants = 0;
  let successes = 0;
  let failures = 0;
  let byPurpose: Record<string, { drained: number; ok: number; err: number }> = {};

  for (const item of claimed) {
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
      // 413 and 429 look alike and need OPPOSITE responses. A 429 is "you are
      // going too fast" — wait and the identical payload succeeds. A 413 is
      // "this one request is too big" — it will fail identically forever, so
      // waiting is not a strategy and neither is retrying. Fail it on the first
      // attempt so the alert lands now instead of two cron ticks later. John
      // Kostov's 2026-08-28 wrap-up burned all three attempts on the same 413
      // and nobody heard about it until Peter noticed the CPR row was empty.
      const isTooLarge = !r.ok && /Groq HTTP 413/.test(r.error ?? "");
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
        const newAttempts = isTooLarge ? 3 : (item.attempts ?? 0) + 1;
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
          // The QUEUE item is dead, but until 2026-09-02 the DOCUMENT row went on
          // saying "queued_for_llm" forever, so the Documents view showed a statement
          // as still in progress days after nothing was ever going to touch it again.
          // Capital One 26-08 and Chase CC 26-08 both sat that way for two days. The
          // alert above fires either way; this is about the record Peter actually reads.
          if (item.document_id) {
            await sb.from("documents").update({
              processing_status: "error",
              notes: JSON.stringify({
                failed: "llm_parse",
                queue_item: item.id,
                purpose: item.purpose,
                error: r.error ?? "unknown",
                failed_at: new Date().toISOString(),
              }),
            }).eq("id", item.document_id);
          }
          await ensureWatcherTask({
            agencyId: item.agency_id,
            source: `llm_parse_item_dead:${item.id}`,
            title: isTooLarge
              ? `Parse payload too big, not retryable: ${label}`
              : `Parse gave up after 3 tries: ${label}`,
            description: isTooLarge
              ? `Queue item ${item.id} (${item.purpose}) was rejected for exceeding the model's `
                + `per-request token ceiling. Retrying cannot help — the same payload fails the same `
                + `way every time. The text needs to be trimmed at the source before it is queued. `
                + `Nothing downstream of it has been written. Error: ${r.error ?? "unknown"}`
              : `Queue item ${item.id} (${item.purpose}) failed 3 attempts and will not be retried `
                + `automatically. Nothing downstream of it has been written. Last error: ${r.error ?? "unknown"}`,
            priority: "medium",
            category: item.purpose === "parse_bank_statement" ? "finances" : "admin",
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
