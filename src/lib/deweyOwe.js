import { addDaysISO, addMonthsISO } from "./weeks.js";
import { fmtMoney } from "./format.jsx";
import { fmtDate, fmtDateShort } from "./utils.js";

// ============================================================================
// Dewey Owe: the math behind the billing explainer tab (Peter 2026-09-25).
// The team types every line of a customer's SF Billing & payment history,
// newest first. This file works out what the policy costs in all, what has
// really been paid, and a plain step by step of how each bill came to be.
// No screen code here, so the math can be run and checked on its own.
//
// Peter's rules:
//  * Binder and New Business say the same thing. With both, the Binder is
//    greyed and not counted. With no New Business line, the Binder stands in.
//  * New Business and Renewal start a policy term: 6 months for auto, 12 for
//    fire. The premium is always positive, paid up front or split.
//  * Binder, New Business and Renewal force an Auto or Fire pick, and every
//    other line on the same account carries it.
//  * Policy Change and Billing Change go either way. A negative one is
//    credited all at once, right away. A positive one is split evenly over
//    the payments left in the term.
//  * Bill, AutoPay Revised Due and Notice of Cancel NonPay are SF saying what
//    is due. They move no money; each one is checked against the lines.
//  * Declined is always negative and shows in place of Paid, so a locked Paid
//    goes just before it and the two cancel out.
//  * Return is always negative and cancels the latest Paid of the same amount
//    before it, on the same account.
//  * A declined or returned payment, other than the first New Business
//    payment, draws a locked $25 Return Payment Fee.
//  * Late Payment Fee is always $25, entered by hand.
//  * Linked lines are joined by a drawn line, not by colour alone.
//  * Payment plans: monthly, 2 payments, or paid in full.
//  * One Paid line can pay for several policies. It goes on a billing account
//    (Billing 1, Billing 2 and so on) that pays for the accounts picked for it,
//    and the payment is split across them.
//
// Where the brief was silent (2026-09-25):
//  * Payments are monthly across the term unless the start line says paid in
//    full. Payment one is due the day the term starts. The rest fall on the
//    day of the month SF's first bill in the term is due, or the start day
//    when there is no bill yet.
//  * The payments left for a positive change are those due on or after the
//    change's effective date.
//  * If the team typed SF's own Return Payment Fee line, it is linked to the
//    return or decline instead of adding a second fee.
//  * Each line carries only the dates the math uses (Peter 2026-09-25, "do
//    whichever makes more sense"). Binder, New Business and Renewal: just the
//    effective date, the day the term starts. Paid, Declined, Return, the two
//    fees and Waiver: just the process date, the day it went through; they have
//    no effective or due date. Bills and changes carry both: the process date
//    says when they hit the bill, the effective or due date drives the math. A
//    cancel notice's past-due amount is as of its process date.
//  * Waiver is SF taking a fee back off: +$25 under Paid, linked to the latest
//    fee below it on the same account (Peter 2026-09-25, "1A").
//  * Order is the table's order, newest at the top, the way SF lists the lines.
//    Dates drive the math, not the order, since some lines have no process date.
//  * A billing account payment pays the oldest amount due first, across all the
//    accounts it pays for. That is the usual way a payment is applied to open
//    balances. A payment it undoes comes back off the same accounts it went to.
//  * Bills, cancel notices and fees can sit on a billing account too. A bill
//    there is checked against every account it pays for, added together.
//  * A line with no type and no amount is an empty line, even with dates in it,
//    so a date carried down to a new line never turns it into a line to check.
//  * Amounts are whole cents throughout, so nothing drifts by a penny.
// ============================================================================

export const RETURN_FEE_CENTS = 2500;
export const LATE_FEE_CENTS = 2500;
// A waiver takes one fee back off, and every fee is $25.
export const WAIVER_CENTS = 2500;
// SF's own fee line lands on the return's day or soon after.
const FEE_CLAIM_DAYS = 31;
// A bill this close to the lines counts as a match: SF rounds splits its own way.
const MATCH_CENTS = 50;

// proc: whether the process date column applies. due: whether the effective/due
// date column is required, optional, or unused. Every line has at least one date.
export const DEWEY_TYPES = [
  { key: "binder",              label: "Binder",                  col: "owed",  sign: 1,  role: "start",    proc: "none",     due: "required" },
  { key: "new_business",        label: "New Business",            col: "owed",  sign: 1,  role: "start",    proc: "none",     due: "required" },
  { key: "renewal",             label: "Renewal",                 col: "owed",  sign: 1,  role: "start",    proc: "none",     due: "required" },
  { key: "policy_change",       label: "Policy Change",           col: "owed",  sign: 0,  role: "change",   proc: "required", due: "required" },
  { key: "billing_change",      label: "Billing Change",          col: "owed",  sign: 0,  role: "change",   proc: "required", due: "required" },
  { key: "bill",                label: "Bill",                    col: "owed",  sign: 0,  role: "bill",     proc: "required", due: "required" },
  { key: "autopay_revised_due", label: "AutoPay Revised Due",     col: "owed",  sign: 0,  role: "bill",     proc: "required", due: "required" },
  { key: "notice_cancel",       label: "Notice of Cancel NonPay", col: "owed",  sign: 1,  role: "notice",   proc: "required", due: "optional" },
  { key: "paid",                label: "Paid",                    col: "paid",  sign: 1,  role: "payment",  proc: "required", due: "none" },
  { key: "declined",            label: "Declined",                col: "paid",  sign: -1, role: "declined", proc: "required", due: "none" },
  { key: "return",              label: "Return",                  col: "paid",  sign: -1, role: "return",   proc: "required", due: "none" },
  { key: "return_fee",          label: "Return Payment Fee",      col: "paid",  sign: -1, role: "fee",      proc: "required", due: "none", fixed: RETURN_FEE_CENTS },
  { key: "late_fee",            label: "Late Payment Fee",        col: "paid",  sign: -1, role: "fee",      proc: "required", due: "none", fixed: LATE_FEE_CENTS },
  { key: "waiver",              label: "Waiver",                  col: "paid",  sign: 1,  role: "waiver",   proc: "required", due: "none", fixed: WAIVER_CENTS },
];
const TYPE = Object.fromEntries(DEWEY_TYPES.map(t => [t.key, t]));
export const deweyType = (k) => TYPE[k] || null;
export const isStartType = (k) => TYPE[k]?.role === "start";

