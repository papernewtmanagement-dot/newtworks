import { Fragment, useState, useEffect, useMemo, useRef } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport, useElementWidth } from "../lib/hooks.js";
import { todayISOCentral } from "../lib/weeks.js";
import { fmtDateShort } from "../lib/utils.js";
import { noPwManager } from "../lib/forms.js";
import {
  DEWEY_TYPES, DEWEY_LOBS, DEWEY_PLANS, deweyType, blankRow, isBlankRow, rowCents, tidyAmount,
  buildLedger, explainBilling, outOfOrderIds, sortRowsByDate, isBillingKey, accountLabel, normalizeAccountKey, lineDate, fmtAmount,
} from "../lib/deweyOwe.js";

// =====================================================================
// Dewey: the Dashboard's billing explainer (Peter 2026-09-25).
// The team copies every line of the customer's SF Billing & payment
// history into the table, newest first, then presses Make it Make Sense.
// All the math lives in src/lib/deweyOwe.js; this file only draws it.
//
//  * Worksheets save by customer: first name, last initial and the last 4
//    of the phone (billing_worksheet_save / _get / _list). Saving happens as
//    they type once the customer is filled in. The page also keeps the
//    current worksheet in this browser, so a refresh loses nothing.
//  * Each type forces its own column: Paid or Owed. Credit and debit never
//    share a line.
//  * Each type shows only the date boxes it has: Binder, New Business and
//    Renewal just the effective date; Paid, Declined, Return, the fees and
//    Waiver just the process date; bills and changes both (Peter 2026-09-25).
//  * A new line starts on the date of the line above it, and a second date box
//    starts on the last due date entered above, so the calendar opens where
//    the team already is.
//  * One Paid line that pays for several policies goes on a billing account
//    (Billing 1 and so on), which pays for the accounts picked for it.
//  * Locked lines (the Paid behind a Declined, the fee behind a return or
//    decline) are drawn for the team and cannot be changed.
//  * Linked lines are joined by a drawn line in the left margin, one track
//    per link (Peter asked for lines over colour alone).
//  * The answer is a small grid, dates across, like Peter's own spreadsheet:
//    what happened above each date, then Due, Paid, Unpaid (due and not yet
//    paid) and Balance (left on the whole policy), then SF's latest bill with a
//    check. Every line sits on its own date. Months alternate and the
//    regular due dates are marked. A declined payment shows struck through.
//    The step by step sits behind "Show every step".
//  * Problems show after the button is pressed, not while typing
//    (Bargas-Avila et al. 2007), the same way the Log tab does it.
// =====================================================================

const STORE_KEY = "newtworks.deweyOwe.v1";
const LINE_COLORS = [T.purple, T.teal, T.gold, T.pink, T.blue, T.red];
const LANE_W = 12;
const INPUT_H = 34;
const ROW_PAD = 8;
const COMPACT_BELOW = 900;
const SAVE_AFTER_MS = 1200;
const GRID = "minmax(170px, 1.6fr) 138px 104px 104px 138px minmax(120px, 1fr) 28px";
const LOB_LABEL = Object.fromEntries(DEWEY_LOBS.map(l => [l.key, l.label]));

const box = {
  width: "100%", height: INPUT_H, padding: "0 8px", borderRadius: 7, border: `1px solid ${T.slate300}`,
  background: T.white, color: T.slate900, fontSize: 13, fontFamily: "inherit", outline: "none", boxSizing: "border-box",
};
const moneyBox = { ...box, textAlign: "right" };
const lockedCell = {
  height: INPUT_H, display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: T.slate500,
  padding: "0 8px", boxSizing: "border-box", whiteSpace: "nowrap",
};
const miniLabel = { fontSize: 11, fontWeight: 600, color: T.slate500, marginBottom: 3, lineHeight: "13px" };
const btnPrimary = {
  padding: "10px 18px", borderRadius: 8, border: "none", fontWeight: 700, fontSize: 14, cursor: "pointer",
  background: T.blue, color: T.white, fontFamily: "inherit",
};
const btnGhost = {
  padding: "8px 12px", borderRadius: 8, border: `1px solid ${T.slate300}`, background: T.white, color: T.slate700,
  fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit",
};
const linkBtn = {
  background: "none", border: "none", padding: 0, color: T.slate500, fontSize: 13, fontWeight: 600,
  cursor: "pointer", fontFamily: "inherit", textDecoration: "underline",
};
const xBtn = {
  width: 28, height: INPUT_H, border: "none", background: "transparent", color: T.slate400, fontSize: 18,
  lineHeight: 1, cursor: "pointer", padding: 0, fontFamily: "inherit", flexShrink: 0,
};
const chip = (on) => ({
  padding: "4px 10px", borderRadius: 999, fontSize: 12, fontWeight: 700, cursor: "pointer", fontFamily: "inherit",
  border: `1px solid ${on ? T.blue : T.slate300}`, background: on ? T.blueLt : T.white, color: on ? T.blue : T.slate600,
  boxSizing: "border-box",
});
const TONE_COLOR = { start: T.blue, good: T.green, warn: T.amber, match: T.green, off: T.red, muted: T.slate300 };

// ---------- the worksheet in hand ----------
const emptyCustomer = () => ({ first: "", initial: "", phone4: "" });
function freshDraft() {
  return { rows: [blankRow(1)], accounts: { 1: { lob: "", plan: "monthly" } }, customer: emptyCustomer(), loadedKey: "" };
}
function cleanRows(list) {
  return (Array.isArray(list) ? list : []).filter(r => r && typeof r.id === "string").map(r => {
    const row = {
      id: r.id, type: deweyType(r.type) ? r.type : "", processDate: r.processDate || "", amount: r.amount ?? "",
      dueDate: r.dueDate || "", account: normalizeAccountKey(r.account),
    };
    // A line saved while its type had a different date box keeps its one date.
    const t = deweyType(row.type);
    if (t?.proc === "none") {
      if (!row.dueDate) row.dueDate = row.processDate;
      row.processDate = "";
    } else if (t?.due === "none") {
      if (!row.processDate) row.processDate = row.dueDate;
      row.dueDate = "";
    }
    return row;
  });
}
function cleanAccounts(obj) {
  return obj && typeof obj === "object" && !Array.isArray(obj) ? obj : { 1: { lob: "", plan: "monthly" } };
}
function loadDraft() {
  try {
    const d = JSON.parse(window.localStorage.getItem(STORE_KEY) || "null");
    if (d && typeof d === "object") {
      const rows = cleanRows(d.rows);
      const c = d.customer || {};
      return {
        rows: rows.length ? rows : [blankRow(1)],
        accounts: cleanAccounts(d.accounts),
        customer: { first: String(c.first || ""), initial: String(c.initial || ""), phone4: String(c.phone4 || "") },
        loadedKey: typeof d.loadedKey === "string" ? d.loadedKey : "",
      };
    }
  } catch { /* private mode or a damaged draft: start clean */ }
  return freshDraft();
}
function saveDraft(d) {
  try { window.localStorage.setItem(STORE_KEY, JSON.stringify(d)); } catch { /* private mode */ }
}
const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
// First name (any capitals), last initial, phone last 4. Empty until all three are in.
function keyOf(c) {
  const first = String(c.first || "").trim();
  const initial = String(c.initial || "").trim().toUpperCase();
  const phone = String(c.phone4 || "").trim();
  return first && /^[A-Z]$/.test(initial) && /^\d{4}$/.test(phone) ? `${first.toLowerCase()}|${initial}|${phone}` : "";
}
const customerName = (c) => `${cap(String(c.first || "").trim())} ${String(c.initial || "").trim().toUpperCase()}.`;
const savedLines = (rows) => rows.filter(r => !isBlankRow(r));
function errText(e) {
  return String(e?.message || e || "Something went wrong.").replace(/^.*?ERROR:\s*/, "");
}
// Today reads as a time, any other day as a date.
function savedWhen(d) {
  return d.toDateString() === new Date().toDateString()
    ? d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })
    : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

