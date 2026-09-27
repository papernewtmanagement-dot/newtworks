// =========================================================================
// llm-queue-drainer/statement_reader.ts
// =========================================================================
// THE statement reader's text handling, prompts and checks. Pure functions:
// no database, no network — so they can be run against real statement text
// before a deploy.
//
// Since 2026-09-26 every bank, card and investment statement is read here.
// document-processor no longer reads statements itself; it queues them, and
// llm-queue-drainer reads them with these helpers. Peter's ruling: the reader
// fixes what it can on its own — fine print trimmed, flipped signs corrected,
// health savings statements summarised — instead of a person hand-editing the
// queued text. Before this date each of those was fixed by hand in the queue.
//
// What lives here:
//   prepareStatementText      trim fine print so the statement fits one pass
//   BANK_STATEMENT_PROMPT_COMPACT / parseCompactStatement
//   reclassifyCreditsFromText card refunds misread as charges
//   resignFromTrailingMinus   deposit accounts whose withdrawals print "123.45-"
//   checkStatementPeriod      catches a "next closing date" read as the period
//   investment summary        health savings: money added, growth/loss, balance
// =========================================================================

import { stripFences } from "../_shared/supabase.ts";

export type ReaderTxn = { date: string; payee: string; memo: string; amount: number };

// ---------------------------------------------------------------------------
// 1. TRIMMING
// ---------------------------------------------------------------------------

// Known issuer fine-print blocks, cut between two markers.
//
// AMEX 26-08 is 16,806 characters, of which roughly 8,700 are the same notices
// printed on every statement. None of it contains a transaction, and it was
// consuming about 2,175 tokens of a hard 8,000-token request budget on every
// call — budget the model then did not have left for its answer.
//
// SAFETY: a span is only cut when it holds almost no date-shaped text. Every
// transaction line carries a date, so a block with fewer than three of them
// cannot be hiding the detail.
const STATEMENT_BOILERPLATE_SPANS: { start: RegExp; end: RegExp }[] = [
  { start: /Late Payment Warning:/i, end: /Account Summary/i },
  { start: /Change of Address, phone number, email/i, end: /Payments and Credits Summary/i },
  // Capital One: ~8,900 chars of interest explanation and billing rights.
  { start: /How can I Avoid Paying Interest Charges/i, end: /Payments, Credits and Adjustments/i },
  // Chase: ~7,100 chars of payment/interest legalese before the activity table.
  { start: /You can pay down balances faster/i, end: /ACCOUNT ACTIVITY/i },
];

function trimKnownSpans(text: string): { text: string; removed: number } {
  const dateish = /\d{2}\/\d{2}\/\d{2}\b/g;
  let out = text;
  let removed = 0;
  for (const { start, end } of STATEMENT_BOILERPLATE_SPANS) {
    const s = start.exec(out);
    if (!s) continue;
    const rest = out.slice(s.index);
    const e = end.exec(rest);
    if (!e || e.index <= s[0].length) continue;
    const span = rest.slice(0, e.index);
    if (span.length < 300) continue;
    const dateHits = (span.match(dateish) ?? []).length;
    if (dateHits >= 3) continue;
    out = out.slice(0, s.index) + " " + out.slice(s.index + span.length);
    removed += span.length;
  }
  return { text: out, removed };
}

// Generic fine-print trimmer, added 2026-09-26. Works on ANY issuer, including
// ones nobody has written a span for yet.
//
// Every figure the reader needs is a dollar amount or sits next to one or next
// to a date: transaction lines, the account summary, the period header. Legal
// notices are long runs of prose with neither. So: find every money amount and
// every date, and cut any stretch of 900+ characters that contains none,
// keeping 200 characters on each side so a heading next to an amount
// ("Other Withdrawals", "Payments and Credits") survives.
//
// By construction it never removes an amount or a date. Measured on the real
// September 2026 statements before shipping (all amounts preserved in every
// case): agency card 15,134 -> 8,035 chars (it had failed three times with an
// empty answer), personal checking 11,448 -> 3,676, AMEX 18,230 -> 10,805,
// Chase 11,948 -> 4,579, US Bank Income 11,541 -> 3,729.
const MONEY_TOKEN = /(?<![\d.,])\$?\s?\d{1,3}(?:,\d{3})*\.\d{2}-?(?![\d%])/g;
const DATE_TOKEN =
  /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b/g;
