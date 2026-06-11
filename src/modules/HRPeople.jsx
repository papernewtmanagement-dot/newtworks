import { useState, useMemo, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";


// Returns true if a staff member holds any one of the three license types.
const hasAnyLicense = (m) => !!(m && (m.license_pc || m.license_lh || m.license_ips));
// ============================================================
// BCC HR & PEOPLE MODULE v1.0
// Business Command Center — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// SECTIONS:
//   1. Overview      — Pipeline summary, team snapshot, alerts
//   2. Recruiting    — Kanban pipeline: New→Screen→Interview→Offer→Hired
//   3. Applicants    — Full applicant list with Groq scores
//   4. Onboarding    — Active onboarding checklists per new hire
//   5. Staff         — Current team directory with licensing status
//   6. Performance   — Monthly KPI tracking per staff member
//   7. Commissions   — Commission structures and monthly calculations
//
// KEY AUTOMATION:
//   Resume Scanner (Composio + Groq) auto-creates applicant
//   records from Gmail, scores candidates 1-10, generates
//   One Page Interview Focus — no manual data entry needed.
//
// COMPLIANCE FLAGS:
//   • Staff must be licensed before performing licensed activities
//   • Family employees require year-end W-2 review with CPA
//   • New hires must be notified to SF within required timeframe
//   • Agent is liable for all staff activities (AA05 Section I.P)
//
// DATA: Reads applicants, staff, onboarding_checklists,
//       staff_performance, commission_structures tables
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

// ─── Pipeline Stage Config ────────────────────────────────────
const STAGES = {
  new:       { label:"New",        color:T.slate500, bg:T.slate100, order:0 },
  screening: { label:"Screening",  color:T.blue,     bg:T.blueLt,  order:1 },
  interview: { label:"Interview",  color:T.amber,    bg:T.amberLt, order:2 },
  offer:     { label:"Offer",      color:T.purple,   bg:T.purpleLt,order:3 },
  hired:     { label:"Hired",      color:T.green,    bg:T.greenLt, order:4 },
  rejected:  { label:"Rejected",   color:T.red,      bg:T.redLt,   order:5 },
};

// ─── Producer ROI Hook ───────────────────────────────────────
function useProducerROI() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const currentYear  = new Date().getFullYear();
        const currentMonth = new Date().getMonth() + 1;

        const [agencyRes, staffRes, prodRes, payrollDetailRes, payrollRunsRes, compRes, aippRes, aippTrackRes] = await Promise.all([
          supabase.from("agency").select("id, name, smvc_rate_pc, blended_rate_other, lapse_rate_annual, rates_are_defaults").eq("id", AGENCY_ID).maybeSingle(),
          supabase.from("staff").select("id, first_name, last_name, role, start_date, pay_rate, pay_type, employment_type, is_active, email, phone, notes, license_pc, license_lh, license_ips, license_states, compliance_flag, nickname").eq("agency_id", AGENCY_ID),
          supabase.from("producer_production").select("staff_id, period_year, period_month, line_of_business, policies_issued, premium_issued").eq("agency_id", AGENCY_ID).order("period_year",{ascending:false}).order("period_month",{ascending:false}),
          supabase.from("payroll_detail").select("staff_id, gross_pay, payroll_run_id"),
          supabase.from("payroll_runs").select("id, pay_date, pay_period_start, pay_period_end").eq("agency_id", AGENCY_ID).order("pay_date",{ascending:false}).limit(24),
          supabase.from("comp_recap").select("period_year, period_month, comp_type, comp_category, amount").eq("agency_id", AGENCY_ID),
          supabase.from("v_aipp_projection").select("*").eq("agency_id", AGENCY_ID).maybeSingle(),
          supabase.from("aipp_tracking").select("*").eq("agency_id", AGENCY_ID).order("program_year",{ascending:false}).limit(1),
        ]);

        const agency = agencyRes.data || {};
        const staff  = (staffRes.data || []).filter(s => s.is_active !== false);
        const production = prodRes.data || [];
        const payrollDetail = payrollDetailRes.data || [];
        const payrollRuns = payrollRunsRes.data || [];
        const compRecaps = compRes.data || [];

        // Lapse rate from comp_recap: prior-year vs current-year auto+fire YTD renewals
        const isPC = (cat) => {
          const c = (cat || "").toLowerCase();
          return c.includes("auto") || c.includes("home") || c.includes("fire") || c.includes("umbrella");
        };
        const renewalsYtd = (year) => compRecaps
          .filter(r => r.period_year === year && r.comp_type === "renewal" && isPC(r.comp_category) && r.period_month <= currentMonth)
          .reduce((s,r) => s + parseFloat(r.amount || 0), 0);

        const priorRenewals = renewalsYtd(currentYear - 1);
        const currentRenewals = renewalsYtd(currentYear);
        let computedLapse = null;
        if (priorRenewals > 0) {
          computedLapse = Math.max(0, Math.min(50, (1 - currentRenewals / priorRenewals) * 100));
        }
        const lapseRate = agency.lapse_rate_annual != null
          ? (parseFloat(agency.lapse_rate_annual) <= 1 ? parseFloat(agency.lapse_rate_annual) * 100 : parseFloat(agency.lapse_rate_annual))
          : (computedLapse != null ? computedLapse : 10);

        // Per-producer monthly gross pay from last 3 payroll runs (×2 for semi-monthly)
        const last3RunIds = new Set(payrollRuns.slice(0, 3).map(r => r.id));
        const grossByStaff = {};
        const runsCountByStaff = {};
        for (const d of payrollDetail) {
          if (!last3RunIds.has(d.payroll_run_id)) continue;
          grossByStaff[d.staff_id] = (grossByStaff[d.staff_id] || 0) + parseFloat(d.gross_pay || 0);
          runsCountByStaff[d.staff_id] = (runsCountByStaff[d.staff_id] || 0) + 1;
        }
        const monthlyGrossByStaff = {};
        for (const sid of Object.keys(grossByStaff)) {
          const total = grossByStaff[sid];
          const runs = runsCountByStaff[sid] || 1;
          monthlyGrossByStaff[sid] = (total / runs) * 2;
        }

        // Rates in the agency table are stored as decimals (e.g. 0.10 = 10%).
        // The Performance UI works in PERCENT, so normalize: a value <= 1 is a
        // decimal fraction and gets ×100; a value > 1 is already a percent.
        const toPct = (v, dflt) => {
          const n = parseFloat(v);
          if (!Number.isFinite(n) || n <= 0) return dflt;
          return n <= 1 ? n * 100 : n;
        };
        const smvc = toPct(agency.smvc_rate_pc, 10);
        const blended = toPct(agency.blended_rate_other, 9);

        // Group production by staff/year/month
        const prodByKey = {};
        for (const p of production) {
          const k = `${p.staff_id}|${p.period_year}|${p.period_month}`;
          if (!prodByKey[k]) prodByKey[k] = { pc_premium: 0, other_premium: 0, policies: 0 };
          if (p.line_of_business === "auto" || p.line_of_business === "fire") {
            prodByKey[k].pc_premium += parseFloat(p.premium_issued || 0);
          } else {
            prodByKey[k].other_premium += parseFloat(p.premium_issued || 0);
          }
          prodByKey[k].policies += parseInt(p.policies_issued || 0, 10);
        }

        // Producers only (LSPs, Producers, FSS)
        const producers = staff.filter(s => {
          const r = (s.role || "").toLowerCase();
          return r.includes("lsp") || r.includes("producer") || r.includes("financial services");
        });

        const producerRows = producers.map(s => {
          const history = [];
          for (let back = 0; back < 24; back++) {
            const date = new Date(currentYear, currentMonth - 1 - back, 1);
            const y = date.getFullYear();
            const m = date.getMonth() + 1;
            const k = `${s.id}|${y}|${m}`;
            const row = prodByKey[k] || { pc_premium: 0, other_premium: 0, policies: 0 };
            const newCommission = (row.pc_premium * smvc / 100) + (row.other_premium * blended / 100);
            history.push({
              year: y, month: m,
              monthLabel: date.toLocaleDateString("en-US",{month:"short", year:"2-digit"}),
              pcPremium: row.pc_premium,
              otherPremium: row.other_premium,
              policies: row.policies,
              newCommission,
            });
          }
          history.reverse();

          const current = history[history.length - 1] || { pcPremium: 0, otherPremium: 0, policies: 0, newCommission: 0 };
          const recent6 = history.slice(-6);
          const avgPC = recent6.reduce((s,h) => s + h.pcPremium, 0) / Math.max(1, recent6.length);
          const avgOther = recent6.reduce((s,h) => s + h.otherPremium, 0) / Math.max(1, recent6.length);
          const avgNewCommission = (avgPC * smvc / 100) + (avgOther * blended / 100);

          const monthlyGross = monthlyGrossByStaff[s.id] || (parseFloat(s.pay_rate || 0) / 12) || 0;
          const monthlyLoaded = monthlyGross * 1.15;

          const startDate = s.start_date ? new Date(s.start_date) : new Date();
          const tenureMonths = Math.max(0, Math.round((Date.now() - startDate.getTime()) / (1000 * 60 * 60 * 24 * 30.42)));

          return {
            staff_id: s.id,
            name: `${s.first_name} ${s.last_name}`,
            role: s.role,
            start_date: s.start_date,
            tenureMonths,
            payRate: parseFloat(s.pay_rate || 0),
            monthlyGross,
            monthlyLoaded,
            currentMonth: current,
            history,
            avgPC,
            avgOther,
            avgNewCommission,
          };
        });

        // AIPP projection (server-side view) + tracking baseline
        const aipp = aippRes?.data || null;
        const aippTracking = (aippTrackRes?.data && aippTrackRes.data[0]) || null;

        setData({
          agency,
          smvcRate: smvc,
          blendedRate: blended,
          lapseRate,
          lapseRateComputed: computedLapse,
          lapseRateOverride: agency.lapse_rate_annual != null,
          ratesAreDefaults: agency.rates_are_defaults === true,
          priorRenewals,
          currentRenewals,
          producerRows,
          allActiveStaff: staff,
          aipp,
          aippTracking,
          hasProductionData: production.length > 0,
        });
      } catch (e) {
        console.error("Producer ROI load error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  return { data, loading };
}

// ─── Helpers ──────────────────────────────────────────────────
const scoreColor = (s) => s >= 8 ? T.green : s >= 6 ? T.amber : T.red;
const scoreBg    = (s) => s >= 8 ? T.greenLt : s >= 6 ? T.amberLt : T.redLt;
const pct = (a, t) => t ? Math.min(100, Math.round((a/t)*100)) : 0;
const fmt = (n, unit) => unit === "dollars" ? "$"+n.toLocaleString() : unit === "percentage" ? n+"%" : n.toString();

// ─── Shared Components ────────────────────────────────────────
const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);