// Locked dates read like the date boxes around them.
function usDate(iso) {
  if (!iso) return "";
  const [y, m, d] = iso.split("-");
  return `${m}/${d}/${y}`;
}

function DeweyStyles() {
  return (
    <style>{`
      @keyframes nwDeweyPop {
        0%   { transform: scale(0.9) rotate(-3deg); }
        60%  { transform: scale(1.06) rotate(2deg); }
        100% { transform: none; }
      }
      .nw-dewey-pop { animation: nwDeweyPop 480ms cubic-bezier(.2,.8,.3,1.2); transform-origin: 50% 90%; }
      /* The scratch: the arm swings up from the shoulder, rubs a few times, rests. */
      @keyframes nwDeweyScratch {
        0%, 50%, 100% { transform: rotate(0deg); }
        8%  { transform: rotate(-13deg); }
        14% { transform: rotate(-5deg); }
        20% { transform: rotate(-13deg); }
        26% { transform: rotate(-5deg); }
        32% { transform: rotate(-13deg); }
        38% { transform: rotate(-5deg); }
        44% { transform: rotate(-11deg); }
      }
      .nw-dewey-arm { transform-box: view-box; transform-origin: 100px 74px; animation: nwDeweyScratch 2.6s ease-in-out infinite; }
      @keyframes nwDeweyBob {
        0%, 100% { transform: translateY(0) rotate(0deg); }
        50%      { transform: translateY(-5px) rotate(-10deg); }
      }
      .nw-dewey-q1 { transform-box: fill-box; transform-origin: center; animation: nwDeweyBob 1.8s ease-in-out infinite; }
      .nw-dewey-q2 { transform-box: fill-box; transform-origin: center; animation: nwDeweyBob 2.3s ease-in-out -0.9s infinite; }
      @media (prefers-reduced-motion: reduce) {
        .nw-dewey-pop, .nw-dewey-arm, .nw-dewey-q1, .nw-dewey-q2 { animation: none; }
      }
      .nw-dewey input:focus, .nw-dewey select:focus { border-color: ${T.blue} !important; }
      .nw-dewey input:focus-visible, .nw-dewey select:focus-visible, .nw-dewey button:focus-visible {
        outline: none; box-shadow: 0 0 0 3px ${T.blueLt}, 0 0 0 4px ${T.blue};
      }
    `}</style>
  );
}