const PROSE_MIN_GAP = 900;
const PROSE_KEEP = 200;

function trimLongProse(text: string): { text: string; removed: number } {
  const marks: [number, number][] = [];
  for (const re of [MONEY_TOKEN, DATE_TOKEN]) {
    for (const m of text.matchAll(re)) marks.push([m.index ?? 0, (m.index ?? 0) + m[0].length]);
  }
  marks.sort((a, b) => a[0] - b[0]);
  const cuts: [number, number][] = [];
  let prevEnd = 0;
  for (const [s, e] of [...marks, [text.length, text.length] as [number, number]]) {
    if (s - prevEnd >= PROSE_MIN_GAP) cuts.push([prevEnd + PROSE_KEEP, s - PROSE_KEEP]);
    prevEnd = Math.max(prevEnd, e);
  }
  let out = "";
  let cursor = 0;
  let removed = 0;
  for (const [a, b] of cuts) {
    out += text.slice(cursor, a) + " … ";
    removed += b - a;
    cursor = b;
  }
  out += text.slice(cursor);
  return { text: out, removed };
}

export function prepareStatementText(raw: string): { text: string; removed: number } {
  const a = trimKnownSpans(raw);
  const b = trimLongProse(a.text);
  return { text: b.text, removed: a.removed + b.removed };
}

// ---------------------------------------------------------------------------
// 2. BANK AND CARD STATEMENTS — prompt and parser
// ---------------------------------------------------------------------------

