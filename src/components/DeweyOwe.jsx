import { useState, useEffect, useMemo, useRef } from "react";
import { T } from "../lib/theme.js";
import { useViewport, useElementWidth } from "../lib/hooks.js";
import { todayISOCentral } from "../lib/weeks.js";
import { fmtDateShort } from "../lib/utils.js";
import {
  DEWEY_TYPES, DEWEY_LOBS, DEWEY_PLANS, deweyType, blankRow, rowCents, tidyAmount,
  buildLedger, explainBilling, outOfOrderIds, sortRowsByDate,
} from "../lib/deweyOwe.js";

// =====================================================================
// Dewey Owe: the Dashboard's billing explainer (Peter 2026-09-25).
// The team copies every line of the customer's SF Billing & payment
// history into the table, newest first, then presses Make it Make Sense.
// All the math lives in src/lib/deweyOwe.js; this file only draws it.
//
//  * The page is a scratchpad. Lines stay in this browser until Start over,
//    so a refresh loses nothing, and no customer detail is ever saved.
//  * Each type forces its own column, so credit and debit never share a line.
//  * Locked lines (the Paid behind a Declined, the fee behind a return or
//    decline) are drawn for the team, never typed, and cannot be changed.
//  * Linked lines are joined by a drawn line in the left margin, one lane
//    per link, so two links never share a line (Peter asked for lines over
//    colour alone).
//  * Problems show after the button is pressed, not while typing
//    (Bargas-Avila et al. 2007), the same way the Log tab does it.
// =====================================================================

const STORE_KEY = "newtworks.deweyOwe.v1";
const LINE_COLORS = [T.purple, T.teal, T.gold, T.pink, T.blue, T.red];
const LANE_W = 12;
const INPUT_H = 34;
const ROW_PAD = 8;
const COMPACT_BELOW = 900;
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

