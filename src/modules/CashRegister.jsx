import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// ============================================================
// BCC CASH REGISTER MODULE v1.0
// Business Command Center — State Farm Agent Edition
//
// SECTIONS:
//   1. Live Balance Board  — Projected balances for all accounts
//   2. Suspense Register   — All transactions this month, with status
//   3. Coding Queue        — Transactions waiting for Peter's input
//   4. Weekly Snapshot     — Week-by-week cash movement summary
//   5. Coding Rules        — Auto-classification rules memory
//
// GL FIREWALL: No transaction hits journal_entries until
// coding_status is 'peter_classified' or 'auto_classified'.
// ============================================================

// ─── Design Tokens ────────────────────────────────────────────
const T = {
  navy:    "#1B2B4B", blue:    "#2D7DD2", blueLt:  "#EFF6FF",
  green:   "#10B981", greenLt: "#D1FAE5", amber:   "#F59E0B",
  amberLt: "#FEF3C7", red:    "#EF4444", redLt:   "#FEE2E2",
  purple:  "#7C3AED", purpleLt:"#EDE9FE",
  slate50: "#F8FAFC", slate100:"#F1F5F9", slate200:"#E2E8F0",
  slate400:"#94A3B8", slate500:"#64748B", slate600:"#475569",
  slate700:"#334155", slate800:"#1E293B", white:   "#FFFFFF",
};

const fmt = (n) => new Intl.NumberFormat("en-US", { style:"currency", currency:"USD" }).format(n ?? 0);
const fmtDate = (d) => d ? new Date(d + "T00:00:00").toLocaleDateString("en-US", { month:"short", day:"numeric" }) : "—";

// ─── Status Badge ─────────────────────────────────────────────
function StatusBadge({ status }) {
  const MAP = {
    peter_classified: { label: "✓ Coded",       bg: T.greenLt,   color: T.green   },
    auto_classified:  { label: "⚡ Auto-coded",  bg: T.blueLt,    color: T.blue    },
    needs_peter:      { label: "❓ Needs Input", bg: T.amberLt,   color: T.amber   },
    unclassified:     { label: "⚠ Unclassified", bg: T.redLt,    color: T.red     },
    possible_transfer:{ label: "↔ Transfer",     bg: T.purpleLt,  color: T.purple  },
  };
  const s = MAP[status] || { label: status, bg: T.slate100, color: T.slate600 };
  return (
    <span style={{ padding:"2px 8px", borderRadius:12, fontSize:11, fontWeight:600,
                   background: s.bg, color: s.color, whiteSpace:"nowrap" }}>
      {s.label}
    </span>
  );
}