export const BANK_STATEMENT_PROMPT_COMPACT = `You are a parser for U.S. bank and credit card statements. You will be given the
text of one statement covering a single account. Long legal notices have been
cut out and replaced with "…".

Output PLAIN TEXT LINES ONLY. No JSON, no prose, no markdown, no code fences.
Emit exactly these line types, pipe-delimited, in this order:

PERIOD|<start YYYY-MM-DD>|<end YYYY-MM-DD>
  The period THIS statement covers. It is REQUIRED and is printed differently by
  each issuer: "Opening/Closing Date 07/23/26 - 08/22/26" (Chase), "Jul 29, 2026 -
  Aug 28, 2026" next to the card name (Capital One), a "Statement Period" line
  (US Bank), "Closing Date 09/14/26" with "Days in Billing Period: 31" (AMEX:
  the period starts the day after the previous closing, so 31 days back).
  NEVER use a "Next Closing Date" or a payment due date — those are in the
  future. The end of the period is on or just after the last transaction.
  A two-digit year is 20xx.
LAST4|<last 4 digits of the account, or NULL>
OPEN|<opening/beginning/previous balance as a number, or NULL>
  REQUIRED whenever the statement prints it. Chase and Capital One label it
  "Previous Balance", US Bank "Beginning Balance on <date>".
CLOSE|<closing/ending/new balance as a number, or NULL>
SUMCHARGES|<Account Summary total of new charges + fees + interest, or NULL>
SUMCREDITS|<Account Summary total of payments + credits, POSITIVE, or NULL>
TXN|<YYYY-MM-DD>|<KIND>|<payee>|<memo>|<amount>
...one TXN line per transaction...

KIND is exactly one letter classifying which part of the statement the line came
from. Decide this BEFORE you decide the sign:
  P = purchase / charge / fee / interest charged / withdrawal   -> amount NEGATIVE
  Y = payment made toward the account balance                  -> amount POSITIVE
  C = refund, credit, deposit, or interest paid to the account -> amount POSITIVE
  O = none of the above (use only if genuinely unclear)

SECTIONS ARE THE AUTHORITY ON KIND. Track which heading you are under
("Payments", "Credits", "New Charges", "Deposits", "Withdrawals", "Fees") and
take KIND from it, NEVER from the merchant name: an AMAZON.COM line under
"Credits" is C, while AMAZON.COM under "New Charges" is P.

Rules:
- Emit PERIOD, LAST4, OPEN, CLOSE, SUMCHARGES and SUMCREDITS exactly once each,
  before any TXN line.
- SUMCHARGES and SUMCREDITS come from the "Account Summary" block. Copy them as
  printed — never add them up from the transaction lines. Add every summary line
  that belongs on the same side:
    SUMCHARGES = "New Charges" + "Fees" + "Interest Charged" (AMEX, Chase), or
      "Transactions"/"Purchases" + "Cash Advances"/"Advances" + "Fees Charged" +
      "Interest Charged" (Capital One, US Bank cards), or "Other Withdrawals" +
      "Checks Paid" + "Card Withdrawals" (US Bank deposit accounts).
    SUMCREDITS = "Payments/Credits" (AMEX, Chase), or "Payments" + "Other
      Credits" (Capital One, US Bank cards), or "Deposits / Credits" (US Bank
      deposit accounts).
  Report both as POSITIVE numbers. Emit NULL only when there is no summary.
- Emit one TXN line for EVERY transaction line printed on the statement. Do not
  summarise, sample, or stop early. A dropped line breaks the books.
- Report a credit card's balance as a POSITIVE number (the amount owed).
- A per-cardmember subtotal ("Total for Account ...") is NOT a transaction.
- US Bank prints money OUT with a TRAILING minus ("$ 50.00-") and money IN with
  no sign. The printed minus is the authority, never the wording.
- A minus sign printed INSIDE a payments or credits section does not make the
  line a charge ("- $8.99" under Capital One credits is C, POSITIVE).
- date MUST be the TRANSACTION date, never the posting date.
- Skip beginning-balance, ending-balance and "Total" lines, and daily balance
  lists ("Balance Summary").
- Combine a multi-line description into one payee/memo pair. Append the bank's
  own notation ("CR", "AUTOPAY", "RETURNED PAYMENT") to memo.
- If memo would be empty, leave it empty: TXN|2026-07-04|P|COSTCO||-84.12
- Never put a "|" inside payee or memo.
- Repeated identical lines (same date, payee, amount) are separate transactions:
  emit one TXN line for EACH. Never merge them.
- ISO dates only. Amounts as bare numbers: no currency symbols, no thousands
  separators, no parentheses. Leading minus for money out.`;

export type ParsedStatement = {
  statement_period: { start: string; end: string } | null;
  account_last4: string | null;
  opening_balance: number | null;
  closing_balance: number | null;
  declared_charges: number | null;
  declared_credits: number | null;
  transactions: ReaderTxn[];
};

function num(s: string): number | null {
  const t = (s ?? "").trim();
  if (!t || t.toUpperCase() === "NULL") return null;
  const v = Number(t.replace(/[$,]/g, ""));
  return Number.isFinite(v) ? v : null;
}