function freshDraft() {
  return { rows: [blankRow(1)], accounts: { 1: { lob: "", plan: "monthly" } } };
}
function loadDraft() {
  try {
    const d = JSON.parse(window.localStorage.getItem(STORE_KEY) || "null");
    if (d && Array.isArray(d.rows) && d.accounts && typeof d.accounts === "object") {
      const rows = d.rows.filter(r => r && typeof r.id === "string").map(r => ({
        id: r.id, type: r.type || "", processDate: r.processDate || "", amount: r.amount ?? "",
        dueDate: r.dueDate || "", account: Number(r.account) || 1,
      }));
      if (rows.length) return { rows, accounts: d.accounts };
    }
  } catch { /* private mode or a damaged draft: start clean */ }
  return freshDraft();
}
function saveDraft(d) {
  try { window.localStorage.setItem(STORE_KEY, JSON.stringify(d)); } catch { /* private mode */ }
}
// Locked dates read like the date boxes around them.
function usDate(iso) {
  if (!iso) return "";
  const [y, m, d] = iso.split("-");
  return `${m}/${d}/${y}`;
}
function withPeriod(s) {
  return /[.!?]$/.test(s) ? s : `${s}.`;
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
      @media (prefers-reduced-motion: reduce) { .nw-dewey-pop { animation: none; } }
      .nw-dewey input:focus, .nw-dewey select:focus { border-color: ${T.blue} !important; }
      .nw-dewey input:focus-visible, .nw-dewey select:focus-visible, .nw-dewey button:focus-visible {
        outline: none; box-shadow: 0 0 0 3px ${T.blueLt}, 0 0 0 4px ${T.blue};
      }
    `}</style>
  );
}

// Dewey: a receipt scratching his head. Once the lines make sense he
// stops scratching and smiles.
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
          <text x="102" y="26" fontSize="26" transform="rotate(12 102 26)">?</text>
          <text x="1" y="40" fontSize="17" transform="rotate(-12 1 40)" opacity="0.85">?</text>
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
          <path d="M100 74 Q116 66 111 47" stroke={T.slate700} strokeWidth="3" fill="none" strokeLinecap="round" />
          <circle cx="111" cy="44" r="4.5" fill={T.white} stroke={T.slate700} strokeWidth="2.5" />
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
  r, i, ledger, accounts, accountIds, compact, gutterW, dotY, tint, greyed,
  onRow, onRemove, onLob, onPlan, onNewAccount, typeRef, isLast, onEnter,
}) {
  const t = deweyType(r.type);
  const locked = !!r.auto;
  const meta = accounts[r.account] || {};
  const lob = LOB_LABEL[meta.lob] || "";
  const start = t?.role === "start";
  const shown = t && (locked || t.fixed) ? (rowCents(r) / 100).toFixed(2) : "";
  const dueLabel = t && (t.role === "bill" || t.role === "notice") ? "Due date" : "Effective date";

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
      {start && !greyed && (
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

  const dateCell = locked
    ? <div style={lockedCell}>{usDate(r.processDate)}</div>
    : <input type="date" value={r.processDate} aria-label="Process date"
        onChange={e => onRow(r.id, { processDate: e.target.value })} style={box} />;

  const amountCell = (col) => {
    if (!t || t.col !== col) return <div style={{ height: INPUT_H }} />;
    if (locked || t.fixed) return <div style={{ ...lockedCell, justifyContent: "flex-end" }}>{shown}</div>;
    return (
      <input type="text" inputMode="decimal" value={r.amount} aria-label={col === "credit" ? "Credit" : "Debit"}
        placeholder={t.sign === -1 ? "-0.00" : "0.00"}
        onChange={e => onRow(r.id, { amount: e.target.value })}
        onBlur={() => onRow(r.id, { amount: tidyAmount(r) })} style={moneyBox} />
    );
  };

  const dueCell = !t || t.due === "none"
    ? <div style={{ height: INPUT_H }} />
    : <input type="date" value={r.dueDate} aria-label={dueLabel}
        onChange={e => onRow(r.id, { dueDate: e.target.value })} style={box} />;

  const acctCell = locked ? (
    <div style={lockedCell}>Account {r.account}{lob ? <Tag>{lob}</Tag> : null}</div>
  ) : (
    <div style={{ display: "flex", gap: 6, alignItems: "center", height: INPUT_H }}>
      <select value={String(r.account)} aria-label="Account" style={{ ...box, flex: "1 1 auto", minWidth: 0 }}
        onChange={e => (e.target.value === "new" ? onNewAccount(r.id) : onRow(r.id, { account: Number(e.target.value) }))}>
        {accountIds.map(a => <option key={a} value={String(a)}>Account {a}</option>)}
        <option value="new">+ New account</option>
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
            {cell("Process date", dateCell)}
            {t ? cell(t.col === "credit" ? "Credit" : "Debit", amountCell(t.col)) : null}
            {t && t.due !== "none" ? cell(dueLabel, dueCell) : null}
            {cell("Account", acctCell)}
          </>
        ) : (
          <>
            {typeCell}
            {dateCell}
            {amountCell("credit")}
            {amountCell("debit")}
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

function AccountExplained({ a, many, onJump }) {
  return (
    <div style={{ display: "grid", gap: 12 }}>
      {many && <div style={{ fontSize: 14, fontWeight: 800, color: T.slate900 }}>Account {a.account}: {a.lob}, {a.plan}</div>}
      <div style={{ background: T.slate50, borderRadius: 10, padding: "12px 14px", display: "grid", gap: 6 }}>
        {a.summary.map(s => (
          <div key={s.key} style={{ fontSize: 14, color: T.slate600, lineHeight: 1.5 }}>
            {s.label}: <strong style={{ color: s.tone === "warn" ? T.red : T.slate900 }}>{s.value}</strong>.
            {s.note ? <span> {withPeriod(s.note)}</span> : null}
          </div>
        ))}
      </div>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate600 }}>How it got here</div>
      <ol style={{ listStyle: "none", margin: 0, padding: 0, display: "grid", gap: 10 }}>
        {a.steps.map((s, k) => (
          <li key={`${s.rowId}-${k}`} style={{ display: "grid", gridTemplateColumns: "54px 1fr", gap: 10, opacity: s.tone === "muted" ? 0.65 : 1 }}>
            <button type="button" onClick={() => onJump(s.rowId)} title="Show this line in the table" style={{
              background: "none", border: "none", padding: "2px 0 0", textAlign: "left", fontSize: 12, fontWeight: 700,
              color: T.slate500, cursor: "pointer", fontFamily: "inherit", alignSelf: "start",
            }}>{fmtDateShort(s.date)}</button>
            <div style={{ display: "grid", gap: 2 }}>
              <div style={{ display: "flex", gap: 8, alignItems: "baseline", fontSize: 14, color: T.slate900, fontWeight: s.tone === "start" ? 700 : 500 }}>
                <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: 999, flexShrink: 0, background: TONE_COLOR[s.tone] || T.slate400 }} />
                <span>{s.text}</span>
              </div>
              {(s.sub || []).filter(Boolean).length > 0 && (
                <div style={{ marginLeft: 16, display: "grid", gap: 2 }}>
                  {s.sub.filter(Boolean).map((line, j, arr) => <StepSub key={j} step={s} line={line} last={j === arr.length - 1} />)}
                </div>
              )}
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}

function Explanation({ expl, onClose, onJump }) {
  return (
    <section style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 18, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
        <div style={{ fontSize: 16, fontWeight: 800, color: T.slate900 }}>
          {expl.ok ? "Here's what happened" : "A few lines need fixing first"}
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
      {expl.ok && expl.accounts.map(a => (
        <AccountExplained key={a.account} a={a} many={expl.accounts.length > 1} onJump={onJump} />
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

export default function DeweyOwe() {
  const _vp = useViewport();
  const phone = _vp.isPhone;
  const today = todayISOCentral();
  const [draft, setDraft] = useState(loadDraft);
  const [open, setOpen] = useState(false);
  const [scrollTick, setScrollTick] = useState(0);
  const [focusId, setFocusId] = useState(null);
  const [flashId, setFlashId] = useState(null);
  const tableRef = useRef(null);
  const boxRef = useRef(null);
  const typeRefs = useRef(new Map());
  const width = useElementWidth(tableRef);
  const compact = width > 0 && width < COMPACT_BELOW;
  const { rows, accounts } = draft;

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

  const ledger = useMemo(() => buildLedger(rows), [rows]);
  const expl = useMemo(() => (open ? explainBilling({ rows, accounts, today }) : null), [open, rows, accounts, today]);
  const ooo = useMemo(() => new Set(outOfOrderIds(rows)), [rows]);
  const accountIds = useMemo(
    () => Object.keys(accounts || {}).map(Number).filter(Number.isFinite).sort((a, b) => a - b),
    [accounts],
  );
  const problemIds = useMemo(() => new Set((expl?.problems || []).map(p => p.rowId).filter(Boolean)), [expl]);
  const warnIds = useMemo(() => new Set((expl?.warnings || []).map(w => w.rowId).filter(Boolean)), [expl]);

  const setRows = (fn) => setDraft(d => ({ ...d, rows: fn(d.rows) }));
  const onRow = (id, patch) => setRows(rs => rs.map(r => {
    if (r.id !== id) return r;
    const next = { ...r, ...patch };
    if ("type" in patch) {
      const t = deweyType(next.type);
      if (!t || t.due === "none") next.dueDate = "";
      if (t && t.fixed) next.amount = "";
      else if (t && String(next.amount).trim() !== "") next.amount = tidyAmount(next);
    }
    return next;
  }));
  const onRemove = (id) => setRows(rs => {
    const left = rs.filter(r => r.id !== id);
    return left.length ? left : [blankRow(1)];
  });
  const addRow = () => {
    const last = rows[rows.length - 1];
    const nr = blankRow(last ? last.account : 1);
    setRows(rs => [...rs, nr]);
    setFocusId(nr.id);
  };
  const onLob = (a, lob) => setDraft(d => ({ ...d, accounts: { ...d.accounts, [a]: { plan: "monthly", ...(d.accounts[a] || {}), lob } } }));
  const onPlan = (a, plan) => setDraft(d => ({ ...d, accounts: { ...d.accounts, [a]: { lob: "", ...(d.accounts[a] || {}), plan } } }));
  const onNewAccount = (rowId) => {
    const n = (accountIds.length ? Math.max(...accountIds) : 0) + 1;
    setDraft(d => ({
      rows: d.rows.map(r => (r.id === rowId ? { ...r, account: n } : r)),
      accounts: { ...d.accounts, [n]: { lob: "", plan: "monthly" } },
    }));
  };
  const makeSense = () => { setOpen(true); setScrollTick(t => t + 1); };
  const startOver = () => {
    if (!window.confirm("Clear every line and start over?")) return;
    setDraft(freshDraft());
    setOpen(false);
  };
  const jumpTo = (rowId) => {
    const el = document.getElementById(`dewey-row-${rowId}`);
    if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
    setFlashId(rowId);
  };

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
        {expl ? <Explanation expl={expl} onClose={() => setOpen(false)} onJump={jumpTo} /> : null}
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
        {!compact && (
          <div style={{ display: "flex", background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
            <div style={{ width: gutterW, flexShrink: 0 }} />
            <div style={{ flex: 1, minWidth: 0, display: "grid", gap: 8, gridTemplateColumns: GRID, padding: "8px 10px 8px 0" }}>
              {["Type", "Process date", "Credit", "Debit", "Effective / due date", "Account", ""].map((h, k) => (
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
            <Row key={r.id} r={r} i={i} ledger={ledger} accounts={accounts} accountIds={accountIds} compact={compact}
              gutterW={gutterW} dotY={dotY} tint={tint} greyed={greyed}
              onRow={onRow} onRemove={onRemove} onLob={onLob} onPlan={onPlan} onNewAccount={onNewAccount}
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
