import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import WeeklyCPR from "./WeeklyCPR.jsx";

// ── Design Tokens ──────────────────────────────────────────────
import { T } from "../lib/theme.js";

const fmt = v => { const n=parseFloat(v); return isNaN(n)?"$0.00":"$"+Math.abs(n).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2}); };
const pct = (v,m) => (((parseFloat(v)||0)/(parseFloat(m)||1))*100).toFixed(1);

// ── Mini Components ────────────────────────────────────────────
const Card = ({children, style={}}) => (
  <div style={{background:T.white, borderRadius:12, border:`1px solid ${T.slate200}`, padding:"16px 18px", ...style}}>
    {children}
  </div>
);

const SectionTitle = ({icon, title, action}) => (
  <div style={{display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:14}}>
    <div style={{display:"flex", alignItems:"center", gap:8}}>
      <span style={{fontSize:16}}>{icon}</span>
      <span style={{fontSize:13, fontWeight:700, color:T.slate800}}>{title}</span>
    </div>
    {action}
  </div>
);

const Badge = ({type="info", children}) => {
  const styles = {
    info:    {bg:T.blueLt,  color:T.blue},
    success: {bg:T.greenLt, color:T.green},
    warning: {bg:T.amberLt, color:T.amber},
    danger:  {bg:T.redLt,   color:T.red},
  };
  const s = styles[type] || styles.info;
  return (
    <span style={{display:"inline-flex", alignItems:"center", padding:"2px 8px", borderRadius:20, fontSize:10, fontWeight:700, background:s.bg, color:s.color}}>
      {children}
    </span>
  );
};

const EmptyRow = ({message}) => (
  <div style={{padding:"20px 0", textAlign:"center", color:T.slate400, fontSize:12}}>{message}</div>
);

const ProgressBar = ({value, max, color=T.blue, height=6}) => {
  const pctVal = Math.min(100, Math.max(0, ((parseFloat(value)||0)/(parseFloat(max)||1))*100));
  return (
    <div style={{background:T.slate100, borderRadius:99, height, overflow:"hidden"}}>
      <div style={{width:`${pctVal}%`, background:color, height:"100%", borderRadius:99, transition:"width 0.5s ease"}} />
    </div>
  );
};