const AskBtn = ({ context, size="normal" }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context); window.open("https://claude.ai","_blank"); }}
    style={{ display:"flex", alignItems:"center", gap:5, background:T.blue, color:T.white, border:"none", borderRadius:7, padding:size==="small"?"5px 10px":"7px 13px", fontSize:size==="small"?10:11, fontWeight:600, cursor:"pointer", whiteSpace:"nowrap", flexShrink:0 }}
  >⚡ Ask Claude</button>
);

const ProgressBar = ({ value, max, color=T.blue, height=6 }) => (
  <div style={{ height, background:T.slate100, borderRadius:height/2, overflow:"hidden" }}>
    <div style={{ height:"100%", width:`${pct(value,max)}%`, background:color, borderRadius:height/2, transition:"width 0.6s ease" }} />
  </div>
);

const StageBadge = ({ status }) => {
  const s = STAGES[status] || STAGES.new;
  return <span style={{ fontSize:10, fontWeight:600, padding:"3px 8px", borderRadius:20, background:s.bg, color:s.color }}>{s.label}</span>;
};

// ─── Section: Overview ────────────────────────────────────────
const HROverview = ({ applicants, staff, onboarding }) => {
  const [showAddEmployee, setShowAddEmployee] = useState(false);
  const [newEmployee, setNewEmployee] = useState({first_name:"", last_name:"", role:"", email:"", phone:"", start_date:"", employment_type:"w2"});

  const saveEmployee = async () => {
    if (!newEmployee.first_name || !newEmployee.last_name) return;
    if (supabase) {
      await supabase.from("staff").insert({ ...newEmployee, agency_id: AGENCY_ID, is_active: true });
    }
    setShowAddEmployee(false);
    setNewEmployee({first_name:"", last_name:"", role:"", email:"", phone:"", start_date:"", employment_type:"w2"});
  };

  const active      = applicants.filter(a => !["hired","rejected"].includes(a.status));
  const newApps     = applicants.filter(a => a.status === "new").length;
  const inInterview = applicants.filter(a => a.status === "interview").length;
  const inOffer     = applicants.filter(a => a.status === "offer").length;
  const activeStaff = staff.filter(s => s.is_active).length;
  const flagged     = staff.filter(s => s.compliance_flag).length;

  return (
    <div>
      {/* KPI Row */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(120px,1fr))", gap:10, marginBottom:16 }}>
        {[
          { label:"Active Pipeline",   value:active.length,   color:T.blue,  border:T.blue  },
          { label:"New Applicants",    value:newApps,         color:newApps>0?T.amber:T.slate400, border:newApps>0?T.amber:T.slate200 },
          { label:"In Interviews",     value:inInterview,     color:T.purple,border:T.purple },
          { label:"Offers Pending",    value:inOffer,         color:T.green, border:T.green },
          { label:"Active Staff",      value:activeStaff,     color:T.navy,  border:T.navy  },
          { label:"Compliance Flags",  value:flagged,         color:flagged>0?T.red:T.green, border:flagged>0?T.red:T.green },
        ].map((k,i) => (
          <div key={i} style={{ background:T.white, border:`1px solid ${T.slate200}`, borderTop:`3px solid ${k.border}`, borderRadius:12, padding:"14px 16px" }}>
            <div style={{ fontSize:11, color:T.slate500, fontWeight:500, marginBottom:6 }}>{k.label}</div>
            <div style={{ fontSize:24, fontWeight:700, color:k.color, letterSpacing:"-0.02em" }}>{k.value}</div>
          </div>
        ))}
      </div>

      {/* Compliance reminder */}
      <div style={{ background:T.amberLt, border:`1px solid #FCD34D`, borderLeft:`4px solid ${T.amber}`, borderRadius:10, padding:"12px 16px", marginBottom:16 }}>
        <div style={{ fontSize:12, fontWeight:700, color:"#92400E", marginBottom:4 }}>⚠ AA05 Section I.P — Agent is liable for all staff activities</div>
        <div style={{ fontSize:11, color:"#92400E", lineHeight:1.6 }}>
          You are contractually responsible for every action your staff takes on behalf of the agency. All staff performing licensed activities must hold active licenses. Unlicensed staff may not quote, bind, or solicit. Family employees require year-end W-2 review with your CPA.
        </div>
      </div>

      <div style={{ display:"grid", gridTemplateColumns:"minmax(0,1fr) minmax(0,1fr)", gap:12 }}>
        {/* Active Pipeline */}
        
      <div style={{display:"flex",justifyContent:"flex-end",marginBottom:12}}>
        <button onClick={()=>setShowAddEmployee(s=>!s)} style={{padding:"8px 16px",fontSize:12,fontWeight:600,background:"#1E3A5F",color:"#fff",border:"none",borderRadius:8,cursor:"pointer"}}>➕ Add Employee</button>
      </div>

      {showAddEmployee && (
        <div style={{background:"#EFF6FF",border:"1px solid #BFDBFE",borderRadius:10,padding:16,marginBottom:16}}>
          <div style={{fontSize:13,fontWeight:700,color:"#1E3A5F",marginBottom:12}}>Add New Employee</div>
          <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:10,marginBottom:10}}>
            <input placeholder="First name *" value={newEmployee.first_name} onChange={e=>setNewEmployee({...newEmployee,first_name:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Last name *" value={newEmployee.last_name} onChange={e=>setNewEmployee({...newEmployee,last_name:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Role / Title" value={newEmployee.role} onChange={e=>setNewEmployee({...newEmployee,role:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Email" value={newEmployee.email} onChange={e=>setNewEmployee({...newEmployee,email:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Phone" value={newEmployee.phone} onChange={e=>setNewEmployee({...newEmployee,phone:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input type="date" placeholder="Start date" value={newEmployee.start_date} onChange={e=>setNewEmployee({...newEmployee,start_date:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <select value={newEmployee.employment_type} onChange={e=>setNewEmployee({...newEmployee,employment_type:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}}>
              <option value="w2">W-2 Employee</option>
              <option value="1099">1099 Contractor</option>
              <option value="family">Family Employee (W-2)</option>
            </select>
          </div>
          <div style={{display:"flex",gap:8,justifyContent:"flex-end"}}>
            <button onClick={()=>setShowAddEmployee(false)} style={{padding:"6px 14px",fontSize:12,background:"#F1F5F9",color:"#334155",border:"none",borderRadius:6,cursor:"pointer"}}>Cancel</button>
            <button onClick={saveEmployee} style={{padding:"6px 14px",fontSize:12,background:"#1E3A5F",color:"#fff",border:"none",borderRadius:6,cursor:"pointer",fontWeight:600}}>Save Employee</button>
          </div>
        </div>
      )}
<Card>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800, marginBottom:12 }}>Active recruiting pipeline</div>
          {active.length === 0 ? (
            <div style={{ fontSize:12, color:T.slate400, textAlign:"center", padding:"16px 0" }}>No active applicants</div>
          ) : active.map((app,i) => (
            <div key={app.id} style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 0", borderBottom:i<active.length-1?`1px solid ${T.slate100}`:"none" }}>
              <div style={{ width:32, height:32, borderRadius:8, background:scoreBg(app.claude_score), display:"flex", alignItems:"center", justifyContent:"center", flexShrink:0 }}>
                <span style={{ fontSize:13, fontWeight:700, color:scoreColor(app.claude_score) }}>{app.claude_score}</span>
              </div>
              <div style={{ flex:1, minWidth:0 }}>
                <div style={{ fontSize:12, fontWeight:600, color:T.slate800 }}>{app.first_name} {app.last_name}</div>
                <div style={{ fontSize:10, color:T.slate500 }}>{app.position} · {app.intake_received_at}</div>
              </div>
              <StageBadge status={app.status} />
            </div>
          ))}
        </Card>

        {/* Team Snapshot */}
        <Card>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800, marginBottom:12 }}>Current team</div>
          {staff.filter(s => s.is_active).map((member,i) => (
            <div key={member.id} style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 0", borderBottom:i<staff.length-1?`1px solid ${T.slate100}`:"none" }}>
              <div style={{ width:32, height:32, borderRadius:8, background:hasAnyLicense(member)?T.greenLt:T.slate100, display:"flex", alignItems:"center", justifyContent:"center", flexShrink:0, fontSize:11, fontWeight:700, color:hasAnyLicense(member)?T.green:T.slate500 }}>
                {(member.first_name?.[0] || "?")}{(member.last_name?.[0] || "")}
              </div>
              <div style={{ flex:1 }}>
                <div style={{ fontSize:12, fontWeight:600, color:T.slate800 }}>{member.first_name} {member.last_name}</div>
                <div style={{ fontSize:10, color:T.slate500 }}>{member.role || "-"} · {(member.employment_type || "").toString().toUpperCase()}</div>
              </div>
              <div style={{ display:"flex", flexDirection:"column", alignItems:"flex-end", gap:3 }}>
                {hasAnyLicense(member) ? (
                  <div style={{ display:"flex", gap:3, flexWrap:"wrap", justifyContent:"flex-end" }}>
                    {member.license_pc && <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:T.greenLt, color:"#065F46" }}>P&amp;C</span>}
                    {member.license_lh && <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:"#DBEAFE", color:"#1E40AF" }}>L&amp;H</span>}
                    {member.license_ips && <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:"#EDE9FE", color:"#5B21B6" }}>IPS</span>}
                  </div>
                ) : (
                  <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:T.slate100, color:T.slate500 }}>Unlicensed</span>
                )}
                {member.compliance_flag && (
                  <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:T.amberLt, color:"#92400E" }}>⚠ CPA Flag</span>
                )}
              </div>
            </div>
          ))}
        </Card>
      </div>
    </div>
  );
};

