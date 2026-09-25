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
//  * Order is by process date. Lines on the same day keep the order they were
//    entered, lower on the page being earlier, the way SF lists them.
//  * Amounts are whole cents throughout, so nothing drifts by a penny.
// ============================================================================

export const RETURN_FEE_CENTS = 2500;
export const LATE_FEE_CENTS = 2500;
// SF's own fee line lands on the return's day or soon after.
const FEE_CLAIM_DAYS = 31;
// A bill this close to the lines counts as a match: SF rounds splits its own way.
const MATCH_CENTS = 50;

// due: whether the effective/due date column is required, optional, or unused.
export const DEWEY_TYPES = [
  { key: "binder",              label: "Binder",                  col: "debit",  sign: 1,  role: "start",    due: "required" },
  { key: "new_business",        label: "New Business",            col: "debit",  sign: 1,  role: "start",    due: "required" },
  { key: "renewal",             label: "Renewal",                 col: "debit",  sign: 1,  role: "start",    due: "required" },
  { key: "policy_change",       label: "Policy Change",           col: "debit",  sign: 0,  role: "change",   due: "required" },
  { key: "billing_change",      label: "Billing Change",          col: "debit",  sign: 0,  role: "change",   due: "required" },
  { key: "bill",                label: "Bill",                    col: "debit",  sign: 0,  role: "bill",     due: "required" },
  { key: "autopay_revised_due", label: "AutoPay Revised Due",     col: "debit",  sign: 0,  role: "bill",     due: "required" },
  { key: "notice_cancel",       label: "Notice of Cancel NonPay", col: "debit",  sign: 1,  role: "notice",   due: "optional" },
  { key: "paid",                label: "Paid",                    col: "credit", sign: 1,  role: "payment",  due: "none" },
  { key: "declined",            label: "Declined",                col: "credit", sign: -1, role: "declined", due: "none" },
  { key: "return",              label: "Return",                  col: "credit", sign: -1, role: "return",   due: "none" },
  { key: "return_fee",          label: "Return Payment Fee",      col: "credit", sign: -1, role: "fee",      due: "none", fixed: RETURN_FEE_CENTS },
  { key: "late_fee",            label: "Late Payment Fee",        col: "credit", sign: -1, role: "fee",      due: "none", fixed: LATE_FEE_CENTS },
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
  { key: "full",    label: "Paid in full" },
];

// ---------- rows ----------
export function newRowId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
}
export function blankRow(account = 1) {
  return { id: newRowId(), type: "", processDate: "", amount: "", dueDate: "", account };
}
export function isBlankRow(r) {
  return !r || (!r.type && !r.processDate && !String(r.amount ?? "").trim() && !r.dueDate);
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
  if (t.fixed) return -t.fixed;
  const c = parseCents(row.amount);
  if (c === null) return null;
  if (t.sign === 1) return Math.abs(c);
  if (t.sign === -1) return -Math.abs(c);
  return c;
}

// What the amount box should read once the line's type has had its say.
export function tidyAmount(row) {
  const c = rowCents(row);
  if (c === null) return row?.amount ?? "";
  return (c / 100).toFixed(2);
}

// ---------- helpers ----------
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
// Earliest first. Same process date: lower on the page happened first.
function chronoSort(list) {
  return list.map((r, i) => ({ r, i }))
    .filter(x => !isBlankRow(x.r))
    .sort((a, b) => {
      const da = a.r.processDate || "";
      const db = b.r.processDate || "";
      if (da !== db) return da < db ? -1 : 1;
      return b.i - a.i;
    })
    .map(x => x.r);
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
      processDate: r.processDate, dueDate: "", account: r.account, amount: (-c / 100).toFixed(2),
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
    if (src.processDate) {
      const hi = addDaysISO(src.processDate, FEE_CLAIM_DAYS);
      const typed = chrono.find(q => !q.auto && q.type === "return_fee" && q.account === src.account && !feeTaken.has(q.id)
        && (q.processDate || "") >= src.processDate && (q.processDate || "") <= hi);
      if (typed) {
        feeTaken.add(typed.id);
        g.feeId = typed.id;
        g.members.push(typed.id);
        continue;
      }
    }
    const fee = {
      id: `${src.id}~fee`, auto: "fee", sourceId: src.id, type: "return_fee",
      processDate: src.processDate, dueDate: "", account: src.account, amount: "-25.00",
    };
    display.splice(display.indexOf(src), 0, fee);   // just above: it came after
    g.feeId = fee.id;
    g.members.push(fee.id);
  }

  chrono = chronoSort(display);
  const at = new Map(display.map((r, i) => [r.id, i]));
  const linked = groups.filter(g => g.members.length > 1);
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
    display, chrono, groups, linked, laneCount: laneEnds.length, groupOf, info,
    byId: new Map(display.map(r => [r.id, r])),
  };
}