// ─── Coding Modal ─────────────────────────────────────────────
function CodingModal({ txn, coaAccounts, onSave, onClose }) {
  const [debit,  setDebit]  = useState(txn.suggested_debit_account  || "");
  const [credit, setCredit] = useState(txn.suggested_credit_account || "");
  const [note,   setNote]   = useState(txn.peter_note || "");
  const [saving, setSaving] = useState(false);

  async function handleSave() {
    setSaving(true);
    await supabase.from("bank_register_preliminary").update({
      peter_debit_account:  debit,
      peter_credit_account: credit,
      peter_note:           note,
      coding_status:        "peter_classified",
      peter_coded_at:       new Date().toISOString(),
    }).eq("id", txn.id);

    // If Peter codes this, prompt to save as a rule
    if (txn.merchant && debit && credit) {
      await supabase.from("txn_coding_rules").upsert({
        agency_id:           AGENCY_ID,
        match_merchant:      txn.merchant.toUpperCase(),
        match_merchant_mode: "contains",
        match_direction:     txn.direction,
        debit_account:       debit,
        credit_account:      credit,
        rule_name:           `${txn.merchant} — ${txn.direction}`,
        rule_source:         "peter_answer",
        confidence:          "high",
        description_template: note || txn.merchant,
        usage_count:         1,
        last_matched_at:     new Date().toISOString(),
        updated_at:          new Date().toISOString(),
      }, { onConflict: "agency_id,match_merchant,match_direction", ignoreDuplicates: false });
    }

    setSaving(false);
    onSave();
  }

  const inputStyle = {
    width:"100%", padding:"8px 10px", border:`1px solid ${T.slate200}`,
    borderRadius:6, fontSize:13, outline:"none",
    background: T.white, color: T.slate800,
  };
  const labelStyle = { fontSize:12, fontWeight:600, color: T.slate600, display:"block", marginBottom:4 };

  return (
    <div style={{ position:"fixed", inset:0, background:"rgba(0,0,0,0.45)", zIndex:1000,
                  display:"flex", alignItems:"center", justifyContent:"center", padding:20 }}>
      <div style={{ background:T.white, borderRadius:12, padding:28, maxWidth:520, width:"100%",
                    boxShadow:"0 20px 60px rgba(0,0,0,0.2)" }}>
        <div style={{ marginBottom:20 }}>
          <div style={{ fontSize:18, fontWeight:700, color:T.slate800, marginBottom:4 }}>
            Code This Transaction
          </div>
          <div style={{ fontSize:13, color:T.slate500 }}>
            {fmtDate(txn.txn_date)} · {txn.account_label} · {txn.direction === "credit" ? "+" : "-"}{fmt(txn.amount)}
          </div>
          <div style={{ fontSize:14, fontWeight:600, color:T.slate700, marginTop:4 }}>
            {txn.merchant || "Unknown Merchant"}
          </div>
          {txn.coding_question && (
            <div style={{ marginTop:10, padding:"10px 14px", background:T.amberLt,
                          borderRadius:8, fontSize:13, color:"#92400e" }}>
              ❓ {txn.coding_question}
            </div>
          )}
        </div>

        <div style={{ display:"grid", gap:16, marginBottom:20 }}>
          <div>
            <label style={labelStyle}>Debit Account (what goes UP?)</label>
            <input style={inputStyle} value={debit} onChange={e=>setDebit(e.target.value)}
                   placeholder="e.g. 6300-Rent, 6100-Payroll-Wages" list="coa-list" />
          </div>
          <div>
            <label style={labelStyle}>Credit Account (what goes DOWN?)</label>
            <input style={inputStyle} value={credit} onChange={e=>setCredit(e.target.value)}
                   placeholder="e.g. 1020-USBank-4335" list="coa-list" />
          </div>
          <div>
            <label style={labelStyle}>Note / Memo (optional)</label>
            <input style={inputStyle} value={note} onChange={e=>setNote(e.target.value)}
                   placeholder="e.g. June office rent payment" />
          </div>
        </div>

        <datalist id="coa-list">
          {(coaAccounts || []).map(a => <option key={a} value={a} />)}
        </datalist>

        <div style={{ display:"flex", gap:10, justifyContent:"flex-end" }}>
          <button onClick={onClose}
            style={{ padding:"8px 18px", border:`1px solid ${T.slate200}`, borderRadius:8,
                     background:T.white, color:T.slate600, fontSize:13, cursor:"pointer" }}>
            Cancel
          </button>
          <button onClick={handleSave} disabled={saving || !debit || !credit}
            style={{ padding:"8px 18px", borderRadius:8, border:"none",
                     background: (!debit||!credit) ? T.slate200 : T.blue,
                     color: (!debit||!credit) ? T.slate500 : T.white,
                     fontSize:13, fontWeight:600, cursor: (!debit||!credit) ? "default" : "pointer" }}>
            {saving ? "Saving…" : "✓ Save & Create Rule"}
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Section 1: Live Balance Board ────────────────────────────
function BalanceBoardSection({ balances }) {
  if (!balances?.length) return (
    <div style={{ padding:32, textAlign:"center", color:T.slate400, fontSize:14 }}>
      No account balances found. Make sure account_starting_balances is populated.
    </div>
  );

  return (
    <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(220px, 1fr))", gap:16, marginBottom:24 }}>
      {balances.map(b => {
        const isCC = b.account_type === "credit_card";
        const bal  = parseFloat(b.projected_balance ?? b.starting_balance ?? 0);
        const isNeg = bal < 0;
        return (
          <div key={b.account_last4} style={{
            background: T.white, borderRadius:12, padding:"20px 22px",
            border:`1px solid ${T.slate200}`,
            boxShadow:"0 1px 4px rgba(0,0,0,0.06)"
          }}>
            <div style={{ fontSize:11, fontWeight:700, color:T.slate400, textTransform:"uppercase",
                          letterSpacing:"0.08em", marginBottom:4 }}>
              {isCC ? "💳 Credit Card" : "🏦 Checking"}
            </div>
            <div style={{ fontSize:14, fontWeight:600, color:T.slate700, marginBottom:8 }}>
              {b.account_label || `···${b.account_last4}`}
            </div>
            <div style={{ fontSize:28, fontWeight:800,
                          color: isCC ? (isNeg ? T.red : T.green) : (bal < 5000 ? T.amber : T.green) }}>
              {fmt(Math.abs(bal))}
            </div>
            <div style={{ fontSize:11, color:T.slate400, marginTop:4 }}>
              {isCC ? (isNeg ? "Balance Owed" : "Credit") : "Projected Balance"}
            </div>
            {b.uncoded_count > 0 && (
              <div style={{ marginTop:10, padding:"4px 10px", background:T.amberLt,
                            borderRadius:8, fontSize:11, color:"#92400e", fontWeight:600 }}>
                ⚠ {b.uncoded_count} transaction{b.uncoded_count > 1 ? "s" : ""} need coding
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ─── Section 2: Suspense Register ─────────────────────────────
function SuspenseRegisterSection({ txns, coaAccounts, onRefresh }) {
  const [filter,    setFilter]    = useState("all");
  const [codingTxn, setCodingTxn] = useState(null);
  const [search,    setSearch]    = useState("");

  const displayed = (txns || []).filter(t => {
    if (filter !== "all" && t.coding_status !== filter) return false;
    if (search && !`${t.merchant} ${t.account_label} ${t.peter_note || ""}`.toLowerCase().includes(search.toLowerCase())) return false;
    return true;
  });

  const counts = {
    all:              (txns||[]).length,
    needs_peter:      (txns||[]).filter(t=>t.coding_status==="needs_peter").length,
    unclassified:     (txns||[]).filter(t=>t.coding_status==="unclassified").length,
    auto_classified:  (txns||[]).filter(t=>t.coding_status==="auto_classified").length,
    peter_classified: (txns||[]).filter(t=>t.coding_status==="peter_classified").length,
  };

  const btnStyle = (active) => ({
    padding:"6px 14px", borderRadius:20, border:"none", fontSize:12, fontWeight:600,
    cursor:"pointer", transition:"all 0.15s",
    background: active ? T.navy : T.slate100,
    color:       active ? T.white : T.slate600,
  });

  return (
    <div>
      {/* Filter bar */}
      <div style={{ display:"flex", gap:8, flexWrap:"wrap", marginBottom:16, alignItems:"center" }}>
        <button style={btnStyle(filter==="all")}            onClick={()=>setFilter("all")}>All ({counts.all})</button>
        <button style={btnStyle(filter==="needs_peter")}    onClick={()=>setFilter("needs_peter")}>❓ Needs Input ({counts.needs_peter})</button>
        <button style={btnStyle(filter==="unclassified")}   onClick={()=>setFilter("unclassified")}>⚠ Unclassified ({counts.unclassified})</button>
        <button style={btnStyle(filter==="auto_classified")} onClick={()=>setFilter("auto_classified")}>⚡ Auto ({counts.auto_classified})</button>
        <button style={btnStyle(filter==="peter_classified")} onClick={()=>setFilter("peter_classified")}>✓ Coded ({counts.peter_classified})</button>
        <input value={search} onChange={e=>setSearch(e.target.value)}
          placeholder="Search merchant…"
          style={{ marginLeft:"auto", padding:"6px 12px", border:`1px solid ${T.slate200}`,
                   borderRadius:20, fontSize:12, outline:"none", minWidth:160 }} />
      </div>

      {/* Table */}
      <div style={{ overflowX:"auto" }}>
        <table style={{ width:"100%", borderCollapse:"collapse", fontSize:13 }}>
          <thead>
            <tr style={{ background:T.slate50 }}>
              {["Date","Account","Merchant","Amount","Status","GL Accounts",""].map(h => (
                <th key={h} style={{ padding:"10px 12px", textAlign:"left", fontSize:11,
                                     fontWeight:700, color:T.slate500, textTransform:"uppercase",
                                     letterSpacing:"0.06em", borderBottom:`1px solid ${T.slate200}`, whiteSpace:"nowrap" }}>
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {displayed.length === 0 && (
              <tr><td colSpan={7} style={{ padding:32, textAlign:"center", color:T.slate400 }}>
                No transactions match this filter.
              </td></tr>
            )}
            {displayed.map((t, i) => {
              const isDebit = t.direction === "debit";
              const debitAcct  = t.peter_debit_account  || t.suggested_debit_account;
              const creditAcct = t.peter_credit_account || t.suggested_credit_account;
              return (
                <tr key={t.id} style={{ borderBottom:`1px solid ${T.slate100}`,
                                        background: i%2===0 ? T.white : T.slate50 }}>
                  <td style={{ padding:"10px 12px", color:T.slate600, whiteSpace:"nowrap" }}>
                    {fmtDate(t.txn_date)}
                  </td>
                  <td style={{ padding:"10px 12px", color:T.slate600, fontSize:12, whiteSpace:"nowrap" }}>
                    {t.account_label?.replace("US Bank Business ","") || `···${t.account_last4}`}
                  </td>
                  <td style={{ padding:"10px 12px", color:T.slate800, fontWeight:500 }}>
                    {t.merchant || <span style={{color:T.slate400,fontStyle:"italic"}}>Unknown</span>}
                    {t.peter_note && <div style={{fontSize:11,color:T.slate400}}>{t.peter_note}</div>}
                  </td>
                  <td style={{ padding:"10px 12px", fontWeight:700, whiteSpace:"nowrap",
                                color: isDebit ? T.red : T.green }}>
                    {isDebit ? "-" : "+"}{fmt(t.amount)}
                  </td>
                  <td style={{ padding:"10px 12px" }}>
                    <StatusBadge status={t.coding_status} />
                  </td>
                  <td style={{ padding:"10px 12px", fontSize:11, color:T.slate500 }}>
                    {debitAcct && creditAcct
                      ? <><span style={{color:T.slate700}}>DR</span> {debitAcct}<br/>
                          <span style={{color:T.slate700}}>CR</span> {creditAcct}</>
                      : <span style={{color:T.slate300,fontStyle:"italic"}}>Not coded</span>}
                  </td>
                  <td style={{ padding:"10px 12px" }}>
                    {(t.coding_status === "needs_peter" || t.coding_status === "unclassified") && (
                      <button onClick={() => setCodingTxn(t)}
                        style={{ padding:"5px 12px", background:T.amber, color:T.white,
                                 border:"none", borderRadius:6, fontSize:12, fontWeight:600,
                                 cursor:"pointer" }}>
                        Code
                      </button>
                    )}
                    {t.coding_status === "peter_classified" && (
                      <button onClick={() => setCodingTxn(t)}
                        style={{ padding:"5px 12px", background:T.slate100, color:T.slate600,
                                 border:"none", borderRadius:6, fontSize:12, cursor:"pointer" }}>
                        Edit
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {codingTxn && (
        <CodingModal
          txn={codingTxn}
          coaAccounts={coaAccounts}
          onSave={() => { setCodingTxn(null); onRefresh(); }}
          onClose={() => setCodingTxn(null)}
        />
      )}
    </div>
  );
}

// ─── Section 3: Coding Queue ──────────────────────────────────
function CodingQueueSection({ questions, coaAccounts, onRefresh }) {
  const [codingTxn, setCodingTxn] = useState(null);

  if (!questions?.length) return (
    <div style={{ padding:"40px 0", textAlign:"center" }}>
      <div style={{ fontSize:40, marginBottom:12 }}>✅</div>
      <div style={{ fontSize:16, fontWeight:600, color:T.green }}>All Clear</div>
      <div style={{ fontSize:13, color:T.slate400, marginTop:4 }}>
        No transactions waiting for your input.
      </div>
    </div>
  );

  return (
    <div>
      <div style={{ padding:"12px 16px", background:T.amberLt, borderRadius:8, marginBottom:16,
                    fontSize:13, color:"#92400e", fontWeight:500 }}>
        ⚠ {questions.length} transaction{questions.length > 1 ? "s" : ""} are waiting for your input before they can be posted to the GL.
      </div>
      <div style={{ display:"flex", flexDirection:"column", gap:12 }}>
        {questions.map(q => (
          <div key={q.id} style={{ background:T.white, border:`1px solid ${T.slate200}`,
                                   borderRadius:10, padding:"16px 18px",
                                   borderLeft:`4px solid ${T.amber}` }}>
            <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", gap:16, flexWrap:"wrap" }}>
              <div style={{ flex:1 }}>
                <div style={{ fontWeight:700, fontSize:14, color:T.slate800, marginBottom:2 }}>
                  {q.merchant || "Unknown Merchant"}
                </div>
                <div style={{ fontSize:12, color:T.slate500 }}>
                  {fmtDate(q.txn_date)} · {q.account_label} ·{" "}
                  <span style={{ fontWeight:700, color: q.direction==="debit" ? T.red : T.green }}>
                    {q.direction==="debit" ? "-" : "+"}{fmt(q.amount)}
                  </span>
                </div>
                {q.coding_question && (
                  <div style={{ marginTop:8, fontSize:13, color:T.slate600, fontStyle:"italic" }}>
                    "{q.coding_question}"
                  </div>
                )}
                {q.suggested_debit_account && (
                  <div style={{ marginTop:6, fontSize:12, color:T.slate400 }}>
                    💡 Suggested: DR {q.suggested_debit_account} / CR {q.suggested_credit_account}
                    {q.suggested_confidence && ` (${q.suggested_confidence} confidence)`}
                  </div>
                )}
              </div>
              <button onClick={() => setCodingTxn(q)}
                style={{ padding:"8px 18px", background:T.amber, color:T.white,
                         border:"none", borderRadius:8, fontSize:13, fontWeight:700,
                         cursor:"pointer", whiteSpace:"nowrap" }}>
                Answer & Code →
              </button>
            </div>
          </div>
        ))}
      </div>

      {codingTxn && (
        <CodingModal
          txn={codingTxn}
          coaAccounts={coaAccounts}
          onSave={() => { setCodingTxn(null); onRefresh(); }}
          onClose={() => setCodingTxn(null)}
        />
      )}
    </div>
  );
}

// ─── Section 4: Weekly Snapshot ───────────────────────────────
function WeeklySnapshotSection({ snapshots, weeklyView }) {
  // weeklyView = rows from v_weekly_cash_position
  const weeks = [...new Set((weeklyView||[]).map(r => r.week_ending))].sort().reverse();

  if (!weeks.length) return (
    <div style={{ padding:32, textAlign:"center", color:T.slate400, fontSize:14 }}>
      Weekly data will appear once transactions are recorded in the register.
    </div>
  );

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:20 }}>
      {weeks.map(wk => {
        const rows = weeklyView.filter(r => r.week_ending === wk);
        return (
          <div key={wk} style={{ background:T.white, border:`1px solid ${T.slate200}`,
                                  borderRadius:10, overflow:"hidden" }}>
            <div style={{ background:T.navy, padding:"12px 18px",
                          display:"flex", justifyContent:"space-between", alignItems:"center" }}>
              <span style={{ color:T.white, fontWeight:700, fontSize:14 }}>
                Week ending {new Date(wk + "T00:00:00").toLocaleDateString("en-US", {month:"short",day:"numeric",year:"numeric"})}
              </span>
              <span style={{ fontSize:12, color:"rgba(255,255,255,0.6)" }}>
                {rows.reduce((s,r)=>s+(r.txn_count||0),0)} transactions
              </span>
            </div>
            <table style={{ width:"100%", borderCollapse:"collapse", fontSize:13 }}>
              <thead>
                <tr style={{ background:T.slate50 }}>
                  {["Account","Credits","Debits","Net","Proj. Balance","Uncoded"].map(h => (
                    <th key={h} style={{ padding:"8px 14px", textAlign:"right", fontSize:11,
                                         fontWeight:700, color:T.slate500, textTransform:"uppercase",
                                         letterSpacing:"0.05em", borderBottom:`1px solid ${T.slate200}`,
                                         "&:first-child":{textAlign:"left"} }}>
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map(r => (
                  <tr key={r.account_last4} style={{ borderBottom:`1px solid ${T.slate100}` }}>
                    <td style={{ padding:"10px 14px", color:T.slate700, fontWeight:500, textAlign:"left" }}>
                      {r.account_label?.replace("US Bank Business ","") || `···${r.account_last4}`}
                    </td>
                    <td style={{ padding:"10px 14px", textAlign:"right", color:T.green, fontWeight:600 }}>{fmt(r.credits)}</td>
                    <td style={{ padding:"10px 14px", textAlign:"right", color:T.red,   fontWeight:600 }}>{fmt(r.debits)}</td>
                    <td style={{ padding:"10px 14px", textAlign:"right", fontWeight:700,
                                  color: parseFloat(r.credits||0) - parseFloat(r.debits||0) >= 0 ? T.green : T.red }}>
                      {fmt(parseFloat(r.credits||0) - parseFloat(r.debits||0))}
                    </td>
                    <td style={{ padding:"10px 14px", textAlign:"right", color:T.slate700, fontWeight:600 }}>
                      {r.projected_end_of_week_balance != null ? fmt(r.projected_end_of_week_balance) : "—"}
                    </td>
                    <td style={{ padding:"10px 14px", textAlign:"right" }}>
                      {(r.uncoded_count || 0) > 0
                        ? <span style={{ color:T.amber, fontWeight:700 }}>{r.uncoded_count}</span>
                        : <span style={{ color:T.green }}>✓ 0</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      })}
    </div>
  );
}

// ─── Section 5: Coding Rules ──────────────────────────────────
function CodingRulesSection({ rules, onRefresh }) {
  const [editing, setEditing] = useState(null);
  const [saving,  setSaving]  = useState(false);

  async function toggleRule(id, current) {
    await supabase.from("txn_coding_rules").update({ is_active: !current, updated_at: new Date().toISOString() }).eq("id", id);
    onRefresh();
  }

  return (
    <div>
      <div style={{ marginBottom:14, fontSize:13, color:T.slate500 }}>
        These rules auto-classify new transactions. Rules created from your answers grow this library over time.
        The more you code, the less you'll need to answer.
      </div>
      <div style={{ overflowX:"auto" }}>
        <table style={{ width:"100%", borderCollapse:"collapse", fontSize:13 }}>
          <thead>
            <tr style={{ background:T.slate50 }}>
              {["Merchant Match","Direction","Debit Account","Credit Account","Source","Used","Active"].map(h => (
                <th key={h} style={{ padding:"9px 12px", textAlign:"left", fontSize:11,
                                     fontWeight:700, color:T.slate500, textTransform:"uppercase",
                                     letterSpacing:"0.06em", borderBottom:`1px solid ${T.slate200}` }}>
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {(rules||[]).map((r, i) => (
              <tr key={r.id} style={{ borderBottom:`1px solid ${T.slate100}`,
                                      background: r.is_active ? (i%2===0?T.white:T.slate50) : T.slate100,
                                      opacity: r.is_active ? 1 : 0.5 }}>
                <td style={{ padding:"9px 12px", fontWeight:600, color:T.slate800 }}>
                  {r.match_merchant} <span style={{fontSize:10,color:T.slate400}}>({r.match_merchant_mode})</span>
                </td>
                <td style={{ padding:"9px 12px", color:T.slate600 }}>
                  <span style={{ padding:"2px 8px", borderRadius:12, fontSize:11, fontWeight:600,
                                 background: r.match_direction==="credit" ? T.greenLt : T.redLt,
                                 color: r.match_direction==="credit" ? T.green : T.red }}>
                    {r.match_direction || "any"}
                  </span>
                </td>
                <td style={{ padding:"9px 12px", fontSize:12, color:T.slate600 }}>{r.debit_account}</td>
                <td style={{ padding:"9px 12px", fontSize:12, color:T.slate600 }}>{r.credit_account}</td>
                <td style={{ padding:"9px 12px", fontSize:11, color:T.slate400 }}>
                  {r.rule_source === "peter_answer" ? "👤 Peter" : "⚙ System"}
                </td>
                <td style={{ padding:"9px 12px", color:T.slate500 }}>{r.usage_count || 0}×</td>
                <td style={{ padding:"9px 12px" }}>
                  <button onClick={() => toggleRule(r.id, r.is_active)}
                    style={{ padding:"4px 10px", border:"none", borderRadius:6, fontSize:11,
                             fontWeight:600, cursor:"pointer",
                             background: r.is_active ? T.greenLt : T.redLt,
                             color:      r.is_active ? T.green   : T.red }}>
                    {r.is_active ? "Active" : "Off"}
                  </button>
                </td>
              </tr>
            ))}
            {(!rules||rules.length===0) && (
              <tr><td colSpan={7} style={{ padding:24, textAlign:"center", color:T.slate400 }}>
                No rules yet. Code a transaction to create your first rule automatically.
              </td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ─── Main Data Hook ───────────────────────────────────────────
function useCashRegisterData() {
  const [data,    setData]    = useState(null);
  const [loading, setLoading] = useState(true);

  async function load() {
    setLoading(true);
    try {
      const [
        registerRes, questionsRes, rulesRes,
        balancesRes, weeklyRes, snapshotRes, coaRes,
      ] = await Promise.all([
        supabase.from("bank_register_preliminary")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .order("txn_date", { ascending: false })
          .order("amount", { ascending: false })
          .limit(200),

        supabase.from("v_bank_register_coding_questions")
          .select("*"),

        supabase.from("txn_coding_rules")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .order("usage_count", { ascending: false }),

        supabase.from("v_projected_account_balance")
          .select("account_last4, account_label, account_type, running_balance, txn_date, starting_balance, starting_date")
          .order("account_last4")
          .order("txn_date", { ascending: false }),

        supabase.from("v_weekly_cash_position")
          .select("*")
          .order("week_ending", { ascending: false }),

        supabase.from("bank_register_weekly_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .order("week_ending", { ascending: false })
          .limit(12),

        supabase.from("chart_of_accounts")
          .select("account_code, account_name")
          .order("account_code"),
      ]);

      // Projected balances: latest running_balance per account
      const seen = new Set();
      const projBalances = [];
      for (const r of (balancesRes.data || [])) {
        if (!seen.has(r.account_last4)) {
          seen.add(r.account_last4);
          const register = (registerRes.data || []).filter(t => t.account_last4 === r.account_last4);
          const uncoded  = register.filter(t => ["needs_peter","unclassified"].includes(t.coding_status)).length;
          projBalances.push({ ...r, projected_balance: r.running_balance, uncoded_count: uncoded });
        }
      }
      // Accounts with no transactions yet — pull from account_starting_balances
      if (projBalances.length === 0) {
        const sbRes = await supabase.from("account_starting_balances").select("*").eq("agency_id", AGENCY_ID);
        for (const s of (sbRes.data || [])) {
          projBalances.push({ account_last4: s.account_last4, account_label: s.account_label,
                              account_type: s.account_type, projected_balance: parseFloat(s.balance),
                              starting_balance: parseFloat(s.balance), uncoded_count: 0 });
        }
      }

      const coaAccounts = (coaRes.data || []).map(a => `${a.account_code}-${a.account_name}`);

      setData({
        register:     registerRes.data || [],
        questions:    questionsRes.data || [],
        rules:        rulesRes.data || [],
        balances:     projBalances,
        weeklyView:   weeklyRes.data || [],
        snapshots:    snapshotRes.data || [],
        coaAccounts,
      });
    } catch (err) {
      console.error("CashRegister load error:", err);
      setData({ register:[], questions:[], rules:[], balances:[], weeklyView:[], snapshots:[], coaAccounts:[] });
    }
    setLoading(false);
  }

  useEffect(() => { load(); }, []);
  return { data, loading, refresh: load };
}

// ─── Main Export ──────────────────────────────────────────────
export default function CashRegister() {
  const [activeTab, setActiveTab] = useState("balances");
  const { data, loading, refresh } = useCashRegisterData();

  const tabs = [
    { id:"balances",  label:"💰 Live Balances" },
    { id:"register",  label:"📋 Suspense Register" },
    { id:"queue",     label: data ? `❓ Coding Queue (${data.questions?.length || 0})` : "❓ Coding Queue" },
    { id:"weekly",    label:"📅 Weekly Snapshot" },
    { id:"rules",     label:"⚙ Coding Rules" },
  ];

  const tabStyle = (active) => ({
    padding:"9px 18px", border:"none", borderRadius:"8px 8px 0 0",
    fontSize:13, fontWeight:600, cursor:"pointer",
    background: active ? T.white : "transparent",
    color:      active ? T.navy  : T.slate500,
    borderBottom: active ? `2px solid ${T.blue}` : "2px solid transparent",
    transition:"all 0.15s",
  });

  return (
    <div style={{ padding:24, background:T.slate50, minHeight:"100vh", fontFamily:"system-ui, sans-serif" }}>
      {/* Header */}
      <div style={{ marginBottom:20 }}>
        <div style={{ display:"flex", alignItems:"center", gap:12, marginBottom:4 }}>
          <div style={{ fontSize:24, fontWeight:800, color:T.slate900 }}>Cash Register</div>
          <span style={{ padding:"3px 10px", background:T.blueLt, color:T.blue,
                         borderRadius:12, fontSize:11, fontWeight:700 }}>LIVE</span>
        </div>
        <div style={{ fontSize:13, color:T.slate500 }}>
          Real-time bank &amp; credit card transaction tracking. GL firewall active — only coded transactions post to the ledger.
        </div>
      </div>

      {/* GL Firewall Banner */}
      {data && data.questions?.length > 0 && (
        <div onClick={() => setActiveTab("queue")}
          style={{ padding:"10px 16px", background:T.amberLt, borderRadius:8, marginBottom:16,
                   cursor:"pointer", display:"flex", alignItems:"center", gap:10,
                   border:`1px solid ${T.amber}` }}>
          <span style={{ fontSize:18 }}>🛑</span>
          <span style={{ fontSize:13, color:"#92400e", fontWeight:600 }}>
            GL Firewall: {data.questions.length} transaction{data.questions.length>1?"s":""} blocked from ledger — click to code them.
          </span>
        </div>
      )}

      {/* Tab Nav */}
      <div style={{ display:"flex", gap:2, borderBottom:`1px solid ${T.slate200}`,
                    marginBottom:20, background:T.slate100, padding:"0 4px", borderRadius:"10px 10px 0 0" }}>
        {tabs.map(t => (
          <button key={t.id} style={tabStyle(activeTab===t.id)} onClick={()=>setActiveTab(t.id)}>
            {t.label}
          </button>
        ))}
      </div>

      {/* Content */}
      {loading && (
        <div style={{ padding:48, textAlign:"center", color:T.slate400, fontSize:14 }}>
          Loading cash register…
        </div>
      )}

      {!loading && data && (
        <>
          {activeTab === "balances" && <BalanceBoardSection   balances={data.balances} />}
          {activeTab === "register" && <SuspenseRegisterSection txns={data.register} coaAccounts={data.coaAccounts} onRefresh={refresh} />}
          {activeTab === "queue"    && <CodingQueueSection    questions={data.questions} coaAccounts={data.coaAccounts} onRefresh={refresh} />}
          {activeTab === "weekly"   && <WeeklySnapshotSection snapshots={data.snapshots} weeklyView={data.weeklyView} />}
          {activeTab === "rules"    && <CodingRulesSection    rules={data.rules} onRefresh={refresh} />}
        </>
      )}
    </div>
  );
}