// ─── Section: Recruiting Pipeline ────────────────────────────
const RecruitingPipeline = ({ applicants, onUpdate }) => {
  const [selected, setSelected] = useState(null);
  const stages = ["new","screening","interview","offer","hired","rejected"];


  const selectedApp = applicants.find(a => a.id === selected);

  return (
    <div>
      {/* Pipeline Kanban */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(6,minmax(0,1fr))", gap:8, marginBottom:16 }}>
        {stages.map(stage => {
          const s = STAGES[stage];
          const stageApps = applicants.filter(a => a.status === stage);
          return (
            <div key={stage} style={{ background:T.slate50, borderRadius:10, padding:"10px 8px", minHeight:120 }}>
              <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:8 }}>
                <span style={{ fontSize:10, fontWeight:700, color:s.color }}>{s.label}</span>
                <span style={{ fontSize:10, fontWeight:700, padding:"1px 6px", borderRadius:10, background:s.bg, color:s.color }}>{stageApps.length}</span>
              </div>
              {stageApps.map(app => (
                <div
                  key={app.id}
                  onClick={() => setSelected(selected===app.id?null:app.id)}
                  style={{ background:T.white, border:`1px solid ${selected===app.id?T.blue:T.slate200}`, borderRadius:8, padding:"8px 10px", marginBottom:6, cursor:"pointer" }}
                >
                  <div style={{ fontSize:11, fontWeight:600, color:T.slate800 }}>{app.first_name} {app.last_name}</div>
                  <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginTop:4 }}>
                    <span style={{ fontSize:9, color:T.slate400 }}>{app.position.split(" ").slice(-1)[0]}</span>
                    <span style={{ fontSize:11, fontWeight:700, color:scoreColor(app.claude_score) }}>{app.claude_score}/10</span>
                  </div>
                </div>
              ))}
            </div>
          );
        })}
      </div>

      {/* Applicant Detail Panel */}
      {selectedApp && (
        <Card>
          <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:16 }}>
            <div>
              <div style={{ fontSize:16, fontWeight:700, color:T.slate900 }}>{selectedApp.first_name} {selectedApp.last_name}</div>
              <div style={{ fontSize:12, color:T.slate500, marginTop:2 }}>{selectedApp.position} · Received {selectedApp.intake_received_at}</div>
            </div>
            <div style={{ display:"flex", gap:8, alignItems:"center" }}>
              <div style={{ width:44, height:44, borderRadius:12, background:scoreBg(selectedApp.claude_score), display:"flex", alignItems:"center", justifyContent:"center" }}>
                <span style={{ fontSize:18, fontWeight:700, color:scoreColor(selectedApp.claude_score) }}>{selectedApp.claude_score}</span>
              </div>
              <StageBadge status={selectedApp.status} />
              <AskBtn size="small" context={`Applicant profile:\nName: ${selectedApp.first_name} ${selectedApp.last_name}\nPosition: ${selectedApp.position}\nClaude Score: ${selectedApp.claude_score}/10\nSummary: ${selectedApp.claude_summary}\n${selectedApp.interview_focus?"Interview Focus:\n"+selectedApp.interview_focus:""}\n${selectedApp.interview_notes?"Interview Notes: "+selectedApp.interview_notes:""}\n\nHelp me think through this candidate. Should I move forward? What should I focus on in the interview?`} />
            </div>
          </div>

          {/* Claude Summary */}
          <div style={{ background:T.slate50, borderRadius:10, padding:"12px 14px", marginBottom:12 }}>
            <div style={{ fontSize:11, fontWeight:600, color:T.slate600, marginBottom:4 }}>CLAUDE SUMMARY (Groq Analysis)</div>
            <div style={{ fontSize:12, color:T.slate700, lineHeight:1.7 }}>{selectedApp.claude_summary}</div>
          </div>

          {/* Interview Focus */}
          {selectedApp.interview_focus && (
            <div style={{ background:T.amberLt, border:`1px solid #FCD34D`, borderRadius:10, padding:"12px 14px", marginBottom:12 }}>
              <div style={{ fontSize:11, fontWeight:700, color:"#92400E", marginBottom:8 }}>ONE PAGE INTERVIEW FOCUS</div>
              <pre style={{ fontSize:11, color:"#78350F", lineHeight:1.7, margin:0, whiteSpace:"pre-wrap", fontFamily:"inherit" }}>
                {selectedApp.interview_focus}
              </pre>
            </div>
          )}

          {/* Interview notes */}
          {selectedApp.interview_notes && (
            <div style={{ background:T.blueLt, borderRadius:10, padding:"12px 14px", marginBottom:12 }}>
              <div style={{ fontSize:11, fontWeight:600, color:"#1E40AF", marginBottom:4 }}>INTERVIEW NOTES</div>
              <div style={{ fontSize:12, color:"#1E40AF", lineHeight:1.7 }}>{selectedApp.interview_notes}</div>
            </div>
          )}

          {/* Stage Actions */}
          <div style={{ display:"flex", gap:8, flexWrap:"wrap" }}>
            {selectedApp.status === "new" && (
              <button onClick={() => onUpdate(selectedApp.id,"screening")} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" }}>→ Move to Screening</button>
            )}
            {selectedApp.status === "screening" && (
              <button onClick={() => onUpdate(selectedApp.id,"interview")} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.amber, border:"none", borderRadius:7, cursor:"pointer" }}>→ Schedule Interview</button>
            )}
            {selectedApp.status === "interview" && (
              <>
                <button onClick={() => onUpdate(selectedApp.id,"offer")} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.green, border:"none", borderRadius:7, cursor:"pointer" }}>→ Extend Offer</button>
                <button onClick={() => onUpdate(selectedApp.id,"rejected")} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.red, background:T.redLt, border:"none", borderRadius:7, cursor:"pointer" }}>✕ Reject</button>
              </>
            )}
            {selectedApp.status === "offer" && (
              <>
                <button onClick={() => onUpdate(selectedApp.id,"hired")} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.green, border:"none", borderRadius:7, cursor:"pointer" }}>✓ Mark Hired</button>
                <button onClick={() => onUpdate(selectedApp.id,"rejected")} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.red, background:T.redLt, border:"none", borderRadius:7, cursor:"pointer" }}>✕ Offer Declined</button>
              </>
            )}
          </div>
        </Card>
      )}
    </div>
  );
};