// Returns null when no transactions were recovered.
export function parseCompactStatement(raw: string): ParsedStatement | null {
  let period: { start: string; end: string } | null = null;
  let last4: string | null = null;
  let open: number | null = null;
  let close: number | null = null;
  let declCharges: number | null = null;
  let declCredits: number | null = null;
  const txns: ReaderTxn[] = [];

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
    } else if (tag === "SUMCHARGES" && parts.length >= 2) {
      const v = num(parts[1]);
      declCharges = v === null ? null : Math.abs(v);
    } else if (tag === "SUMCREDITS" && parts.length >= 2) {
      const v = num(parts[1]);
      declCredits = v === null ? null : Math.abs(v);
    } else if (tag === "TXN" && parts.length >= 6) {
      // amount is ALWAYS last and date ALWAYS first, so a stray "|" in the memo
      // folds back into the memo instead of shifting the amount.
      const date = parts[1].trim();
      const kind = (parts[2] ?? "").trim().toUpperCase().charAt(0);
      const rawAmt = num(parts[parts.length - 1]);
      const payee = parts[3].trim();
      const memo = parts.slice(4, parts.length - 1).join(" ").trim();
      if (!date || rawAmt === null || !payee) continue;
      // KIND is authoritative over the typed minus sign. "O" keeps the model's sign.
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
    declared_charges: declCharges,
    declared_credits: declCredits,
    transactions: txns,
  };
}

// ---------------------------------------------------------------------------
// 3. SIGN REPAIRS — each is kept ONLY if the statement's own totals then tie
// ---------------------------------------------------------------------------

