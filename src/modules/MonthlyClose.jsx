import { useState, useMemo, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useSupabaseTable } from "../lib/hooks.js";
import EmptyState from "../components/EmptyState.jsx";

// ============================================================
// BCC MONTHLY CLOSE MODULE v1.0
// Business Command Center — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// PURPOSE:
//   The monthly close cockpit. For any period it answers one
//   question at a glance: "What is the system still waiting on
//   before this month can close?" — then lets the agent mark
//   items received and close the month.
//
// SECTIONS:
//   1. Checklist  — every close item, three-state status, Drive links
//   2. Timeline   — items ordered by expected_by, overdue flags
//
// STATUS MODEL (three-state, locked decision):
//   pending   → grey   → nothing received yet, system waiting
//   partial   → amber  → some period data in, awaiting the rest
//   received  → green  → all expected data in for the period
//
// DATA:
//   Reads  monthly_close_checklist (scoped to agency_id)
//   Joins  documents (drive_url, file_name, processed_at) by document_id
//   Writes status / received_at / is_closed back on agent action
//
// PERIOD ASSIGNMENT RULE:
//   A checklist row's period is period_year / period_month — NOT
//   documents.processed_at (which is the system processing date).
// ============================================================


// ─── Design Tokens ────────────────────────────────────────────
const T = {
  navy:    "#1B2B4B",
  blue:    "#2D7DD2",
  blueLt:  "#EFF6FF",
  green:   "#10B981",
  greenLt: "#D1FAE5",
  amber:   "#F59E0B",
  amberLt: "#FEF3C7",
  red:     "#EF4444",
  redLt:   "#FEE2E2",
  purple:  "#7C3AED",
  purpleLt:"#EDE9FE",
  teal:    "#0D9488",
  tealLt:  "#CCFBF1",
  slate50: "#F8FAFC",
  slate100:"#F1F5F9",
  slate200:"#E2E8F0",
  slate400:"#94A3B8",
  slate500:"#64748B",
  slate600:"#475569",
  slate700:"#334155",
  slate800:"#1E293B",
  slate900:"#0F172A",
  white:   "#FFFFFF",
};

const MONTHS = ["", "January","February","March","April","May","June",
  "July","August","September","October","November","December"];

// ─── Category Config ──────────────────────────────────────────
// Maps doc_category values (aligned to recipe groq_classification)
// to a label + icon for display.
const CAT = {
  comp_recap_daily:   { label:"SF Daily Comp Recaps",  icon:"ð" },
  deduction_statement:{ label:"SF Deduction Statement", icon:"➖" },
  payroll:            { label:"Payroll (Heartland)",   icon:"ð¼" },
  production_report:  { label:"Producer Production",   icon:"ð¯" },
  bank_statement:     { label:"Bank Statement",        icon:"ð¦" },
  cc_statement:       { label:"Credit Card Statement", icon:"ð³" },
  reconciliation:     { label:"GL Reconciliation",     icon:"⚖️" },
  review:             { label:"Transaction Review",    icon:"ð" },
  balance_review:     { label:"Balance Review",        icon:"ð§¾" },
};
const catConfig = (c) => CAT[c] || { label:(c||"Item").replace(/_/g," "), icon:"ð" };

// ─── Status Config (three-state) ──────────────────────────────
const STATUS = {
  received: { label:"Received", color:"#065F46", bg:T.greenLt, dot:T.green,  hint:"All expected data is in" },
  partial:  { label:"Partial",  color:"#92400E", bg:T.amberLt, dot:T.amber,  hint:"Some data in — awaiting the rest" },
  pending:  { label:"Waiting",  color:T.slate600, bg:T.slate100, dot:T.slate400, hint:"Nothing received yet" },
};
const statusConfig = (s) => STATUS[s] || STATUS.pending;

// ─── Helpers ──────────────────────────────────────────────────
const fmtDate = (d) => {
  if (!d) return "—";
  const dt = new Date(d);
  if (isNaN(dt.getTime())) return "—";
  return dt.toLocaleDateString("en-US", { month:"short", day:"numeric", year:"numeric" });
};