// ── Widget: Financial KPIs ─────────────────────────────────────
const FinancialWidget = ({ data, onNavigate }) => {
  const s = data.summary || {};
  const kpis = [
    { label:"Revenue MTD",    value:fmt(s.revenueMTD),    color:T.green,  border:T.green },
    { label:"Expenses MTD",   value:fmt(s.expensesMTD),   color:T.red,    border:T.red   },
    { label:"Net Income MTD", value:fmt(s.netIncomeMTD),  color:s.netIncomeMTD>=0?T.green:T.red, border:s.netIncomeMTD>=0?T.green:T.red },
    { label:"Revenue YTD",   value:fmt(s.revenueYTD),    color:T.slate900,   border:T.slate900  },
  ];
  return (
    <Card>
      <SectionTitle icon="💰" title="Financial Overview"
        action={<button onClick={()=>onNavigate("financials")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>View Full P&L →</button>}
      />
      <div style={{display:"grid", gridTemplateColumns:"1fr 1fr", gap:10}}>
        {kpis.map((k,i) => (
          <div key={i} style={{padding:"10px 12px", borderRadius:8, border:`1px solid ${k.border}20`, background:`${k.border}08`}}>
            <div style={{fontSize:10, color:T.slate500, marginBottom:4, fontWeight:600}}>{k.label}</div>
            <div style={{fontSize:16, fontWeight:800, color:k.color}}>{k.value}</div>
          </div>
        ))}
      </div>
    </Card>
  );
};

// ── Widget: AIPP Progress ──────────────────────────────────────
const AIPPWidget = ({ data, onNavigate }) => {
  const a = data.aipp || {};
  const earned = parseFloat(a.earned)||0;
  const target = parseFloat(a.target)||1;
  const achievement = pct(earned, target);
  return (
    <Card>
      <SectionTitle icon="🏆" title={`AIPP ${a.year||2026} Progress`}
        action={<button onClick={()=>onNavigate("financials")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>Details →</button>}
      />
      <div style={{display:"flex", justifyContent:"space-between", alignItems:"flex-end", marginBottom:8}}>
        <div>
          <div style={{fontSize:28, fontWeight:800, color:parseFloat(achievement)>=80?T.green:T.amber}}>{achievement}%</div>
          <div style={{fontSize:11, color:T.slate500}}>{fmt(earned)} of {fmt(target)} target</div>
        </div>
        <div style={{textAlign:"right"}}>
          <div style={{fontSize:11, color:T.slate500}}>Projected</div>
          <div style={{fontSize:16, fontWeight:700, color:T.slate900}}>{fmt(a.projected)}</div>
        </div>
      </div>
      <ProgressBar value={earned} max={target} color={parseFloat(achievement)>=80?T.green:T.amber} height={8} />
    </Card>
  );
};


// ── Widget: Standing Goals Pace ────────────────────────────────
// Tracks Peter's 3 standing goals: 25% P&C book growth, Champions Circle
// qualification (400 Scorecard pts), and +1pt owner profit per quarter.
// Sources: book_snapshot · sf_on_time_snapshot · scorecard_tracking · v_income_statement.
const GoalsPaceWidget = ({ data, onNavigate }) => {
  const g = data.goalsPace || {};

  const statusColor = (p) => {
    if (p == null) return T.slate400;
    if (p >= 95)   return T.green;
    if (p >= 75)   return T.amber;
    return T.red;
  };
  const statusLabel = (p) => {
    if (p == null) return "—";
    if (p >= 110)  return "Ahead";
    if (p >= 95)   return "On Pace";
    if (p >= 75)   return "Behind";
    return "Off Pace";
  };

  const Row = ({ icon, title, current, target, sub, pacePct, navTarget }) => {
    const c = statusColor(pacePct);
    return (
      <div style={{padding:"12px 0", borderBottom:`1px solid ${T.slate100}`}}>
        <div style={{display:"flex", justifyContent:"space-between", alignItems:"baseline", marginBottom:6, gap:8}}>
          <div style={{display:"flex", alignItems:"center", gap:8, fontSize:12, fontWeight:700, color:T.slate800, minWidth:0, flex:1}}>
            <span style={{fontSize:15}}>{icon}</span>
            <span style={{overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap"}}>{title}</span>
          </div>
          <div style={{fontSize:10, fontWeight:700, color:c, padding:"2px 9px", borderRadius:10, background:`${c}18`, flexShrink:0}}>{statusLabel(pacePct)}</div>
        </div>
        <div style={{display:"flex", justifyContent:"space-between", alignItems:"baseline", marginBottom:6, gap:8}}>
          <div style={{fontSize:15, fontWeight:800, color:T.slate900}}>
            {current}<span style={{fontSize:11, fontWeight:500, color:T.slate500}}> / {target}</span>
          </div>
          {sub && <div style={{fontSize:10, color:T.slate500, textAlign:"right", maxWidth:"60%"}}>{sub}</div>}
        </div>
        <ProgressBar value={Math.max(0, Math.min(pacePct||0, 100))} max={100} color={c} height={6} />
      </div>
    );
  };

  return (
    <Card>
      <SectionTitle icon="🎯" title="Standing Goals — Pace Check"
        action={<button onClick={()=>onNavigate("financials")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>Financials →</button>}
      />
      <Row
        icon="📈"
        title="P&C Book Growth (25%/yr)"
        current={g.pc?.current_label || "—"}
        target={g.pc?.target_label || "—"}
        sub={g.pc?.sub}
        pacePct={g.pc?.pace_pct}
      />
      <Row
        icon="🏆"
        title="Champions Circle (400 pts)"
        current={g.cc?.current_label || "—"}
        target={g.cc?.target_label || "—"}
        sub={g.cc?.sub}
        pacePct={g.cc?.pace_pct}
      />
      <Row
        icon="💰"
        title="Owner Profit (+1pt/qtr)"
        current={g.op?.current_label || "—"}
        target={g.op?.target_label || "—"}
        sub={g.op?.sub}
        pacePct={g.op?.pace_pct}
      />
      <div style={{fontSize:10, color:T.slate400, marginTop:10, textAlign:"center"}}>
        {g.as_of_note || "Pace computed live · book_snapshot · sf_on_time_snapshot · GL"}
      </div>
    </Card>
  );
};

// ── Widget: Monthly Close Progress ────────────────────────────
// Visual checklist: closed months shown as compact pills, current month shows
// item-by-item received/outstanding with the actual document labels.
const MonthlyCloseWidget = ({ data, onNavigate }) => {
  const checklist = data.closeChecklist || [];
  const monthName = (y, m) => new Date(y, m-1, 1).toLocaleDateString("en-US",{month:"short", year:"numeric"});
  const monthLong = (y, m) => new Date(y, m-1, 1).toLocaleDateString("en-US",{month:"long", year:"numeric"});

  // Group rows by year-month
  const groups = {};
  for (const row of checklist) {
    const key = `${row.period_year}-${String(row.period_month).padStart(2,"0")}`;
    if (!groups[key]) groups[key] = { year: row.period_year, month: row.period_month, items: [], is_closed: row.is_closed };
    groups[key].items.push(row);
    if (row.is_closed) groups[key].is_closed = true;
  }
  const sortedKeys = Object.keys(groups).sort().reverse();
  const periods = sortedKeys.map(k => groups[k]);

  // Empty state
  if (periods.length === 0) {
    return (
      <Card>
        <SectionTitle icon="📅" title="Monthly Close" />
        <div style={{padding:"16px 0", fontSize:12, color:T.slate400, textAlign:"center"}}>
          Ask your Claude to set up your monthly close checklist
        </div>
      </Card>
    );
  }

  const current = periods.find(p => !p.is_closed) || periods[0];
  const closedMonths = periods.filter(p => p.is_closed).slice(0, 4);

  const received = current.items.filter(i => i.received_at).length;
  const total = current.items.length;
  const allReceived = received === total && total > 0;
  const outstandingItems = current.items.filter(i => !i.received_at);
  const receivedItems = current.items.filter(i => i.received_at);
  const formatDate = (d) => d ? new Date(d).toLocaleDateString("en-US",{month:"short",day:"numeric"}) : "";

  return (
    <Card>
      <SectionTitle icon="📅" title={`Monthly Close — ${monthLong(current.year, current.month)}`}
        action={<button onClick={()=>onNavigate("documents")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>View All →</button>}
      />

      {/* Summary header */}
      <div style={{display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:10}}>
        <div style={{fontSize:13, color:T.slate700}}>
          <span style={{fontWeight:700, color:allReceived?T.green:T.amber}}>{received}</span>
          <span style={{color:T.slate400}}> / {total} documents received</span>
        </div>
        <Badge type={allReceived?"success":"warning"}>{allReceived?"Ready to Close":"In Progress"}</Badge>
      </div>
      <ProgressBar value={received} max={total} color={allReceived?T.green:T.amber} height={6} />

      {/* Item-by-item checklist for current month */}
      <div style={{marginTop:12, display:"flex", flexDirection:"column", gap:5}}>
        {receivedItems.map((item, i) => (
          <div key={`r${i}`} style={{display:"flex", alignItems:"center", justifyContent:"space-between", fontSize:11, padding:"5px 8px", borderRadius:6, background:T.greenLt}}>
            <div style={{display:"flex", alignItems:"center", gap:7, minWidth:0, flex:1}}>
              <span style={{color:T.green, fontSize:13, lineHeight:1}}>✓</span>
              <span style={{color:T.slate800, fontWeight:500, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap"}}>{item.doc_label}</span>
            </div>
            <span style={{color:T.slate500, fontSize:10, flexShrink:0, marginLeft:8}}>{formatDate(item.received_at)}</span>
          </div>
        ))}
        {outstandingItems.map((item, i) => (
          <div key={`o${i}`} style={{display:"flex", alignItems:"center", justifyContent:"space-between", fontSize:11, padding:"5px 8px", borderRadius:6, background:T.amberLt}}>
            <div style={{display:"flex", alignItems:"center", gap:7, minWidth:0, flex:1}}>
              <span style={{color:T.amber, fontSize:13, lineHeight:1}}>○</span>
              <span style={{color:T.slate800, fontWeight:500, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap"}}>{item.doc_label}</span>
            </div>
            <span style={{color:T.amber, fontSize:10, fontWeight:600, flexShrink:0, marginLeft:8}}>
              Expected {formatDate(item.expected_by)}
            </span>
          </div>
        ))}
      </div>

      {/* Closed prior months — compact strip */}
      {closedMonths.length > 0 && (
        <div style={{marginTop:14, paddingTop:10, borderTop:`1px dashed ${T.slate200}`}}>
          <div style={{fontSize:10, color:T.slate500, fontWeight:600, marginBottom:6, letterSpacing:"0.04em", textTransform:"uppercase"}}>
            Recently Closed
          </div>
          <div style={{display:"flex", gap:6, flexWrap:"wrap"}}>
            {closedMonths.map((p, i) => (
              <div key={i} style={{display:"flex", alignItems:"center", gap:5, padding:"3px 8px", borderRadius:12, background:T.green, color:"#fff", fontSize:10, fontWeight:600}}>
                <span>✓</span>
                <span>{monthName(p.year, p.month)}</span>
                <span style={{opacity:0.75, fontSize:9, fontWeight:500}}>{p.items.length}/{p.items.length}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </Card>
  );
};

// ── Widget: High Priority Tasks ───────────────────────────────
const TasksWidget = ({ data, onNavigate }) => {
  const tasks = (data.tasks || [])
    .filter(t => t.priority === "high" && t.status !== "completed")
    .slice(0, 5);
  return (
    <Card>
      <SectionTitle icon="✅" title="High Priority Tasks"
        action={<button onClick={()=>onNavigate("tasks")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>All Tasks →</button>}
      />
      {tasks.length === 0 ? (
        <EmptyRow message="No high priority tasks — you're clear! ✨" />
      ) : (
        <div style={{display:"flex", flexDirection:"column", gap:8}}>
          {tasks.map((t,i) => (
            <div key={i} style={{display:"flex", justifyContent:"space-between", alignItems:"center", padding:"8px 10px", borderRadius:8, background:T.slate50, border:`1px solid ${T.slate200}`}}>
              <div>
                <div style={{fontSize:12, fontWeight:600, color:T.slate800}}>{t.title||t.task_title}</div>
                {t.due_date && <div style={{fontSize:10, color:T.slate500, marginTop:2}}>Due: {t.due_date}</div>}
              </div>
              <Badge type="danger">High</Badge>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
};

// ── Widget: Open Items (Claude waiting on answers) ────────────
const OpenItemsWidget = ({ data, onNavigate }) => {
  const openItems = (data.openItems || data.persistentMemory || [])
    .filter(m => m.memory_type === "open_item" || m.needs_followup === true || m.is_active === true || m.status === "pending_agent_input")
    .slice(0, 5);
  return (
    <Card>
      <SectionTitle icon="🔍" title="Open Items — Claude Needs Your Input"
        action={<button onClick={()=>onNavigate("memory")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>View All →</button>}
      />
      {openItems.length === 0 ? (
        <EmptyRow message="No open items — Claude has everything it needs ✨" />
      ) : (
        <div style={{display:"flex", flexDirection:"column", gap:8}}>
          {openItems.map((item,i) => (
            <div key={i} style={{padding:"8px 10px", borderRadius:8, background:T.amberLt, border:`1px solid #FDE68A`}}>
              <div style={{fontSize:12, fontWeight:600, color:"#92400E"}}>{item.title||item.content?.slice(0,60)||"Pending item"}</div>
              {item.context && <div style={{fontSize:10, color:"#B45309", marginTop:2}}>{item.context.slice(0,80)}</div>}
            </div>
          ))}
        </div>
      )}
    </Card>
  );
};

// ── Widget: Active Alerts ─────────────────────────────────────
const AlertsWidget = ({ data, onNavigate }) => {
  const alerts = (data.alerts || [])
    .filter(a => !a.is_resolved)
    .sort((a,b) => {
      const sev = {critical:0, warning:1, info:2};
      return (sev[a.severity]||2) - (sev[b.severity]||2);
    })
    .slice(0, 4);
  return (
    <Card>
      <SectionTitle icon="🔔" title="Active Alerts"
        action={<button onClick={()=>onNavigate("alerts")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>All Alerts →</button>}
      />
      {alerts.length === 0 ? (
        <div style={{display:"flex", alignItems:"center", gap:10, padding:"12px 0"}}>
          <span style={{fontSize:24}}>✅</span>
          <div>
            <div style={{fontSize:13, fontWeight:600, color:T.green}}>All Clear</div>
            <div style={{fontSize:11, color:T.slate500}}>No active alerts requiring attention</div>
          </div>
        </div>
      ) : (
        <div style={{display:"flex", flexDirection:"column", gap:8}}>
          {alerts.map((a,i) => (
            <div key={i} style={{display:"flex", justifyContent:"space-between", alignItems:"flex-start", padding:"8px 10px", borderRadius:8, background:a.severity==="critical"?T.redLt:a.severity==="warning"?T.amberLt:T.blueLt, border:`1px solid ${a.severity==="critical"?"#FCA5A5":a.severity==="warning"?"#FDE68A":"#BFDBFE"}`}}>
              <div style={{flex:1}}>
                <div style={{fontSize:12, fontWeight:600, color:a.severity==="critical"?T.red:a.severity==="warning"?T.amber:T.blue}}>{a.title}</div>
                {a.due_date && <div style={{fontSize:10, color:T.slate600, marginTop:2}}>Due: {a.due_date}</div>}
              </div>
              <Badge type={a.severity==="critical"?"danger":a.severity==="warning"?"warning":"info"}>
                {a.severity}
              </Badge>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
};

// ── Widget: Compliance Summary ────────────────────────────────
const ComplianceWidget = ({ data, onNavigate }) => {
  const rules = data.complianceRules || [];
  const violations = rules.filter(r => r.status === "violation" || r.is_active).length;
  const pending = rules.filter(r => r.status === "pending_review").length;
  const compliant = rules.filter(r => r.status === "compliant").length;
  const total = rules.length;

  return (
    <Card>
      <SectionTitle icon="⚖️" title="Compliance Status"
        action={<button onClick={()=>onNavigate("compliance")} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>Review →</button>}
      />
      {total === 0 ? (
        <div style={{fontSize:11, color:T.amber, textAlign:"center", padding:"12px 0"}}>
          ⚠️ Compliance rules not seeded yet<br/>
          <span style={{color:T.slate500}}>Ask Claude: "Seed my SF compliance rules"</span>
        </div>
      ) : (
        <div style={{display:"grid", gridTemplateColumns:"1fr 1fr 1fr", gap:8}}>
          {[
            {label:"Compliant", value:compliant, color:T.green, bg:T.greenLt},
            {label:"Pending",   value:pending,   color:T.amber, bg:T.amberLt},
            {label:"Violations",value:violations,color:T.red,   bg:T.redLt},
          ].map((s,i) => (
            <div key={i} style={{textAlign:"center", padding:"10px 8px", borderRadius:8, background:s.bg}}>
              <div style={{fontSize:22, fontWeight:800, color:s.color}}>{s.value}</div>
              <div style={{fontSize:10, color:T.slate600, fontWeight:600}}>{s.label}</div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
};

// ── Main Dashboard Component ───────────────────────────────────
// ── Widget: Weekly CPR ─────────────────────────────────────────
const WeeklyCPRWidget = ({ data, onOpen }) => {
  const r = data.cprLatest;
  const fmtD = (iso) => { if (!iso) return "—"; try { return new Date(iso + "T00:00:00").toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"}); } catch { return iso; } };
  const fmtP = (v) => (v===null||v===undefined||v==="") ? "—" : `${Number(v).toFixed(2)}%`;
  return (
    <Card>
      <SectionTitle icon="📋" title="Weekly CPR"
        action={<button onClick={onOpen} style={{fontSize:11,color:T.blue,background:"none",border:"none",cursor:"pointer",fontWeight:600}}>Open form →</button>}
      />
      {r ? (
        <div>
          <div style={{fontSize:11, color:T.slate500, marginBottom:10}}>
            Latest week ending <span style={{fontWeight:700, color:T.slate800}}>{fmtD(r.week_ending_date)}</span>
          </div>
          <div style={{display:"grid", gridTemplateColumns:"1fr 1fr", gap:10, marginBottom:10}}>
            <div style={{padding:"8px 10px", borderRadius:8, border:`1px solid ${T.blue}30`, background:`${T.blue}08`}}>
              <div style={{fontSize:10, color:T.slate500, fontWeight:600}}>AUTO</div>
              <div style={{fontSize:16, fontWeight:800, color:T.blue}}>{fmtP(r.auto_ratio_pct)}</div>
              <div style={{fontSize:10, color:T.slate500}}>rank {r.auto_rank ?? "—"}</div>
            </div>
            <div style={{padding:"8px 10px", borderRadius:8, border:`1px solid ${T.amber}30`, background:`${T.amber}08`}}>
              <div style={{fontSize:10, color:T.slate500, fontWeight:600}}>FIRE</div>
              <div style={{fontSize:16, fontWeight:800, color:T.amber}}>{fmtP(r.fire_ratio_pct)}</div>
              <div style={{fontSize:10, color:T.slate500}}>rank {r.fire_rank ?? "—"}</div>
            </div>
          </div>
          <div style={{display:"grid", gridTemplateColumns:"repeat(4, 1fr)", gap:6}}>
            {[["Non Pays", r.non_pays],["New", r.new_claims],["Open", r.open_claims],["Unreview", r.unreviewed_claims]].map(([lbl, val], i) => (
              <div key={i} style={{padding:"6px 8px", borderRadius:6, background:T.slate50, border:`1px solid ${T.slate200}`}}>
                <div style={{fontSize:9, color:T.slate500, fontWeight:600}}>{lbl}</div>
                <div style={{fontSize:14, fontWeight:800, color:T.slate800}}>{val ?? "—"}</div>
              </div>
            ))}
          </div>
        </div>
      ) : (
        <EmptyRow message="No CPR entered yet — click 'Open form' above to start." />
      )}
    </Card>
  );
};

export default function Dashboard({ onNavigate = () => {} }) {
  const [dashData, setDashData] = useState({});
  const [loading, setLoading] = useState(true);
  const [agencyName, setAgencyName] = useState("Your Agency");
  const [greeting, setGreeting] = useState("Good morning");
  const [showCPR, setShowCPR] = useState(false);

  useEffect(() => {
    const hr = new Date().getHours();
    setGreeting(hr < 12 ? "Good morning" : hr < 17 ? "Good afternoon" : "Good evening");
  }, []);

  useEffect(() => {
    async function loadDashboard() {
      setLoading(true);
      try {
        // Parallel fetch all dashboard data
        const [
          agencyRes, summaryRes, aippRes, tasksRes,
          alertsRes, memoryRes, complianceRes, closeRes, closeChecklistRes, cprRes
        ] = await Promise.allSettled([
          supabase.from("agency").select("*").limit(1).maybeSingle(),
          Promise.resolve({ data: null }), // removed — no comp_recap_data  table
          //Promise.resolve({ data: null }), // comp_recap_data  removed — no such table in schema
          supabase.from("aipp_tracking").select("*").order("program_year",{ascending:false}).limit(1).maybeSingle(),
          supabase.from("tasks").select("*").eq("status","open").order("priority").limit(20),
          supabase.from("alerts").select("*").eq("is_resolved",false).order("created_at",{ascending:false}).limit(10),
          supabase.from("persistent_memory").select("*").eq("is_active",true).order("updated_at",{ascending:false}).limit(10),
          supabase.from("compliance_rules").select("id,title,severity,is_active").limit(100),
          supabase.from("documents").select("*").order("created_at",{ascending:false}).limit(20),
          supabase.from("monthly_close_checklist").select("*").order("period_year",{ascending:false}).order("period_month",{ascending:false}).limit(60),
          supabase.from("weekly_cpr_reports").select("*").eq("agency_id", AGENCY_ID).order("week_ending_date",{ascending:false}).limit(1).maybeSingle(),
        ]);

        const agency = agencyRes.status==="fulfilled" ? agencyRes.value.data : null;
        if (agency?.name) setAgencyName(agency.name);

        // Build comp_recap summary from view
        const { data: compData } = await supabase.from("comp_recap").select("*").order("period_year",{ascending:false}).order("period_month",{ascending:false}).limit(20);
        const latestComp = (compData||[])[0] || {};

        // Build income statement summary (current year + prior year for goal comparisons)
        const now = new Date();
        const curYear  = now.getFullYear();
        const curMonth = now.getMonth() + 1;
        const { data: isData } = await supabase.from("v_income_statement")
          .select("account_name, account_type, amount, month, year")
          .gte("year", curYear - 1)
          .limit(1500);

        const isCur = (isData||[]).filter(r => r.year === curYear);
        const incomeLines  = isCur.filter(r => r.account_type === "income");
        const expenseLines = isCur.filter(r => r.account_type === "expense");
        const sum = rows => rows.reduce((s, r) => s + parseFloat(r.amount || 0), 0);
        const revenueMTD  = sum(incomeLines.filter(r  => r.month === curMonth));
        const expensesMTD = sum(expenseLines.filter(r => r.month === curMonth));
        const revenueYTD  = sum(incomeLines);

        // ─── Standing Goals pace computation ─────────────────────
        // Pull goal feeds in parallel
        const [bookRes, bpgRes, sfRes, scRes] = await Promise.allSettled([
          supabase.from("book_snapshot").select("snapshot_date, auto_pif, fire_pif").eq("agency_id", AGENCY_ID).order("snapshot_date",{ascending:false}).limit(1).maybeSingle(),
          supabase.from("book_performance_goals").select("lob, metric, target_value").eq("agency_id", AGENCY_ID).eq("year", curYear),
          supabase.from("sf_on_time_snapshot").select("*").eq("agency_id", AGENCY_ID).order("snapshot_date",{ascending:false}).limit(1).maybeSingle(),
          supabase.from("scorecard_tracking").select("metric_name, min_target, max_target").eq("agency_id", AGENCY_ID).eq("program_year", curYear),
        ]);
        const book = bookRes.status==="fulfilled" ? bookRes.value.data : null;
        const bpg  = bpgRes.status==="fulfilled" ? (bpgRes.value.data||[]) : [];
        const sf   = sfRes.status==="fulfilled" ? sfRes.value.data : null;
        const scBands = (scRes.status==="fulfilled" ? (scRes.value.data||[]) : []).reduce((acc,r) => { acc[r.metric_name] = {min:parseFloat(r.min_target)||0, max:parseFloat(r.max_target)||0}; return acc; }, {});

        // Days through year (for annualization)
        const yearStart = new Date(curYear, 0, 1);
        const daysElapsed = Math.max(1, Math.floor((now - yearStart) / 86400000) + 1);
        const annualize = (ytd) => (parseFloat(ytd)||0) * (365 / daysElapsed);
        const yearProgress = daysElapsed / 365;

        // ─── Goal 1: P&C Book Growth (25%/yr) ───
        let pc = null;
        const bpgByKey = bpg.reduce((m,r) => { m[`${r.lob}.${r.metric}`] = parseFloat(r.target_value)||0; return m; }, {});
        const autoTarget = bpgByKey["auto.pif"];
        const fireTarget = bpgByKey["fire.pif"];
        const autoGainTgt = bpgByKey["auto.gain"];
        const fireGainTgt = bpgByKey["fire.gain"];
        if (book && autoTarget && fireTarget && autoGainTgt!=null && fireGainTgt!=null) {
          const ysAutoPC  = autoTarget - autoGainTgt;
          const ysFirePC  = fireTarget - fireGainTgt;
          const ysPC      = ysAutoPC + ysFirePC;
          const curPC     = (book.auto_pif||0) + (book.fire_pif||0);
          const netYTD    = curPC - ysPC;
          const tgtGain   = ysPC * 0.25;                     // 25% of year-start P&C
          const annualGain= annualize(netYTD);
          const growthPctYTD     = ysPC > 0 ? (netYTD / ysPC) * 100 : 0;
          const growthPctOnTime  = ysPC > 0 ? (annualGain / ysPC) * 100 : 0;
          const pace_pct  = growthPctOnTime > 0 ? (growthPctOnTime / 25) * 100 : 0;
          pc = {
            current_label: `${curPC.toLocaleString()} PIF`,
            target_label:  `${Math.round(ysPC * 1.25).toLocaleString()} PIF`,
            sub: `+${netYTD} YTD · on-time +${Math.round(annualGain)} (need +${Math.round(tgtGain)}) · ${growthPctYTD.toFixed(1)}% / 25%`,
            pace_pct,
          };
        }

        // ─── Goal 2: Champions Circle (400 pts, Auto + Fire + FS only) ───
        let cc = null;
        if (sf) {
          const lin = (val, min, max, capPts) => {
            if (!max || max <= min) return 0;
            const raw = ((val - min) / (max - min)) * capPts;
            return Math.max(0, Math.min(capPts, raw));
          };
          const autoGainAnn = annualize((sf.auto_production_ytd||0) - (sf.auto_lapse_ytd||0));
          const autoProdAnn = annualize(sf.auto_production_ytd||0);
          const fireGainAnn = annualize((sf.fire_production_ytd||0) - (sf.fire_lapse_ytd||0));
          const fireProdAnn = annualize(sf.fire_production_ytd||0);
          const fsCreditsAnn= annualize((parseFloat(sf.life_premium_credits_ytd)||0) + (parseFloat(sf.ips_activity_ytd)||0));
          const autoGainPts = scBands.auto_pif_gain        ? lin(autoGainAnn, scBands.auto_pif_gain.min, scBands.auto_pif_gain.max, 200) : 0;
          const autoProdPts = scBands.auto_pif_production  ? lin(autoProdAnn, scBands.auto_pif_production.min, scBands.auto_pif_production.max, 125) : 0;
          const fireGainPts = scBands.fire_pif_gain        ? lin(fireGainAnn, scBands.fire_pif_gain.min, scBands.fire_pif_gain.max, 100) : 0;
          const fireProdPts = scBands.fire_pif_production  ? lin(fireProdAnn, scBands.fire_pif_production.min, scBands.fire_pif_production.max, 100) : 0;
          const fsPts       = scBands.fs_credits           ? lin(fsCreditsAnn, scBands.fs_credits.min, scBands.fs_credits.max, 225) : 0;
          const autoPts     = Math.max(autoGainPts, autoProdPts);
          const firePts     = Math.max(fireGainPts, fireProdPts);
          const totalPts    = autoPts + firePts + fsPts;
          const pace_pct    = (totalPts / 400) * 100;
          cc = {
            current_label: `${Math.round(totalPts)} pts`,
            target_label:  `400 pts`,
            sub: `Auto ${Math.round(autoPts)} · Fire ${Math.round(firePts)} · FS ${Math.round(fsPts)}`,
            pace_pct,
          };
        }

        // ─── Goal 3: Owner Profit (+1pt/quarter) ───
        let op = null;
        const isAll = (isData||[]);
        const sumQ = (year, q) => {
          const months = [q*3-2, q*3-1, q*3];
          const rev = sum(isAll.filter(r => r.year===year && months.includes(r.month) && r.account_type==="income"));
          const exp = sum(isAll.filter(r => r.year===year && months.includes(r.month) && r.account_type==="expense"));
          return rev > 0 ? { revenue:rev, expenses:exp, margin: ((rev - exp) / rev) * 100 } : null;
        };
        // Latest closed quarter = the most recent quarter whose final month is < current month/year
        const curQ  = Math.ceil(curMonth / 3);
        let lastClosedYear, lastClosedQ, priorClosedYear, priorClosedQ;
        if (curQ === 1) { lastClosedYear = curYear-1; lastClosedQ = 4; priorClosedYear = curYear-1; priorClosedQ = 3; }
        else            { lastClosedYear = curYear;   lastClosedQ = curQ-1; priorClosedYear = (curQ-1===1) ? curYear-1 : curYear; priorClosedQ = curQ===2 ? 4 : curQ-2; if (priorClosedYear !== curYear) priorClosedYear = curYear-1; }
        const latestQ = sumQ(lastClosedYear, lastClosedQ);
        const priorQ  = sumQ(priorClosedYear, priorClosedQ);
        if (latestQ && priorQ) {
          const delta = latestQ.margin - priorQ.margin;
          const pace_pct = (delta / 1.0) * 100; // 1pp = 100% pace
          const sign = delta >= 0 ? "+" : "";
          op = {
            current_label: `${latestQ.margin.toFixed(1)}%`,
            target_label:  `${(priorQ.margin + 1).toFixed(1)}%`,
            sub: `${sign}${delta.toFixed(1)} pp vs Q${priorClosedQ} ${priorClosedYear} (${priorQ.margin.toFixed(1)}%)`,
            pace_pct: Math.max(0, Math.min(200, pace_pct)),
          };
        } else if (latestQ) {
          op = {
            current_label: `${latestQ.margin.toFixed(1)}%`,
            target_label:  "—",
            sub: `Q${lastClosedQ} ${lastClosedYear} margin · prior Q unavailable`,
            pace_pct: null,
          };
        }

        const goalsPace = {
          pc, cc, op,
          as_of_note: sf?.snapshot_date
            ? `Live as of ${sf.snapshot_date} · day ${daysElapsed} of 365`
            : `Live · day ${daysElapsed} of 365`,
        };

        setDashData({
          agency,
          summary: {
            revenueMTD, expensesMTD,
            netIncomeMTD: revenueMTD - expensesMTD,
            revenueYTD,
          },
          aipp: (() => {
            const a = aippRes.status==="fulfilled" ? aippRes.value.data : null;
            if (!a) return { year: new Date().getFullYear(), target:0, earned:0, projected:0 };
            return {
              year:      a.program_year || new Date().getFullYear(),
              target:    parseFloat(a.target_amount)        || 0,
              earned:    parseFloat(a.earned_ytd)           || 0,
              projected: parseFloat(a.projected_full_year)  || 0,
              achievement: parseFloat(a.achievement_percentage) || 0,
              notes:     a.notes || null,
            };
          })(),
          tasks: tasksRes.status==="fulfilled" ? (tasksRes.value.data||[]) : [],
          alerts: alertsRes.status==="fulfilled" ? (alertsRes.value.data||[]) : [],
          openItems: memoryRes.status==="fulfilled" ? (memoryRes.value.data||[]) : [],
          complianceRules: complianceRes.status==="fulfilled" ? (complianceRes.value.data||[]) : [],
          closeDocuments: closeRes.status==="fulfilled" ? (closeRes.value.data||[]) : [],
          closeChecklist: closeChecklistRes.status==="fulfilled" ? (closeChecklistRes.value.data||[]) : [],
          cprLatest: cprRes.status==="fulfilled" ? (cprRes.value.data || null) : null,
          goalsPace,
        });
      } catch (err) {
        console.error("Dashboard load error:", err);
      } finally {
        setLoading(false);
      }
    }
    loadDashboard();
  }, []);

  const today = new Date().toLocaleDateString("en-US",{weekday:"long",month:"long",day:"numeric",year:"numeric"});

  if (loading) {
    return (
      <div style={{padding:32, display:"flex", flexDirection:"column", alignItems:"center", gap:16}}>
        <div style={{fontSize:32}}>⚡</div>
        <div style={{fontSize:14, color:T.slate500}}>Loading your command center...</div>
      </div>
    );
  }

  return (
    <div style={{padding:"0 0 40px 0"}}>
      {/* Header */}
      <div style={{padding:"20px 0 16px 0", borderBottom:`1px solid ${T.slate200}`, marginBottom:20}}>
        <div style={{fontSize:22, fontWeight:700, color:T.slate900}}>{today}</div>
      </div>

      {/* Top Row — Standing Goals Pace (full width) */}
      <div style={{marginBottom:14}}>
        <GoalsPaceWidget data={dashData} onNavigate={onNavigate} />
      </div>

      {/* Second Row — Financial + AIPP */}
      <div style={{display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(240px, 1fr))", gap:14, marginBottom:14}}>
        <FinancialWidget data={dashData} onNavigate={onNavigate} />
        <AIPPWidget data={dashData} onNavigate={onNavigate} />
      </div>

      {/* Second Row — Monthly Close + Alerts */}
      <div style={{display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(240px, 1fr))", gap:14, marginBottom:14}}>
        <MonthlyCloseWidget data={dashData} onNavigate={onNavigate} />
        <AlertsWidget data={dashData} onNavigate={onNavigate} />
      </div>

      {/* Third Row — Tasks + Compliance */}
      <div style={{display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(240px, 1fr))", gap:14, marginBottom:14}}>
        <TasksWidget data={dashData} onNavigate={onNavigate} />
        <ComplianceWidget data={dashData} onNavigate={onNavigate} />
      </div>

      {/* Fourth Row — Weekly CPR (full width) */}
      <div style={{marginBottom:14}}>
        <WeeklyCPRWidget data={dashData} onOpen={() => setShowCPR(true)} />
      </div>

      {/* Bottom Row — Open Items (full width) */}
      <OpenItemsWidget data={dashData} onNavigate={onNavigate} />

      {/* Weekly CPR overlay (modal) */}
      {showCPR ? <WeeklyCPR onClose={() => setShowCPR(false)} /> : null}
    </div>
  );
}