const MONTH_ABBR = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function amountPattern(amount: number): string {
  const [whole, cents] = Math.abs(amount).toFixed(2).split(".");
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",?")}\\.${cents}`;
}

// Card refunds misread as charges. A refund from a merchant you also buy from
// looks like a purchase by name; the statement's credits block knows better.
// Scans EVERY credits block (Capital One repeats the heading per cardmember).
export function reclassifyCreditsFromText(statementText: string, txns: ReaderTxn[]): { flipped: number; txns: ReaderTxn[] } {
  const headingRe =
    /Payments,\s*Credits\s*and\s*Adjustments|Payments\s+and\s+Other\s+Credits|Credits\s+Amount|^[ \t]*Credits[ \t]*$/gim;
  const endRe =
    /Transactions\b|New Charges|Total New Charges|Fees\s+Amount|Fees Charged|Interest Charged|Cash Advances|Purchases\s+Amount/i;

  const spans: string[] = [];
  for (const m of statementText.matchAll(headingRe)) {
    const from = (m.index ?? 0) + m[0].length;
    const rest = statementText.slice(from, from + 4000);
    const e = endRe.exec(rest);
    spans.push(e ? rest.slice(0, e.index) : rest);
  }
  if (spans.length === 0) return { flipped: 0, txns };
  const span = spans.join("\n");

  let flipped = 0;
  const out = txns.map((t) => {
    if (t.amount >= 0) return t;
    const day = String(Number(t.date.slice(8, 10)));
    const mon = MONTH_ABBR[Number(t.date.slice(5, 7)) - 1];
    const dayPat = `(?:\\b0?${day}\\/|${mon}\\s+0?${day}\\b)`;
    const near = new RegExp(`${dayPat}[^|\\n]{0,140}?\\$?${amountPattern(t.amount)}`);
    if (near.test(span)) {
      flipped += 1;
      return { ...t, amount: Math.abs(t.amount) };
    }
    return t;
  });
  return { flipped, txns: out };
}

// Deposit accounts that print money OUT with a trailing minus ("1,000.00-").
// Added 2026-09-26 after US Bank Personal Checking 26-09 came out $2,231.66
// short: the PDF text put half the withdrawals after two pages of disclosures,
// away from their "Other Withdrawals" heading, and the model signed $5,596.42 of
// them as deposits. The printed trailing minus is the bank's own answer, so read
// it from the text: find each line by its date and amount, with no other date
// in between (so one line can never borrow the next line's sign), and take the
// sign printed right after the amount. A line whose matches disagree (the same
// date and amount printed both ways) is left alone.
// Tested before shipping on that statement with EVERY sign deliberately flipped:
// all 17 lines came back correct, including a $1,000.00 transfer in on Sep 16
// and a $1,000.00 Venmo payment out on Sep 17.
const ANY_DATE_PAT =
  "(?:\\b\\d{1,2}\\/\\d{1,2}\\b|\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?\\s+\\d{1,2}\\b)";

export function resignFromTrailingMinus(text: string, txns: ReaderTxn[]): { changed: number; unresolved: number; txns: ReaderTxn[] } {
  const trailing = (text.match(/\d\.\d{2}-(?!\d)/g) ?? []).length;
  if (trailing < 2) return { changed: 0, unresolved: txns.length, txns };
  let changed = 0;
  let unresolved = 0;
  const out = txns.map((t) => {
    const month = Number(t.date.slice(5, 7));
    const day = String(Number(t.date.slice(8, 10)));
    const mon = MONTH_ABBR[month - 1];
    if (!mon) { unresolved++; return t; }
    const dayPat = `(?:\\b0?${month}\\/0?${day}\\b|\\b${mon}[a-z]*\\.?\\s+0?${day}\\b)`;
    const re = new RegExp(
      `${dayPat}(?:(?!${ANY_DATE_PAT})[\\s\\S]){0,240}?(?<![\\d.,])\\$?\\s?${amountPattern(t.amount)}(-?)(?![\\d.])`,
      "g",
    );
    const signs = new Set<number>();
    for (const m of text.matchAll(re)) signs.add(m[1] === "-" ? -1 : 1);
    if (signs.size !== 1) { unresolved++; return t; }
    const amount = [...signs][0] * Math.abs(t.amount);
    if (amount !== t.amount) changed++;
    return { ...t, amount };
  });
  return { changed, unresolved, txns: out };
}

// ---------------------------------------------------------------------------
// 4. PERIOD CHECK
// ---------------------------------------------------------------------------

// AMEX Discretionary 26-09 was stored as Sep 14 - Oct 15 2026: the model took
// "Next Closing Date 10/15/26" as the end of the period. The balances tied, so
// nothing else noticed, and the account showed a statement from the future.
// A period that ends after today, starts after it ends, or ends well past the
// last transaction is refused so the item retries instead of writing bad dates.
export function checkStatementPeriod(
  period: { start: string; end: string },
  txns: ReaderTxn[],
  todayIso: string,
): string | null {
  const iso = /^\d{4}-\d{2}-\d{2}$/;
  if (!iso.test(period.start) || !iso.test(period.end)) return `period is not in YYYY-MM-DD form (${period.start} to ${period.end})`;
  if (period.start > period.end) return `period starts after it ends (${period.start} to ${period.end})`;
  if (period.end > todayIso) return `period ends in the future (${period.end}) — a "next closing date" was probably read as the period`;
  const dates = txns.map((t) => t.date).filter((d) => iso.test(d)).sort();
  if (dates.length) {
    const lastTxn = dates[dates.length - 1];
    const gapDays = (Date.parse(period.end) - Date.parse(lastTxn)) / 86400000;
    if (gapDays > 10) return `period ends ${period.end}, ${Math.round(gapDays)} days after the last transaction (${lastTxn}) — period looks misread`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 5. INVESTMENT ACCOUNTS (health savings) — summary only
// ---------------------------------------------------------------------------

// Peter's ruling 2026-09-26: a health savings statement is read for three
// things only — money added, growth or loss, and the current balance. The
// holdings, trades, dividend reinvestments and cash-flow tables are not read.
// The Fidelity report also bundles a second, unrelated brokerage account, so
// the reader looks only at the section for this account's number.
//
// Money taken out is read too, but only so the balance still ties: a
// withdrawal must never be booked as an investment loss.
export const INVESTMENT_SUMMARY_PROMPT = `You read the account summary of ONE investment account (a health savings
account) from a brokerage statement. The statement may list several accounts;
use ONLY the account whose number ends in the digits given on the first line.

Use the figures for THIS PERIOD only, never Year-to-Date.
A "-" printed in place of a number means 0.