// Dewey: a receipt scratching his head, question marks bobbing. Once the
// lines make sense he stops scratching and smiles.
function Dewey({ mood, size }) {
  const happy = mood === "happy";
  const ink = T.slate900;
  return (
    <svg key={mood} className={happy ? "nw-dewey-pop" : undefined} width={size} height={Math.round(size * 140 / 120)}
      viewBox="0 0 120 140" role="img" style={{ flexShrink: 0, overflow: "visible" }}
      aria-label={happy ? "Dewey Owe, a receipt who finally gets it" : "Dewey Owe, a confused receipt"}>
      {happy ? (
        <g fill={T.gold}>
          <path d="M108 8 l3 8 8 3 -8 3 -3 8 -3 -8 -8 -3 8 -3z" />
          <path d="M9 30 l2 5 5 2 -5 2 -2 5 -2 -5 -5 -2 5 -2z" />
        </g>
      ) : (
        <g fill={T.amber} fontWeight="800" style={{ fontFamily: "inherit" }}>
          <g className="nw-dewey-q1"><text x="102" y="26" fontSize="26" transform="rotate(12 102 26)">?</text></g>
          <g className="nw-dewey-q2"><text x="1" y="40" fontSize="17" transform="rotate(-12 1 40)" opacity="0.85">?</text></g>
        </g>
      )}
      <path d="M24 12 H96 Q100 12 100 16 V118 L92 126 L84 118 L76 126 L68 118 L60 126 L52 118 L44 126 L36 118 L28 126 L20 118 V16 Q20 12 24 12 Z"
        fill={T.white} stroke={T.slate700} strokeWidth="3" strokeLinejoin="round" />
      <circle cx="60" cy="30" r="10" fill={T.greenLt} stroke={T.green} strokeWidth="2" />
      <text x="60" y="35.5" textAnchor="middle" fontSize="15" fontWeight="800" fill={T.green} style={{ fontFamily: "inherit" }}>$</text>
      {happy ? (
        <g stroke={ink} strokeWidth="3" fill="none" strokeLinecap="round">
          <path d="M40 57 Q46 50 52 57" />
          <path d="M68 57 Q74 50 80 57" />
          <path d="M47 71 Q60 84 73 71" />
        </g>
      ) : (
        <g stroke={ink} strokeWidth="3" fill="none" strokeLinecap="round" strokeLinejoin="round">
          <path d="M39 46 L53 49" />
          <path d="M67 45 Q74 38 81 42" />
          <path d="M47 76 q4.3 -4 8.6 0 t8.6 0 t8.6 0" />
        </g>
      )}
      {happy ? (
        <g fill={T.pinkLt}>
          <circle cx="40" cy="68" r="5" />
          <circle cx="80" cy="68" r="5" />
        </g>
      ) : (
        <g>
          <circle cx="46" cy="57" r="4.5" fill={ink} />
          <circle cx="74" cy="56" r="4.5" fill={ink} />
          <g className="nw-dewey-arm">
            <path d="M100 74 Q116 66 111 47" stroke={T.slate700} strokeWidth="3" fill="none" strokeLinecap="round" />
            <circle cx="111" cy="44" r="4.5" fill={T.white} stroke={T.slate700} strokeWidth="2.5" />
          </g>
        </g>
      )}
      <path d="M34 92 H86 M34 100 H72 M34 108 H80" stroke={T.slate300} strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}

function Bubble({ phone }) {
  return (
    <div style={{
      position: "relative", flex: "1 1 260px", minWidth: 0, maxWidth: 660, background: T.white,
      border: `1px solid ${T.slate200}`, borderRadius: 16, padding: phone ? "12px 14px" : "14px 18px",
      fontSize: phone ? 14 : 15, lineHeight: 1.55, color: T.slate800, boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
    }}>
      <span aria-hidden="true" style={{
        position: "absolute", left: -8, top: phone ? 20 : 30, width: 14, height: 14, background: T.white,
        borderLeft: `1px solid ${T.slate200}`, borderBottom: `1px solid ${T.slate200}`, transform: "rotate(45deg)",
        boxSizing: "border-box",
      }} />
      Hi, I'm Dewey Owe! Is SF billing super confusing? Enter every line from the customer's{" "}
      <strong>SF Billing &amp; payment history</strong>, newest to oldest. Go all the way back to the New Business
      or Renewal line from when the bill last made sense, and I'll help you make sense of it!
    </div>
  );
}

function Tag({ children }) {
  return (
    <span style={{
      flexShrink: 0, padding: "2px 8px", borderRadius: 999, background: T.slate100, color: T.slate600,
      fontSize: 11, fontWeight: 700,
    }}>{children}</span>
  );
}

// The drawn links, one lane each. Lane 0 sits next to the lines.
function Gutter({ i, ledger, width, dotY }) {
  const parts = [];
  const rowId = ledger.display[i]?.id;
  for (const g of ledger.linked) {
    if (i < g.top || i > g.bottom) continue;
    const color = LINE_COLORS[g.colorIndex % LINE_COLORS.length];
    const x = width - 8 - g.lane * LANE_W;
    const top = i === g.top ? dotY : 0;
    const line = { position: "absolute", left: x, width: 2, top, background: color };
    if (i === g.bottom) line.height = dotY - top; else line.bottom = 0;
    parts.push(<span key={`${g.id}-l`} style={line} />);
    if (g.members.includes(rowId)) {
      parts.push(<span key={`${g.id}-t`} style={{ position: "absolute", left: x, right: 0, top: dotY - 1, height: 2, background: color }} />);
      parts.push(<span key={`${g.id}-d`} style={{
        position: "absolute", left: x - 3, top: dotY - 4, width: 8, height: 8, borderRadius: 999, background: color,
        boxSizing: "border-box",
      }} />);
    }
  }
  return <div aria-hidden="true" style={{ position: "relative", width, flexShrink: 0 }}>{parts}</div>;
}

function Row({
  r, i, ledger, accounts, policyIds, billingIds, compact, gutterW, dotY, tint, greyed,
  onRow, onRemove, onLob, onPlan, onNewAccount, onNewBilling, typeRef, isLast, onEnter,
}) {
  const t = deweyType(r.type);
  const locked = !!r.auto;
  const billing = isBillingKey(r.account);
  const meta = billing ? {} : (accounts[r.account] || {});
  const lob = LOB_LABEL[meta.lob] || "";
  const start = t?.role === "start";
  const billingOk = !t || (t.role !== "start" && t.role !== "change");
  const shown = t && (locked || t.fixed) ? (rowCents(r) / 100).toFixed(2) : "";
  const dueLabel = t && (t.role === "bill" || t.role === "notice") ? "Due date" : "Effective date";
  const colLabel = (col) => (col === "paid" ? "Paid" : "Owed");

  const cell = (label, content, extra) => (
    <div style={{ minWidth: 0, ...extra }}>
      {compact && label ? <div style={miniLabel}>{label}</div> : null}
      {content}
    </div>
  );

  const typeCell = locked ? (
    <div style={lockedCell} title={r.auto === "paid"
      ? "Added so the declined payment balances out. It can't be changed."
      : "SF's fee for a declined or returned payment. It can't be changed."}>
      {t.label}<span aria-label="locked">🔒</span>
    </div>
  ) : (
    <div>
      <div style={{ display: "flex", gap: 6 }}>
        <select ref={typeRef} value={r.type} aria-label="Type" onChange={e => onRow(r.id, { type: e.target.value })}
          style={{ ...box, color: r.type ? T.slate900 : T.slate400 }}>
          <option value="">Pick a type</option>
          {DEWEY_TYPES.map(x => <option key={x.key} value={x.key}>{x.label}</option>)}
        </select>
        {compact && <button type="button" onClick={() => onRemove(r.id)} style={xBtn} aria-label="Remove line" title="Remove line">×</button>}
      </div>
      {start && !greyed && !billing && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 6, alignItems: "center" }}>
          {DEWEY_LOBS.map(l => (
            <button key={l.key} type="button" aria-pressed={meta.lob === l.key} onClick={() => onLob(r.account, l.key)}
              style={chip(meta.lob === l.key)}>{l.label}</button>
          ))}
          <select value={meta.plan || "monthly"} aria-label="How it's paid" onChange={e => onPlan(r.account, e.target.value)}
            style={{ ...box, width: "auto", height: 28, fontSize: 12, padding: "0 6px" }}>
            {DEWEY_PLANS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
          </select>
        </div>
      )}
      {greyed && <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>Same as New Business. Not counted.</div>}
    </div>
  );

  const hasProc = !t || t.proc !== "none";
  const hasDue = !!t && t.due !== "none";
  const dateCell = !hasProc ? <div style={{ height: INPUT_H }} />
    : locked ? <div style={lockedCell}>{usDate(r.processDate)}</div>
    : <input type="date" value={r.processDate} aria-label="Process date"
        onChange={e => onRow(r.id, { processDate: e.target.value })} style={box} />;

  const amountCell = (col) => {
    if (!t || t.col !== col) return <div style={{ height: INPUT_H }} />;
    if (locked || t.fixed) return <div style={{ ...lockedCell, justifyContent: "flex-end" }}>{shown}</div>;
    return (
      <input type="text" inputMode="decimal" value={r.amount} aria-label={colLabel(col)}
        placeholder={t.sign === -1 ? "-0.00" : "0.00"}
        onChange={e => onRow(r.id, { amount: e.target.value })}
        onBlur={() => onRow(r.id, { amount: tidyAmount(r) })} style={moneyBox} />
    );
  };

  const dueCell = !hasDue ? <div style={{ height: INPUT_H }} />
    : locked ? <div style={lockedCell}>{usDate(r.dueDate)}</div>
    : <input type="date" value={r.dueDate} aria-label={dueLabel}
        onChange={e => onRow(r.id, { dueDate: e.target.value })} style={box} />;

  const pick = (v) => {
    if (v === "new") onNewAccount(r.id);
    else if (v === "newb") onNewBilling(r.id);
    else onRow(r.id, { account: normalizeAccountKey(v) });
  };
  const acctCell = locked ? (
    <div style={lockedCell}>{accountLabel(r.account)}{lob ? <Tag>{lob}</Tag> : null}</div>
  ) : (
    <div style={{ display: "flex", gap: 6, alignItems: "center", height: INPUT_H }}>
      <select value={String(r.account)} aria-label="Account" style={{ ...box, flex: "1 1 auto", minWidth: 0 }}
        onChange={e => pick(e.target.value)}>
        {policyIds.map(a => <option key={a} value={String(a)}>{accountLabel(a)}</option>)}
        {(billingOk || billing) && billingIds.map(b => <option key={b} value={b}>{accountLabel(b)}</option>)}
        <option value="new">+ New account</option>
        {billingOk && <option value="newb">+ New billing account</option>}
      </select>
      {lob && !start ? <Tag>{lob}</Tag> : null}
    </div>
  );

  const onKeyDown = (e) => {
    if (e.key !== "Enter" || !isLast) return;
    const tag = e.target?.tagName;
    if (tag !== "INPUT" && tag !== "SELECT") return;
    e.preventDefault();
    onEnter();
  };

  const bg = tint === "problem" ? T.redLt : tint === "flash" ? T.blueLt : tint === "warn" ? T.amberLt : locked ? T.slate50 : T.white;
  return (
    <div id={`dewey-row-${r.id}`} onKeyDown={onKeyDown} style={{ display: "flex", alignItems: "stretch", background: bg, transition: "background 300ms" }}>
      <Gutter i={i} ledger={ledger} width={gutterW} dotY={dotY} />
      <div style={{
        flex: 1, minWidth: 0, display: "grid", alignItems: "start", opacity: greyed ? 0.55 : 1,
        gap: compact ? "8px 10px" : 8, gridTemplateColumns: compact ? "repeat(auto-fit, minmax(130px, 1fr))" : GRID,
        padding: `${ROW_PAD}px 10px ${ROW_PAD}px 0`, borderBottom: `1px solid ${T.slate100}`,
      }}>
        {compact ? (
          <>
            {cell("Type", typeCell, { gridColumn: "1 / -1" })}
            {hasProc ? cell("Process date", dateCell) : null}
            {hasDue ? cell(dueLabel, dueCell) : null}
            {t ? cell(colLabel(t.col), amountCell(t.col)) : null}
            {cell("Account", acctCell)}
          </>
        ) : (
          <>
            {typeCell}
            {dateCell}
            {amountCell("paid")}
            {amountCell("owed")}
            {dueCell}
            {acctCell}
            {locked ? <div /> : <button type="button" onClick={() => onRemove(r.id)} style={xBtn} aria-label="Remove line" title="Remove line">×</button>}
          </>
        )}
      </div>
    </div>
  );
}