// Lines whose process date is newer than the line above them.
export function outOfOrderIds(rows) {
  const bad = [];
  let above = null;
  for (const r of rows || []) {
    if (isBlankRow(r) || !r.processDate) continue;
    if (above && r.processDate > above) bad.push(r.id);
    above = r.processDate;
  }
  return bad;
}

// Newest first by process date. Undated lines keep their place at the end.
export function sortRowsByDate(rows) {
  const dated = rows.map((r, i) => ({ r, i })).filter(x => x.r.processDate);
  const undated = rows.filter(r => !r.processDate);
  dated.sort((a, b) => (a.r.processDate === b.r.processDate ? a.i - b.i : a.r.processDate < b.r.processDate ? 1 : -1));
  return [...dated.map(x => x.r), ...undated];
}

// ============================================================================
// explainBilling: the step by step and the bottom line, per account.
// accounts: { [n]: { lob: "auto" | "fire", plan: "monthly" | "full" } }
// ============================================================================
export function explainBilling({ rows, accounts, today }) {
  const L = buildLedger(rows);
  const problems = [];
  const warnings = [];
  const label = (k) => TYPE[k]?.label || "line";

  for (const r of L.display) {
    if (r.auto || isBlankRow(r)) continue;
    const t = TYPE[r.type];
    const miss = [];
    if (!t) miss.push("type");
    if (!r.processDate) miss.push("process date");
    if (t && !t.fixed && rowCents(r) === null) miss.push("amount");
    if (t && t.due === "required" && !r.dueDate) miss.push(t.role === "bill" ? "due date" : "effective date");
    if (miss.length) {
      problems.push({ rowId: r.id,
        text: `${t ? t.label : "A line"}${r.processDate ? ` on ${when(r.processDate, today)}` : ""} needs its ${andList(miss)}.` });
    }
  }

  const acctList = [...L.info.keys()].sort((a, b) => a - b);
  if (!acctList.length) problems.push({ text: "Enter the lines from SF's Billing & payment history first." });
  for (const a of acctList) {
    const inf = L.info.get(a);
    if (!inf.terms.length) {
      problems.push({ account: a, text: `Account ${a} needs its New Business or Renewal line. Keep going back in SF's history until you reach one.` });
      continue;
    }
    const meta = (accounts || {})[a] || {};
    if (!LOB[meta.lob]) {
      problems.push({ account: a, rowId: inf.terms[0].start.id,
        text: `Pick Auto or Fire on Account ${a}'s ${label(inf.terms[0].start.type)} line.` });
    }
  }

  for (const g of L.groups) {
    if (g.kind !== "return" || g.paymentId) continue;
    const r = L.byId.get(g.sourceId);
    warnings.push({ rowId: r.id,
      text: `No ${$(rowCents(r))} payment shows before the ${when(r.processDate, today)} Return. The payment it undoes may be further back.` });
  }

  if (problems.length) return { ok: false, problems, warnings, accounts: [], ledger: L };

  const feeLines = (g) => (!g ? []
    : g.firstPayment ? ["No return payment fee. It was the first New Business payment."]
    : g.feeId ? [`That adds a ${$(RETURN_FEE_CENTS)} return payment fee.`] : []);

  const out = [];
  for (const a of acctList) {
    const meta = accounts[a];
    const lob = LOB[meta.lob];
    const nPay = meta.plan === "full" ? 1 : lob.months;
    const inf = L.info.get(a);

    const terms = inf.terms.map(tm => {
      const S = tm.start.dueDate || tm.start.processDate;
      const P = rowCents(tm.start);
      const firstBill = tm.rows.find(r => (r.type === "bill" || r.type === "autopay_revised_due") && r.dueDate && r.dueDate > S);
      const day = Number((firstBill ? firstBill.dueDate : S).slice(8, 10));
      const dates = Array.from({ length: nPay }, (_, k) => (k === 0 ? S : addMonthsISO(S, k, day)));
      return { start: tm.start, S, P, end: addMonthsISO(S, lob.months), dates, amts: split(P, nPay) };
    });
    const termByStart = new Map(terms.map(t => [t.start.id, t]));
    const dueBy = (cutoff) => terms.reduce((s, t) => s + t.dates.reduce((x, d, k) => x + (d <= cutoff ? t.amts[k] : 0), 0), 0);

    let cur = null;
    let paid = 0, paidIn = 0, reversed = 0, fees = 0, credits = 0, extras = 0, changesNet = 0, premium = 0;
    const steps = [];

    for (const r of L.chrono.filter(x => x.account === a)) {
      const t = TYPE[r.type];
      const c = rowCents(r);
      const base = { rowId: r.id, date: r.processDate };

      if (r.type === "binder" && inf.hasNB) {
        steps.push({ ...base, tone: "muted", text: "Binder. Same as the New Business line, so it is not counted." });
        continue;
      }
      if (termByStart.has(r.id)) {
        cur = termByStart.get(r.id);
        premium += cur.P;
        const sub = [nPay === 1
          ? `Paid in full: one payment of ${$(cur.P)}.`
          : `Split into ${nPay} monthly payments of about ${$(cur.amts[nPay - 1])}.`];
        if (r.type === "binder") sub.unshift("There is no New Business line, so the Binder counts as the start.");
        steps.push({ ...base, tone: "start",
          text: `${label(r.type)}. ${lob.label} policy, ${$(cur.P)} for ${lob.months} months, starting ${when(cur.S, today)}.`, sub });
        continue;
      }
      const term = cur || terms[0];

      switch (t.role) {
        case "change": {
          changesNet += c;
          const nm = r.type === "policy_change" ? "Policy change" : "Billing change";
          const why = r.type === "billing_change" ? " A correction to the bill." : "";
          if (c > 0) {
            const E = r.dueDate || r.processDate;
            const left = term.dates.map((d, k) => (d >= E ? k : -1)).filter(k => k >= 0);
            if (left.length) {
              const shares = split(c, left.length);
              left.forEach((k, j) => { term.amts[k] += shares[j]; });
              steps.push({ ...base, text: `${nm} added ${$(c)}.${why}`, sub: [left.length === 1
                ? `One payment left, so it all goes on that one. It is now ${$(term.amts[left[0]])}.`
                : `Split over the ${left.length} payments left: about ${$(shares[shares.length - 1])} more on each. Payments are now about ${$(term.amts[left[left.length - 1]])}.`] });
            } else {
              extras += c;
              steps.push({ ...base, text: `${nm} added ${$(c)}.${why}`, sub: ["No payments left in this term, so it is due all at once."] });
            }
          } else if (c < 0) {
            credits += c;
            steps.push({ ...base, text: `${nm} took off ${$(c)}.${why}`, sub: ["Credited all at once, right away."] });
          } else {
            steps.push({ ...base, tone: "muted", text: `${nm} for ${$(0)}. The cost did not move.` });
          }
          break;
        }
        case "payment": {
          paid += c;
          paidIn += c;
          if (!r.auto) steps.push({ ...base, tone: "good", text: `Paid ${$(c)}.`, sub: [`Paid so far: ${$s(paid)}.`] });
          break;
        }
        case "declined": {
          paid += c;
          reversed -= c;
          steps.push({ ...base, tone: "warn", text: `A ${$(c)} payment was declined. It never went through.`, sub: feeLines(L.groupOf.get(r.id)) });
          break;
        }
        case "return": {
          paid += c;
          reversed -= c;
          const g = L.groupOf.get(r.id);
          const m = g && g.paymentId ? L.byId.get(g.paymentId) : null;
          steps.push({ ...base, tone: "warn",
            text: m ? `The ${$(c)} payment from ${when(m.processDate, today)} came back. It no longer counts as paid.`
                    : `A ${$(c)} payment came back. It no longer counts as paid.`,
            sub: feeLines(g) });
          break;
        }
        case "fee": {
          fees -= c;
          if (!L.groupOf.get(r.id)) {
            steps.push({ ...base, tone: "warn", text: `${r.type === "late_fee" ? "Late payment fee" : "Return payment fee"}: ${$(c)}.` });
          }
          break;
        }
        case "bill":
        case "notice": {
          const notice = t.role === "notice";
          const cutoff = notice ? r.processDate : (r.dueDate || r.processDate);
          const inst = dueBy(cutoff);
          const expected = inst + fees + extras + credits - paid;
          const diff = c - expected;
          const due = r.dueDate ? `, due ${when(r.dueDate, today)}` : "";
          const head = notice
            ? `Cancel notice: ${$(c)} past due${r.dueDate ? `, to be paid by ${when(r.dueDate, today)}` : ""}.`
            : c < 0 ? `SF shows a ${$(c)} credit${due}.`
            : r.type === "bill" ? `SF billed ${$(c)}${due}.`
            : `SF changed the amount due to ${$(c)}${due}.`;
          const parts = [`${$(inst)} in payments`];
          if (fees) parts.push(`+ ${$(fees)} in fees`);
          if (extras) parts.push(`+ ${$(extras)} in changes`);
          if (credits) parts.push(`\u2212 ${$(credits)} in credits`);
          parts.push(paid >= 0 ? `\u2212 ${$(paid)} paid` : `+ ${$(paid)} came back`);
          const ok = Math.abs(diff) <= MATCH_CENTS;
          steps.push({ ...base, tone: ok ? "match" : "off", text: head, sub: [
            `${notice ? "Past due as of" : "By"} ${when(cutoff, today)}: ${parts.join(" ")} = ${$s(expected)}.`,
            ok ? "Matches SF." : `SF's number is ${$(diff)} ${diff > 0 ? "more" : "less"} than these lines add up to. A line may be missing, or SF spread a change its own way.`,
          ] });
          break;
        }
        default:
          break;
      }
    }

    const totalCost = premium + changesNet + fees;
    const left = totalCost - paid;
    const nowDue = dueBy(today) + fees + extras + credits - paid;
    const last = terms[terms.length - 1];
    const future = last.dates.map((d, k) => [d, k]).filter(([d]) => d > today);

    const costParts = [`${$(premium)} premium`];
    if (changesNet > 0) costParts.push(`${$(changesNet)} added in changes`);
    if (changesNet < 0) costParts.push(`${$(changesNet)} taken off in changes`);
    if (fees) costParts.push(`${$(fees)} in fees`);

    const summary = [
      { key: "cost", label: terms.length > 1 ? `Cost of these ${terms.length} terms` : "Cost of the policy", value: $(totalCost), note: andList(costParts) },
      { key: "paid", label: "Paid so far", value: $s(paid),
        note: reversed ? `${$(paidIn)} in payments, less ${$(reversed)} that was declined or came back.` : "" },
      left > MATCH_CENTS ? { key: "left", label: "Still to pay", value: $(left), note: "Over the whole policy." }
        : left < -MATCH_CENTS ? { key: "left", label: "Overpaid", value: $(left), note: "That is a credit to the customer." }
        : { key: "left", label: "Still to pay", value: $(0), note: "Paid in full." },
      nowDue > MATCH_CENTS ? { key: "now", tone: "warn", label: "Behind today", value: $(nowDue), note: "Should already be paid, and is not." }
        : nowDue < -MATCH_CENTS ? { key: "now", tone: "good", label: "Ahead today", value: $(nowDue), note: "Paid more than is due so far." }
        : { key: "now", tone: "good", label: "Today", value: "On schedule", note: "" },
    ];
    if (future.length) {
      const [nextDate, nextK] = future[0];
      summary.push({ key: "next", label: "Payments left", value: `${future.length} of about ${$(last.amts[future[future.length - 1][1]])}`,
        note: `Next one around ${when(nextDate, today)}${nextK !== future[future.length - 1][1] && last.amts[nextK] !== last.amts[future[future.length - 1][1]] ? `, for ${$(last.amts[nextK])}` : ""}.` });
    } else if (last.end && last.end <= today) {
      summary.push({ key: "next", label: "Term", value: "Over", note: `This term ended ${when(last.end, today)}.` });
    }

    out.push({ account: a, lob: lob.label, plan: nPay === 1 ? "paid in full" : "monthly payments", steps, summary });
  }

  return { ok: true, problems: [], warnings, accounts: out, ledger: L };
}