// A simple date-only "today" in the browser's local zone, for overdue math.
const todayISO = () => {
  const n = new Date();
  return new Date(n.getFullYear(), n.getMonth(), n.getDate());
};

const isOverdue = (item) => {
  if (item.status === "received" || item.is_closed) return false;
  if (!item.expected_by) return false;
  const exp = new Date(item.expected_by);
  if (isNaN(exp.getTime())) return false;
  return exp < todayISO();
};

// ─── Shared Components ────────────────────────────────────────
const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);

const AskBtn = ({ context, size="normal" }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context || ""); window.open("https://claude.ai","_blank"); }}
    style={{ display:"flex", alignItems:"center", gap:5, background:T.blue, color:T.white, border:"none", borderRadius:7, padding:size==="small"?"5px 10px":"7px 13px", fontSize:size==="small"?10:11, fontWeight:600, cursor:"pointer", whiteSpace:"nowrap", flexShrink:0 }}
  >⚡ Ask Claude</button>
);

const StatusPill = ({ status }) => {
  const sc = statusConfig(status);
  return (
    <span style={{ display:"inline-flex", alignItems:"center", gap:5, fontSize:10, fontWeight:600, padding:"3px 9px", borderRadius:20, background:sc.bg, color:sc.color, whiteSpace:"nowrap" }}>
      <span style={{ width:6, height:6, borderRadius:"50%", background:sc.dot, flexShrink:0 }} />
      {sc.label}
    </span>
  );
};

const KpiTile = ({ label, value, sub, accent }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"14px 16px", borderTop:`3px solid ${accent || T.slate200}` }}>
    <div style={{ fontSize:11, color:T.slate500, marginBottom:6, fontWeight:500 }}>{label}</div>
    <div style={{ fontSize:24, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em", lineHeight:1.1 }}>{value}</div>
    {sub && <div style={{ fontSize:11, color:T.slate500, marginTop:5 }}>{sub}</div>}
  </div>
);


// ─── Checklist Row ────────────────────────────────────────────
const ChecklistRow = ({ item, doc, busy, monthClosed, onMark, onRevert }) => {
  const [expanded, setExpanded] = useState(false);
  const cc = catConfig(item.doc_category);
  const overdue = isOverdue(item);
  const driveUrl = doc?.drive_url || null;

  return (
    <div style={{
      background:T.white,
      border:`1px solid ${expanded ? T.blue : T.slate200}`,
      borderLeft:`4px solid ${statusConfig(item.status).dot}`,
      borderRadius:10, overflow:"hidden",
    }}>
      {/* Header row */}
      <div
        style={{ display:"flex", alignItems:"center", gap:12, padding:"12px 14px", cursor:"pointer" }}
        onClick={() => setExpanded(e => !e)}
      >
        <div style={{ fontSize:18, flexShrink:0 }}>{cc.icon}</div>

        <div style={{ flex:1, minWidth:0 }}>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate900, lineHeight:1.35 }}>
            {item.doc_label || cc.label}
          </div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2, display:"flex", gap:10, flexWrap:"wrap" }}>
            <span>Expected {fmtDate(item.expected_by)}</span>
            {item.received_at && <span style={{ color:T.green }}>Received {fmtDate(item.received_at)}</span>}
            {overdue && (
              <span style={{ color:T.red, fontWeight:600 }}>● Overdue</span>
            )}
          </div>
        </div>

        <StatusPill status={item.status} />
      </div>

      {/* Expanded detail */}
      {expanded && (
        <div style={{ borderTop:`1px solid ${T.slate100}`, padding:"12px 14px", background:T.slate50 }}>
          {item.notes && (
            <div style={{ fontSize:12, color:T.slate600, lineHeight:1.6, marginBottom:12, whiteSpace:"pre-wrap" }}>
              {item.notes}
            </div>
          )}

          <div style={{ display:"flex", flexWrap:"wrap", gap:8, alignItems:"center" }}>
            {driveUrl ? (
              <a
                href={driveUrl} target="_blank" rel="noopener noreferrer"
                style={{ display:"inline-flex", alignItems:"center", gap:6, fontSize:11, fontWeight:600, color:T.blue, background:T.blueLt, border:`1px solid ${T.slate200}`, borderRadius:7, padding:"6px 11px", textDecoration:"none" }}
              >
                ð {doc?.file_name || "View source document"}
              </a>
            ) : item.document_id ? (
              <span style={{ fontSize:11, color:T.slate500 }}>Source document linked (no Drive URL yet)</span>
            ) : (
              <span style={{ fontSize:11, color:T.slate400 }}>No source document linked</span>
            )}

            <div style={{ flex:1 }} />

            {!monthClosed && item.status !== "received" && (
              <button
                disabled={busy}
                onClick={() => onMark(item)}
                style={{ fontSize:11, fontWeight:600, color:T.white, background:T.green, border:"none", borderRadius:7, padding:"6px 12px", cursor:busy?"default":"pointer", opacity:busy?0.6:1 }}
              >✓ Mark received</button>
            )}
            {!monthClosed && item.status === "received" && (
              <button
                disabled={busy}
                onClick={() => onRevert(item)}
                style={{ fontSize:11, fontWeight:600, color:T.slate600, background:T.white, border:`1px solid ${T.slate200}`, borderRadius:7, padding:"6px 12px", cursor:busy?"default":"pointer", opacity:busy?0.6:1 }}
              >↺ Reopen item</button>
            )}
          </div>
        </div>
      )}
    </div>
  );
};