// ─── Section: Staff Directory ─────────────────────────────────
const StaffDirectory = ({ staff }) => {
  const [expanded, setExpanded] = useState(null);
  const [editingId, setEditingId] = useState(null);
  const [form, setForm] = useState({});
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState("");
  // Local overlay of edits so saved changes show immediately without a full reload
  const [overrides, setOverrides] = useState({});

  const startEdit = (member) => {
    setSaveError("");
    setEditingId(member.id);
    setForm({
      first_name: member.first_name || "",
      last_name: member.last_name || "",
      role: member.role || "",
      employment_type: member.employment_type || "",
      email: member.email || "",
      phone: member.phone || "",
      pay_type: member.pay_type || "",
      pay_rate: member.pay_rate ?? "",
      pay_frequency: member.pay_frequency || "",
      license_pc: member.license_pc === true,
      license_lh: member.license_lh === true,
      license_ips: member.license_ips === true,
      license_states: Array.isArray(member.license_states) ? member.license_states.join(", ") : "",
      start_date: member.start_date || "",
      compliance_flag: member.compliance_flag || "",
      notes: member.notes || "",
    });
  };

  const cancelEdit = () => { setEditingId(null); setForm({}); setSaveError(""); };

  const saveEdit = async (id) => {
    if (saving) return;
    setSaving(true);
    setSaveError("");
    // Build the update payload, coercing types to match the staff table.
    const payload = {
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      role: form.role.trim() || null,
      employment_type: form.employment_type.trim() || null,
      email: form.email.trim() || null,
      phone: form.phone.trim() || null,
      pay_type: form.pay_type.trim() || null,
      pay_rate: form.pay_rate === "" || form.pay_rate == null ? null : Number(form.pay_rate),
      pay_frequency: form.pay_frequency.trim() || null,
      license_pc: form.license_pc === true,
      license_lh: form.license_lh === true,
      license_ips: form.license_ips === true,
      license_states: form.license_states.trim()
        ? form.license_states.split(",").map(s => s.trim()).filter(Boolean)
        : [],
      start_date: form.start_date || null,
      compliance_flag: form.compliance_flag.trim() || null,
      notes: form.notes.trim() || null,
      updated_at: new Date().toISOString(),
    };
    if (!payload.first_name || !payload.last_name) {
      setSaveError("First and last name are required.");
      setSaving(false);
      return;
    }
    if (payload.pay_rate != null && !Number.isFinite(payload.pay_rate)) {
      setSaveError("Pay rate must be a number.");
      setSaving(false);
      return;
    }
    try {
      if (!supabase) { setSaveError("No database connection."); setSaving(false); return; }
      const { error } = await supabase
        .from("staff")
        .update(payload)
        .eq("id", id)
        .eq("agency_id", AGENCY_ID);
      if (error) {
        setSaveError(error.message || "Save failed. You may need to be signed in.");
        setSaving(false);
        return;
      }
      // Apply locally so the change is visible immediately.
      setOverrides(prev => ({ ...prev, [id]: payload }));
      setEditingId(null);
      setForm({});
    } catch (e) {
      setSaveError(e?.message || "Unexpected error while saving.");
    } finally {
      setSaving(false);
    }
  };

  const inputStyle = { padding:"8px 10px", borderRadius:6, border:`1px solid ${T.slate200}`, fontSize:12, width:"100%", boxSizing:"border-box", background:T.white, color:T.slate800 };
  const labelStyle = { fontSize:9, color:T.slate400, marginBottom:3, display:"block" };

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
      {staff.filter(s => s.is_active).map(raw => {
        // Merge any saved override on top of the loaded row.
        const member = overrides[raw.id] ? { ...raw, ...overrides[raw.id] } : raw;
        const isExpanded = expanded === member.id;
        const isEditing = editingId === member.id;
        return (
          <Card key={member.id} style={{ border:`1px solid ${isExpanded?T.blue:T.slate200}` }}>
            <div style={{ display:"flex", alignItems:"center", gap:14, cursor:"pointer" }} onClick={() => { if (!isEditing) setExpanded(isExpanded?null:member.id); }}>
              {/* Avatar */}
              <div style={{ width:48, height:48, borderRadius:12, background:hasAnyLicense(member)?T.navy:T.slate200, display:"flex", alignItems:"center", justifyContent:"center", fontSize:16, fontWeight:700, color:hasAnyLicense(member)?T.white:T.slate500, flexShrink:0 }}>
                {(member.first_name?.[0] || "?")}{(member.last_name?.[0] || "")}
              </div>

              <div style={{ flex:1 }}>
                <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:4 }}>
                  <span style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{member.first_name} {member.last_name}</span>
                  {hasAnyLicense(member) ? (
                    <div style={{ display:"flex", gap:4, flexWrap:"wrap" }}>
                      {member.license_pc && <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.greenLt, color:"#065F46" }}>P&amp;C</span>}
                      {member.license_lh && <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:"#DBEAFE", color:"#1E40AF" }}>L&amp;H</span>}
                      {member.license_ips && <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:"#EDE9FE", color:"#5B21B6" }}>IPS</span>}
                    </div>
                  ) : (
                    <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.slate100, color:T.slate500 }}>Unlicensed — cannot perform licensed activities</span>
                  )}
                  {member.compliance_flag && (
                    <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.amberLt, color:"#92400E" }}>⚠ CPA Flag</span>
                  )}
                </div>
                <div style={{ fontSize:12, color:T.slate500 }}>
                  {member.role || "-"} · {member.employment_type === "w2" ? "W-2 Employee" : member.employment_type === "family" ? "Family Employee (W-2)" : member.employment_type === "1099" ? "1099 Contractor" : (member.employment_type || "Employee")} · Since {member.start_date || "-"}
                </div>
              </div>

              <div style={{ textAlign:"right", flexShrink:0 }}>
                <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>
                  {member.pay_rate == null ? "-" : (member.pay_type || "").toLowerCase() === "hourly" ? `$${Number(member.pay_rate).toFixed(2)}/hr` : `$${Number(member.pay_rate).toLocaleString(undefined,{maximumFractionDigits:2})}/period`}
                </div>
                <div style={{ fontSize:10, color:T.slate400 }}>{(member.pay_type || "-").toString().replace(/_/g," ").toLowerCase()}</div>
              </div>

              <span style={{ color:T.slate400, fontSize:12 }}>{isExpanded?"▲":"▼"}</span>
            </div>

            {isExpanded && !isEditing && (
              <div style={{ marginTop:14, paddingTop:14, borderTop:`1px solid ${T.slate100}` }}>
                <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(140px,1fr))", gap:8, marginBottom:12 }}>
                  {[
                    { label:"Email",      value:member.email||"—" },
                    { label:"Phone",      value:member.phone||"—" },
                    { label:"Licensed States", value:(member.license_states || []).length>0?(member.license_states || []).join(", "):"None" },
                    { label:"Start Date", value:member.start_date||"—" },
                  ].map((d,i) => (
                    <div key={i} style={{ background:T.slate50, borderRadius:8, padding:"7px 10px" }}>
                      <div style={{ fontSize:9, color:T.slate400, marginBottom:2 }}>{d.label}</div>
                      <div style={{ fontSize:11, fontWeight:500, color:T.slate700 }}>{d.value}</div>
                    </div>
                  ))}
                </div>
                {member.notes && (
                  <div style={{ fontSize:11, color:T.slate600, lineHeight:1.6, padding:"8px 10px", background:T.slate50, borderRadius:8, marginBottom:10 }}>
                    {member.notes}
                  </div>
                )}
                {member.compliance_flag && (
                  <div style={{ fontSize:11, color:"#92400E", background:T.amberLt, padding:"8px 10px", borderRadius:8, marginBottom:10 }}>
                    ⚠ {member.compliance_flag}
                  </div>
                )}
                <div style={{ display:"flex", gap:8, flexWrap:"wrap", alignItems:"center" }}>
                  <button
                    onClick={(e) => { e.stopPropagation(); startEdit(member); }}
                    style={{ padding:"6px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.navy, border:"none", borderRadius:7, cursor:"pointer" }}>
                    ✏️ Edit
                  </button>
                  <AskBtn size="small" context={`Staff member profile:\nName: ${member.first_name || ""} ${member.last_name || ""}\nRole: ${member.role || "-"}\nEmployment: ${member.employment_type || "-"}\nPay: ${member.pay_type || "-"} - ${member.pay_rate == null ? "-" : (member.pay_type || "").toLowerCase()==="hourly" ? "$"+Number(member.pay_rate).toFixed(2)+"/hr" : "$"+Number(member.pay_rate).toLocaleString()+"/period"}\nLicenses: ${[member.license_pc && "P&C", member.license_lh && "L&H", member.license_ips && "IPS"].filter(Boolean).join(", ") || "None"}${((member.license_states||[]).length ? " (states: " + (member.license_states||[]).join(", ") + ")" : "")}\nStart: ${member.start_date || "-"}\nNotes: ${member.notes || "-"}\n${member.compliance_flag?"Compliance flag: "+member.compliance_flag:""}\n\nHelp me review this team member's profile. Are there any compliance concerns or HR items I should address?`} />
                </div>
              </div>
            )}

            {isEditing && (
              <div style={{ marginTop:14, paddingTop:14, borderTop:`1px solid ${T.blue}` }} onClick={(e) => e.stopPropagation()}>
                <div style={{ fontSize:12, fontWeight:700, color:T.navy, marginBottom:12 }}>Edit {member.first_name} {member.last_name}</div>
                <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10, marginBottom:10 }}>
                  <div><label style={labelStyle}>First name *</label><input style={inputStyle} value={form.first_name} onChange={e=>setForm({...form, first_name:e.target.value})} /></div>
                  <div><label style={labelStyle}>Last name *</label><input style={inputStyle} value={form.last_name} onChange={e=>setForm({...form, last_name:e.target.value})} /></div>
                  <div><label style={labelStyle}>Role / Title</label><input style={inputStyle} value={form.role} onChange={e=>setForm({...form, role:e.target.value})} /></div>
                  <div><label style={labelStyle}>Employment type</label><input style={inputStyle} value={form.employment_type} onChange={e=>setForm({...form, employment_type:e.target.value})} placeholder="Full Time / 1099 / family" /></div>
                  <div><label style={labelStyle}>Email</label><input style={inputStyle} value={form.email} onChange={e=>setForm({...form, email:e.target.value})} /></div>
                  <div><label style={labelStyle}>Phone</label><input style={inputStyle} value={form.phone} onChange={e=>setForm({...form, phone:e.target.value})} /></div>
                  <div><label style={labelStyle}>Pay type</label>
                    <select style={inputStyle} value={form.pay_type} onChange={e=>setForm({...form, pay_type:e.target.value})}>
                      <option value="">—</option>
                      <option value="SALARY">SALARY</option>
                      <option value="HOURLY">HOURLY</option>
                    </select>
                  </div>
                  <div><label style={labelStyle}>Pay rate</label><input style={inputStyle} type="number" step="0.01" value={form.pay_rate} onChange={e=>setForm({...form, pay_rate:e.target.value})} /></div>
                  <div><label style={labelStyle}>Pay frequency</label><input style={inputStyle} value={form.pay_frequency} onChange={e=>setForm({...form, pay_frequency:e.target.value})} placeholder="weekly / biweekly / semimonthly" /></div>
                  <div><label style={labelStyle}>Start date</label><input style={inputStyle} type="date" value={form.start_date || ""} onChange={e=>setForm({...form, start_date:e.target.value})} /></div>
                  <div><label style={labelStyle}>Licensed states (comma-separated)</label><input style={inputStyle} value={form.license_states} onChange={e=>setForm({...form, license_states:e.target.value})} placeholder="TX, NM" /></div>
                  <div style={{ display:"flex", flexDirection:"column", gap:6, paddingTop:18 }}>
                    <div style={{ display:"flex", alignItems:"center", gap:8 }}>
                      <input id={`lpc-${member.id}`} type="checkbox" checked={form.license_pc===true} onChange={e=>setForm({...form, license_pc:e.target.checked})} style={{ width:16, height:16 }} />
                      <label htmlFor={`lpc-${member.id}`} style={{ fontSize:12, color:T.slate700, cursor:"pointer" }}>P&amp;C license</label>
                    </div>
                    <div style={{ display:"flex", alignItems:"center", gap:8 }}>
                      <input id={`llh-${member.id}`} type="checkbox" checked={form.license_lh===true} onChange={e=>setForm({...form, license_lh:e.target.checked})} style={{ width:16, height:16 }} />
                      <label htmlFor={`llh-${member.id}`} style={{ fontSize:12, color:T.slate700, cursor:"pointer" }}>L&amp;H license</label>
                    </div>
                    <div style={{ display:"flex", alignItems:"center", gap:8 }}>
                      <input id={`lips-${member.id}`} type="checkbox" checked={form.license_ips===true} onChange={e=>setForm({...form, license_ips:e.target.checked})} style={{ width:16, height:16 }} />
                      <label htmlFor={`lips-${member.id}`} style={{ fontSize:12, color:T.slate700, cursor:"pointer" }}>IPS license</label>
                    </div>
                  </div>
                </div>
                <div style={{ marginBottom:10 }}>
                  <label style={labelStyle}>Compliance flag (leave blank if none)</label>
                  <input style={inputStyle} value={form.compliance_flag} onChange={e=>setForm({...form, compliance_flag:e.target.value})} placeholder="e.g. Family employee — year-end W-2 review" />
                </div>
                <div style={{ marginBottom:12 }}>
                  <label style={labelStyle}>Notes</label>
                  <textarea style={{ ...inputStyle, resize:"vertical", minHeight:56, fontFamily:"inherit", lineHeight:1.5 }} rows={2} value={form.notes} onChange={e=>setForm({...form, notes:e.target.value})} />
                </div>

                {saveError && (
                  <div style={{ fontSize:11, color:"#991B1B", background:T.redLt, border:`1px solid #FECACA`, borderRadius:6, padding:"7px 10px", marginBottom:10 }}>
                    {saveError}
                  </div>
                )}

                <div style={{ display:"flex", gap:8, justifyContent:"flex-end" }}>
                  <button onClick={cancelEdit} disabled={saving} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate700, background:T.slate100, border:"none", borderRadius:7, cursor:saving?"not-allowed":"pointer" }}>Cancel</button>
                  <button onClick={() => saveEdit(member.id)} disabled={saving} style={{ padding:"7px 16px", fontSize:11, fontWeight:600, color:T.white, background:saving?T.slate400:T.navy, border:"none", borderRadius:7, cursor:saving?"not-allowed":"pointer" }}>
                    {saving ? "Saving…" : "Save Changes"}
                  </button>
                </div>
              </div>
            )}
          </Card>
        );
      })}
    </div>
  );
};