export const DEWEY_LOBS = [
  { key: "auto", label: "Auto", months: 6 },
  { key: "fire", label: "Fire", months: 12 },
];
const LOB = Object.fromEntries(DEWEY_LOBS.map(l => [l.key, l]));
export const DEWEY_PLANS = [
  { key: "monthly", label: "Monthly" },
  { key: "two",     label: "2 payments" },
  { key: "full",    label: "Paid in full" },
];
const payCount = (plan, months) => (plan === "full" ? 1 : plan === "two" ? 2 : months);

// Accounts are numbers (Account 1). Billing accounts are "B1", "B2" (Billing 1).
export const isBillingKey = (k) => typeof k === "string" && /^B\d+$/.test(k);
export const accountLabel = (k) => (isBillingKey(k) ? `Billing ${k.slice(1)}` : `Account ${k}`);
export function normalizeAccountKey(k) {
  if (isBillingKey(k)) return k;
  const n = Number(k);
  return Number.isInteger(n) && n > 0 ? n : 1;
}

// ---------- rows ----------
export function newRowId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
}
export function blankRow(account = 1) {
  return { id: newRowId(), type: "", processDate: "", amount: "", dueDate: "", account };
}
export function isBlankRow(r) {
  return !r || (!r.type && !String(r.amount ?? "").trim());
}