function StepSub({ step, line, last }) {
  if (last && step.tone === "match") {
    return <div style={{ fontSize: 13, color: T.slate700, lineHeight: 1.45 }}><span style={{ color: T.green, fontWeight: 800 }}>✓</span> {line}</div>;
  }
  if (last && step.tone === "off") {
    return <div style={{ fontSize: 13, color: T.slate800, lineHeight: 1.45 }}><span style={{ color: T.red, fontWeight: 800 }}>≠</span> {line}</div>;
  }
  return <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.45 }}>{line}</div>;
}

// ---------- the answer: a small grid, dates across ----------
// Peter 2026-09-25: laid out like his spreadsheet, simple and not a lot of
// reading. What happened sits above its date; under it, what came due, what
// was paid, and what was still owed at that point. SF's own bills sit in the
// last row with a check against the lines. On a narrow screen the grid turns
// so the dates run down the page instead of scrolling sideways.
const signed = (c) => (c == null ? "" : `${c < 0 ? "\u2212" : ""}${fmtAmount(c)}`);
const LABEL_TONE = { start: T.blue, change: T.slate700, credit: T.teal, fee: T.gold, bounce: T.red, muted: T.slate500 };
const TAG = { display: "block", fontSize: 10, fontWeight: 700, color: T.red };

// Every payment on its day. A declined one shows struck through and never
// counts; one that came back shows as a minus. A note says where it went.
function PaidCell({ c }) {
  if (c.total || !c.pays.length) return signed(c.paid);
  return (
    <div style={{ display: "grid", gap: 2, justifyItems: "end" }}>
      {c.pays.map((p, i) => (
        <span key={i} style={{ whiteSpace: "nowrap" }}>
          {p.kind === "declined"
            ? <><span style={{ textDecoration: "line-through", color: T.slate400 }}>{fmtAmount(p.cents)}</span><span style={TAG}>declined</span></>
            : <>{signed(p.cents)}{p.kind === "returned" ? <span style={TAG}>returned</span> : null}</>}
          {p.note ? <span style={{ display: "block", fontSize: 11, fontWeight: 500, color: T.slate500, whiteSpace: "normal" }}>{p.note}</span> : null}
        </span>
      ))}
    </div>
  );
}

const GRID_ROWS = [
  { key: "due", label: "Due", help: "What came due that day: a payment, a fee, a change.", cell: (c) => signed(c.due) },
  { key: "paid", label: "Paid", help: "What came in that day. A minus is a payment that came back.", cell: (c) => <PaidCell c={c} /> },
  { key: "owed", label: "Unpaid", help: "Due so far and not paid yet. This is what SF bills and sends notices on. A minus means paid ahead.", cell: (c) => signed(c.owed) },
  { key: "balance", label: "Balance", help: "What is left to pay on the whole policy. A change, a fee or a payment moves it the day it happens.", cell: (c) => signed(c.balance) },
];
// Peter 2026-09-25: months alternate so they read as groups, and the regular
// payment due dates stand out.
const colBg = (c) => (c.today ? T.amberLt : c.total ? T.white : c.band ? T.slate100 : T.white);
const DUE_PILL = { display: "inline-block", background: T.blue, color: T.white, borderRadius: 999, padding: "2px 8px" };
function GridDate({ c }) {
  if (c.total) return "Total";
  if (c.today) return <>Today<div style={{ fontSize: 10, fontWeight: 600, color: T.slate500 }}>{fmtDateShort(c.date)}</div></>;
  return c.isDue ? <span style={DUE_PILL} title="A regular payment due date">{fmtDateShort(c.date)}</span> : fmtDateShort(c.date);
}
const GRID_COL_W = 78;
// Dates run across on a computer, like Peter's sheet; a very long policy
// scrolls inside the box with the row names pinned. On a phone they run down.
const ACROSS_MIN_W = 700;

function SfCell({ list, inline }) {
  return (
    <div style={inline ? { display: "flex", flexWrap: "wrap", justifyContent: "flex-end", alignItems: "baseline", gap: "2px 12px" }
      : { display: "grid", gap: 2, justifyItems: "end" }}>
      {inline && <span style={{ fontSize: 11, fontWeight: 700, color: T.slate500 }}>SF bill</span>}
      {list.map((x, i) => (
        <span key={i} title={x.ok ? "Matches the lines." : `The lines add up to ${signed(x.expected)}.`} style={{ whiteSpace: "nowrap" }}>
          {x.revised ? <span style={{ fontSize: 10, color: T.slate500, marginRight: 4 }}>revised</span> : null}
          {signed(x.cents)}{" "}
          <span style={{ color: x.ok ? T.green : T.red, fontWeight: 800 }}>{x.ok ? "✓" : "≠"}</span>
          {!x.ok && <span style={{ display: "block", fontSize: 11, color: T.slate500 }}>lines say {signed(x.expected)}</span>}
          {x.note && <span style={{ display: "block", fontSize: 11, color: T.slate500, whiteSpace: "normal" }}>{x.note}</span>}
        </span>
      ))}
    </div>
  );
}