// ─── Section: Onboarding ─────────────────────────────────────
const OnboardingSection = ({ onboarding }) => {
  const categoryColors = {
    licensing:  { color:T.green,  bg:T.greenLt  },
    documents:  { color:T.blue,   bg:T.blueLt   },
    compliance: { color:T.red,    bg:T.redLt    },
    systems:    { color:T.teal,   bg:T.tealLt   },
    training:   { color:T.purple, bg:T.purpleLt },
  };

  return (
    <div>
      {onboarding.map(record => {
        const completed = record.items.filter(i => i.completed).length;
        const total = record.items.length;
        const pctDone = Math.round((completed/total)*100);
        const grouped = record.items.reduce((acc, item) => {
          if (!acc[item.category]) acc[item.category] = [];
          acc[item.category].push(item);
          return acc;
        }, {});

        return (
          <Card key={record.staff_id}>
            <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:14 }}>
              <div>
                <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{record.staff_name}</div>
                <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>Started {record.start_date} · {record.days_employed} days employed · {record.template} template</div>
              </div>
              <div style={{ textAlign:"right" }}>
                <div style={{ fontSize:22, fontWeight:700, color:pctDone===100?T.green:T.amber, letterSpacing:"-0.02em" }}>{pctDone}%</div>
                <div style={{ fontSize:10, color:T.slate400 }}>{completed}/{total} complete</div>
              </div>
            </div>

            <div style={{ height:8, background:T.slate100, borderRadius:4, overflow:"hidden", marginBottom:16 }}>
              <div style={{ height:"100%", width:`${pctDone}%`, background:pctDone===100?T.green:T.amber, borderRadius:4, transition:"width 0.6s ease" }} />
            </div>

            {Object.entries(grouped).map(([cat, items]) => {
              const cc = categoryColors[cat] || { color:T.slate500, bg:T.slate100 };
              return (
                <div key={cat} style={{ marginBottom:14 }}>
                  <div style={{ fontSize:11, fontWeight:700, color:cc.color, marginBottom:6, textTransform:"capitalize" }}>{cat}</div>
                  {items.map((item,i) => (
                    <div key={i} style={{ display:"flex", alignItems:"center", gap:10, padding:"7px 0", borderBottom:i<items.length-1?`1px solid ${T.slate100}`:"none" }}>
                      <div style={{ width:18, height:18, borderRadius:4, background:item.completed?T.green:T.slate200, display:"flex", alignItems:"center", justifyContent:"center", flexShrink:0 }}>
                        {item.completed && <span style={{ color:T.white, fontSize:10 }}>✓</span>}
                      </div>
                      <span style={{ flex:1, fontSize:12, color:item.completed?T.slate400:T.slate800, textDecoration:item.completed?"line-through":"none" }}>{item.item}</span>
                      <span style={{ fontSize:10, color:T.slate400, flexShrink:0 }}>{item.due}</span>
                    </div>
                  ))}
                </div>
              );
            })}
          </Card>
        );
      })}
    </div>
  );
};

// ─── Section: Performance — Producer ROI ──────────────────────────────────
// ─── AIPP Projection Card ─────────────────────────────────────
// AIPP = 5% of qualifying NEW P&C premium issued, paid each January.
// Eligibility: 60+ months (5 yrs) service; continues up to 240 months (20 yrs).
// Base = NEW PREMIUM ISSUED (auto/fire/small-health), NOT commissions.
// Sourced from v_aipp_projection (server-side), which needs producer_production rows.
const AippProjectionCard = ({ aipp, aippTracking, hasProductionData }) => {
  const money = (n) => "$" + Math.round(Number(n) || 0).toLocaleString();
  const hasProjection = aipp && Number(aipp.qualifying_premium_ytd) > 0;

  const target = aippTracking ? Number(aippTracking.target_amount) : null;
  const ratePct = aipp ? (Number(aipp.aipp_rate) * 100) : 5;

  return (
    <Card style={{ borderLeft: `4px solid ${T.green}` }}>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:10 }}>
        <div>
          <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>AIPP Projection</div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>
            {ratePct.toFixed(0)}% of qualifying NEW P&amp;C premium issued · paid each January
          </div>
        </div>
        <AskBtn size="small" context={hasProjection
          ? `My AIPP projection for ${aipp.program_year}:\nQualifying new P&C premium YTD (through month ${aipp.through_month}): ${money(aipp.qualifying_premium_ytd)}\nProjected full-year qualifying premium: ${money(aipp.projected_full_year_premium)}\nAIPP earned YTD: ${money(aipp.aipp_earned_ytd)}\nProjected AIPP payout: ${money(aipp.aipp_projected_payout)} (paid ~${aipp.projected_payout_date})\n\nAm I on pace? Which product lines should I push to lift this?`
          : `I do not yet have producer production data loaded, so my AIPP projection is empty. AIPP is 5% of qualifying NEW P&C premium issued, paid each January. What should I do to get my production reports flowing so this projects automatically?`} />
      </div>

      {hasProjection ? (
        <>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(150px, 1fr))", gap:10 }}>
            <div style={{ background:T.slate50, padding:"10px 12px", borderRadius:8 }}>
              <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>Qualifying Premium YTD</div>
              <div style={{ fontSize:16, fontWeight:700, color:T.slate900 }}>{money(aipp.qualifying_premium_ytd)}</div>
              <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>through month {aipp.through_month}</div>
            </div>
            <div style={{ background:T.slate50, padding:"10px 12px", borderRadius:8 }}>
              <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>Projected Full-Year Premium</div>
              <div style={{ fontSize:16, fontWeight:700, color:T.slate900 }}>{money(aipp.projected_full_year_premium)}</div>
            </div>
            <div style={{ background:T.greenLt, padding:"10px 12px", borderRadius:8 }}>
              <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>AIPP Earned YTD</div>
              <div style={{ fontSize:16, fontWeight:700, color:"#065F46" }}>{money(aipp.aipp_earned_ytd)}</div>
            </div>
            <div style={{ background:T.blueLt, padding:"10px 12px", borderRadius:8 }}>
              <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>Projected Payout</div>
              <div style={{ fontSize:16, fontWeight:700, color:"#1E40AF" }}>{money(aipp.aipp_projected_payout)}</div>
              <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>~{aipp.projected_payout_date}</div>
            </div>
          </div>
          {target ? (
            <div style={{ marginTop:12 }}>
              <div style={{ display:"flex", justifyContent:"space-between", fontSize:11, color:T.slate600, marginBottom:5 }}>
                <span>Pace vs target ({money(target)})</span>
                <span>{Math.min(999, Math.round((Number(aipp.aipp_projected_payout)/target)*100))}%</span>
              </div>
              <ProgressBar value={Number(aipp.aipp_projected_payout)} max={target}
                color={Number(aipp.aipp_projected_payout) >= target ? T.green : T.amber} height={8} />
            </div>
          ) : null}
        </>
      ) : (
        <div style={{ padding:"14px 14px", background:T.slate50, borderRadius:8, fontSize:12, color:T.slate600, lineHeight:1.6 }}>
          <div style={{ fontWeight:600, color:T.slate700, marginBottom:4 }}>Awaiting production data</div>
          No producer production has been loaded yet, so there is nothing to project. Once your monthly
          Producer Production Report is emailed in, the document importer files it and this projection fills
          in automatically — 5% of qualifying new P&amp;C premium, compounding toward your next-January payout.
          {aippTracking ? <div style={{ marginTop:6 }}>Target on file for {aippTracking.program_year}: <strong>{money(aippTracking.target_amount)}</strong>.</div> : null}
        </div>
      )}

      <div style={{ marginTop:12, padding:"10px 12px", background:T.greenLt, borderRadius:8, fontSize:11, color:T.slate700, lineHeight:1.5 }}>
        <strong>Eligibility:</strong> requires 60+ months (5 years) of service and continues up to 240 months (20 years).
        The base is new premium <em>issued</em> on qualifying P&amp;C lines — not commission earned.
      </div>
    </Card>
  );
};