// "$1,234.50", "(12)", "-12", "−12" all read. Returns whole cents, or null.
export function parseCents(v) {
  if (v === null || v === undefined) return null;
  let s = String(v).trim().replace(/[$,\s]/g, "").replace(/[\u2212\u2013\u2014]/g, "-");
  const paren = /^\((.*)\)$/.exec(s);
  if (paren) s = `-${paren[1]}`;
  if (s === "" || s === "-" || s === "." || s === "-.") return null;
  const n = Number(s);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

// A line's amount in cents with its type's sign applied. The fees are fixed.
export function rowCents(row) {
  const t = TYPE[row?.type];
  if (!t) return null;
  if (t.fixed) return t.sign * t.fixed;
  const c = parseCents(row.amount);
  if (c === null) return null;
  if (t.sign === 1) return Math.abs(c);
  if (t.sign === -1) return -Math.abs(c);
  return c;
}

// The date a line goes by: its process date, or its effective date for the
// lines that have no process date.
export function lineDate(r) {
  if (!r) return "";
  return (TYPE[r.type]?.proc === "none" ? r.dueDate : r.processDate) || r.processDate || r.dueDate || "";
}

// A locked line takes its date in whichever box its own type uses.
function datedAs(type, date) {
  return TYPE[type]?.proc === "none" ? { processDate: "", dueDate: date } : { processDate: date, dueDate: "" };
}

// What the amount box should read once the line's type has had its say.
export function tidyAmount(row) {
  const c = rowCents(row);
  if (c === null) return row?.amount ?? "";
  return (c / 100).toFixed(2);
}

// ---------- helpers ----------
// A grid amount: 1,234.56 with no dollar sign. The sign is shown by the caller.
export function fmtAmount(c) {
  return (Math.abs(c) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
const $ = (c) => fmtMoney(Math.abs(c) / 100, { decimals: 2 });
const $s = (c) => (c < 0 ? `\u2212${$(c)}` : $(c));
function when(iso, today) {
  if (!iso) return "";
  return iso.slice(0, 4) === String(today || "").slice(0, 4) ? fmtDateShort(iso) : fmtDate(iso);
}
function andList(words) {
  if (words.length < 2) return words.join("");
  return `${words.slice(0, -1).join(", ")} and ${words[words.length - 1]}`;
}
// n shares adding back to the total exactly; the first carries the odd cents.
function split(total, n) {
  if (n <= 0) return [];
  const sign = total < 0 ? -1 : 1;
  const abs = Math.abs(total);
  const base = Math.floor(abs / n);
  const rem = abs - base * n;
  return Array.from({ length: n }, (_, k) => sign * (base + (k === 0 ? rem : 0)));
}
// Earliest first: the table read from the bottom up, the way SF lists the lines.
function chronoSort(list) {
  return list.filter(r => !isBlankRow(r)).reverse();
}

// One account's policy terms. A counted start line opens each term. Lines
// dated before the first start belong to the first term.
function splitTerms(aRows) {
  const hasNB = aRows.some(r => r.type === "new_business");
  const counts = (r) => r.type === "new_business" || r.type === "renewal" || (r.type === "binder" && !hasNB);
  const terms = [];
  const before = [];
  for (const r of aRows) {
    if (counts(r)) terms.push({ start: r, rows: [] });
    else if (r.type === "binder") continue;
    else if (terms.length) terms[terms.length - 1].rows.push(r);
    else before.push(r);
  }
  if (terms.length) terms[0].rows.unshift(...before);
  const first = terms[0];
  const firstNB = first && (first.start.type === "new_business" || first.start.type === "binder")
    ? first.rows.find(r => r.type === "paid") : null;
  return { hasNB, terms, firstNBPaymentId: firstNB ? firstNB.id : null };
}

// ============================================================================
// buildLedger: the table as it should be drawn. Adds the locked lines (the
// Paid behind each Declined, the fee behind each return or decline), links
// each return or decline to its payment and fee, and gives every link its own
// lane so the drawn lines never sit on top of each other.
// ============================================================================
export function buildLedger(rows) {
  const list = Array.isArray(rows) ? rows : [];
  const display = [];
  const groups = [];

  for (const r of list) {
    display.push(r);
    if (r.type !== "declined") continue;
    const c = rowCents(r);
    if (!c) continue;
    const paid = {
      id: `${r.id}~paid`, auto: "paid", sourceId: r.id, type: "paid",
      ...datedAs("paid", lineDate(r)), account: r.account, amount: (-c / 100).toFixed(2),
    };
    display.push(paid);
    groups.push({ id: `g~${r.id}`, kind: "declined", sourceId: r.id, paymentId: paid.id, feeId: null, members: [r.id, paid.id] });
  }

  let chrono = chronoSort(display);
  const pos = new Map(chrono.map((r, k) => [r.id, k]));

  const claimed = new Set();
  for (const r of chrono) {
    if (r.type !== "return") continue;
    const c = rowCents(r);
    if (!c) continue;
    let match = null;
    for (let k = pos.get(r.id) - 1; k >= 0; k--) {
      const q = chrono[k];
      if (q.auto || q.type !== "paid" || q.account !== r.account || claimed.has(q.id)) continue;
      if (rowCents(q) === -c) { match = q; break; }
    }
    if (match) claimed.add(match.id);
    groups.push({ id: `g~${r.id}`, kind: "return", sourceId: r.id, paymentId: match ? match.id : null, feeId: null,
      members: match ? [r.id, match.id] : [r.id] });
  }

  const info = new Map();
  const perAcct = new Map();
  for (const r of chrono) {
    if (!perAcct.has(r.account)) perAcct.set(r.account, []);
    perAcct.get(r.account).push(r);
  }
  for (const [a, aRows] of perAcct) info.set(a, splitTerms(aRows));

  // Fees, earliest return or decline first so each takes the right SF fee line.
  const byId = new Map(display.map(r => [r.id, r]));
  const feeTaken = new Set();
  const ordered = [...groups].sort((x, y) => (pos.get(x.sourceId) ?? 0) - (pos.get(y.sourceId) ?? 0));
  for (const g of ordered) {
    const src = byId.get(g.sourceId);
    const firstPay = info.get(src.account)?.firstNBPaymentId || null;
    if (g.paymentId && g.paymentId === firstPay) { g.firstPayment = true; continue; }
    const srcDate = lineDate(src);
    if (srcDate) {
      const hi = addDaysISO(srcDate, FEE_CLAIM_DAYS);
      const typed = chrono.find(q => !q.auto && q.type === "return_fee" && q.account === src.account && !feeTaken.has(q.id)
        && lineDate(q) >= srcDate && lineDate(q) <= hi);
      if (typed) {
        feeTaken.add(typed.id);
        g.feeId = typed.id;
        g.members.push(typed.id);
        continue;
      }
    }
    const fee = {
      id: `${src.id}~fee`, auto: "fee", sourceId: src.id, type: "return_fee",
      ...datedAs("return_fee", srcDate), account: src.account, amount: "-25.00",
    };
    display.splice(display.indexOf(src), 0, fee);   // just above: it came after
    g.feeId = fee.id;
    g.members.push(fee.id);
  }

  chrono = chronoSort(display);

  // A Waiver takes back the latest fee below it on the same account.
  const cpos = new Map(chrono.map((r, k) => [r.id, k]));
  const waived = new Set();
  const waivers = [];
  for (const r of chrono) {
    if (r.type !== "waiver") continue;
    let fee = null;
    for (let k = cpos.get(r.id) - 1; k >= 0; k--) {
      const q = chrono[k];
      if ((q.type === "return_fee" || q.type === "late_fee") && q.account === r.account && !waived.has(q.id)) { fee = q; break; }
    }
    if (fee) waived.add(fee.id);
    waivers.push({ id: `w~${r.id}`, kind: "waiver", sourceId: r.id, feeId: fee ? fee.id : null, members: fee ? [r.id, fee.id] : [r.id] });
  }
  const waiverOf = new Map(waivers.map(w => [w.sourceId, w]));

  const at = new Map(display.map((r, i) => [r.id, i]));
  const linked = [...groups, ...waivers].filter(g => g.members.length > 1);
  for (const g of linked) {
    const ix = g.members.map(id => at.get(id));
    g.top = Math.min(...ix);
    g.bottom = Math.max(...ix);
  }
  linked.sort((x, y) => x.top - y.top || y.bottom - x.bottom);
  const laneEnds = [];
  linked.forEach((g, i) => {
    let lane = laneEnds.findIndex(end => end < g.top);
    if (lane === -1) { lane = laneEnds.length; laneEnds.push(g.bottom); } else laneEnds[lane] = g.bottom;
    g.lane = lane;
    g.colorIndex = i;
  });
  const groupOf = new Map();
  for (const g of groups) for (const id of g.members) groupOf.set(id, g);

  return {
    display, chrono, groups, linked, laneCount: laneEnds.length, groupOf, waiverOf, info,
    byId: new Map(display.map(r => [r.id, r])),
  };
}

// The date a line is ordered by. Start lines have none: their effective date can
// sit well after the lines SF lists above them (a renewal is processed about a
// month before it starts), so they stay where the team put them.
function orderDate(r) {
  if (isBlankRow(r) || TYPE[r.type]?.role === "start") return "";
  return lineDate(r);
}

// Lines dated newer than the dated line above them.
export function outOfOrderIds(rows) {
  const bad = [];
  let above = null;
  for (const r of rows || []) {
    const d = orderDate(r);
    if (!d) continue;
    if (above && d > above) bad.push(r.id);
    above = d;
  }
  return bad;
}

// Newest first. A line with no date to order by (a start line, an empty line)
// travels with the dated line above it, so it keeps its place beside it.
export function sortRowsByDate(rows) {
  const chunks = [];
  for (const r of rows) {
    const d = orderDate(r);
    if (d || !chunks.length) chunks.push({ d, rows: [r] });
    else chunks[chunks.length - 1].rows.push(r);
  }
  const lead = chunks[0] && !chunks[0].d ? [chunks.shift()] : [];
  const sorted = chunks.map((c, i) => ({ ...c, i }))
    .sort((a, b) => (a.d === b.d ? a.i - b.i : a.d < b.d ? 1 : -1));
  return [...lead, ...sorted].flatMap(c => c.rows);
}

// ============================================================================
// explainBilling: the step by step and the bottom line.
// accounts: { [n]: { lob: "auto" | "fire", plan: "monthly" | "two" | "full" },
//             ["Bn"]: { covers: [account numbers] } }
// Returns sections: each billing account first (the bill the customer sees),
// then each account.
// ============================================================================
export function explainBilling({ rows, accounts, today }) {
  const L = buildLedger(rows);
  const meta = accounts || {};
  const problems = [];
  const warnings = [];
  const label = (k) => TYPE[k]?.label || "line";

  for (const r of L.display) {
    if (r.auto || isBlankRow(r)) continue;
    const t = TYPE[r.type];
    const on = lineDate(r) ? ` on ${when(lineDate(r), today)}` : "";
    const miss = [];
    if (!t) miss.push("type");
    if (t && t.proc === "required" && !r.processDate) miss.push("process date");
    if (t && !t.fixed && rowCents(r) === null) miss.push("amount");
    if (t && t.due === "required" && !r.dueDate) miss.push(t.role === "bill" ? "due date" : "effective date");
    if (miss.length) problems.push({ rowId: r.id, text: `${t ? t.label : "A line"}${on} needs its ${andList(miss)}.` });
    if (t && isBillingKey(r.account) && (t.role === "start" || t.role === "change")) {
      problems.push({ rowId: r.id, text: `${t.label}${on} goes on the account it is for, not on ${accountLabel(r.account)}.` });
    }
  }

  const keys = [...L.info.keys()];
  const billingKeys = keys.filter(isBillingKey).sort((x, y) => Number(x.slice(1)) - Number(y.slice(1)));
  const coversOf = (b) => [...new Set((Array.isArray(meta[b]?.covers) ? meta[b].covers : [])
    .map(Number).filter(n => Number.isInteger(n) && n > 0))].sort((x, y) => x - y);
  const policySet = new Set(keys.filter(k => !isBillingKey(k)));
  for (const b of billingKeys) for (const a of coversOf(b)) policySet.add(a);
  const policyKeys = [...policySet].sort((x, y) => x - y);

  if (!keys.length) problems.push({ text: "Enter the lines from SF's Billing & payment history first." });
  for (const b of billingKeys) {
    if (!coversOf(b).length) problems.push({ account: b, text: `Pick the accounts ${accountLabel(b)} pays for.` });
  }
  for (const a of policyKeys) {
    const inf = L.info.get(a);
    if (!inf || !inf.terms.length) {
      problems.push({ account: a, text: `${accountLabel(a)} needs its New Business or Renewal line. Keep going back in SF's history until you reach one.` });
      continue;
    }
    if (!LOB[meta[a]?.lob]) {
      problems.push({ account: a, rowId: inf.terms[0].start.id,
        text: `Pick Auto or Fire on ${accountLabel(a)}'s ${label(inf.terms[0].start.type)} line.` });
    }
  }
  for (const g of L.groups) {
    if (g.kind !== "return" || g.paymentId) continue;
    const r = L.byId.get(g.sourceId);
    warnings.push({ rowId: r.id,
      text: `No ${$(rowCents(r))} payment shows below the ${when(lineDate(r), today)} Return. The payment it undoes may be further back.` });
  }
  for (const w of L.waiverOf.values()) {
    if (w.feeId) continue;
    const r = L.byId.get(w.sourceId);
    warnings.push({ rowId: r.id,
      text: `No fee shows below the ${when(lineDate(r), today)} Waiver. The fee it takes back may be further back.` });
  }
  if (problems.length) return { ok: false, problems, warnings, sections: [], ledger: L };

  // ---------- the schedule for every account ----------
  // A policy's payment day comes from the first bill due after its term starts:
  // its own bills, or bills on a billing account that pays for it.
  const billsFor = (a) => L.chrono.filter(r => (r.type === "bill" || r.type === "autopay_revised_due") && r.dueDate
    && (r.account === a || (isBillingKey(r.account) && coversOf(r.account).includes(a))));
  const S = new Map();
  for (const a of policyKeys) {
    const lob = LOB[meta[a].lob];
    const plan = DEWEY_PLANS.find(p => p.key === meta[a].plan) || DEWEY_PLANS[0];
    const nPay = payCount(plan.key, lob.months);
    const gap = lob.months / nPay;
    const bills = billsFor(a);
    const terms = L.info.get(a).terms.map(tm => {
      const start = tm.start.dueDate || tm.start.processDate;
      const P = rowCents(tm.start);
      const firstBill = bills.find(r => r.dueDate > start);
      const day = Number((firstBill ? firstBill.dueDate : start).slice(8, 10));
      const dates = Array.from({ length: nPay }, (_, k) => (k === 0 ? start : addMonthsISO(start, k * gap, day)));
      return { start: tm.start, S: start, P, end: addMonthsISO(start, lob.months), dates, amts: split(P, nPay) };
    });
    S.set(a, {
      key: a, lob, plan, nPay, gap, terms, termByStart: new Map(terms.map(t => [t.start.id, t])), hasNB: L.info.get(a).hasNB,
      cur: null, premium: 0, changesNet: 0, credits: 0, paid: 0, paidIn: 0, reversed: 0, oneTime: [], steps: [], ev: [],
    });
  }
  const Bs = new Map();
  for (const b of billingKeys) {
    Bs.set(b, { key: b, covers: coversOf(b), fees: [], paidB: 0, paidIn: 0, reversed: 0, steps: [], ev: [], splits: new Map() });
  }

  const sumC = (list, kind) => list.reduce((s, o) => s + (!kind || o.kind === kind ? o.cents : 0), 0);
  const dueBy = (st, cutoff) => st.terms.reduce((s, t) => s + t.dates.reduce((x, d, k) => x + (d <= cutoff ? t.amts[k] : 0), 0), 0);
  // What the account should have paid by the cutoff, less what it has.
  const expectedOf = (st, cutoff) => dueBy(st, cutoff) + sumC(st.oneTime) + st.credits - st.paid;
  // The amounts still unpaid, oldest first, once `applied` has paid the oldest ones.
  // A minus item (a waiver with no fee to take back) pays down the oldest ones too.
  const unpaidOf = (items, applied) => {
    const sorted = items.filter(it => it.cents > 0).sort((x, y) => (x.date < y.date ? -1 : x.date > y.date ? 1 : 0));
    let left = Math.max(0, applied - items.reduce((s, it) => s + (it.cents < 0 ? it.cents : 0), 0));
    const out = [];
    for (const it of sorted) {
      const use = Math.min(left, it.cents);
      left -= use;
      if (it.cents - use > 0) out.push({ date: it.date, cents: it.cents - use });
    }
    return out;
  };
  const itemsOf = (st) => [
    ...st.terms.flatMap(t => t.dates.map((d, k) => ({ date: d, cents: t.amts[k] }))),
    ...st.oneTime.map(o => ({ date: o.date, cents: o.cents })),
  ];
  // A billing payment pays the oldest amount due first, across its accounts.
  // Paying more than everything left sits with the first account as a credit.
  const allocate = (bs, cents) => {
    const pool = [];
    unpaidOf(bs.fees, bs.paidB).forEach(it => pool.push({ ...it, key: "fees", ord: 0 }));
    bs.covers.forEach((a, i) => {
      const st = S.get(a);
      unpaidOf(itemsOf(st), st.paid - st.credits).forEach(it => pool.push({ ...it, key: a, ord: i + 1 }));
    });
    pool.sort((x, y) => (x.date < y.date ? -1 : x.date > y.date ? 1 : x.ord - y.ord));
    const shares = new Map();
    let left = cents;
    for (const it of pool) {
      if (left <= 0) break;
      const use = Math.min(left, it.cents);
      shares.set(it.key, (shares.get(it.key) || 0) + use);
      left -= use;
    }
    if (left > 0) shares.set(bs.covers[0], (shares.get(bs.covers[0]) || 0) + left);
    return shares;
  };
  // A return with no payment found comes back off each account in step with what it has paid.
  const spreadBack = (bs, cents) => {
    const w = [["fees", Math.max(0, bs.paidB)], ...bs.covers.map(a => [a, Math.max(0, S.get(a).paid)])].filter(([, v]) => v > 0);
    const out = new Map();
    if (!w.length) { out.set(bs.covers[0], cents); return out; }
    const total = w.reduce((s, [, v]) => s + v, 0);
    let given = 0;
    w.forEach(([k, v], i) => {
      const share = i === w.length - 1 ? cents - given : Math.round(cents * v / total);
      out.set(k, share);
      given += share;
    });
    return out;
  };
  const applyShares = (bs, shares, sign) => {
    for (const [k, v] of shares) {
      if (k === "fees") { bs.paidB += sign * v; continue; }
      const st = S.get(k);
      st.paid += sign * v;
      if (sign > 0) st.paidIn += v; else st.reversed += v;
    }
  };
  const shareText = (shares, word) => {
    const bits = [...shares].filter(([, v]) => v).map(([k, v]) => `${$(v)} ${word} ${k === "fees" ? "the fees" : accountLabel(k)}`);
    return bits.length ? `${andList(bits)}.` : "";
  };
  const feeLines = (g) => (!g ? []
    : g.firstPayment ? ["No return payment fee. It was the first New Business payment."]
    : g.feeId ? [`That adds a ${$(RETURN_FEE_CENTS)} return payment fee.`] : []);
  const billStep = (base, r, t, c, eq, diff) => {
    const due = r.dueDate ? `, due ${when(r.dueDate, today)}` : "";
    const head = t.role === "notice"
      ? `Cancel notice: ${$(c)} past due${r.dueDate ? `, to be paid by ${when(r.dueDate, today)}` : ""}.`
      : c < 0 ? `SF shows a ${$(c)} credit${due}.`
      : r.type === "bill" ? `SF billed ${$(c)}${due}.`
      : `SF changed the amount due to ${$(c)}${due}.`;
    const ok = Math.abs(diff) <= MATCH_CENTS;
    return { ...base, tone: ok ? "match" : "off", text: head, sub: [eq, ok ? "Matches SF."
      : `SF's number is ${$(diff)} ${diff > 0 ? "more" : "less"} than these lines add up to. A line may be missing, or SF spread a change its own way.`] };
  };

  // A waiver takes its fee back off the list of what is owed. With no fee
  // found, it goes on the list as a fee of minus $25, which works as a credit.
  const waive = (fees, r, c, base, onCredit) => {
    const w = L.waiverOf.get(r.id);
    const fee = w && w.feeId ? L.byId.get(w.feeId) : null;
    const i = fee ? fees.findIndex(o => o.id === fee.id) : -1;
    if (i >= 0) fees.splice(i, 1); else onCredit(c);
    return { ...base, tone: "good", text: fee
      ? `Waiver. SF took back the ${$(c)} ${fee.type === "late_fee" ? "late payment fee" : "return payment fee"} from ${when(lineDate(fee), today)}.`
      : `Waiver. SF took ${$(c)} in fees back off.` };
  };

  const feeName = (r) => (r.type === "late_fee" ? "Late fee" : "Return fee");
  // SF's own amount goes in the grid on the day it is due (a cancel notice on
  // the day it was sent), checked against what the lines add up to.
  const sfEvent = (r, t, c, expected) => ({
    date: t.role === "notice" ? r.processDate : (r.dueDate || r.processDate),
    label: t.role === "notice" ? "Cancel notice" : null, tone: "bounce",
    sf: { cents: c, expected, ok: Math.abs(c - expected) <= MATCH_CENTS, revised: r.type === "autopay_revised_due" },
  });

  // ---------- one line on an account ----------
  const walkPolicy = (st, r, t, c, base) => {
    if (r.type === "binder" && st.hasNB) {
      st.steps.push({ ...base, tone: "muted", text: "Binder. Same as the New Business line, so it is not counted." });
      return;
    }
    if (st.termByStart.has(r.id)) {
      st.cur = st.termByStart.get(r.id);
      st.premium += st.cur.P;
      const sub = [st.nPay === 1
        ? `Paid in full: one payment of ${$(st.cur.P)}.`
        : st.nPay === 2
          ? `Split into 2 payments of about ${$(st.cur.amts[1])}, ${st.gap} months apart.`
          : `Split into ${st.nPay} monthly payments of about ${$(st.cur.amts[st.nPay - 1])}.`];
      if (r.type === "binder") sub.unshift("There is no New Business line, so the Binder counts as the start.");
      st.steps.push({ ...base, tone: "start",
        text: `${label(r.type)}. ${st.lob.label} policy, ${$(st.cur.P)} for ${st.lob.months} months, starting ${when(st.cur.S, today)}.`, sub });
      st.ev.push({ date: st.cur.S, label: `${label(r.type)} ${fmtAmount(st.cur.P)}`, tone: "start" });
      return;
    }
    const term = st.cur || st.terms[0];
    switch (t.role) {
      case "change": {
        st.changesNet += c;
        const nm = r.type === "policy_change" ? "Policy change" : "Billing change";
        const why = r.type === "billing_change" ? " A correction to the bill." : "";
        const E = r.dueDate || r.processDate;
        if (c > 0) st.ev.push({ date: E, label: `${nm} +${fmtAmount(c)}`, tone: "change" });
        if (c < 0) st.ev.push({ date: E, label: `${nm} \u2212${fmtAmount(c)}`, tone: "credit", due: c });
        if (c > 0) {
          const left = term.dates.map((d, k) => (d >= E ? k : -1)).filter(k => k >= 0);
          if (left.length) {
            const shares = split(c, left.length);
            left.forEach((k, j) => { term.amts[k] += shares[j]; });
            st.steps.push({ ...base, text: `${nm} added ${$(c)}.${why}`, sub: [left.length === 1
              ? `One payment left, so it all goes on that one. It is now ${$(term.amts[left[0]])}.`
              : `Split over the ${left.length} payments left: about ${$(shares[shares.length - 1])} more on each. Payments are now about ${$(term.amts[left[left.length - 1]])}.`] });
          } else {
            st.ev[st.ev.length - 1].due = c;
            st.oneTime.push({ date: lineDate(r), cents: c, kind: "extra" });
            st.steps.push({ ...base, text: `${nm} added ${$(c)}.${why}`, sub: ["No payments left in this term, so it is due all at once."] });
          }
        } else if (c < 0) {
          st.credits += c;
          st.steps.push({ ...base, text: `${nm} took off ${$(c)}.${why}`, sub: ["Credited all at once, right away."] });
        } else {
          st.steps.push({ ...base, tone: "muted", text: `${nm} for ${$(0)}. The cost did not move.` });
        }
        break;
      }
      case "payment": {
        st.paid += c;
        st.paidIn += c;
        if (!r.auto) st.steps.push({ ...base, tone: "good", text: `Paid ${$(c)}.`, sub: [`Paid so far: ${$s(st.paid)}.`] });
        if (!r.auto) st.ev.push({ date: lineDate(r), paid: c, bucket: true });
        break;
      }
      case "declined": {
        st.paid += c;
        st.reversed -= c;
        st.steps.push({ ...base, tone: "warn", text: `A ${$(c)} payment was declined. It never went through.`, sub: feeLines(L.groupOf.get(r.id)) });
        st.ev.push({ date: lineDate(r), label: `Declined ${fmtAmount(c)}`, tone: "bounce" });
        break;
      }
      case "return": {
        st.paid += c;
        st.reversed -= c;
        const g = L.groupOf.get(r.id);
        const m = g && g.paymentId ? L.byId.get(g.paymentId) : null;
        st.steps.push({ ...base, tone: "warn",
          text: m ? `The ${$(c)} payment from ${when(lineDate(m), today)} came back. It no longer counts as paid.`
                  : `A ${$(c)} payment came back. It no longer counts as paid.`,
          sub: feeLines(g) });
        st.ev.push({ date: lineDate(r), label: `Returned ${fmtAmount(c)}`, tone: "bounce", paid: c });
        break;
      }
      case "waiver": {
        st.steps.push(waive(st.oneTime, r, c, base, (v) => st.oneTime.push({ id: r.id, date: lineDate(r), cents: -v, kind: "fee" })));
        st.ev.push({ date: lineDate(r), label: `Waiver \u2212${fmtAmount(c)}`, tone: "credit", due: -c });
        break;
      }
      case "fee": {
        st.oneTime.push({ id: r.id, date: lineDate(r), cents: -c, kind: "fee" });
        st.ev.push({ date: lineDate(r), label: `${feeName(r)} ${fmtAmount(c)}`, tone: "fee", due: -c });
        if (!L.groupOf.get(r.id)) {
          st.steps.push({ ...base, tone: "warn", text: `${r.type === "late_fee" ? "Late payment fee" : "Return payment fee"}: ${$(c)}.` });
        }
        break;
      }
      case "bill":
      case "notice": {
        const cutoff = t.role === "notice" ? r.processDate : (r.dueDate || r.processDate);
        const inst = dueBy(st, cutoff);
        const fees = sumC(st.oneTime, "fee");
        const extras = sumC(st.oneTime, "extra");
        const parts = [`${$(inst)} in payments`];
        if (fees > 0) parts.push(`+ ${$(fees)} in fees`);
        if (fees < 0) parts.push(`\u2212 ${$(fees)} in fees waived`);
        if (extras) parts.push(`+ ${$(extras)} in changes`);
        if (st.credits) parts.push(`\u2212 ${$(st.credits)} in credits`);
        parts.push(st.paid >= 0 ? `\u2212 ${$(st.paid)} paid` : `+ ${$(st.paid)} came back`);
        const expected = expectedOf(st, cutoff);
        st.steps.push(billStep(base, r, t, c,
          `${t.role === "notice" ? "Past due as of" : "By"} ${when(cutoff, today)}: ${parts.join(" ")} = ${$s(expected)}.`, c - expected));
        st.ev.push(sfEvent(r, t, c, expected));
        break;
      }
      default:
        break;
    }
  };

  // ---------- one line on a billing account ----------
  const walkBilling = (bs, r, t, c, base) => {
    const g = L.groupOf.get(r.id);
    switch (t.role) {
      case "payment": {
        const shares = allocate(bs, c);
        bs.splits.set(r.id, shares);
        applyShares(bs, shares, 1);
        bs.paidIn += c;
        if (r.auto) break;
        bs.steps.push({ ...base, tone: "good", text: `Paid ${$(c)}.`, sub: [`Split, oldest amount due first: ${shareText(shares, "to")}`] });
        bs.ev.push({ date: lineDate(r), paid: c, bucket: true });
        for (const [k, v] of shares) {
          if (k === "fees" || !v) continue;
          const st = S.get(k);
          st.steps.push({ ...base, tone: "good", text: `${$(v)} of a ${$(c)} ${accountLabel(bs.key)} payment came here.`, sub: [`Paid so far: ${$s(st.paid)}.`] });
          st.ev.push({ date: lineDate(r), paid: v, bucket: true, via: bs.key });
        }
        break;
      }
      case "declined": {
        const shares = g && g.paymentId ? bs.splits.get(g.paymentId) : null;
        if (shares) applyShares(bs, shares, -1);
        bs.reversed -= c;
        bs.steps.push({ ...base, tone: "warn", text: `A ${$(c)} payment was declined. It never went through.`, sub: feeLines(g) });
        bs.ev.push({ date: lineDate(r), label: `Declined ${fmtAmount(c)}`, tone: "bounce" });
        break;
      }
      case "return": {
        const m = g && g.paymentId ? L.byId.get(g.paymentId) : null;
        const shares = (m && bs.splits.get(m.id)) || spreadBack(bs, -c);
        applyShares(bs, shares, -1);
        bs.reversed -= c;
        bs.steps.push({ ...base, tone: "warn",
          text: m ? `The ${$(c)} payment from ${when(lineDate(m), today)} came back. It no longer counts as paid.`
                  : `A ${$(c)} payment came back. It no longer counts as paid.`,
          sub: [`Taken back: ${shareText(shares, "from")}`, ...feeLines(g)] });
        bs.ev.push({ date: lineDate(r), label: `Returned ${fmtAmount(c)}`, tone: "bounce", paid: c });
        for (const [k, v] of shares) {
          if (k === "fees" || !v) continue;
          const st = S.get(k);
          st.steps.push({ ...base, tone: "warn", text: `A ${accountLabel(bs.key)} payment came back. ${$(v)} of it comes off here.`, sub: [`Paid so far: ${$s(st.paid)}.`] });
          st.ev.push({ date: lineDate(r), label: `${accountLabel(bs.key)} payment returned`, tone: "bounce", paid: -v, via: bs.key });
        }
        break;
      }
      case "waiver": {
        bs.steps.push(waive(bs.fees, r, c, base, (v) => bs.fees.push({ id: r.id, date: lineDate(r), cents: -v, kind: "fee" })));
        bs.ev.push({ date: lineDate(r), label: `Waiver \u2212${fmtAmount(c)}`, tone: "credit", due: -c });
        break;
      }
      case "fee": {
        bs.fees.push({ id: r.id, date: lineDate(r), cents: -c, kind: "fee" });
        bs.ev.push({ date: lineDate(r), label: `${feeName(r)} ${fmtAmount(c)}`, tone: "fee", due: -c });
        if (!g) bs.steps.push({ ...base, tone: "warn", text: `${r.type === "late_fee" ? "Late payment fee" : "Return payment fee"}: ${$(c)}.` });
        break;
      }
      case "bill":
      case "notice": {
        const cutoff = t.role === "notice" ? r.processDate : (r.dueDate || r.processDate);
        const per = bs.covers.map(a => [a, expectedOf(S.get(a), cutoff)]);
        const feesOut = sumC(bs.fees) - bs.paidB;
        const expected = per.reduce((s, [, v]) => s + v, 0) + feesOut;
        const parts = per.map(([a, v]) => `${accountLabel(a)} ${$s(v)}`);
        if (feesOut) parts.push(`${$s(feesOut)} in fees`);
        bs.steps.push(billStep(base, r, t, c,
          `${t.role === "notice" ? "Past due as of" : "By"} ${when(cutoff, today)}: ${parts.join(" + ")} = ${$s(expected)}.`, c - expected));
        bs.ev.push(sfEvent(r, t, c, expected));
        break;
      }
      default:
        break;
    }
  };

  for (const r of L.chrono) {
    const t = TYPE[r.type];
    if (!t) continue;
    const c = rowCents(r);
    const base = { rowId: r.id, date: lineDate(r) };
    if (isBillingKey(r.account)) {
      const bs = Bs.get(r.account);
      if (bs) walkBilling(bs, r, t, c, base);
    } else {
      const st = S.get(r.account);
      if (st) walkPolicy(st, r, t, c, base);
    }
  }

  // ---------- the grid: dates across, what was due, paid and still owed ----------
  // Peter 2026-09-25: the answer is a small grid like his spreadsheet, not a lot
  // of reading. One column per date that matters: every payment due date, and
  // the day of each change, fee, waiver, bounced payment and SF bill. A payment
  // lands in the first column on or after the day it was made. Today gets a
  // column, and Total ends the row.
  const installmentsOf = (st) => st.terms.flatMap(t => t.dates.map((d, k) => ({ date: d, cents: t.amts[k] })));
  const buildGrid = (installments, events) => {
    const cols = new Map();
    const col = (d) => {
      if (!cols.has(d)) cols.set(d, { date: d, labels: [], due: 0, paid: 0, sf: [], hasDue: false, hasPaid: false });
      return cols.get(d);
    };
    for (const it of installments) { const c = col(it.date); c.due += it.cents; c.hasDue = true; }
    for (const e of events) if (e.date && !e.bucket) col(e.date);
    const firstDate = [...cols.keys()].sort()[0];
    if (!firstDate || today >= firstDate) col(today);
    const ordered = () => [...cols.values()].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
    for (const e of events) {
      if (!e.date) continue;
      const c = (e.bucket ? ordered().find(x => x.date >= e.date) : cols.get(e.date)) || col(e.date);
      if (e.label) c.labels.push({ text: e.label, tone: e.tone || "" });
      if (e.due) { c.due += e.due; c.hasDue = true; }
      if (e.paid) { c.paid += e.paid; c.hasPaid = true; }
      if (e.sf) c.sf.push(e.sf);
    }
    let run = 0;
    let dueAll = 0;
    let paidAll = 0;
    const out = ordered().map(c => {
      run += c.due - c.paid;
      dueAll += c.due;
      paidAll += c.paid;
      const future = c.date > today;
      return { key: c.date, date: c.date, today: c.date === today, future, labels: c.labels,
        due: c.hasDue ? c.due : null, paid: c.hasPaid ? c.paid : null, balance: future ? null : run, sf: c.sf };
    });
    out.push({ key: "total", total: true, labels: [], due: dueAll, paid: paidAll, balance: run, sf: [] });
    return out;
  };
  const planWords = (st) => (st.nPay === 1 ? "paid in full" : st.nPay === 2 ? "2 payments" : "monthly payments");

  const sections = [];
  for (const bs of Bs.values()) {
    const inst = bs.covers.flatMap(a => installmentsOf(S.get(a)));
    const acctEvents = bs.covers.flatMap(a => S.get(a).ev
      .filter(e => !e.via && !e.sf)
      .map(e => (e.label ? { ...e, label: `${accountLabel(a)}: ${e.label}` } : e)));
    sections.push({
      kind: "billing", key: bs.key, title: `${accountLabel(bs.key)}: pays for ${andList(bs.covers.map(accountLabel))}`,
      steps: bs.steps, grid: buildGrid(inst, [...acctEvents, ...bs.ev]),
    });
  }
  for (const st of S.values()) {
    sections.push({
      kind: "account", key: st.key, title: `${accountLabel(st.key)}: ${st.lob.label}, ${planWords(st)}`,
      steps: st.steps, grid: buildGrid(installmentsOf(st), st.ev),
    });
  }

  return { ok: true, problems: [], warnings, sections, ledger: L };
}