function DateGrid({ grid, width }) {
  const anySf = grid.some(c => c.sf.length);
  const across = width === 0 || width >= ACROSS_MIN_W;
  // Columns share the width when they fit, so Total never hides off the side.
  const fit = width === 0 || width >= 80 + grid.length * GRID_COL_W;
  const ink = (c) => (c.future ? T.slate400 : T.slate800);
  // Unpaid is red when behind; either total goes teal when paid ahead.
  const rowInk = (c, key) => {
    const v = c[key];
    if (v == null || c.future || (key !== "owed" && key !== "balance")) return ink(c);
    return key === "owed" && v > 50 ? T.red : v < -50 ? T.teal : ink(c);
  };
  const bold = (c) => (c.today || c.total ? 800 : 500);
  const edge = (c) => (c.total ? `2px solid ${T.slate300}` : "none");
  const th = { fontSize: 12, fontWeight: 700, color: T.slate600, textAlign: "left", padding: "6px 10px 6px 0", whiteSpace: "nowrap" };
  const pin = { position: "sticky", left: 0, zIndex: 1, background: T.white };
  const num = { padding: "6px 6px", textAlign: "right", whiteSpace: "nowrap", verticalAlign: "top", borderTop: `1px solid ${T.slate200}` };

  if (across) {
    return (
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ borderCollapse: "collapse", fontSize: 13, fontVariantNumeric: "tabular-nums",
          ...(fit ? { width: "100%", tableLayout: "fixed" } : {}) }}>
          {fit && <colgroup><col style={{ width: 72 }} />{grid.map(c => <col key={c.key} />)}</colgroup>}
          <thead>
            <tr>
              <th style={pin} />
              {grid.map(c => (
                <th key={c.key} style={{ verticalAlign: "bottom", padding: "6px 6px 4px", textAlign: "right", minWidth: fit ? 0 : GRID_COL_W - 12, background: colBg(c), borderLeft: edge(c) }}>
                  {c.labels.map((l, i) => (
                    <div key={i} style={{ fontSize: 11, fontWeight: l.tone === "muted" ? 500 : 700, lineHeight: 1.3, color: LABEL_TONE[l.tone] || T.slate700 }}>{l.text}</div>
                  ))}
                </th>
              ))}
            </tr>
            <tr>
              <th style={pin} />
              {grid.map(c => (
                <th key={c.key} style={{ padding: "4px 6px 6px", textAlign: "right", fontSize: 12, fontWeight: 800, color: c.future ? T.slate400 : T.slate900,
                  background: colBg(c), borderLeft: edge(c), whiteSpace: "nowrap" }}>
                  <GridDate c={c} />
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {GRID_ROWS.map(rd => (
              <tr key={rd.key}>
                <th scope="row" title={rd.help} style={{ ...th, ...pin, borderTop: `1px solid ${T.slate200}` }}>{rd.label}</th>
                {grid.map(c => (
                  <td key={c.key} style={{ ...num, background: colBg(c), fontWeight: bold(c), borderLeft: edge(c),
                    color: rowInk(c, rd.key) }}>{rd.cell(c)}</td>
                ))}
              </tr>
            ))}
            {anySf && (
              <tr>
                <th scope="row" title="What SF billed, checked against the lines." style={{ ...th, ...pin, borderTop: `1px solid ${T.slate200}` }}>SF bill</th>
                {grid.map(c => (
                  <td key={c.key} style={{ ...num, background: colBg(c), borderLeft: edge(c), color: ink(c) }}>
                    {c.sf.length ? <SfCell list={c.sf} /> : null}
                  </td>
                ))}
              </tr>
            )}
          </tbody>
        </table>
      </div>
    );
  }

  const heads = ["", ...GRID_ROWS.map(r => r.label)];
  const cell = { padding: "4px 4px 6px", textAlign: "right", whiteSpace: "nowrap", verticalAlign: "top" };
  return (
    <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
      <table style={{ borderCollapse: "collapse", fontSize: 13, fontVariantNumeric: "tabular-nums", width: "100%", maxWidth: 560 }}>
        <thead>
          <tr>{heads.map((h, i) => <th key={i} style={{ ...th, textAlign: i ? "right" : "left", padding: "4px 6px" }}>{h}</th>)}</tr>
        </thead>
        <tbody>
          {grid.map(c => (
            <Fragment key={c.key}>
              {c.labels.length > 0 && (
                <tr style={{ background: colBg(c) }}>
                  <td colSpan={heads.length} style={{ padding: "8px 6px 0", fontSize: 11, fontWeight: 700, borderTop: `1px solid ${T.slate200}` }}>
                    {c.labels.map((l, i) => (
                      <span key={i} style={{ color: LABEL_TONE[l.tone] || T.slate700, fontWeight: l.tone === "muted" ? 500 : 700, marginRight: 10, whiteSpace: "nowrap" }}>{l.text}</span>
                    ))}
                  </td>
                </tr>
              )}
              <tr style={{ background: colBg(c), borderTop: c.total ? `2px solid ${T.slate300}` : c.labels.length ? "none" : `1px solid ${T.slate200}` }}>
                <td style={{ ...cell, textAlign: "left", fontWeight: 800, color: c.future ? T.slate400 : T.slate900 }}><GridDate c={c} /></td>
                {GRID_ROWS.map(rd => (
                  <td key={rd.key} style={{ ...cell, fontWeight: bold(c), color: rowInk(c, rd.key) }}>{rd.cell(c)}</td>
                ))}
              </tr>
              {c.sf.length > 0 && (
                <tr style={{ background: colBg(c) }}>
                  <td colSpan={heads.length} style={{ padding: "0 6px 8px", fontSize: 12, color: ink(c) }}><SfCell list={c.sf} inline /></td>
                </tr>
              )}
            </Fragment>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// The old step by step, kept one tap away for when a number needs explaining.
function StepList({ steps, onJump }) {
  return (
    <ol style={{ listStyle: "none", margin: 0, padding: 0, display: "grid", gap: 10 }}>
      {steps.map((st, k) => (
        <li key={`${st.rowId}-${k}`} style={{ display: "grid", gridTemplateColumns: "54px 1fr", gap: 10, opacity: st.tone === "muted" ? 0.65 : 1 }}>
          <button type="button" onClick={() => onJump(st.rowId)} title="Show this line in the table" style={{
            background: "none", border: "none", padding: "2px 0 0", textAlign: "left", fontSize: 12, fontWeight: 700,
            color: T.slate500, cursor: "pointer", fontFamily: "inherit", alignSelf: "start",
          }}>{fmtDateShort(st.date)}</button>
          <div style={{ display: "grid", gap: 2 }}>
            <div style={{ display: "flex", gap: 8, alignItems: "baseline", fontSize: 14, color: T.slate900, fontWeight: st.tone === "start" ? 700 : 500 }}>
              <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: 999, flexShrink: 0, background: TONE_COLOR[st.tone] || T.slate400 }} />
              <span>{st.text}</span>
            </div>
            {(st.sub || []).filter(Boolean).length > 0 && (
              <div style={{ marginLeft: 16, display: "grid", gap: 2 }}>
                {st.sub.filter(Boolean).map((line, j, arr) => <StepSub key={j} step={st} line={line} last={j === arr.length - 1} />)}
              </div>
            )}
          </div>
        </li>
      ))}
    </ol>
  );
}

function SectionExplained({ s, showTitle, width, onJump }) {
  const [stepsOpen, setStepsOpen] = useState(false);
  return (
    <div style={{ display: "grid", gap: 10 }}>
      {showTitle && <div style={{ fontSize: 14, fontWeight: 800, color: T.slate900 }}>{s.title}</div>}
      <DateGrid grid={s.grid} width={width} />
      {s.steps.length > 0 && (
        <div>
          <button type="button" onClick={() => setStepsOpen(o => !o)} aria-expanded={stepsOpen} style={linkBtn}>
            {stepsOpen ? "Hide the steps" : "Show every step"}
          </button>
          {stepsOpen && <div style={{ marginTop: 10 }}><StepList steps={s.steps} onJump={onJump} /></div>}
        </div>
      )}
    </div>
  );
}

function Explanation({ expl, who, onClose, onJump }) {
  const ref = useRef(null);
  const width = useElementWidth(ref);
  const [eachOpen, setEachOpen] = useState(false);
  const billing = (expl.sections || []).filter(s => s.kind === "billing");
  const accounts = (expl.sections || []).filter(s => s.kind === "account");
  return (
    <section ref={ref} style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 18, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
        <div style={{ fontSize: 16, fontWeight: 800, color: T.slate900 }}>
          {expl.ok ? `Here's what happened${who ? ` for ${who}` : ""}` : "A few lines need fixing first"}
        </div>
        <button type="button" onClick={onClose} style={xBtn} aria-label="Close" title="Close">×</button>
      </div>
      {!expl.ok && (
        <div style={{ display: "grid", gap: 6 }}>
          {expl.problems.map((p, k) => (
            <button key={k} type="button" onClick={() => p.rowId && onJump(p.rowId)} style={{
              textAlign: "left", background: T.redLt, border: "none", borderRadius: 8, padding: "8px 12px", fontSize: 14,
              color: T.slate800, cursor: p.rowId ? "pointer" : "default", fontFamily: "inherit",
            }}>{p.text}</button>
          ))}
        </div>
      )}
      {expl.ok && billing.map(s => <SectionExplained key={String(s.key)} s={s} showTitle width={width - 36} onJump={onJump} />)}
      {expl.ok && billing.length > 0 && accounts.length > 0 && (
        <div>
          <button type="button" onClick={() => setEachOpen(o => !o)} aria-expanded={eachOpen} style={linkBtn}>
            {eachOpen ? "Hide each account" : "Show each account"}
          </button>
        </div>
      )}
      {expl.ok && (!billing.length || eachOpen) && accounts.map(s => (
        <SectionExplained key={String(s.key)} s={s} showTitle={billing.length > 0 || accounts.length > 1} width={width - 36} onJump={onJump} />
      ))}
      {expl.warnings.length > 0 && (
        <div style={{ display: "grid", gap: 6 }}>
          {expl.warnings.map((w, k) => (
            <div key={k} style={{ fontSize: 13, color: T.slate800, background: T.amberLt, borderRadius: 8, padding: "8px 12px" }}>{w.text}</div>
          ))}
        </div>
      )}
    </section>
  );
}

// ---------- the customer the worksheet belongs to ----------
function CustomerBar({ customer, onCustomer, status, onToggleList, listOpen }) {
  const statusColor = status.kind === "error" ? T.red : T.slate500;
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center", padding: "10px 12px", borderBottom: `1px solid ${T.slate200}` }}>
      <span style={{ fontSize: 13, fontWeight: 700, color: T.slate700 }}>Customer</span>
      <input {...noPwManager("dw1")} value={customer.first} placeholder="First name" aria-label="Customer first name"
        onChange={e => onCustomer({ first: e.target.value })} style={{ ...box, width: 150 }} />
      <input {...noPwManager("dw2")} value={customer.initial} placeholder="Last initial" aria-label="Customer last initial"
        maxLength={1} onChange={e => onCustomer({ initial: e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 1).toUpperCase() })}
        style={{ ...box, width: 96 }} />
      <input {...noPwManager("dw3")} value={customer.phone4} placeholder="Phone last 4" aria-label="Customer phone last 4"
        inputMode="numeric" maxLength={4} onChange={e => onCustomer({ phone4: e.target.value.replace(/\D/g, "").slice(0, 4) })}
        style={{ ...box, width: 112 }} />
      {status.text ? <span style={{ fontSize: 12, color: statusColor }}>{status.text}</span> : null}
      <button type="button" onClick={onToggleList} aria-expanded={listOpen} style={{ ...btnGhost, marginLeft: "auto" }}>
        Saved worksheets
      </button>
    </div>
  );
}

function SavedList({ onOpen }) {
  const [q, setQ] = useState("");
  const [list, setList] = useState(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    const t = setTimeout(async () => {
      if (!supabase) { setErr("Saved worksheets need the live site."); setList([]); return; }
      const r = await supabase.rpc("billing_worksheet_list", { p_search: q.trim() || null, p_limit: 25 });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); setList([]); return; }
      setErr("");
      setList(Array.isArray(r.data) ? r.data : []);
    }, 250);
    return () => { alive = false; clearTimeout(t); };
  }, [q]);
  return (
    <div style={{ padding: 12, background: T.slate50, borderBottom: `1px solid ${T.slate200}`, display: "grid", gap: 8 }}>
      <input {...noPwManager("dw4")} value={q} onChange={e => setQ(e.target.value)} placeholder="Search by first name"
        aria-label="Search saved worksheets" style={{ ...box, maxWidth: 260 }} />
      {err ? <div style={{ fontSize: 13, color: T.red }}>{err}</div> : null}
      {list === null ? <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
        : list.length === 0 ? (!err && <div style={{ fontSize: 13, color: T.slate500 }}>No saved worksheets{q.trim() ? " by that name" : " yet"}.</div>)
        : (
          <div style={{ display: "grid", gap: 4 }}>
            {list.map(w => (
              <button key={w.id} type="button" onClick={() => onOpen(w)} style={{
                display: "flex", flexWrap: "wrap", gap: "2px 12px", alignItems: "baseline", textAlign: "left", width: "100%",
                background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "8px 12px", cursor: "pointer",
                fontFamily: "inherit", fontSize: 13, color: T.slate800, boxSizing: "border-box",
              }}>
                <strong>{customerName(w)}</strong>
                <span style={{ color: T.slate600 }}>Phone ends {w.phone4}</span>
                <span style={{ marginLeft: "auto", color: T.slate500 }}>
                  {w.line_count} {w.line_count === 1 ? "line" : "lines"}, saved {fmtDateShort(String(w.updated_at).slice(0, 10))}{w.updated_by ? ` by ${w.updated_by}` : ""}
                </span>
              </button>
            ))}
          </div>
        )}
    </div>
  );
}