// ─── Section: Performance — Producer ROI ──────────────────────
const PerformanceSection = ({ roi }) => {
  if (!roi) {
    return (
      <Card>
        <div style={{ padding: "20px 0", textAlign: "center", fontSize: 13, color: T.slate500 }}>
          Loading producer performance data…
        </div>
      </Card>
    );
  }

  const { smvcRate, blendedRate, lapseRate, lapseRateComputed, lapseRateOverride,
          priorRenewals, currentRenewals, producerRows,
          ratesAreDefaults, aipp, aippTracking, hasProductionData } = roi;

  const noProducers = producerRows.length === 0;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>

      {/* ─── AIPP PROJECTION CARD ─────────────────────────────────── */}
      <AippProjectionCard aipp={aipp} aippTracking={aippTracking} hasProductionData={hasProductionData} />

      {ratesAreDefaults && (
        <div style={{ padding: "9px 13px", background: T.amberLt, border: `1px solid ${T.amber}`, borderRadius: 8, fontSize: 11.5, color: "#92400E", lineHeight: 1.5 }}>
          <strong>Estimated rates in use.</strong> SMVC, blended, and lapse rates below are placeholder defaults until your actual AA05 numbers are confirmed. Tell your Claude your real P&C SMVC rate to lock these in.
        </div>
      )}

      {noProducers && (
        <Card>
          <div style={{ padding: "16px 0", textAlign: "center", fontSize: 13, color: T.slate500 }}>
            No producers (Producer / LSP / Financial Services Specialist) found in your staff list for the per-producer ROI projection.
          </div>
        </Card>
      )}

      {/* ─── BOOK LAPSE RATE CARD ─────────────────────────────────── */}
      <Card style={{ borderLeft: `4px solid ${T.blue}` }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 10 }}>
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Book Lapse Rate (P&C, YTD)</div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
              Same-period auto + fire renewal commission: prior year vs current year
            </div>
          </div>
          <AskBtn size="small" context={`My agency book lapse rate analysis:\nPrior year YTD P&C renewal commission: $${Math.round(priorRenewals).toLocaleString()}\nCurrent year YTD P&C renewal commission: $${Math.round(currentRenewals).toLocaleString()}\nComputed lapse rate: ${(lapseRateComputed || 0).toFixed(1)}%\nApplied lapse rate (used in projections): ${lapseRate.toFixed(1)}%\n\nIs this lapse rate normal for our book? What should I focus on to reduce it?`} />
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10 }}>
          <div style={{ background: T.slate50, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Prior Year YTD Renewals</div>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>
              {Number.isFinite(priorRenewals) ? "$" + Math.round(priorRenewals).toLocaleString() : "—"}
            </div>
          </div>
          <div style={{ background: T.slate50, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Current Year YTD Renewals</div>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>
              {Number.isFinite(currentRenewals) ? "$" + Math.round(currentRenewals).toLocaleString() : "—"}
            </div>
          </div>
          <div style={{ background: lapseRate > 15 ? T.redLt : lapseRate > 10 ? T.amberLt : T.greenLt, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>
              Lapse Rate {lapseRateOverride ? "(manual)" : "(computed)"}
            </div>
            <div style={{ fontSize: 16, fontWeight: 700, color: lapseRate > 15 ? "#991B1B" : lapseRate > 10 ? "#92400E" : "#065F46" }}>
              {lapseRate.toFixed(1)}%
            </div>
          </div>
          <div style={{ background: T.slate50, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Applied to Projections</div>
            <div style={{ fontSize: 12, color: T.slate700, lineHeight: 1.4 }}>
              {(100 - lapseRate).toFixed(0)}% of policies renew next year (assumption)
            </div>
          </div>
        </div>

        <div style={{ marginTop: 12, padding: "10px 12px", background: T.blueLt, borderRadius: 8, fontSize: 11, color: T.slate700, lineHeight: 1.5 }}>
          <strong>Why this matters:</strong> Each producer&apos;s new business takes 12-18 months to start producing renewal commission.
          A lapse rate of {lapseRate.toFixed(1)}% means roughly {(100 - lapseRate).toFixed(0)}% of what they write today will still be on the books next year, generating renewal commission.
          The projections below use this rate to estimate when each producer becomes profitable against their fully-loaded payroll cost.
        </div>
      </Card>

      {/* ─── PER-PRODUCER ROI ANALYSIS ───────────────────────────── */}
      {!noProducers && producerRows.map(p => <ProducerROICard key={p.staff_id} producer={p} smvcRate={smvcRate} blendedRate={blendedRate} lapseRate={lapseRate} />)}

      {/* ─── ASSUMPTIONS FOOTER ──────────────────────────────────── */}
      <Card style={{ background: T.slate50, border: `1px dashed ${T.slate200}` }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: T.slate700, marginBottom: 8 }}>Assumptions used in projections</div>
        <div style={{ fontSize: 11, color: T.slate600, lineHeight: 1.7 }}>
          <div>• <strong>SMVC rate (P&C):</strong> {smvcRate.toFixed(2)}% — agent earns this percent of issued auto + fire premium per A005 agreement</div>
          <div>• <strong>Blended rate (other):</strong> {blendedRate.toFixed(2)}% — blended commission for Life, Health, Financial Services</div>
          <div>• <strong>Lapse rate:</strong> {lapseRate.toFixed(1)}% per year — applied as compounding annual decay to renewing cohorts</div>
          <div>• <strong>Fully-loaded payroll:</strong> gross pay × 1.15 — covers FICA, FUTA, SUTA, WC</div>
          <div>• <strong>Renewal start:</strong> month 13 — new business policies issued today start generating renewal commission 12 months from now</div>
          <div>• <strong>Steady-state pace:</strong> 6-month rolling average of issued premium per producer</div>
        </div>
      </Card>
    </div>
  );
};

// ─── Producer ROI Card — per-producer analysis with stacked cohort projection ───
const ProducerROICard = ({ producer, smvcRate, blendedRate, lapseRate }) => {
  const persistency = 1 - lapseRate / 100;

  // Build the 24 future months of projection
  // Each historical month is a "cohort" that survives going forward
  // For future months, we assume steady-state at producer.avg{PC,Other}
  const futureMonths = 24;
  const totalMonths = producer.history.length + futureMonths;

  // Build cohort series: one per month index in the timeline (0 = oldest history, history.length = current+1)
  const cohorts = [];
  for (let i = 0; i < producer.history.length; i++) {
    const h = producer.history[i];
    cohorts.push({ pcPremium: h.pcPremium, otherPremium: h.otherPremium, isHistory: true });
  }
  for (let i = 0; i < futureMonths; i++) {
    cohorts.push({ pcPremium: producer.avgPC, otherPremium: producer.avgOther, isHistory: false });
  }

  // For each forward month index from producer.history.length onward (i.e., projection months),
  // compute total commission to agency = sum of (cohort_k's renewal commission at age = (month - k))
  // Rules: at age 0 (same month as written), commission = full new-business commission (SMVC × pc + blended × other)
  //        at age 1-11 months, no additional commission yet (it's the same policies, paid once at issue under SF)
  //        at age 12+, the renewal commission kicks in, reduced by persistency^floor((age-12)/12 + 1)
  //
  // Simpler model that matches Rebecca's description:
  //   For month N going forward, projected commission = NEW commission this month +
  //     for each cohort k written ≥12 months ago: cohort_k_commission × persistency^(years_since)
  //   where years_since = floor((N - k) / 12)

  const forwardStartIdx = producer.history.length;
  const projectionMonths = []; // {label, newCommission, renewalCommission, totalCommission, isHistory}

  for (let i = 0; i < totalMonths; i++) {
    const date = new Date(producer.history[0].year, producer.history[0].month - 1 + i, 1);
    const label = date.toLocaleDateString("en-US", { month: "short", year: "2-digit" });
    const isHistory = i < forwardStartIdx;

    const cohortAtI = cohorts[i] || { pcPremium: 0, otherPremium: 0 };
    const newCommission = (cohortAtI.pcPremium * smvcRate / 100) + (cohortAtI.otherPremium * blendedRate / 100);

    // Renewal commission: only project this for FORWARD months. Historical bars show
    // only what the producer actually earned (new business commission) — we don't
    // retroactively simulate renewals that the producer didn't actually generate.
    let renewalCommission = 0;
    if (!isHistory) {
      for (let k = 0; k < i; k++) {
        const age = i - k;
        if (age < 12) continue;
        const yearsRenewed = Math.floor((age - 12) / 12) + 1;
        const survivalFactor = Math.pow(persistency, yearsRenewed);
        const cohortCommission = (cohorts[k].pcPremium * smvcRate / 100) + (cohorts[k].otherPremium * blendedRate / 100);
        renewalCommission += cohortCommission * survivalFactor;
      }
    }

    projectionMonths.push({ label, newCommission, renewalCommission,
                            totalCommission: newCommission + renewalCommission, isHistory });
  }

  // Find breakeven month — first FORWARD month where totalCommission >= monthlyLoaded
  const monthlyLoaded = producer.monthlyLoaded;
  let breakevenIdx = -1;
  for (let i = forwardStartIdx; i < projectionMonths.length; i++) {
    if (projectionMonths[i].totalCommission >= monthlyLoaded) {
      breakevenIdx = i;
      break;
    }
  }
  const breakevenLabel = breakevenIdx >= 0 ? projectionMonths[breakevenIdx].label : null;
  const monthsToBreakeven = breakevenIdx >= 0 ? breakevenIdx - forwardStartIdx + 1 : null;

  // Status pill — logic accounts for the difference between covering cost from
  // new business alone (rare for producers) vs needing renewal stack-up over time
  // (typical, expected, and what the projection chart visualizes).
  let status, statusColor, statusBg, statusText;
  // Check this at the END of the calc so we use newly-computed currentNewCommission
  // (defined later); we'll set status after all calcs are done. Placeholder here.
  status = "On track"; statusColor = "#065F46"; statusBg = T.greenLt;
  statusText = "";

  // Current month metrics — actual new-business commission this producer earned the agency THIS MONTH.
  // We deliberately do NOT add simulated renewal income here. Renewal commission in comp_recap is at
  // the AGENCY level, not tagged to a producer; attributing it back is misleading.
  // The renewal projection in the chart below shows what the cohort math says SHOULD build over time.
  const cur = producer.currentMonth;
  const currentNewCommission = (cur.pcPremium * smvcRate / 100) + (cur.otherPremium * blendedRate / 100);
  const currentNetToAgency = currentNewCommission - monthlyLoaded;

  // Now set the real status based on actual + projected economics
  if (currentNewCommission >= monthlyLoaded) {
    status = "Profitable now"; statusColor = "#065F46"; statusBg = T.greenLt;
    statusText = `New-business commission alone covers fully-loaded cost (${producer.name.split(" ")[0]} is a star producer)`;
  } else if (breakevenIdx < 0) {
    status = "Behind pace"; statusColor = "#991B1B"; statusBg = T.redLt;
    statusText = `Not projected to break even within 24 months at current pace — production needs to increase or cost structure needs review`;
  } else if (monthsToBreakeven <= 18) {
    status = "On track"; statusColor = "#065F46"; statusBg = T.greenLt;
    statusText = `Cohort math projects renewals will cover fully-loaded cost in ${monthsToBreakeven} months (${breakevenLabel}) — within the 12-18 month target window`;
  } else {
    status = "Slow ramp"; statusColor = "#92400E"; statusBg = T.amberLt;
    statusText = `Cohort math projects breakeven in ${monthsToBreakeven} months (${breakevenLabel}) — outside the 18-month target. Consider production target adjustment.`;
  }

  // Chart dimensions
  const chartH = 180;
  const maxValue = Math.max(
    monthlyLoaded * 1.3,
    ...projectionMonths.map(p => p.totalCommission)
  ) || 1;

  return (
    <Card>
      {/* Header */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 14 }}>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{producer.name}</div>
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
            {producer.role} · Started {producer.start_date} · Tenure {producer.tenureMonths} months
          </div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: 6 }}>
          <span style={{ fontSize: 10, fontWeight: 700, padding: "4px 10px", borderRadius: 20, background: statusBg, color: statusColor }}>{status}</span>
          <AskBtn size="small" context={`Producer ROI analysis — ${producer.name}\nRole: ${producer.role}\nTenure: ${producer.tenureMonths} months\nMonthly issued premium (P&C avg): $${Math.round(producer.avgPC).toLocaleString()}\nMonthly issued premium (other avg): $${Math.round(producer.avgOther).toLocaleString()}\nMonthly fully-loaded cost: $${Math.round(monthlyLoaded).toLocaleString()}\nNew-business commission this month: $${Math.round(currentNewCommission).toLocaleString()} (issued premium × SMVC rate)\nMonthly fully-loaded cost: $${Math.round(monthlyLoaded).toLocaleString()}\nNet to agency this month (new-biz only): $${Math.round(currentNetToAgency).toLocaleString()}\nProjected breakeven (when renewal stack-up + new biz covers cost): ${breakevenLabel || "outside 24 months"}\nLapse rate applied: ${lapseRate.toFixed(1)}%\nSMVC rate: ${smvcRate.toFixed(2)}% on P&C, ${blendedRate.toFixed(2)}% blended on other lines\n\nIs this producer on track? Should I increase their production target? What should I be doing differently?`} />
        </div>
      </div>

      {/* Status text */}
      <div style={{ fontSize: 11, color: T.slate600, marginBottom: 14, fontStyle: "italic" }}>{statusText}</div>

      {/* Current Month Economics */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8, marginBottom: 16 }}>
        <div style={{ background: T.slate50, padding: "9px 11px", borderRadius: 8 }}>
          <div style={{ fontSize: 9, color: T.slate500, marginBottom: 3 }}>P&C Premium Issued</div>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>${Math.round(cur.pcPremium).toLocaleString()}</div>
          <div style={{ fontSize: 10, color: T.slate400, marginTop: 2 }}>{cur.policies} policies</div>
        </div>
        <div style={{ background: T.slate50, padding: "9px 11px", borderRadius: 8 }}>
          <div style={{ fontSize: 9, color: T.slate500, marginBottom: 3 }}>Other Lines Premium</div>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>${Math.round(cur.otherPremium).toLocaleString()}</div>
          <div style={{ fontSize: 10, color: T.slate400, marginTop: 2 }}>Life · FS</div>
        </div>
        <div style={{ background: T.blueLt, padding: "9px 11px", borderRadius: 8 }}>
          <div style={{ fontSize: 9, color: T.slate500, marginBottom: 3 }}>New-Biz Commission</div>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.blue }}>${Math.round(currentNewCommission).toLocaleString()}</div>
          <div style={{ fontSize: 10, color: T.slate400, marginTop: 2 }}>Premium × SMVC</div>
        </div>
        <div style={{ background: T.amberLt, padding: "9px 11px", borderRadius: 8 }}>
          <div style={{ fontSize: 9, color: T.slate500, marginBottom: 3 }}>Fully-Loaded Cost</div>
          <div style={{ fontSize: 14, fontWeight: 700, color: "#92400E" }}>${Math.round(monthlyLoaded).toLocaleString()}</div>
          <div style={{ fontSize: 10, color: T.slate400, marginTop: 2 }}>Gross × 1.15</div>
        </div>
        <div style={{ background: currentNetToAgency >= 0 ? T.greenLt : T.redLt, padding: "9px 11px", borderRadius: 8 }}>
          <div style={{ fontSize: 9, color: T.slate500, marginBottom: 3 }}>Net to Agency</div>
          <div style={{ fontSize: 14, fontWeight: 700, color: currentNetToAgency >= 0 ? "#065F46" : "#991B1B" }}>
            {currentNetToAgency >= 0 ? "+" : "-"}${Math.round(Math.abs(currentNetToAgency)).toLocaleString()}
          </div>
          <div style={{ fontSize: 10, color: T.slate400, marginTop: 2 }}>This month</div>
        </div>
      </div>

      {/* 24-Month Projection Chart */}
      <div style={{ marginTop: 8 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: T.slate800 }}>Commission Trajectory — 24 months back, 24 months forward</div>
          <div style={{ display: "flex", gap: 12, fontSize: 10, color: T.slate500 }}>
            <span><span style={{ display: "inline-block", width: 10, height: 10, background: T.green, borderRadius: 2, marginRight: 4, verticalAlign: "middle" }} />New business</span>
            <span><span style={{ display: "inline-block", width: 10, height: 10, background: T.blue, borderRadius: 2, marginRight: 4, verticalAlign: "middle" }} />Renewals</span>
            <span><span style={{ display: "inline-block", width: 18, height: 2, background: T.red, marginRight: 4, verticalAlign: "middle" }} />Cost line</span>
          </div>
        </div>

        <div style={{ position: "relative", height: chartH + 30, background: T.slate50, borderRadius: 8, padding: "10px 8px 4px 8px" }}>
          {/* Cost line */}
          <div style={{
            position: "absolute",
            left: 8, right: 8,
            top: 10 + chartH - (monthlyLoaded / maxValue * chartH),
            height: 2, background: T.red,
            borderTop: `2px dashed ${T.red}`,
            zIndex: 2,
          }} />
          <div style={{
            position: "absolute",
            right: 12,
            top: 10 + chartH - (monthlyLoaded / maxValue * chartH) - 16,
            fontSize: 9, fontWeight: 700, color: T.red,
            background: T.white, padding: "1px 5px", borderRadius: 4,
            zIndex: 3,
          }}>${Math.round(monthlyLoaded).toLocaleString()}/mo cost</div>

          {/* Bars */}
          <div style={{ display: "flex", alignItems: "flex-end", gap: 1, height: chartH, position: "relative" }}>
            {projectionMonths.map((m, i) => {
              const newH = (m.newCommission / maxValue) * chartH;
              const renH = (m.renewalCommission / maxValue) * chartH;
              const isBreakeven = i === breakevenIdx;
              return (
                <div key={i} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "flex-end", height: chartH, position: "relative" }}>
                  {isBreakeven && (
                    <div style={{ position: "absolute", top: -4, fontSize: 14 }}>⭐</div>
                  )}
                  <div style={{ width: "85%", display: "flex", flexDirection: "column", justifyContent: "flex-end", height: chartH, opacity: m.isHistory ? 1 : 0.7 }}>
                    {renH > 0 && (
                      <div style={{ height: renH, background: T.blue, borderRadius: "0", borderTop: newH > 0 ? "none" : "2px 2px 0 0" }} />
                    )}
                    {newH > 0 && (
                      <div style={{ height: newH, background: T.green, borderRadius: renH > 0 ? "0" : "2px 2px 0 0" }} />
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          {/* X-axis labels — every 6th month */}
          <div style={{ display: "flex", gap: 1, marginTop: 4 }}>
            {projectionMonths.map((m, i) => (
              <div key={i} style={{ flex: 1, fontSize: 8, color: m.isHistory ? T.slate500 : T.slate400, textAlign: "center" }}>
                {i % 6 === 0 ? m.label : ""}
              </div>
            ))}
          </div>

          {/* Vertical "now" divider */}
          <div style={{
            position: "absolute",
            left: `${8 + (forwardStartIdx / projectionMonths.length) * (100 - 1.6)}%`,
            top: 6, height: chartH + 8,
            borderLeft: `1px dashed ${T.slate400}`,
            zIndex: 1,
          }} />
        </div>

        {breakevenLabel && (
          <div style={{ marginTop: 10, padding: "10px 12px", background: T.greenLt, borderRadius: 8, fontSize: 11, color: "#065F46" }}>
            <strong>⭐ Projected breakeven: {breakevenLabel}</strong> — at {producer.name.split(" ")[0]}&apos;s current 6-month avg of ${Math.round(producer.avgPC + producer.avgOther).toLocaleString()}/mo issued premium, the agency earns ${Math.round(producer.avgNewCommission).toLocaleString()}/mo in new-business commission. As renewals stack up over time (at {(100-lapseRate).toFixed(0)}% persistency), total monthly commission generated by {producer.name.split(" ")[0]}&apos;s book is projected to first cover their ${Math.round(monthlyLoaded).toLocaleString()}/mo fully-loaded cost in {monthsToBreakeven} months.
          </div>
        )}
        {!breakevenLabel && (
          <div style={{ marginTop: 10, padding: "10px 12px", background: T.amberLt, borderRadius: 8, fontSize: 11, color: "#92400E" }}>
            <strong>Projected breakeven not within 24 months.</strong> At current pace of ${Math.round(producer.avgPC + producer.avgOther).toLocaleString()}/mo issued premium (${Math.round(producer.avgNewCommission).toLocaleString()}/mo new-business commission to the agency), this producer&apos;s renewal-tail trajectory does not catch up to ${Math.round(monthlyLoaded).toLocaleString()}/mo fully-loaded cost within the projection window. Either issued premium needs to increase, or pay rate needs review.
          </div>
        )}
      </div>
    </Card>
  );
};


// ─── Section: Commissions ─────────────────────────────────────
const CommissionsSection = ({ commissions }) => (
  <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
    {commissions.map(c => (
      <Card key={c.id}>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:14 }}>
          <div>
            <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{c.staff_name}</div>
            <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>{c.structure_name} · Effective {c.effective_date}</div>
          </div>
          <div style={{ textAlign:"right" }}>
            <div style={{ fontSize:11, color:T.slate400, marginBottom:2 }}>This month</div>
            <div style={{ fontSize:20, fontWeight:700, color:T.green }}>${c.this_month.toLocaleString()}</div>
            <div style={{ fontSize:10, color:T.slate400 }}>YTD: ${c.ytd_earned.toLocaleString()}</div>
          </div>
        </div>

        {/* Tier Structure */}
        <div style={{ marginBottom:12 }}>
          <div style={{ fontSize:11, fontWeight:600, color:T.slate600, marginBottom:8 }}>Commission Tiers</div>
          <div style={{ display:"flex", flexDirection:"column", gap:4 }}>
            {c.tiers.map((tier,i) => (
              <div key={i} style={{ display:"flex", alignItems:"center", gap:10, padding:"8px 12px", background:T.slate50, borderRadius:8 }}>
                <span style={{ fontSize:12, color:T.slate600, flex:1 }}>
                  ${tier.min.toLocaleString()} {tier.max?`— $${tier.max.toLocaleString()}`:"and above"}
                </span>
                <span style={{ fontSize:14, fontWeight:700, color:T.blue }}>{tier.rate}%</span>
              </div>
            ))}
          </div>
        </div>

        {/* Qualifying Products */}
        <div style={{ marginBottom:12 }}>
          <div style={{ fontSize:11, fontWeight:600, color:T.slate600, marginBottom:6 }}>Qualifying products</div>
          <div style={{ display:"flex", gap:6, flexWrap:"wrap" }}>
            {c.qualifying_products.map(p => (
              <span key={p} style={{ fontSize:10, fontWeight:600, padding:"3px 8px", borderRadius:20, background:T.blueLt, color:T.blue }}>{p}</span>
            ))}
          </div>
        </div>

        {c.notes && (
          <div style={{ fontSize:11, color:T.slate600, lineHeight:1.6, padding:"8px 10px", background:T.slate50, borderRadius:8, marginBottom:10 }}>
            {c.notes}
          </div>
        )}

        <AskBtn size="small" context={`Commission structure review:\nStaff: ${c.staff_name}\nStructure: ${c.structure_name}\nThis month earned: $${c.this_month}\nYTD earned: $${c.ytd_earned}\nTiers: ${c.tiers.map(t=>`$${t.min}-${t.max||"+"} at ${t.rate}%`).join(", ")}\n\nHelp me verify this commission calculation is correct and review if the structure still makes sense given current production levels.`} />
      </Card>
    ))}
  </div>
);

// ─── Main HR Module ───────────────────────────────────────────
export default function HRPeople() {
  const { data: roi } = useProducerROI();
  const [section,     setSection]     = useState("overview");
  const [applicants,  setApplicants]  = useState([]);

  // Load applicants from live Supabase table. Empty result yields empty pipeline.
  useEffect(() => {
    if (!supabase || !AGENCY_ID) return;
    let cancelled = false;
    supabase
      .from("applicants")
      .select("id, first_name, last_name, email, phone, status, source, claude_score, claude_summary, interview_focus_doc, intake_received_at, created_at")
      .eq("agency_id", AGENCY_ID)
      .order("created_at", { ascending: false })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        // Normalize live data to the shape the UI expects.
        const normalized = (data || []).map(a => ({
          ...a,
          position: a.position || "—",
          interview_focus: a.interview_focus_doc || null,
          interview_date: null,
          interview_notes: null,
          rating: null,
        }));
        setApplicants(normalized);
      });
    return () => { cancelled = true; };
  }, []);

  const updateApplicantStage = (id, newStatus) => {
    setApplicants(prev => prev.map(a => a.id === id ? {...a, status:newStatus} : a));
  };

  const sections = [
    { id:"overview",    label:"Overview"    },
    { id:"recruiting",  label:"Recruiting"  },
    { id:"staff",       label:"Staff"       },
    { id:"onboarding",  label:"Onboarding"  },
    { id:"performance", label:"Performance" },
    { id:"commissions", label:"Commissions" },
  ];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>HR & People</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            {(roi?.allActiveStaff || []).length} active staff · {applicants.filter(a=>!["hired","rejected"].includes(a.status)).length} applicants in pipeline · Resume scanner active
          </div>
        </div>
        <AskBtn context="Give me a complete HR review. How is my recruiting pipeline looking? Any compliance concerns with my current team? What HR actions should I take this week?" />
      </div>

      {/* Section Navigation */}
      <div style={{ display:"flex", gap:2, flexWrap:"wrap", background:T.slate100, borderRadius:10, padding:4, marginBottom:18 }}>
        {sections.map(s => (
          <button key={s.id} onClick={() => setSection(s.id)} style={{ padding:"7px 14px", fontSize:12, fontWeight:section===s.id?600:400, color:section===s.id?T.slate900:T.slate500, background:section===s.id?T.white:"transparent", border:"none", borderRadius:7, cursor:"pointer", transition:"all 0.12s", boxShadow:section===s.id?"0 1px 3px rgba(0,0,0,0.08)":"none" }}>
            {s.label}
          </button>
        ))}
      </div>

      {/* Section Content */}
      {section === "overview"    && <HROverview        applicants={applicants} staff={roi?.allActiveStaff || []} onboarding={[]} />}
      {section === "recruiting"  && <RecruitingPipeline applicants={applicants} onUpdate={updateApplicantStage} />}
      {section === "staff"       && <StaffDirectory     staff={roi?.allActiveStaff || []} />}
      {section === "onboarding"  && <OnboardingSection  onboarding={[]} />}
      {section === "performance" && <PerformanceSection  roi={roi} />}
      {section === "commissions" && <CommissionsSection  commissions={[]} />}
    </div>
  );
}