Output exactly these six lines and nothing else, pipe-delimited:
PERIOD|<start YYYY-MM-DD>|<end YYYY-MM-DD>
OPEN|<Beginning Account Value for this period>
ADDED|<money added this period: Additions / Contributions / deposits, positive>
TAKEN|<money taken out this period: Subtractions / Distributions / withdrawals / fees, positive>
GROWTH|<Change in Investment Value this period, negative for a loss>
CLOSE|<Ending Account Value for this period>

Bare numbers only: no dollar signs, no commas.`;

// The account's own summary sits a few pages in. Hand the model a window that
// starts at this account's number and includes its summary, not the whole
// 29,000-character report.
export function investmentWindow(text: string, last4: string | null): string {
  if (last4) {
    const re = new RegExp(`${last4}[^\\n]{0,160}?Account Summary`, "i");
    const m = re.exec(text);
    if (m) return text.slice(Math.max(0, (m.index ?? 0) - 400), (m.index ?? 0) + 2600);
  }
  return prepareStatementText(text).text.slice(0, 9000);
}

export type InvestmentSummary = {
  period: { start: string; end: string } | null;
  open: number | null;
  added: number | null;
  taken: number | null;
  growth: number | null;
  close: number | null;
};

export function parseInvestmentSummary(raw: string): InvestmentSummary {
  const out: InvestmentSummary = { period: null, open: null, added: null, taken: null, growth: null, close: null };
  for (const line of stripFences(raw).split("\n")) {
    const parts = line.trim().split("|");
    const tag = (parts[0] ?? "").trim().toUpperCase();
    if (tag === "PERIOD" && parts.length >= 3) {
      const s = parts[1].trim(), e = parts[2].trim();
      if (s && e && s.toUpperCase() !== "NULL" && e.toUpperCase() !== "NULL") out.period = { start: s, end: e };
    } else if (tag === "OPEN") out.open = num(parts[1] ?? "");
    else if (tag === "ADDED") out.added = num(parts[1] ?? "");
    else if (tag === "TAKEN") out.taken = num(parts[1] ?? "");
    else if (tag === "GROWTH") out.growth = num(parts[1] ?? "");
    else if (tag === "CLOSE") out.close = num(parts[1] ?? "");
  }
  return out;
}

// Turns the summary into at most three statement lines dated at period end.
// Refuses (returns an error) unless opening + added - taken + growth = closing
// to the cent, so a misread figure can never reach the books.
export function investmentSummaryToLines(
  s: InvestmentSummary,
  label: string,
): { ok: true; txns: ReaderTxn[]; note: string } | { ok: false; error: string } {
  if (!s.period) return { ok: false, error: "investment summary: no statement period" };
  if (s.open === null || s.close === null) return { ok: false, error: "investment summary: beginning or ending value missing" };
  const added = Math.abs(s.added ?? 0);
  const taken = Math.abs(s.taken ?? 0);
  const growth = s.growth ?? Math.round((s.close - s.open - added + taken) * 100) / 100;
  const gap = Math.round((s.open + added - taken + growth - s.close) * 100) / 100;
  if (Math.abs(gap) > 0.01) {
    return {
      ok: false,
      error: `investment summary does not tie: ${s.open} + ${added} added - ${taken} taken + ${growth} growth `
        + `= ${(s.open + added - taken + growth).toFixed(2)}, statement says ${s.close}`,
    };
  }
  const memo = `${label} ${s.period.start} to ${s.period.end}`;
  const txns: ReaderTxn[] = [];
  if (added > 0) txns.push({ date: s.period.end, payee: "Money added", memo, amount: added });
  if (taken > 0) txns.push({ date: s.period.end, payee: "Money taken out", memo, amount: -taken });
  if (Math.abs(growth) > 0.004) {
    txns.push({ date: s.period.end, payee: growth >= 0 ? "Investment growth" : "Investment loss", memo, amount: growth });
  }
  return {
    ok: true,
    txns,
    note: `investment summary ties: ${s.open} + ${added} added - ${taken} taken + ${growth} growth = ${s.close}`,
  };
}