// ─── Main Module ──────────────────────────────────────────────
export default function MonthlyClose() {
  const [section, setSection] = useState("checklist");
  const [busyId, setBusyId] = useState(null);
  const [closing, setClosing] = useState(false);

  const { data: rows, loading, setData } =
    useSupabaseTable("monthly_close_checklist", AGENCY_ID, { orderBy:"expected_by", ascending:true });

  // Document join: fetch the documents referenced by checklist rows so we
  // can show Drive links + file names. Keyed by document_id.
  const [docMap, setDocMap] = useState({});
  useEffect(() => {
    const ids = Array.from(new Set((rows || []).map(r => r.document_id).filter(Boolean)));
    if (!supabase || ids.length === 0) { setDocMap({}); return; }
    let cancelled = false;
    supabase
      .from("documents")
      .select("id, file_name, drive_url, processed_at")
      .in("id", ids)
      .then(({ data, error }) => {
        if (cancelled || error || !data) return;
        const m = {};
        for (const d of data) m[d.id] = d;
        setDocMap(m);
      });
    return () => { cancelled = true; };
  }, [rows]);

  // ── Available periods (newest first) ─────────────────────────
  const periods = useMemo(() => {
    const seen = new Map();
    for (const r of (rows || [])) {
      if (!r.period_year || !r.period_month) continue;
      const key = `${r.period_year}-${String(r.period_month).padStart(2,"0")}`;
      if (!seen.has(key)) seen.set(key, { year:r.period_year, month:r.period_month, key });
    }
    return Array.from(seen.values()).sort((a,b) =>
      b.year - a.year || b.month - a.month);
  }, [rows]);

  const [periodKey, setPeriodKey] = useState(null);
  useEffect(() => {
    if (periods.length === 0) { setPeriodKey(null); return; }
    if (!periodKey || !periods.some(p => p.key === periodKey)) {
      setPeriodKey(periods[0].key);
    }
  }, [periods]);

  const activePeriod = periods.find(p => p.key === periodKey) || null;

  // ── Items for the active period ──────────────────────────────
  const items = useMemo(() => {
    if (!activePeriod) return [];
    return (rows || [])
      .filter(r => r.period_year === activePeriod.year && r.period_month === activePeriod.month);
  }, [rows, activePeriod]);

  // ── Counts + readiness ───────────────────────────────────────
  const counts = useMemo(() => {
    const c = { received:0, partial:0, pending:0, overdue:0, total:items.length };
    for (const it of items) {
      if (it.status === "received") c.received++;
      else if (it.status === "partial") c.partial++;
      else c.pending++;
      if (isOverdue(it)) c.overdue++;
    }
    return c;
  }, [items]);

  const monthClosed = items.length > 0 && items.every(it => it.is_closed);
  const readyToClose = items.length > 0 && items.every(it => it.status === "received" || it.is_closed);
  const waitingOn = items.filter(it => it.status !== "received" && !it.is_closed);
  const pct = counts.total ? Math.round((counts.received / counts.total) * 100) : 0;

  // ── Write-backs (optimistic, fall back to local if no supabase) ──
  const patchRow = (id, patch) => {
    setData(prev => (prev || []).map(r => r.id === id ? { ...r, ...patch } : r));
  };

  const markReceived = async (item) => {
    if (busyId) return;
    setBusyId(item.id);
    const today = new Date().toISOString().slice(0,10);
    const patch = { status:"received", received_at: item.received_at || today };
    patchRow(item.id, patch);
    if (supabase) {
      const { error } = await supabase
        .from("monthly_close_checklist")
        .update(patch).eq("id", item.id);
      if (error) patchRow(item.id, { status:item.status, received_at:item.received_at });
    }
    setBusyId(null);
  };

  const revertItem = async (item) => {
    if (busyId) return;
    setBusyId(item.id);
    // Revert to partial if a source doc exists, else pending.
    const back = item.document_id ? "partial" : "pending";
    const patch = { status: back };
    patchRow(item.id, patch);
    if (supabase) {
      const { error } = await supabase
        .from("monthly_close_checklist")
        .update(patch).eq("id", item.id);
      if (error) patchRow(item.id, { status:item.status });
    }
    setBusyId(null);
  };

  const closeMonth = async () => {
    if (closing || !activePeriod || items.length === 0) return;
    setClosing(true);
    const ids = items.map(it => it.id);
    setData(prev => (prev || []).map(r => ids.includes(r.id) ? { ...r, is_closed:true } : r));
    if (supabase) {
      const { error } = await supabase
        .from("monthly_close_checklist")
        .update({ is_closed:true })
        .eq("agency_id", AGENCY_ID)
        .eq("period_year", activePeriod.year)
        .eq("period_month", activePeriod.month);
      if (error) {
        setData(prev => (prev || []).map(r => ids.includes(r.id) ? { ...r, is_closed:false } : r));
      }
    }
    setClosing(false);
  };

  const reopenMonth = async () => {
    if (closing || !activePeriod) return;
    setClosing(true);
    const ids = items.map(it => it.id);
    setData(prev => (prev || []).map(r => ids.includes(r.id) ? { ...r, is_closed:false } : r));
    if (supabase) {
      await supabase
        .from("monthly_close_checklist")
        .update({ is_closed:false })
        .eq("agency_id", AGENCY_ID)
        .eq("period_year", activePeriod.year)
        .eq("period_month", activePeriod.month);
    }
    setClosing(false);
  };

  // ── Sorted views ─────────────────────────────────────────────
  const checklistSorted = useMemo(() => {
    const order = { pending:0, partial:1, received:2 };
    return [...items].sort((a,b) => {
      const ao = a.is_closed ? 3 : (order[a.status] ?? 0);
      const bo = b.is_closed ? 3 : (order[b.status] ?? 0);
      if (ao !== bo) return ao - bo;
      return (a.expected_by || "").localeCompare(b.expected_by || "");
    });
  }, [items]);

  const timelineSorted = useMemo(() =>
    [...items].sort((a,b) => (a.expected_by || "").localeCompare(b.expected_by || "")),
  [items]);

  const periodLabel = activePeriod ? `${MONTHS[activePeriod.month]} ${activePeriod.year}` : "";

  const askContext = activePeriod
    ? `Walk me through my ${periodLabel} monthly close. The system is still waiting on: ${waitingOn.map(w => w.doc_label || w.doc_category).join("; ") || "nothing — all items received"}. ${counts.received}/${counts.total} items received. Should I close the month, and is there anything I should reconcile or flag first?`
    : "Help me with my monthly close.";

  // ── Render ───────────────────────────────────────────────────
  if (loading) {
    return <div style={{ padding:40, textAlign:"center", fontSize:13, color:T.slate500 }}>Loading monthly close…</div>;
  }
  if (!rows || rows.length === 0) {
    return (
      <EmptyState
        icon="ð️"
        title="No close checklist yet"
        description="Your monthly close checklist is generated on the 1st of each month. Ask your Claude: &quot;Generate this month's close checklist.&quot;"
        module="documents"
      />
    );
  }

  const sections = [
    { id:"checklist", label:"Checklist" },
    { id:"timeline",  label:"Timeline"  },
  ];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, gap:12, flexWrap:"wrap" }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Monthly Close</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            {periodLabel ? `${periodLabel} · ` : ""}{counts.received}/{counts.total} items received
            {monthClosed ? " · Closed" : counts.overdue > 0 ? ` · ${counts.overdue} overdue` : ""}
          </div>
        </div>
        <div style={{ display:"flex", gap:10, alignItems:"center", flexWrap:"wrap" }}>
          {periods.length > 0 && (
            <select
              value={periodKey || ""}
              onChange={e => setPeriodKey(e.target.value)}
              style={{ fontSize:12, fontWeight:600, color:T.slate700, background:T.white, border:`1px solid ${T.slate200}`, borderRadius:8, padding:"7px 11px", cursor:"pointer" }}
            >
              {periods.map(p => (
                <option key={p.key} value={p.key}>{MONTHS[p.month]} {p.year}</option>
              ))}
            </select>
          )}
          <AskBtn context={askContext} />
        </div>
      </div>

      {/* Closed banner */}
      {monthClosed && (
        <div style={{ display:"flex", alignItems:"center", gap:10, background:T.greenLt, border:`1px solid ${T.green}`, borderRadius:10, padding:"11px 14px", marginBottom:16 }}>
          <span style={{ fontSize:16 }}>✅</span>
          <div style={{ flex:1, fontSize:12.5, color:"#065F46", fontWeight:600 }}>
            {periodLabel} is closed. All {counts.total} items were received and reconciled.
          </div>
          <button
            onClick={reopenMonth}
            disabled={closing}
            style={{ fontSize:11, fontWeight:600, color:"#065F46", background:T.white, border:`1px solid ${T.green}`, borderRadius:7, padding:"6px 12px", cursor:closing?"default":"pointer", opacity:closing?0.6:1 }}
          >↺ Reopen month</button>
        </div>
      )}

      {/* Waiting-on banner */}
      {!monthClosed && waitingOn.length > 0 && (
        <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderLeft:`4px solid ${T.amber}`, borderRadius:10, padding:"13px 16px", marginBottom:16 }}>
          <div style={{ fontSize:12, fontWeight:700, color:T.slate800, marginBottom:8, display:"flex", alignItems:"center", gap:7 }}>
            <span>⏳</span> System is waiting on {waitingOn.length} item{waitingOn.length===1?"":"s"} to close {periodLabel}
          </div>
          <div style={{ display:"flex", flexDirection:"column", gap:6 }}>
            {waitingOn.map(w => {
              const cc = catConfig(w.doc_category);
              const od = isOverdue(w);
              return (
                <div key={w.id} style={{ display:"flex", alignItems:"center", gap:8, fontSize:12, color:T.slate600 }}>
                  <span style={{ width:6, height:6, borderRadius:"50%", background:statusConfig(w.status).dot, flexShrink:0 }} />
                  <span style={{ flex:1, minWidth:0 }}>{cc.icon} {w.doc_label || cc.label}</span>
                  <span style={{ fontSize:11, color: od ? T.red : T.slate400, fontWeight: od ? 600 : 400, whiteSpace:"nowrap" }}>
                    {od ? "Overdue " : "Due "}{fmtDate(w.expected_by)}
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Ready-to-close banner */}
      {!monthClosed && readyToClose && waitingOn.length === 0 && (
        <div style={{ display:"flex", alignItems:"center", gap:10, background:T.blueLt, border:`1px solid ${T.blue}`, borderRadius:10, padding:"11px 14px", marginBottom:16 }}>
          <span style={{ fontSize:16 }}>ð</span>
          <div style={{ flex:1, fontSize:12.5, color:"#1E40AF", fontWeight:600 }}>
            Everything for {periodLabel} is received. You're ready to close.
          </div>
          <button
            onClick={closeMonth}
            disabled={closing}
            style={{ fontSize:12, fontWeight:700, color:T.white, background:T.blue, border:"none", borderRadius:8, padding:"8px 16px", cursor:closing?"default":"pointer", opacity:closing?0.6:1 }}
          >{closing ? "Closing…" : `Close ${MONTHS[activePeriod?.month] || ""}`}</button>
        </div>
      )}

      {/* KPI tiles */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(150px, 1fr))", gap:12, marginBottom:16 }}>
        <KpiTile label="Close progress" value={`${pct}%`} sub={`${counts.received} of ${counts.total} received`} accent={T.blue} />
        <KpiTile label="Received" value={counts.received} sub="All data in" accent={T.green} />
        <KpiTile label="Partial" value={counts.partial} sub="Awaiting the rest" accent={T.amber} />
        <KpiTile label="Waiting" value={counts.pending} sub="Nothing received yet" accent={T.slate400} />
        <KpiTile label="Overdue" value={counts.overdue} sub="Past expected date" accent={counts.overdue > 0 ? T.red : T.slate200} />
      </div>

      {/* Section nav */}
      <div style={{ display:"flex", gap:2, flexWrap:"wrap", background:T.slate100, borderRadius:10, padding:4, marginBottom:18 }}>
        {sections.map(s => (
          <button key={s.id} onClick={() => setSection(s.id)} style={{ padding:"7px 14px", fontSize:12, fontWeight:section===s.id?600:400, color:section===s.id?T.slate900:T.slate500, background:section===s.id?T.white:"transparent", border:"none", borderRadius:7, cursor:"pointer", transition:"all 0.12s", boxShadow:section===s.id?"0 1px 3px rgba(0,0,0,0.08)":"none" }}>
            {s.label}
          </button>
        ))}
      </div>

      {/* Checklist section */}
      {section === "checklist" && (
        <div style={{ display:"flex", flexDirection:"column", gap:9 }}>
          {checklistSorted.length === 0 ? (
            <Card><div style={{ fontSize:13, color:T.slate500, textAlign:"center", padding:"12px 0" }}>No items for this period.</div></Card>
          ) : checklistSorted.map(it => (
            <ChecklistRow
              key={it.id}
              item={it}
              doc={it.document_id ? docMap[it.document_id] : null}
              busy={busyId === it.id}
              monthClosed={monthClosed}
              onMark={markReceived}
              onRevert={revertItem}
            />
          ))}
        </div>
      )}

      {/* Timeline section */}
      {section === "timeline" && (
        <Card>
          <div style={{ fontSize:12, fontWeight:600, color:T.slate700, marginBottom:14 }}>
            Expected order — {periodLabel}
          </div>
          <div style={{ display:"flex", flexDirection:"column", gap:0 }}>
            {timelineSorted.map((it, idx) => {
              const cc = catConfig(it.doc_category);
              const sc = statusConfig(it.status);
              const od = isOverdue(it);
              const last = idx === timelineSorted.length - 1;
              return (
                <div key={it.id} style={{ display:"flex", gap:12, alignItems:"flex-start" }}>
                  {/* rail */}
                  <div style={{ display:"flex", flexDirection:"column", alignItems:"center", flexShrink:0, width:14 }}>
                    <span style={{ width:12, height:12, borderRadius:"50%", background:sc.dot, border:`2px solid ${T.white}`, boxShadow:`0 0 0 1px ${sc.dot}`, marginTop:3 }} />
                    {!last && <span style={{ width:2, flex:1, minHeight:26, background:T.slate200 }} />}
                  </div>
                  {/* body */}
                  <div style={{ flex:1, minWidth:0, paddingBottom:last ? 0 : 14 }}>
                    <div style={{ display:"flex", alignItems:"center", gap:8, flexWrap:"wrap" }}>
                      <span style={{ fontSize:12.5, fontWeight:600, color:T.slate900 }}>{cc.icon} {it.doc_label || cc.label}</span>
                      <StatusPill status={it.status} />
                    </div>
                    <div style={{ fontSize:11, color: od ? T.red : T.slate500, marginTop:2, fontWeight: od ? 600 : 400 }}>
                      {od ? "Overdue — was due " : "Expected "}{fmtDate(it.expected_by)}
                      {it.received_at ? ` · received ${fmtDate(it.received_at)}` : ""}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </Card>
      )}
    </div>
  );
}