export default function DeweyOwe() {
  const _vp = useViewport();
  const phone = _vp.isPhone;
  const today = todayISOCentral();
  const [draft, setDraft] = useState(loadDraft);
  const [open, setOpen] = useState(false);
  const [scrollTick, setScrollTick] = useState(0);
  const [focusId, setFocusId] = useState(null);
  const [flashId, setFlashId] = useState(null);
  const [found, setFound] = useState(null);           // a saved worksheet for the customer typed, not opened yet
  const [save, setSave] = useState({ kind: "", at: null, msg: "" });
  const [listOpen, setListOpen] = useState(false);
  const tableRef = useRef(null);
  const boxRef = useRef(null);
  const typeRefs = useRef(new Map());
  const lastSaved = useRef("");
  const width = useElementWidth(tableRef);
  const compact = width > 0 && width < COMPACT_BELOW;
  const { rows, accounts, customer, loadedKey } = draft;
  const key = keyOf(customer);
  const hasLines = rows.some(r => !isBlankRow(r));

  useEffect(() => { saveDraft(draft); }, [draft]);
  useEffect(() => {
    if (!focusId) return;
    const el = typeRefs.current.get(focusId);
    if (el) el.focus();
    setFocusId(null);
  }, [focusId]);
  useEffect(() => {
    if (!scrollTick || !boxRef.current) return;
    const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    boxRef.current.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
  }, [scrollTick]);
  useEffect(() => {
    if (!flashId) return undefined;
    const t = setTimeout(() => setFlashId(null), 1400);
    return () => clearTimeout(t);
  }, [flashId]);

  // Once the customer is filled in, look for their saved worksheet. An empty
  // page opens it; a page with lines on it asks first.
  useEffect(() => {
    setFound(null);
    if (!key || key === loadedKey || !supabase) return undefined;
    let alive = true;
    const t = setTimeout(async () => {
      const r = await supabase.rpc("billing_worksheet_get", { p_first: customer.first, p_initial: customer.initial, p_phone4: customer.phone4 });
      if (!alive) return;
      if (r.error) { setSave({ kind: "error", at: null, msg: errText(r.error) }); return; }
      const w = r.data && typeof r.data === "object" ? r.data : null;
      if (!w) { setDraft(d => ({ ...d, loadedKey: key })); return; }
      if (!hasLines) openWorksheet(w);
      else setFound(w);
    }, 400);
    return () => { alive = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, loadedKey]);

  // Saves as they go, once the worksheet belongs to a customer.
  useEffect(() => {
    if (!key || key !== loadedKey || !hasLines || !supabase) return undefined;
    const body = JSON.stringify({ lines: savedLines(rows), accounts });
    if (body === lastSaved.current) return undefined;
    const t = setTimeout(async () => {
      setSave({ kind: "saving", at: null, msg: "" });
      const r = await supabase.rpc("billing_worksheet_save", {
        p_first: cap(customer.first.trim()), p_initial: customer.initial, p_phone4: customer.phone4,
        p_lines: savedLines(rows), p_accounts: accounts,
      });
      if (r.error || !r.data?.ok) { setSave({ kind: "error", at: null, msg: errText(r.error || "Not saved.") }); return; }
      lastSaved.current = body;
      setSave({ kind: "saved", at: new Date(), msg: "" });
    }, SAVE_AFTER_MS);
    return () => clearTimeout(t);
  }, [rows, accounts, customer, key, loadedKey, hasLines]);

  const ledger = useMemo(() => buildLedger(rows), [rows]);
  const expl = useMemo(() => (open ? explainBilling({ rows, accounts, today }) : null), [open, rows, accounts, today]);
  const ooo = useMemo(() => new Set(outOfOrderIds(rows)), [rows]);
  // Every account the page knows of, whether set up or only named on a line.
  const policyIds = useMemo(() => {
    const s = new Set(Object.keys(accounts || {}).filter(k => /^\d+$/.test(k)).map(Number));
    for (const r of rows) if (!isBillingKey(r.account)) s.add(r.account);
    return [...s].sort((a, b) => a - b);
  }, [accounts, rows]);
  const billingIds = useMemo(() => {
    const s = new Set(Object.keys(accounts || {}).filter(isBillingKey));
    for (const r of rows) if (isBillingKey(r.account)) s.add(r.account);
    return [...s].sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));
  }, [accounts, rows]);
  const problemIds = useMemo(() => new Set((expl?.problems || []).map(p => p.rowId).filter(Boolean)), [expl]);
  const warnIds = useMemo(() => new Set((expl?.warnings || []).map(w => w.rowId).filter(Boolean)), [expl]);

  const setRows = (fn) => setDraft(d => ({ ...d, rows: fn(d.rows) }));
  const onRow = (id, patch) => setRows(rs => rs.map((r, idx) => {
    if (r.id !== id) return r;
    const next = { ...r, ...patch };
    if ("type" in patch) {
      const t = deweyType(next.type);
      const was = deweyType(r.type);
      if (t) {
        // The date the line already has moves to the box this type uses.
        const have = lineDate(r) || next.processDate || next.dueDate;
        if (t.proc === "none") {
          next.dueDate = next.dueDate && was?.proc === "none" ? next.dueDate : have;
          next.processDate = "";
        } else {
          next.processDate = next.processDate || have;
          if (was?.proc === "none") next.dueDate = "";
          if (t.due === "none") next.dueDate = "";
          else if (!next.dueDate) {
            // Start the second date box where the team already is: the last due date entered above.
            for (let k = idx - 1; k >= 0; k--) { if (rs[k].dueDate) { next.dueDate = rs[k].dueDate; break; } }
          }
        }
      }
      if (t && t.fixed) next.amount = "";
      else if (t && String(next.amount).trim() !== "") next.amount = tidyAmount(next);
      if (t && (t.role === "start" || t.role === "change") && isBillingKey(next.account)) {
        const covers = (draft.accounts[next.account]?.covers || []).map(Number);
        next.account = covers[0] || policyIds[0] || 1;
      }
    }
    return next;
  }));
  const onRemove = (id) => setRows(rs => {
    const left = rs.filter(r => r.id !== id);
    return left.length ? left : [blankRow(1)];
  });
  const addRow = () => {
    const last = rows[rows.length - 1];
    const lastDate = [...rows].reverse().map(lineDate).find(Boolean) || "";
    const nr = { ...blankRow(last ? last.account : 1), processDate: lastDate };
    setRows(rs => [...rs, nr]);
    setFocusId(nr.id);
  };
  const onLob = (a, lob) => setDraft(d => ({ ...d, accounts: { ...d.accounts, [a]: { plan: "monthly", ...(d.accounts[a] || {}), lob } } }));
  const onPlan = (a, plan) => setDraft(d => ({ ...d, accounts: { ...d.accounts, [a]: { lob: "", ...(d.accounts[a] || {}), plan } } }));
  const onNewAccount = (rowId) => {
    const n = (policyIds.length ? Math.max(...policyIds) : 0) + 1;
    setDraft(d => ({
      ...d,
      rows: d.rows.map(r => (r.id === rowId ? { ...r, account: n } : r)),
      accounts: { ...d.accounts, [n]: { lob: "", plan: "monthly" } },
    }));
  };
  // A new billing account starts out paying for every account on the page.
  const onNewBilling = (rowId) => {
    const m = (billingIds.length ? Math.max(...billingIds.map(b => Number(b.slice(1)))) : 0) + 1;
    const b = `B${m}`;
    setDraft(d => ({
      ...d,
      rows: d.rows.map(r => (r.id === rowId ? { ...r, account: b } : r)),
      accounts: { ...d.accounts, [b]: { covers: [...policyIds] } },
    }));
  };
  const onCover = (b, a) => setDraft(d => {
    const cur = (d.accounts[b]?.covers || []).map(Number);
    const covers = cur.includes(a) ? cur.filter(x => x !== a) : [...cur, a].sort((x, y) => x - y);
    return { ...d, accounts: { ...d.accounts, [b]: { ...(d.accounts[b] || {}), covers } } };
  });
  const onCustomer = (patch) => {
    setSave({ kind: "", at: null, msg: "" });
    setDraft(d => ({ ...d, customer: { ...d.customer, ...patch } }));
  };
  function openWorksheet(w) {
    const lines = cleanRows(w.lines);
    const acc = cleanAccounts(w.accounts);
    const cust = { first: cap(String(w.first || "")), initial: String(w.initial || ""), phone4: String(w.phone4 || "") };
    lastSaved.current = JSON.stringify({ lines, accounts: acc });
    setDraft({ rows: lines.length ? lines : [blankRow(1)], accounts: acc, customer: cust, loadedKey: keyOf(cust) });
    setFound(null);
    setOpen(false);
    setSave({ kind: "saved", at: w.updated_at ? new Date(w.updated_at) : null, msg: "" });
  }
  const openFromList = async (w) => {
    if (!supabase) return;
    if (hasLines && (!key || key !== loadedKey) && !window.confirm("Replace the lines on this page with the saved worksheet?")) return;
    const r = await supabase.rpc("billing_worksheet_get", { p_first: w.first, p_initial: w.initial, p_phone4: w.phone4 });
    if (r.error || !r.data) { setSave({ kind: "error", at: null, msg: errText(r.error || "That worksheet is gone.") }); return; }
    openWorksheet(r.data);
    setListOpen(false);
  };
  const makeSense = () => { setOpen(true); setScrollTick(t => t + 1); };
  const startOver = () => {
    if (!window.confirm("Clear the page and start a new worksheet? Saved worksheets stay saved.")) return;
    lastSaved.current = "";
    setDraft(freshDraft());
    setOpen(false);
    setFound(null);
    setSave({ kind: "", at: null, msg: "" });
  };
  const jumpTo = (rowId) => {
    const el = document.getElementById(`dewey-row-${rowId}`);
    if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
    setFlashId(rowId);
  };

  const status = save.kind === "saving" ? { text: "Saving…" }
    : save.kind === "saved" ? { text: save.at ? `Saved ${savedWhen(save.at)}` : "Saved" }
    : save.kind === "error" ? { kind: "error", text: save.msg }
    : hasLines && !key ? { text: "Fill in the customer to save." }
    : { text: "" };
  const gutterW = ledger.laneCount ? 12 + ledger.laneCount * LANE_W : 10;
  const dotY = ROW_PAD + (compact ? 16 : 0) + INPUT_H / 2;
  const lastUserId = rows.length ? rows[rows.length - 1].id : null;
  const mood = expl && expl.ok ? "happy" : "confused";

  return (
    <div className="nw-dewey" style={{ display: "grid", gap: 16 }}>
      <DeweyStyles />
      <div style={{ display: "flex", gap: phone ? 12 : 18, alignItems: "flex-start" }}>
        <Dewey mood={mood} size={phone ? 64 : 104} />
        <Bubble phone={phone} />
      </div>

      <div ref={boxRef} style={{ scrollMarginTop: 16 }}>
        {expl ? <Explanation expl={expl} who={key ? customerName(customer) : ""} onClose={() => setOpen(false)} onJump={jumpTo} /> : null}
      </div>

      {ooo.size > 0 && (
        <div style={{
          display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between",
          background: T.amberLt, borderRadius: 10, padding: "8px 12px", fontSize: 13, color: T.slate800,
        }}>
          <span>Some lines are out of date order. The math follows the process dates either way.</span>
          <button type="button" onClick={() => setRows(sortRowsByDate)} style={btnGhost}>Sort newest first</button>
        </div>
      )}

      <div ref={tableRef} style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, overflow: "hidden" }}>
        <CustomerBar customer={customer} onCustomer={onCustomer} status={status}
          listOpen={listOpen} onToggleList={() => setListOpen(o => !o)} />
        {found && (
          <div style={{
            display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", padding: "10px 12px",
            background: T.blueLt, borderBottom: `1px solid ${T.slate200}`, fontSize: 13, color: T.slate800,
          }}>
            <span>
              {customerName(found)} already has a saved worksheet
              {found.updated_at ? `, last saved ${fmtDateShort(String(found.updated_at).slice(0, 10))}` : ""}
              {found.updated_by ? ` by ${found.updated_by}` : ""}.
            </span>
            <button type="button" onClick={() => openWorksheet(found)} style={btnGhost}>Open it</button>
            <button type="button" onClick={() => { setFound(null); setDraft(d => ({ ...d, loadedKey: key })); }} style={linkBtn}>
              Replace it with this page
            </button>
          </div>
        )}
        {listOpen && <SavedList onOpen={openFromList} />}
        {billingIds.map(b => {
          const covers = (accounts[b]?.covers || []).map(Number);
          return (
            <div key={b} style={{
              display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center", padding: "8px 12px",
              borderBottom: `1px solid ${T.slate100}`, fontSize: 13, color: T.slate700,
            }}>
              <span style={{ fontWeight: 700 }}>{accountLabel(b)} pays for</span>
              {policyIds.map(a => (
                <button key={a} type="button" aria-pressed={covers.includes(a)} onClick={() => onCover(b, a)} style={chip(covers.includes(a))}>
                  {accountLabel(a)}
                </button>
              ))}
            </div>
          );
        })}
        {!compact && (
          <div style={{ display: "flex", background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
            <div style={{ width: gutterW, flexShrink: 0 }} />
            <div style={{ flex: 1, minWidth: 0, display: "grid", gap: 8, gridTemplateColumns: GRID, padding: "8px 10px 8px 0" }}>
              {["Type", "Process date", "Paid", "Owed", "Effective / due date", "Account", ""].map((h, k) => (
                <div key={k} style={{ fontSize: 12, fontWeight: 700, color: T.slate600, textAlign: k === 2 || k === 3 ? "right" : "left", paddingRight: k === 2 || k === 3 ? 8 : 0 }}>{h}</div>
              ))}
            </div>
          </div>
        )}
        {ledger.display.map((r, i) => {
          const greyed = r.type === "binder" && !!ledger.info.get(r.account)?.hasNB;
          const tint = flashId === r.id ? "flash"
            : problemIds.has(r.id) ? "problem"
            : (warnIds.has(r.id) || ooo.has(r.id)) ? "warn" : "";
          return (
            <Row key={r.id} r={r} i={i} ledger={ledger} accounts={accounts} policyIds={policyIds} billingIds={billingIds}
              compact={compact} gutterW={gutterW} dotY={dotY} tint={tint} greyed={greyed}
              onRow={onRow} onRemove={onRemove} onLob={onLob} onPlan={onPlan} onNewAccount={onNewAccount} onNewBilling={onNewBilling}
              typeRef={(el) => { if (el) typeRefs.current.set(r.id, el); else typeRefs.current.delete(r.id); }}
              isLast={r.id === lastUserId} onEnter={addRow} />
          );
        })}
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", padding: 12 }}>
          <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
            <button type="button" onClick={addRow} style={btnGhost}>+ Add line</button>
            <button type="button" onClick={startOver} style={linkBtn}>Start over</button>
          </div>
          <button type="button" onClick={makeSense} style={btnPrimary}>Make it Make Sense</button>
        </div>
      </div>
    </div>
  );
}
