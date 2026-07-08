import { useState, useMemo, useEffect } from "react";
import { supabase, AGENCY_ID, BUSINESS_ENTITY_ID } from "../lib/supabase.js";


// Returns true if a staff member holds any one of the three license types.
const hasAnyLicense = (m) => !!(m && (m.license_pc || m.license_lh || m.license_ips));
// ============================================================
// Newtworks HR & PEOPLE MODULE v1.0
// Newtworks — State Farm Agent Edition
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
//       team_performance, commission_structures tables
// ============================================================


// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

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

        const [agencyRes, staffRes, prodRes, payrollDetailRes, payrollRunsRes, compRes, aippRes, aippTrackRes, lapseRes] = await Promise.all([
          supabase.from("agency").select("id, name, smvc_rate_pc, blended_rate_other, rates_are_defaults").eq("id", AGENCY_ID).maybeSingle(),
          supabase.from("team").select("id, user_id, first_name, last_name, role, role_category, role_level, category, archived_at, start_date, pay_rate, pay_type, pay_frequency, employment_type, is_active, email_personal, phone_personal, sf_alias, account_alpha, email_sf, phone_extension, notes, license_pc, license_lh, license_ips, license_states, compliance_flag, nickname").eq("agency_id", AGENCY_ID),
          supabase.from("producer_production").select("team_member_id, period_year, period_month, line_of_business, policies_issued, premium_issued").eq("agency_id", AGENCY_ID).order("period_year",{ascending:false}).order("period_month",{ascending:false}),
          supabase.from("payroll_detail").select("team_member_id, gross_pay, payroll_run_id").eq("business_entity_id", BUSINESS_ENTITY_ID),
          supabase.from("payroll_runs").select("id, pay_date, pay_period_start, pay_period_end").eq("business_entity_id", BUSINESS_ENTITY_ID).order("pay_date",{ascending:false}).limit(24),
          supabase.from("comp_recap").select("period_year, period_month, comp_type, comp_category, amount").eq("agency_id", AGENCY_ID),
          supabase.from("v_aipp_projection").select("*").eq("agency_id", AGENCY_ID).maybeSingle(),
          supabase.from("aipp_tracking").select("*").eq("agency_id", AGENCY_ID).order("program_year",{ascending:false}).limit(1),
          supabase.from("v_lapse_rate_current").select("annualized_rate").eq("agency_id", AGENCY_ID).eq("line", "blended").maybeSingle(),
        ]);

        const agency = agencyRes.data || {};
        const staff  = (staffRes.data || []).filter(s => s.is_active !== false && !s.archived_at);
        const production = prodRes.data || [];
        const payrollDetail = payrollDetailRes.data || [];
        const payrollRuns = payrollRunsRes.data || [];
        const compRecaps = compRes.data || [];

        // P&C renewal YTD context (prior year vs current year) — shown for reference only.
        const isPC = (cat) => {
          const c = (cat || "").toLowerCase();
          return c.includes("auto") || c.includes("home") || c.includes("fire") || c.includes("umbrella");
        };
        const renewalsYtd = (year) => compRecaps
          .filter(r => r.period_year === year && r.comp_type === "renewal" && isPC(r.comp_category) && r.period_month <= currentMonth)
          .reduce((s,r) => s + parseFloat(r.amount || 0), 0);

        const priorRenewals = renewalsYtd(currentYear - 1);
        const currentRenewals = renewalsYtd(currentYear);

        // Authoritative lapse rate: server-computed from agency_snapshot YTD via compute_lapse_rate().
        // Per the "Lapse rate — never store, compute at runtime" operational rule, the rate is
        // always derived live from policies lost YTD ÷ starting PIF, dollar-weighted across Auto/Fire/Life.
        const serverLapse = parseFloat(lapseRes?.data?.annualized_rate);
        const lapseRate = Number.isFinite(serverLapse) ? serverLapse * 100 : 10;

        // Per-producer monthly gross pay from last 3 payroll runs (×2 for semi-monthly)
        const last3RunIds = new Set(payrollRuns.slice(0, 3).map(r => r.id));
        const grossByStaff = {};
        const runsCountByStaff = {};
        for (const d of payrollDetail) {
          if (!last3RunIds.has(d.payroll_run_id)) continue;
          grossByStaff[d.team_member_id] = (grossByStaff[d.team_member_id] || 0) + parseFloat(d.gross_pay || 0);
          runsCountByStaff[d.team_member_id] = (runsCountByStaff[d.team_member_id] || 0) + 1;
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
          const k = `${p.team_member_id}|${p.period_year}|${p.period_month}`;
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
            team_member_id: s.id,
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
  const [newEmployee, setNewEmployee] = useState({first_name:"", last_name:"", role:"", role_category:"", role_level:"", category:"agency", email_personal:"", phone_personal:"", start_date:"", employment_type:"w2", sf_alias:"", email_sf:"", phone_extension:"", account_alpha:""});

  const saveEmployee = async () => {
    if (!newEmployee.first_name || !newEmployee.last_name) return;
    if (supabase) {
      await supabase.from("team").insert({ ...newEmployee, agency_id: AGENCY_ID, is_active: true });
    }
    setShowAddEmployee(false);
    setNewEmployee({first_name:"", last_name:"", role:"", role_category:"", role_level:"", category:"agency", email_personal:"", phone_personal:"", start_date:"", employment_type:"w2", sf_alias:"", email_sf:"", phone_extension:"", account_alpha:""});
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
          { label:"Active Staff",      value:activeStaff,     color:T.slate900,  border:T.slate900  },
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

      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(220px, 1fr))", gap:12 }}>
        {/* Active Pipeline */}
        
      <div style={{display:"flex",justifyContent:"flex-end",marginBottom:12}}>
        <button onClick={()=>setShowAddEmployee(s=>!s)} style={{padding:"8px 16px",fontSize:12,fontWeight:600,background:"#1E3A5F",color:"#fff",border:"none",borderRadius:8,cursor:"pointer"}}>➕ Add Employee</button>
      </div>

      {showAddEmployee && (
        <div style={{background:"#EFF6FF",border:"1px solid #BFDBFE",borderRadius:10,padding:16,marginBottom:16}}>
          <div style={{fontSize:13,fontWeight:700,color:"#1E3A5F",marginBottom:12}}>Add New Employee</div>
          <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))",gap:10,marginBottom:10}}>
            <input placeholder="First name *" value={newEmployee.first_name} onChange={e=>setNewEmployee({...newEmployee,first_name:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Last name *" value={newEmployee.last_name} onChange={e=>setNewEmployee({...newEmployee,last_name:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <select value={newEmployee.role} onChange={e=>setNewEmployee({...newEmployee,role:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12,background:"#fff"}}>
              <option value="">Role *</option>
              <option value="Acquisition">Acquisition</option>
              <option value="Inside Sales">Inside Sales</option>
              <option value="Reception">Reception</option>
              <option value="Escalation">Escalation</option>
            </select>
            <select value={newEmployee.role_category} onChange={e=>setNewEmployee({...newEmployee,role_category:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12,background:"#fff"}}>
              <option value="">Role category</option>
              <option value="Sales">Sales</option>
              <option value="Retention">Retention</option>
            </select>
            <select value={newEmployee.role_level} onChange={e=>setNewEmployee({...newEmployee,role_level:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12,background:"#fff"}}>
              <option value="">Role level (optional)</option>
              <option value="Owner">Owner</option>
              <option value="Office Manager">Office Manager</option>
              <option value="Unit Manager">Unit Manager</option>
              <option value="Section Manager">Section Manager</option>
              <option value="Account Manager">Account Manager</option>
              <option value="Account Associate">Account Associate</option>
            </select>
            <select value={newEmployee.category} onChange={e=>setNewEmployee({...newEmployee,category:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12,background:"#fff"}}>
              <option value="agency">Agency team</option>
              <option value="admin">Admin team</option>
            </select>
            <input placeholder="Personal email" value={newEmployee.email_personal} onChange={e=>setNewEmployee({...newEmployee,email_personal:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Personal phone" value={newEmployee.phone_personal} onChange={e=>setNewEmployee({...newEmployee,phone_personal:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input type="date" placeholder="Start date" value={newEmployee.start_date} onChange={e=>setNewEmployee({...newEmployee,start_date:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <select value={newEmployee.employment_type} onChange={e=>setNewEmployee({...newEmployee,employment_type:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}}>
              <option value="w2">W-2 Employee</option>
              <option value="1099">1099 Contractor</option>
              <option value="family">Family Employee (W-2)</option>
            </select>
          </div>
          <div style={{fontSize:11,fontWeight:600,color:"#64748B",textTransform:"uppercase",letterSpacing:0.5,marginTop:4,marginBottom:8}}>State Farm fields (optional — can be added later)</div>
          <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))",gap:10,marginBottom:10}}>
            <input placeholder="SF Alias (e.g. VAELNA)" value={newEmployee.sf_alias} onChange={e=>setNewEmployee({...newEmployee,sf_alias:e.target.value.toUpperCase()})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12,textTransform:"uppercase"}} />
            <input placeholder="Account alpha (e.g. A-L)" value={newEmployee.account_alpha} onChange={e=>setNewEmployee({...newEmployee,account_alpha:e.target.value.toUpperCase()})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12,textTransform:"uppercase"}} />
            <input placeholder="SF Email" value={newEmployee.email_sf} onChange={e=>setNewEmployee({...newEmployee,email_sf:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
            <input placeholder="Phone extension" value={newEmployee.phone_extension} onChange={e=>setNewEmployee({...newEmployee,phone_extension:e.target.value})} style={{padding:"8px 10px",borderRadius:6,border:"1px solid #CBD5E1",fontSize:12}} />
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
      {/* Pipeline Kanban (horizontally scrollable on narrow viewports) */}
      <div style={{ overflowX:"auto", marginBottom:16, marginLeft:-4, marginRight:-4, paddingLeft:4, paddingRight:4 }}>
      <div style={{ display:"grid", gridTemplateColumns:"repeat(6,minmax(120px,1fr))", gap:8, minWidth:"720px" }}>
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
              
            </div>
          </div>

          {/* AI Summary */}
          <div style={{ background:T.slate50, borderRadius:10, padding:"12px 14px", marginBottom:12 }}>
            <div style={{ fontSize:11, fontWeight:600, color:T.slate600, marginBottom:4 }}>RESUME ANALYSIS (Groq)</div>
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

  // ── Termination flow state (principle 500: document the decision before making it) ──
  const [terminatingId, setTerminatingId] = useState(null);
  const [termForm, setTermForm] = useState({});
  const [terminating, setTerminating] = useState(false);
  const [termError, setTermError] = useState("");
  // Track terminated IDs so they disappear from the active list immediately on success.
  const [terminatedIds, setTerminatedIds] = useState(new Set());

  const startTerminate = (member) => {
    setTermError("");
    setTerminatingId(member.id);
    setTermForm({
      reason_category: "",
      end_date: new Date().toISOString().slice(0,10),
      final_paycheck_date: "",
      notes: "",
      confirm_name: "",
    });
  };
  const cancelTerminate = () => { setTerminatingId(null); setTermForm({}); setTermError(""); };

  const terminateMember = async (member) => {
    if (terminating) return;
    const expectedName = `${member.first_name || ""} ${member.last_name || ""}`.trim();
    const reason = (termForm.reason_category || "").trim();
    const notes = (termForm.notes || "").trim();
    const endDate = termForm.end_date || new Date().toISOString().slice(0,10);
    const finalPaycheckDate = (termForm.final_paycheck_date || "").trim() || null;
    const typedName = (termForm.confirm_name || "").trim();

    // Principle 500 enforcement: require structured reason + free-text documentation.
    if (!reason) { setTermError("Reason category is required."); return; }
    if (notes.length < 10) { setTermError("Notes are required (at least 10 characters) — this is the documented reasoning per principle 500."); return; }
    if (typedName.toLowerCase() !== expectedName.toLowerCase()) {
      setTermError(`Type the team member's full name ("${expectedName}") to confirm.`);
      return;
    }
    if (!supabase) { setTermError("No database connection."); return; }

    setTerminating(true);
    setTermError("");

    const reasonLabel = {
      ethics_breach:   "Ethics breach (immediate, per principle 500)",
      pip_not_met:     "Signed PIP not met (per principle 500)",
      resignation:     "Resignation (voluntary)",
      mutual_departure:"Mutual departure",
      other:           "Other (documented in notes)",
    }[reason] || reason;

    try {
      // Delegate the whole termination to the terminate-team-member edge fn.
      // It orchestrates: team archive + linked user deactivation,
      // team_telegram_map exclusion, Team List processes strip, the
      // termination-notice email to Peter's SF address, and the Telegram
      // group kick. Email + Telegram are best-effort and surface as
      // warnings; the DB state is always consistent on the function's return.
      const { data: result, error: fnErr } = await supabase.functions.invoke("terminate-team-member", {
        body: {
          team_id: member.id,
          termination_date: endDate,
          reason_category: reasonLabel,
          termination_reason: notes,
          final_paycheck_date: finalPaycheckDate,
        },
      });
      if (fnErr) {
        setTermError(`Termination edge fn failed: ${fnErr.message}`);
        setTerminating(false);
        return;
      }
      if (!result || result.success !== true) {
        setTermError(`Termination failed: ${result?.error || "unknown error from edge fn"}`);
        setTerminating(false);
        return;
      }

      // Write the audit row to team_behavioral_notes (principle 500). Non-blocking;
      // the canonical record of WHAT happened is the edge fn's automation_run_log row,
      // this is the local HR-pattern view.
      const warnings = Array.isArray(result.warnings) ? result.warnings : [];
      const obsText = [
        `TERMINATION — ${reasonLabel}`,
        `End date: ${endDate}`,
        finalPaycheckDate ? `Final paycheck date: ${finalPaycheckDate}` : null,
        `Notes: ${notes}`,
        `Notification email: ${result.email_sent ? "sent" : "FAILED — alert created"}`,
        `Telegram group kick: ${result.telegram_kicked ? "done" : "not done"}`,
        warnings.length > 0 ? `Edge fn warnings: ${warnings.join("; ")}` : null,
      ].filter(Boolean).join("\n");
      const noteIns = await supabase.from("team_behavioral_notes").insert({
        agency_id: AGENCY_ID,
        team_member_id: member.id,
        observation_date: endDate,
        pattern_type: "termination",
        source: "termination_action",
        observation_text: obsText,
      }).select("id");
      if (noteIns.error) console.error("[terminate] audit note failed:", noteIns.error.message);

      // Surface partial-success warnings without rolling back. The DB state is
      // already what it needs to be — the alerts table holds the recovery path.
      if (warnings.length > 0 || !result.email_sent) {
        console.warn("[terminate] partial success:", { email_sent: result.email_sent, telegram_kicked: result.telegram_kicked, warnings });
        alert(
          `${expectedName} terminated, but with warnings:\n\n` +
          `• Notification email: ${result.email_sent ? "sent ✓" : "NOT sent ✗"}\n` +
          `• Telegram kick: ${result.telegram_kicked ? "done ✓" : "skipped/failed"}\n` +
          (warnings.length > 0 ? `\nDetails:\n${warnings.join("\n")}\n` : "") +
          `\nAn alert has been logged.`
        );
      }

      // Local UI: drop the row from the active list immediately.
      setTerminatedIds(prev => { const n = new Set(prev); n.add(member.id); return n; });
      setTerminatingId(null);
      setTermForm({});
      setExpanded(null);
    } catch (e) {
      setTermError(e?.message || "Unexpected error during termination.");
    } finally {
      setTerminating(false);
    }
  };

  // ── Reactivation flow state ──
  const [view, setView] = useState("active"); // "active" or "archived"
  const [archivedStaff, setArchivedStaff] = useState([]);
  const [archivedLoading, setArchivedLoading] = useState(false);
  const [archivedError, setArchivedError] = useState("");
  const [reactivatingId, setReactivatingId] = useState(null);
  const [reactivating, setReactivating] = useState(false);
  const [reactivateError, setReactivateError] = useState("");
  const [reactivateNote, setReactivateNote] = useState("");
  const [reactivatedIds, setReactivatedIds] = useState(new Set());

  // Load archived staff (is_active=false) plus their latest termination note for context.
  useEffect(() => {
    if (view !== "archived" || !supabase) return;
    let cancelled = false;
    setArchivedLoading(true);
    setArchivedError("");
    (async () => {
      const { data: teamRows, error: teamErr } = await supabase
        .from("team")
        .select("id, first_name, last_name, role, role_level, role_category, category, employment_type, start_date, end_date, archived_at, performance_status, pay_type, pay_rate, license_pc, license_lh, license_ips, license_states, email_personal, email_sf, phone_personal, phone_extension, notes, user_id")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", false)
        .order("archived_at", { ascending: false, nullsFirst: false });
      if (cancelled) return;
      if (teamErr) { setArchivedError(teamErr.message || "Failed to load archived staff."); setArchivedLoading(false); return; }
      const rows = teamRows || [];
      let notes = [];
      if (rows.length) {
        const { data: noteRows } = await supabase
          .from("team_behavioral_notes")
          .select("team_member_id, observation_text, observation_date, pattern_type, source")
          .eq("agency_id", AGENCY_ID)
          .in("team_member_id", rows.map(r => r.id))
          .eq("pattern_type", "termination")
          .order("observation_date", { ascending: false });
        notes = noteRows || [];
      }
      const latestNote = {};
      notes.forEach(n => { if (!latestNote[n.team_member_id]) latestNote[n.team_member_id] = n; });
      if (cancelled) return;
      setArchivedStaff(rows.map(t => ({ ...t, _termNote: latestNote[t.id] || null })));
      setArchivedLoading(false);
    })();
    return () => { cancelled = true; };
  }, [view, reactivatedIds]);

  const reactivateMember = async (member, note) => {
    if (reactivating) return;
    setReactivating(true);
    setReactivateError("");
    const nowIso = new Date().toISOString();
    const today = new Date().toISOString().slice(0,10);
    try {
      if (!supabase) { setReactivateError("No database connection."); setReactivating(false); return; }

      // 1) Restore team row. .select() forces PostgREST to return affected rows.
      const teamUpdate = await supabase
        .from("team")
        .update({
          is_active: true,
          end_date: null,
          archived_at: null,
          updated_at: nowIso,
        })
        .eq("id", member.id)
        .eq("agency_id", AGENCY_ID)
        .select("id");
      if (teamUpdate.error) { setReactivateError(`team update failed: ${teamUpdate.error.message}`); setReactivating(false); return; }
      if (!teamUpdate.data || teamUpdate.data.length === 0) {
        setReactivateError("Reactivation did not affect any rows — RLS may be blocking the write.");
        setReactivating(false);
        return;
      }

      // 2) Restore linked user account if one exists.
      if (member.user_id) {
        const userUpdate = await supabase
          .from("users")
          .update({ is_active: true, invite_status: "accepted", updated_at: nowIso })
          .eq("id", member.user_id)
          .eq("agency_id", AGENCY_ID);
        if (userUpdate.error) {
          await supabase.from("team").update({
            is_active: false,
            archived_at: member.archived_at,
            end_date: member.end_date,
          }).eq("id", member.id).eq("agency_id", AGENCY_ID);
          setReactivateError(`users update failed (team rolled back): ${userUpdate.error.message}`);
          setReactivating(false);
          return;
        }
      }

      // 3) Audit: reactivation note.
      //    Secondary operations from here on are non-blocking — reactivation already succeeded —
      //    but errors MUST be surfaced loudly so silent failures don't leave us without a trail.
      const warnings = [];
      const obsText = [
        `REACTIVATION — team member returned to active status.`,
        `Prior end date: ${member.end_date || "unknown"}.`,
        note && note.trim() ? `Notes: ${note.trim()}` : null,
      ].filter(Boolean).join("\n");
      const reactNoteIns = await supabase.from("team_behavioral_notes").insert({
        agency_id: AGENCY_ID,
        team_member_id: member.id,
        observation_date: today,
        pattern_type: "reactivation",
        source: "reactivation_action",
        observation_text: obsText,
      }).select("id");
      if (reactNoteIns.error) warnings.push(`reactivation audit note: ${reactNoteIns.error.message}`);

      // 4) Resolve the related termination note. 0 rows is OK (no prior termination note).
      const resolveNote = await supabase
        .from("team_behavioral_notes")
        .update({ is_resolved: true, resolved_date: today, updated_at: nowIso })
        .eq("agency_id", AGENCY_ID)
        .eq("team_member_id", member.id)
        .eq("pattern_type", "termination")
        .eq("is_resolved", false)
        .select("id");
      if (resolveNote.error) warnings.push(`resolve termination note: ${resolveNote.error.message}`);

      // 5) Cancel any still-open offboarding follow-up task for this person.
      //    0 rows is OK (no open task to cancel).
      const cancelTask = await supabase
        .from("tasks")
        .update({ status: "cancelled", completed_at: nowIso, updated_at: nowIso })
        .eq("agency_id", AGENCY_ID)
        .eq("related_id", member.id)
        .eq("module_reference", "hr_people")
        .eq("status", "open")
        .select("id");
      if (cancelTask.error) warnings.push(`cancel offboarding task: ${cancelTask.error.message}`);

      // Surface non-blocking failures loudly before closing the panel.
      if (warnings.length > 0) {
        console.error("[reactivate] non-blocking failures:", warnings);
        alert(`Reactivation saved, but some side effects failed:\n\n${warnings.join("\n")}`);
      }

      // 6) Local UI: drop from archived list immediately.
      setReactivatedIds(prev => { const n = new Set(prev); n.add(member.id); return n; });
      setReactivatingId(null);
      setReactivateNote("");
    } catch (e) {
      setReactivateError(e?.message || "Unexpected error during reactivation.");
    } finally {
      setReactivating(false);
    }
  };

  // ── Add-member flow state (creates team row + invites a Newtworks user) ──
  // Insert into public.team, then call invite-team-member edge function
  // which sends a Supabase Auth invite email and creates the public.users
  // row. Then link users.team_member_id = team.id so the sync_team_user_link
  // trigger mirrors team.user_id. New rows are kept in `additions` so they
  // appear immediately without a full reload of useProducerROI.
  const [adding, setAdding] = useState(false);
  const [addOpen, setAddOpen] = useState(false);
  const [addError, setAddError] = useState("");
  const [addForm, setAddForm] = useState({
    first_name:       "",
    last_name:        "",
    email_personal:   "",
    phone_personal:   "",
    address_line1:    "",
    address_line2:    "",
    city:             "",
    state:            "",
    zip_code:         "",
    role:             "",
    role_category:    "",
    role_level:       "",
    category:         "agency",
    employment_type:  "w2",
    start_date:       new Date().toISOString().slice(0,10),
    license_pc:       false,
    license_lh:       false,
    license_ips:      false,
  });
  const [additions, setAdditions] = useState([]);

  const openAdd = () => {
    setAddError("");
    setAddOpen(true);
    setAddForm({
      first_name:      "",
      last_name:       "",
      email_personal:  "",
      phone_personal:  "",
      address_line1:   "",
      address_line2:   "",
      city:            "",
      state:           "",
      zip_code:        "",
      role:            "",
      role_category:   "",
      role_level:      "",
      category:        "agency",
      employment_type: "w2",
      start_date:      new Date().toISOString().slice(0,10),
      license_pc:      false,
      license_lh:      false,
      license_ips:     false,
    });
  };
  const closeAdd = () => { setAddOpen(false); setAddError(""); };

  const addMember = async () => {
    if (adding) return;
    setAddError("");

    const firstName = (addForm.first_name || "").trim();
    const lastName  = (addForm.last_name  || "").trim();
    const email     = (addForm.email_personal || "").trim().toLowerCase();

    if (!firstName || !lastName) { setAddError("First and last name are required."); return; }
    if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      setAddError("A valid personal email is required — the invite is sent there.");
      return;
    }
    if (!supabase) { setAddError("No database connection."); return; }

    setAdding(true);
    const nowIso = new Date().toISOString();

    try {
      // Duplicate-email guard (active or archived).
      const { data: existing, error: existErr } = await supabase
        .from("team")
        .select("id, first_name, last_name, is_active")
        .eq("agency_id", AGENCY_ID)
        .ilike("email_personal", email)
        .limit(1);
      if (existErr) { setAddError(`Duplicate check failed: ${existErr.message}`); setAdding(false); return; }
      if (Array.isArray(existing) && existing.length > 0) {
        const dup = existing[0];
        setAddError(`A team member with that email already exists: ${dup.first_name} ${dup.last_name}${dup.is_active === false ? " (archived)" : ""}.`);
        setAdding(false);
        return;
      }

      // 1) Insert the team row. .select() forces PostgREST to return the new row.
      const teamPayload = {
        agency_id:       AGENCY_ID,
        first_name:      firstName,
        last_name:       lastName,
        email_personal:  email,
        phone_personal:  (addForm.phone_personal || "").trim() || null,
        address_line1:   (addForm.address_line1 || "").trim() || null,
        address_line2:   (addForm.address_line2 || "").trim() || null,
        city:            (addForm.city || "").trim() || null,
        state:           (addForm.state || "").trim().toUpperCase() || null,
        zip_code:        (addForm.zip_code || "").trim() || null,
        role:            (addForm.role || "").trim() || null,
        role_category:   (addForm.role_category || "").trim() || null,
        role_level:      (addForm.role_level || "").trim() || null,
        category:        (addForm.category || "agency").trim() || "agency",
        employment_type: (addForm.employment_type || "").trim() || null,
        start_date:      addForm.start_date || null,
        hire_date:       addForm.start_date || null,
        is_active:       true,
        license_pc:      addForm.license_pc  === true,
        license_lh:      addForm.license_lh  === true,
        license_ips:     addForm.license_ips === true,
        license_states:  [],
        created_at:      nowIso,
        updated_at:      nowIso,
      };
      const teamIns = await supabase
        .from("team")
        .insert(teamPayload)
        .select("*")
        .maybeSingle();
      if (teamIns.error) {
        setAddError(`team insert failed: ${teamIns.error.message}`);
        setAdding(false);
        return;
      }
      const newTeam = teamIns.data;
      if (!newTeam || !newTeam.id) {
        setAddError("team insert returned no row — RLS may be blocking the write.");
        setAdding(false);
        return;
      }

      // 2) Send the invite via the invite-team-member edge function.
      //    The function does its own owner/manager check off the caller's session.
      const { data: invRes, error: invErr } = await supabase.functions.invoke(
        "invite-team-member",
        {
          body: {
            email,
            full_name: `${firstName} ${lastName}`,
            role:      "staff",
          },
        }
      );
      if (invErr || !invRes?.ok) {
        // Roll the team row back so we don't leave an orphan.
        await supabase.from("team").delete().eq("id", newTeam.id).eq("agency_id", AGENCY_ID);
        const detail = invRes?.error || invRes?.detail || invErr?.message || "unknown error";
        setAddError(`Invite failed (team row rolled back): ${detail}`);
        setAdding(false);
        return;
      }

      // 3) Link the freshly-created public.users row to this team row.
      //    Non-blocking: warn if it fails — Claude can repair manually.
      const warnings = [];
      const userLink = await supabase
        .from("users")
        .update({ team_member_id: newTeam.id, updated_at: new Date().toISOString() })
        .eq("agency_id", AGENCY_ID)
        .ilike("email", email)
        .is("team_member_id", null)
        .select("id");
      if (userLink.error) {
        warnings.push(`users link: ${userLink.error.message}`);
      } else if (!userLink.data || userLink.data.length === 0) {
        warnings.push("users row not found to link — the invite went out but team.user_id will be empty until the user signs in.");
      }
      if (warnings.length > 0) {
        console.error("[add member] non-blocking failures:", warnings);
      }

      // 4) Local UI: prepend the new row so it appears immediately.
      setAdditions(prev => [newTeam, ...prev]);
      setAddOpen(false);
      setAddForm({
        first_name:"", last_name:"", email_personal:"",
        role:"", role_category:"", role_level:"",
        category:"agency", employment_type:"w2",
        start_date: new Date().toISOString().slice(0,10),
        license_pc:false, license_lh:false, license_ips:false,
      });
    } catch (e) {
      setAddError(e?.message || "Unexpected error while adding member.");
    } finally {
      setAdding(false);
    }
  };

  const startEdit = (member) => {
    setSaveError("");
    setEditingId(member.id);
    setForm({
      first_name: member.first_name || "",
      last_name: member.last_name || "",
      role: member.role || "",
      role_category: member.role_category || "",
      role_level: member.role_level || "",
      category: member.category || "agency",
      employment_type: member.employment_type || "",
      email_personal:  member.email_personal  || "",
      email_sf:        member.email_sf        || "",
      phone_personal:  member.phone_personal  || "",
      phone_extension: member.phone_extension || "",
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
      role_category: (form.role_category || "").trim() || null,
      role_level: (form.role_level || "").trim() || null,
      category: (form.category || "agency").trim() || "agency",
      employment_type: form.employment_type.trim() || null,
      email_personal:  form.email_personal.trim()  || null,
      email_sf:        form.email_sf.trim()        || null,
      phone_personal:  form.phone_personal.trim()  || null,
      phone_extension: form.phone_extension.trim() || null,
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
      const { data, error } = await supabase
        .from("team")
        .update(payload)
        .eq("id", id)
        .eq("agency_id", AGENCY_ID)
        .select("id");
      if (error) {
        setSaveError(error.message || "Save failed. You may need to be signed in.");
        setSaving(false);
        return;
      }
      if (!data || data.length === 0) {
        setSaveError("Save did not affect any rows — RLS may be blocking the write.");
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

  // Counts for the view toggle
  const mergedActive = [...additions, ...((staff || []).filter(s => !additions.some(a => a.id === s.id)))];
  const activeCount = mergedActive.filter(s => s.is_active && !terminatedIds.has(s.id)).length;
  const archivedCount = archivedStaff.filter(s => !reactivatedIds.has(s.id)).length;

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
      {/* View toggle — Active vs Archived — plus Add member button */}
      <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:4 }}>
        <button
          onClick={() => setView("active")}
          style={{ padding:"6px 12px", fontSize:11, fontWeight:view==="active"?700:500, color:view==="active"?T.white:T.slate700, background:view==="active"?T.slate900:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>
          Active · {activeCount}
        </button>
        <button
          onClick={() => setView("archived")}
          style={{ padding:"6px 12px", fontSize:11, fontWeight:view==="archived"?700:500, color:view==="archived"?T.white:T.slate700, background:view==="archived"?T.slate900:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>
          Archived{view==="archived" ? " · " + archivedCount : ""}
        </button>
        {view === "archived" && archivedLoading && (
          <span style={{ fontSize:11, color:T.slate500 }}>Loading…</span>
        )}
        <div style={{ flex:1 }} />
        <button
          onClick={() => addOpen ? closeAdd() : openAdd()}
          disabled={adding}
          style={{ padding:"6px 14px", fontSize:11, fontWeight:700, color:T.white, background:addOpen?T.slate500:T.slate900, border:"none", borderRadius:7, cursor:adding?"not-allowed":"pointer" }}>
          {addOpen ? "Cancel" : "+ Add member"}
        </button>
      </div>

      {/* ============== ADD MEMBER PANEL ============== */}
      {addOpen && (
        <Card style={{ border:`2px solid ${T.slate900}`, background:T.white, marginBottom:4 }}>
          <div style={{ fontSize:13, fontWeight:700, color:T.slate900, marginBottom:6 }}>Add new team member</div>
          <div style={{ fontSize:11, color:T.slate600, marginBottom:14, lineHeight:1.55 }}>
            Creates a team row, sends a Supabase Auth invite to the personal email, and links the new Newtworks user back to this team row once they sign in. Role defaults to <code>staff</code> (team tier — sees Dashboard, CPR, Hours, Handbook, Processes). To grant admin access, change role to <code>owner</code> or <code>manager</code> after they accept.
          </div>

          {/* Row 1: name + email */}
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))", gap:10, marginBottom:10 }}>
            <div>
              <label style={labelStyle}>First name *</label>
              <input style={inputStyle} value={addForm.first_name} onChange={e => setAddForm(f => ({ ...f, first_name: e.target.value }))} />
            </div>
            <div>
              <label style={labelStyle}>Last name *</label>
              <input style={inputStyle} value={addForm.last_name} onChange={e => setAddForm(f => ({ ...f, last_name: e.target.value }))} />
            </div>
            <div>
              <label style={labelStyle}>Personal email * (invite is sent here)</label>
              <input type="email" style={inputStyle} value={addForm.email_personal} onChange={e => setAddForm(f => ({ ...f, email_personal: e.target.value }))} placeholder="first.last@example.com" />
            </div>
          </div>

          {/* Row 2: role, role category, role level */}
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(150px, 1fr))", gap:10, marginBottom:10 }}>
            <div>
              <label style={labelStyle}>Role</label>
              <select style={inputStyle} value={addForm.role} onChange={e => {
                const r = e.target.value;
                const rc = (r === "Acquisition" || r === "Inside Sales") ? "Sales"
                         : (r === "Reception"   || r === "Escalation")   ? "Retention"
                         : addForm.role_category;
                setAddForm(f => ({ ...f, role: r, role_category: rc }));
              }}>
                <option value="">—</option>
                <option value="Acquisition">Acquisition</option>
                <option value="Inside Sales">Inside Sales</option>
                <option value="Reception">Reception</option>
                <option value="Escalation">Escalation</option>
              </select>
            </div>
            <div>
              <label style={labelStyle}>Role category</label>
              <select style={inputStyle} value={addForm.role_category} onChange={e => setAddForm(f => ({ ...f, role_category: e.target.value }))}>
                <option value="">—</option>
                <option value="Sales">Sales</option>
                <option value="Retention">Retention</option>
              </select>
            </div>
            <div>
              <label style={labelStyle}>Role level</label>
              <select style={inputStyle} value={addForm.role_level} onChange={e => setAddForm(f => ({ ...f, role_level: e.target.value }))}>
                <option value="">—</option>
                <option value="Owner">Owner</option>
                <option value="Office Manager">Office Manager</option>
                <option value="Unit Manager">Unit Manager</option>
                <option value="Section Manager">Section Manager</option>
                <option value="Account Manager">Account Manager</option>
                <option value="Account Associate">Account Associate</option>
              </select>
            </div>
          </div>

          {/* Row 3: category, employment type, start date */}
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(150px, 1fr))", gap:10, marginBottom:10 }}>
            <div>
              <label style={labelStyle}>Category</label>
              <select style={inputStyle} value={addForm.category} onChange={e => setAddForm(f => ({ ...f, category: e.target.value }))}>
                <option value="agency">Agency team</option>
                <option value="admin">Admin team</option>
              </select>
            </div>
            <div>
              <label style={labelStyle}>Employment type</label>
              <select style={inputStyle} value={addForm.employment_type} onChange={e => setAddForm(f => ({ ...f, employment_type: e.target.value }))}>
                <option value="w2">W-2 Employee</option>
                <option value="family">Family Employee (W-2)</option>
                <option value="1099">1099 Contractor</option>
              </select>
            </div>
            <div>
              <label style={labelStyle}>Start date</label>
              <input type="date" style={inputStyle} value={addForm.start_date} onChange={e => setAddForm(f => ({ ...f, start_date: e.target.value }))} />
            </div>
          </div>

          {/* Row 4: licensing */}
          <div style={{ marginBottom:14 }}>
            <label style={labelStyle}>Licensing (held today)</label>
            <div style={{ display:"flex", gap:14, alignItems:"center", paddingTop:4 }}>
              <label style={{ display:"flex", alignItems:"center", gap:6, fontSize:12, color:T.slate800, cursor:"pointer" }}>
                <input type="checkbox" checked={addForm.license_pc} onChange={e => setAddForm(f => ({ ...f, license_pc: e.target.checked }))} /> P&amp;C
              </label>
              <label style={{ display:"flex", alignItems:"center", gap:6, fontSize:12, color:T.slate800, cursor:"pointer" }}>
                <input type="checkbox" checked={addForm.license_lh} onChange={e => setAddForm(f => ({ ...f, license_lh: e.target.checked }))} /> L&amp;H
              </label>
              <label style={{ display:"flex", alignItems:"center", gap:6, fontSize:12, color:T.slate800, cursor:"pointer" }}>
                <input type="checkbox" checked={addForm.license_ips} onChange={e => setAddForm(f => ({ ...f, license_ips: e.target.checked }))} /> IPS
              </label>
            </div>
          </div>

          {/* Row 5: personal phone + address — captured at hire, used in termination notice email */}
          <div style={{ fontSize:11, fontWeight:600, color:T.slate700, textTransform:"uppercase", letterSpacing:"0.04em", margin:"4px 0 8px 0" }}>
            Personal contact (used in offboarding notification)
          </div>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))", gap:10, marginBottom:10 }}>
            <div>
              <label style={labelStyle}>Personal phone</label>
              <input style={inputStyle} value={addForm.phone_personal} onChange={e => setAddForm(f => ({ ...f, phone_personal: e.target.value }))} placeholder="(210) 555-0123" />
            </div>
            <div>
              <label style={labelStyle}>Address line 1</label>
              <input style={inputStyle} value={addForm.address_line1} onChange={e => setAddForm(f => ({ ...f, address_line1: e.target.value }))} placeholder="123 Main St" />
            </div>
            <div>
              <label style={labelStyle}>Address line 2 (optional)</label>
              <input style={inputStyle} value={addForm.address_line2} onChange={e => setAddForm(f => ({ ...f, address_line2: e.target.value }))} placeholder="Apt 4B" />
            </div>
          </div>
          <div style={{ display:"grid", gridTemplateColumns:"2fr 1fr 1fr", gap:10, marginBottom:14 }}>
            <div>
              <label style={labelStyle}>City</label>
              <input style={inputStyle} value={addForm.city} onChange={e => setAddForm(f => ({ ...f, city: e.target.value }))} placeholder="San Antonio" />
            </div>
            <div>
              <label style={labelStyle}>State</label>
              <input style={inputStyle} value={addForm.state} onChange={e => setAddForm(f => ({ ...f, state: e.target.value.toUpperCase().slice(0,2) }))} placeholder="TX" maxLength={2} />
            </div>
            <div>
              <label style={labelStyle}>ZIP</label>
              <input style={inputStyle} value={addForm.zip_code} onChange={e => setAddForm(f => ({ ...f, zip_code: e.target.value }))} placeholder="78260" maxLength={10} />
            </div>
          </div>

          {addError && (
            <div style={{ fontSize:11, color:"#991B1B", background:T.redLt, border:`1px solid #FECACA`, borderRadius:6, padding:"7px 10px", marginBottom:10 }}>
              {addError}
            </div>
          )}

          <div style={{ display:"flex", gap:8, justifyContent:"flex-end" }}>
            <button onClick={closeAdd} disabled={adding} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate700, background:T.slate100, border:"none", borderRadius:7, cursor:adding?"not-allowed":"pointer" }}>Cancel</button>
            <button onClick={addMember} disabled={adding} style={{ padding:"7px 16px", fontSize:11, fontWeight:700, color:T.white, background:adding?T.slate400:T.slate900, border:"none", borderRadius:7, cursor:adding?"not-allowed":"pointer" }}>
              {adding ? "Adding…" : "Save & Invite"}
            </button>
          </div>
        </Card>
      )}

      {/* ============== ARCHIVED VIEW ============== */}
      {view === "archived" && !archivedLoading && archivedError && (
        <div style={{ fontSize:11, color:"#991B1B", background:T.redLt, border:`1px solid #FECACA`, borderRadius:6, padding:"8px 10px" }}>
          {archivedError}
        </div>
      )}
      {view === "archived" && !archivedLoading && !archivedError && archivedStaff.filter(s => !reactivatedIds.has(s.id)).length === 0 && (
        <div style={{ fontSize:12, color:T.slate500, background:T.slate50, borderRadius:8, padding:"16px 14px", textAlign:"center" }}>
          No archived team members.
        </div>
      )}
      {view === "archived" && archivedStaff.filter(s => !reactivatedIds.has(s.id)).map(member => {
        const expectedName = `${member.first_name || ""} ${member.last_name || ""}`.trim();
        const isReactivating = reactivatingId === member.id;
        const term = member._termNote;
        const reasonLine = term && term.observation_text ? term.observation_text.split("\n")[0] : "";
        return (
          <Card key={member.id} style={{ border:`1px solid ${T.slate200}`, background:T.slate50, opacity:0.95 }}>
            <div style={{ display:"flex", alignItems:"center", gap:14 }}>
              <div style={{ width:48, height:48, borderRadius:12, background:T.slate200, display:"flex", alignItems:"center", justifyContent:"center", fontSize:16, fontWeight:700, color:T.slate500, flexShrink:0 }}>
                {(member.first_name?.[0] || "?")}{(member.last_name?.[0] || "")}
              </div>
              <div style={{ flex:1 }}>
                <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:4, flexWrap:"wrap" }}>
                  <span style={{ fontSize:14, fontWeight:700, color:T.slate900, textDecoration:"line-through" }}>{member.first_name} {member.last_name}</span>
                  <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.redLt, color:"#991B1B" }}>
                    Terminated · {member.end_date || (member.archived_at ? member.archived_at.slice(0,10) : "date unknown")}
                  </span>
                </div>
                <div style={{ fontSize:12, color:T.slate500 }}>
                  {member.role || "—"}{member.role_level ? ` · ${member.role_level}` : ""} · {member.employment_type || "—"} · Started {member.start_date || "—"}
                </div>
                {reasonLine && (
                  <div style={{ fontSize:11, color:T.slate600, marginTop:4 }}>{reasonLine}</div>
                )}
              </div>
              <div style={{ flexShrink:0 }}>
                <button
                  onClick={() => { setReactivateError(""); setReactivateNote(""); setReactivatingId(isReactivating ? null : member.id); }}
                  style={{ padding:"6px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.green, border:"none", borderRadius:7, cursor:"pointer" }}>
                  {isReactivating ? "Cancel" : "Reactivate"}
                </button>
              </div>
            </div>

            {isReactivating && (
              <div style={{ marginTop:14, paddingTop:14, borderTop:`2px solid ${T.green}` }}>
                <div style={{ fontSize:12, fontWeight:700, color:T.slate900, marginBottom:6 }}>
                  Reactivate {expectedName}?
                </div>
                <div style={{ fontSize:11, color:T.slate600, marginBottom:10, lineHeight:1.55 }}>
                  Sets the team row back to active, clears the end date and archived stamp, and restores the linked user login if one exists. Cancels any open offboarding follow-up task. Writes a reactivation audit note and marks the prior termination note as resolved.
                </div>
                <div style={{ marginBottom:10 }}>
                  <label style={labelStyle}>Reason / context (optional)</label>
                  <textarea
                    style={{ ...inputStyle, resize:"vertical", minHeight:50, fontFamily:"inherit", lineHeight:1.5 }}
                    rows={2}
                    value={reactivateNote}
                    onChange={e => setReactivateNote(e.target.value)}
                    placeholder="e.g. Rehire after 6-month break · Termination was logged in error · Returning from leave"
                  />
                </div>
                {reactivateError && (
                  <div style={{ fontSize:11, color:"#991B1B", background:T.redLt, border:`1px solid #FECACA`, borderRadius:6, padding:"7px 10px", marginBottom:10 }}>
                    {reactivateError}
                  </div>
                )}
                <div style={{ display:"flex", gap:8, justifyContent:"flex-end" }}>
                  <button onClick={() => setReactivatingId(null)} disabled={reactivating} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate700, background:T.slate100, border:"none", borderRadius:7, cursor:reactivating?"not-allowed":"pointer" }}>Cancel</button>
                  <button
                    onClick={() => reactivateMember(member, reactivateNote)}
                    disabled={reactivating}
                    style={{ padding:"7px 16px", fontSize:11, fontWeight:700, color:T.white, background:reactivating?T.slate400:T.green, border:"none", borderRadius:7, cursor:reactivating?"not-allowed":"pointer" }}>
                    {reactivating ? "Reactivating…" : "Confirm Reactivate"}
                  </button>
                </div>
              </div>
            )}
          </Card>
        );
      })}

      {/* ============== ACTIVE VIEW (existing card list) ============== */}
      {view === "active" && mergedActive.filter(s => s.is_active && !terminatedIds.has(s.id)).map(raw => {
        // Merge any saved override on top of the loaded row.
        const member = overrides[raw.id] ? { ...raw, ...overrides[raw.id] } : raw;
        const isExpanded = expanded === member.id;
        const isEditing = editingId === member.id;
        return (
          <Card key={member.id} style={{ border:`1px solid ${isExpanded?T.blue:T.slate200}` }}>
            <div style={{ display:"flex", alignItems:"center", gap:14, cursor:"pointer" }} onClick={() => { if (!isEditing) setExpanded(isExpanded?null:member.id); }}>
              {/* Avatar */}
              <div style={{ width:48, height:48, borderRadius:12, background:hasAnyLicense(member)?T.slate900:T.slate200, display:"flex", alignItems:"center", justifyContent:"center", fontSize:16, fontWeight:700, color:hasAnyLicense(member)?T.white:T.slate500, flexShrink:0 }}>
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
                    <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.slate100, color:T.slate500 }}>Unlicensed</span>
                  )}
                  {member.compliance_flag && (
                    <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.amberLt, color:"#92400E" }}>⚠ CPA Flag</span>
                  )}
                </div>
                <div style={{ fontSize:12, color:T.slate500 }}>
                  {member.role || "-"}{member.role_level ? ` · ${member.role_level}` : ""} · {member.employment_type === "w2" ? "W-2 Employee" : member.employment_type === "family" ? "Family Employee (W-2)" : member.employment_type === "1099" ? "1099 Contractor" : (member.employment_type || "Employee")} · Since {member.start_date || "-"}
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
                    { label:"Personal Email", value:member.email_personal||"—" },
                    { label:"SF Email",       value:member.email_sf||"—" },
                    { label:"Personal Phone", value:member.phone_personal||"—" },
                    { label:"Phone Ext",      value:member.phone_extension||"—" },
                    { label:"Licensed States", value:(member.license_states || []).length>0?(member.license_states || []).join(", "):"None" },
                    { label:"Start Date",     value:member.start_date||"—" },
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
                    style={{ padding:"6px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" }}>
                    ✏️ Edit
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); startTerminate(member); }}
                    title="Document and execute end of employment. Deactivates linked user login."
                    style={{ padding:"6px 14px", fontSize:11, fontWeight:600, color:T.red, background:T.white, border:`1px solid ${T.red}`, borderRadius:7, cursor:"pointer", marginLeft:"auto" }}>
                    End Employment…
                  </button>
                  
                </div>
              </div>
            )}

            {terminatingId === member.id && (
              <div style={{ marginTop:14, paddingTop:14, borderTop:`2px solid ${T.red}` }} onClick={(e) => e.stopPropagation()}>
                <div style={{ fontSize:12, fontWeight:700, color:T.red, marginBottom:6, textTransform:"uppercase", letterSpacing:"0.04em" }}>
                  ⚠ End Employment — {member.first_name} {member.last_name}
                </div>
                <div style={{ fontSize:11, color:T.slate600, marginBottom:12, lineHeight:1.55 }}>
                  This is the documented record of the termination decision (core principle 500). It archives the team row, deactivates the linked user login, strips the person from the Team List page, marks them excluded from Telegram check-ins, kicks them from the team Telegram group, and emails the termination notice (with the AAO checklist pre-filled) to Peter's State Farm address.
                </div>
                <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(200px, 1fr))", gap:10, marginBottom:10 }}>
                  <div>
                    <label style={labelStyle}>Reason category *</label>
                    <select style={inputStyle} value={termForm.reason_category || ""} onChange={e=>setTermForm({...termForm, reason_category:e.target.value})}>
                      <option value="">— select —</option>
                      <option value="ethics_breach">Ethics breach (immediate)</option>
                      <option value="pip_not_met">Signed PIP not met</option>
                      <option value="resignation">Resignation (voluntary)</option>
                      <option value="mutual_departure">Mutual departure</option>
                      <option value="other">Other</option>
                    </select>
                  </div>
                  <div>
                    <label style={labelStyle}>End date *</label>
                    <input style={inputStyle} type="date" value={termForm.end_date || ""} onChange={e=>setTermForm({...termForm, end_date:e.target.value})} />
                  </div>
                  <div>
                    <label style={labelStyle}>Final paycheck date (optional)</label>
                    <input style={inputStyle} type="date" value={termForm.final_paycheck_date || ""} onChange={e=>setTermForm({...termForm, final_paycheck_date:e.target.value})} />
                  </div>
                </div>
                <div style={{ marginBottom:10 }}>
                  <label style={labelStyle}>Notes / reasoning * (the documented why — principle 500)</label>
                  <textarea
                    style={{ ...inputStyle, resize:"vertical", minHeight:70, fontFamily:"inherit", lineHeight:1.5 }}
                    rows={3}
                    value={termForm.notes || ""}
                    onChange={e=>setTermForm({...termForm, notes:e.target.value})}
                    placeholder="For ethics breach: what was the breach, when discovered. For PIP not met: which signed PIP, which metrics missed. For resignation: notice given, reason if known. For mutual: what was agreed."
                  />
                </div>
                <div style={{ marginBottom:12 }}>
                  <label style={labelStyle}>Type full name to confirm: <strong>{member.first_name} {member.last_name}</strong></label>
                  <input style={inputStyle} value={termForm.confirm_name || ""} onChange={e=>setTermForm({...termForm, confirm_name:e.target.value})} placeholder={`${member.first_name || ""} ${member.last_name || ""}`.trim()} />
                </div>

                {termError && (
                  <div style={{ fontSize:11, color:"#991B1B", background:T.redLt, border:`1px solid #FECACA`, borderRadius:6, padding:"7px 10px", marginBottom:10 }}>
                    {termError}
                  </div>
                )}

                <div style={{ display:"flex", gap:8, justifyContent:"flex-end" }}>
                  <button onClick={cancelTerminate} disabled={terminating} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate700, background:T.slate100, border:"none", borderRadius:7, cursor:terminating?"not-allowed":"pointer" }}>Cancel</button>
                  <button
                    onClick={() => terminateMember(member)}
                    disabled={terminating}
                    style={{ padding:"7px 16px", fontSize:11, fontWeight:700, color:T.white, background:terminating?T.slate400:T.red, border:"none", borderRadius:7, cursor:terminating?"not-allowed":"pointer" }}>
                    {terminating ? "Ending Employment…" : "End Employment"}
                  </button>
                </div>
              </div>
            )}

            {isEditing && (
              <div style={{ marginTop:14, paddingTop:14, borderTop:`1px solid ${T.blue}` }} onClick={(e) => e.stopPropagation()}>
                <div style={{ fontSize:12, fontWeight:700, color:T.slate900, marginBottom:12 }}>Edit {member.first_name} {member.last_name}</div>
                <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))", gap:10, marginBottom:10 }}>
                  <div><label style={labelStyle}>First name *</label><input style={inputStyle} value={form.first_name} onChange={e=>setForm({...form, first_name:e.target.value})} /></div>
                  <div><label style={labelStyle}>Last name *</label><input style={inputStyle} value={form.last_name} onChange={e=>setForm({...form, last_name:e.target.value})} /></div>
                  <div><label style={labelStyle}>Role (function)</label>
                    <select style={inputStyle} value={form.role} onChange={e=>setForm({...form, role:e.target.value})}>
                      <option value="">—</option>
                      <option value="Acquisition">Acquisition</option>
                      <option value="Inside Sales">Inside Sales</option>
                      <option value="Reception">Reception</option>
                      <option value="Escalation">Escalation</option>
                    </select>
                  </div>
                  <div><label style={labelStyle}>Role category</label>
                    <select style={inputStyle} value={form.role_category || ""} onChange={e=>setForm({...form, role_category:e.target.value})}>
                      <option value="">—</option>
                      <option value="Sales">Sales</option>
                      <option value="Retention">Retention</option>
                    </select>
                  </div>
                  <div><label style={labelStyle}>Role level (position)</label>
                    <select style={inputStyle} value={form.role_level || ""} onChange={e=>setForm({...form, role_level:e.target.value})}>
                      <option value="">—</option>
                      <option value="Owner">Owner</option>
                      <option value="Office Manager">Office Manager</option>
                      <option value="Unit Manager">Unit Manager</option>
                      <option value="Section Manager">Section Manager</option>
                      <option value="Account Manager">Account Manager</option>
                      <option value="Account Associate">Account Associate</option>
                    </select>
                  </div>
                  <div><label style={labelStyle}>Team category</label>
                    <select style={inputStyle} value={form.category || "agency"} onChange={e=>setForm({...form, category:e.target.value})}>
                      <option value="agency">Agency team</option>
                      <option value="admin">Admin team</option>
                    </select>
                  </div>
                  <div><label style={labelStyle}>Employment type</label><input style={inputStyle} value={form.employment_type} onChange={e=>setForm({...form, employment_type:e.target.value})} placeholder="Full Time / 1099 / family" /></div>
                  <div><label style={labelStyle}>Personal email</label><input style={inputStyle} value={form.email_personal} onChange={e=>setForm({...form, email_personal:e.target.value})} placeholder="name@gmail.com" /></div>
                  <div><label style={labelStyle}>SF email</label><input style={inputStyle} value={form.email_sf} onChange={e=>setForm({...form, email_sf:e.target.value})} placeholder="name@statefarm.com" /></div>
                  <div><label style={labelStyle}>Personal phone</label><input style={inputStyle} value={form.phone_personal} onChange={e=>setForm({...form, phone_personal:e.target.value})} placeholder="(210) 555-0100" /></div>
                  <div><label style={labelStyle}>Phone extension</label><input style={inputStyle} value={form.phone_extension} onChange={e=>setForm({...form, phone_extension:e.target.value})} placeholder="e.g. 101" /></div>
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
                  <button onClick={() => saveEdit(member.id)} disabled={saving} style={{ padding:"7px 16px", fontSize:11, fontWeight:600, color:T.white, background:saving?T.slate400:T.slate900, border:"none", borderRadius:7, cursor:saving?"not-allowed":"pointer" }}>
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
          <Card key={record.team_member_id}>
            <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:14 }}>
              <div>
                <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{record.team_member_name}</div>
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

  const { smvcRate, blendedRate, lapseRate,
          priorRenewals, currentRenewals, producerRows,
          ratesAreDefaults, aipp, aippTracking, hasProductionData } = roi;

  const noProducers = producerRows.length === 0;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>

      {/* ─── AIPP PROJECTION CARD ─────────────────────────────────── */}
      <AippProjectionCard aipp={aipp} aippTracking={aippTracking} hasProductionData={hasProductionData} />

      {ratesAreDefaults && (
        <div style={{ padding: "9px 13px", background: T.amberLt, border: `1px solid ${T.amber}`, borderRadius: 8, fontSize: 11.5, color: "#92400E", lineHeight: 1.5 }}>
          <strong>Estimated rates in use.</strong> SMVC and blended rates below are placeholder defaults until your actual AA05 numbers are confirmed. Update agency.smvc_rate to lock these in. (Lapse rate is always computed live from your book.)
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
              Annualized YTD: lost policies ÷ starting in-force, dollar-weighted across Auto / Fire / Life
            </div>
          </div>
          
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
              Lapse Rate (YTD annualized)
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
      {!noProducers && producerRows.map(p => <ProducerROICard key={p.team_member_id} producer={p} smvcRate={smvcRate} blendedRate={blendedRate} lapseRate={lapseRate} />)}

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
            <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{c.team_member_name}</div>
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

        
      </Card>
    ))}
  </div>
);

// ─── Main HR Module ───────────────────────────────────────────

// ─── Book Assignments Section ────────────────────────────────
// Snapshot-based alphabet split for service-book assignment.
// One row per (snapshot_date, letter_bucket) in book_alpha_split.
const CANONICAL_BUCKETS = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X-Z"];

const producerLabel = (m) => {
  if (!m) return "Unassigned";
  const nick = m.nickname || m.first_name || "";
  return (nick + " " + (m.last_name || "")).trim();
};

// Shared styles for editor + buttons (defined once near component)
const bookInputStyle = { padding:"5px 8px", fontSize:12, border:`1px solid ${T.slate200}`, borderRadius:6, background:T.white, color:T.slate800 };
const bookBtnPrimary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" };
const bookBtnSecondary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.slate700, background:T.white, border:`1px solid ${T.slate200}`, borderRadius:7, cursor:"pointer" };
const bookBtnDanger = { padding:"6px 12px", fontSize:11, fontWeight:600, color:T.red, background:T.white, border:`1px solid ${T.redLt}`, borderRadius:7, cursor:"pointer" };

const BucketEditor = ({ buckets, draft, setDraft, teamList }) => {
  const update = (bucket, field, value) => {
    setDraft(prev => ({ ...prev, [bucket]: { ...(prev[bucket] || {}), [field]: value } }));
  };
  return (
    <Card>
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(240px, 1fr))", gap:8 }}>
        {(buckets || []).map(b => {
          const v = draft?.[b] || { team_member_id: null, account_count: 0 };
          return (
            <div key={b} style={{ border:`1px solid ${T.slate200}`, borderRadius:8, padding:"8px 10px" }}>
              <div style={{ fontSize:12, fontWeight:700, color:T.slate900, marginBottom:6 }}>{b}</div>
              <select
                value={v.team_member_id || ""}
                onChange={e => update(b, "team_member_id", e.target.value || null)}
                style={{ ...bookInputStyle, width:"100%", marginBottom:6 }}
              >
                <option value="">— Unassigned —</option>
                {(teamList || []).map(t => (
                  <option key={t.id} value={t.id}>{producerLabel(t)}</option>
                ))}
              </select>
              <input
                type="number"
                min="0"
                value={v.account_count ?? 0}
                onChange={e => update(b, "account_count", e.target.value)}
                style={{ ...bookInputStyle, width:"100%" }}
              />
            </div>
          );
        })}
      </div>
    </Card>
  );
};

const BookAssignmentsSection = () => {
  const [allRows, setAllRows] = useState([]);
  const [teamList, setTeamList] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedDate, setSelectedDate] = useState(null);
  const [editing, setEditing] = useState(false);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState({});
  const [newDate, setNewDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [saving, setSaving] = useState(false);

  const load = async () => {
    if (!supabase || !AGENCY_ID) { setLoading(false); return; }
    setLoading(true);
    setError(null);
    const [rowsRes, teamRes] = await Promise.all([
      supabase
        .from("book_alpha_split")
        .select("id, snapshot_date, letter_bucket, team_member_id, account_count, notes")
        .eq("agency_id", AGENCY_ID)
        .order("snapshot_date", { ascending: false }),
      supabase
        .from("team")
        .select("id, first_name, last_name, nickname")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true)
        .eq("is_admin_backoffice", false)
        .order("last_name"),
    ]);
    if (rowsRes?.error || teamRes?.error) {
      setError(rowsRes?.error?.message || teamRes?.error?.message);
      setLoading(false);
      return;
    }
    const rows = Array.isArray(rowsRes?.data) ? rowsRes.data : [];
    const team = Array.isArray(teamRes?.data) ? teamRes.data : [];
    setAllRows(rows);
    setTeamList(team);
    setSelectedDate(prev => prev || (rows.length ? rows[0].snapshot_date : null));
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const allDates = useMemo(() => {
    const set = new Set((allRows || []).map(r => r.snapshot_date));
    return Array.from(set).sort().reverse();
  }, [allRows]);

  const currentRows = useMemo(() => {
    if (!selectedDate) return [];
    return (allRows || []).filter(r => r.snapshot_date === selectedDate);
  }, [allRows, selectedDate]);

  const allBuckets = useMemo(() => {
    const extra = (currentRows || [])
      .map(r => r.letter_bucket)
      .filter(b => !CANONICAL_BUCKETS.includes(b));
    return [...CANONICAL_BUCKETS, ...Array.from(new Set(extra))];
  }, [currentRows]);

  const priorDate = useMemo(() => {
    const i = allDates.indexOf(selectedDate);
    return i >= 0 && i < allDates.length - 1 ? allDates[i + 1] : null;
  }, [allDates, selectedDate]);

  const priorRows = useMemo(() => {
    if (!priorDate) return [];
    return (allRows || []).filter(r => r.snapshot_date === priorDate);
  }, [allRows, priorDate]);

  const findRow = (rows, bucket) => (rows || []).find(r => r.letter_bucket === bucket);
  const memberById = (id) => (teamList || []).find(t => t.id === id);

  const rollup = useMemo(() => {
    const map = new Map();
    (currentRows || []).forEach(r => {
      const key = r.team_member_id || "_unassigned";
      const cur = map.get(key) || { team_member_id: r.team_member_id, total: 0, letters: [] };
      cur.total += Number(r.account_count) || 0;
      cur.letters.push(r.letter_bucket);
      map.set(key, cur);
    });
    return Array.from(map.values()).sort((a, b) => b.total - a.total);
  }, [currentRows]);

  const grandTotal = useMemo(() => rollup.reduce((s, r) => s + r.total, 0), [rollup]);

  const buildDraftFromRows = (rows) => {
    const d = {};
    allBuckets.forEach(b => {
      const r = findRow(rows, b);
      d[b] = { team_member_id: r?.team_member_id || null, account_count: r?.account_count ?? 0 };
    });
    return d;
  };

  const startEdit = () => { setDraft(buildDraftFromRows(currentRows)); setEditing(true); };
  const cancelEdit = () => { setEditing(false); setDraft({}); };

  const saveEdit = async () => {
    setSaving(true);
    const upserts = Object.entries(draft).map(([bucket, v]) => ({
      agency_id: AGENCY_ID,
      snapshot_date: selectedDate,
      letter_bucket: bucket,
      team_member_id: v.team_member_id || null,
      account_count: Number(v.account_count) || 0,
    }));
    const { error: upErr } = await supabase
      .from("book_alpha_split")
      .upsert(upserts, { onConflict: "agency_id,snapshot_date,letter_bucket" });
    setSaving(false);
    if (upErr) { setError(upErr.message); return; }
    setEditing(false);
    setDraft({});
    await load();
  };

  const startAdd = () => {
    setDraft(buildDraftFromRows(currentRows));
    setNewDate(new Date().toISOString().slice(0, 10));
    setAdding(true);
  };
  const cancelAdd = () => { setAdding(false); setDraft({}); };

  const saveAdd = async () => {
    if (!newDate) return;
    setSaving(true);
    const upserts = Object.entries(draft).map(([bucket, v]) => ({
      agency_id: AGENCY_ID,
      snapshot_date: newDate,
      letter_bucket: bucket,
      team_member_id: v.team_member_id || null,
      account_count: Number(v.account_count) || 0,
    }));
    const { error: upErr } = await supabase
      .from("book_alpha_split")
      .upsert(upserts, { onConflict: "agency_id,snapshot_date,letter_bucket" });
    setSaving(false);
    if (upErr) { setError(upErr.message); return; }
    setAdding(false);
    setDraft({});
    setSelectedDate(newDate);
    await load();
  };

  const deleteSnapshot = async () => {
    if (!selectedDate) return;
    if (!window.confirm(`Delete the ${selectedDate} snapshot entirely? This cannot be undone.`)) return;
    setSaving(true);
    const { error: delErr } = await supabase
      .from("book_alpha_split")
      .delete()
      .eq("agency_id", AGENCY_ID)
      .eq("snapshot_date", selectedDate);
    setSaving(false);
    if (delErr) { setError(delErr.message); return; }
    setSelectedDate(null);
    await load();
  };

  if (loading) return <Card><div style={{ color:T.slate500, fontSize:13 }}>Loading book assignments…</div></Card>;

  if ((allRows || []).length === 0 && !adding) {
    return (
      <Card>
        <div style={{ fontSize:14, fontWeight:600, color:T.slate800, marginBottom:8 }}>No book snapshots yet</div>
        <div style={{ fontSize:12, color:T.slate500, marginBottom:14 }}>
          Capture your first alphabet split — which producer services which letters of the alphabet.
        </div>
        <button onClick={startAdd} style={bookBtnPrimary}>Add first snapshot</button>
      </Card>
    );
  }

  if (adding) {
    return (
      <div>
        <Card style={{ marginBottom:12 }}>
          <div style={{ display:"flex", flexWrap:"wrap", gap:10, alignItems:"center", justifyContent:"space-between" }}>
            <div>
              <div style={{ fontSize:14, fontWeight:600, color:T.slate800 }}>New Book Snapshot</div>
              <div style={{ fontSize:11, color:T.slate500 }}>
                Pre-filled from {selectedDate || "blank"} · adjust producers or counts as needed
              </div>
            </div>
            <div style={{ display:"flex", gap:8, alignItems:"center" }}>
              <label style={{ fontSize:11, color:T.slate500 }}>Date</label>
              <input type="date" value={newDate} onChange={e => setNewDate(e.target.value)} style={bookInputStyle} />
              <button onClick={cancelAdd} style={bookBtnSecondary} disabled={saving}>Cancel</button>
              <button onClick={saveAdd} style={bookBtnPrimary} disabled={saving || !newDate}>
                {saving ? "Saving…" : "Save snapshot"}
              </button>
            </div>
          </div>
        </Card>
        <BucketEditor buckets={allBuckets} draft={draft} setDraft={setDraft} teamList={teamList} />
        {error && (
          <div style={{ marginTop:10, padding:"8px 12px", background:T.redLt, color:T.red, borderRadius:8, fontSize:12 }}>
            {error}
          </div>
        )}
      </div>
    );
  }

  return (
    <div>
      <Card style={{ marginBottom:12 }}>
        <div style={{ display:"flex", flexWrap:"wrap", gap:10, alignItems:"center", justifyContent:"space-between" }}>
          <div style={{ display:"flex", flexWrap:"wrap", alignItems:"center", gap:10 }}>
            <div style={{ fontSize:14, fontWeight:600, color:T.slate800 }}>Service Book Assignments</div>
            <select
              value={selectedDate || ""}
              onChange={e => setSelectedDate(e.target.value)}
              disabled={editing}
              style={bookInputStyle}
            >
              {allDates.map(d => <option key={d} value={d}>{d}</option>)}
            </select>
            <div style={{ fontSize:11, color:T.slate500 }}>
              {allDates.length} snapshot{allDates.length === 1 ? "" : "s"}{priorDate ? ` · prior: ${priorDate}` : " · no prior snapshot"}
            </div>
          </div>
          <div style={{ display:"flex", gap:8 }}>
            {!editing && <button onClick={startEdit} style={bookBtnSecondary}>Edit this snapshot</button>}
            {!editing && <button onClick={startAdd} style={bookBtnPrimary}>Add new snapshot</button>}
            {editing && <button onClick={cancelEdit} style={bookBtnSecondary} disabled={saving}>Cancel</button>}
            {editing && <button onClick={saveEdit} style={bookBtnPrimary} disabled={saving}>{saving ? "Saving…" : "Save"}</button>}
          </div>
        </div>
      </Card>

      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(200px, 1fr))", gap:10, marginBottom:12 }}>
        {rollup.map((r, i) => {
          const m = memberById(r.team_member_id);
          const priorTotal = (priorRows || [])
            .filter(p => p.team_member_id === r.team_member_id)
            .reduce((s, p) => s + (Number(p.account_count) || 0), 0);
          const delta = priorDate ? r.total - priorTotal : null;
          return (
            <Card key={r.team_member_id || `na-${i}`} style={{ padding:"12px 14px" }}>
              <div style={{ fontSize:11, color:T.slate500 }}>{producerLabel(m)}</div>
              <div style={{ fontSize:22, fontWeight:700, color:T.slate900, lineHeight:1.1, marginTop:2 }}>
                {Number(r.total || 0).toLocaleString()}
              </div>
              <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>
                {r.letters.length} letter{r.letters.length === 1 ? "" : "s"} · {r.letters.join(", ")}
              </div>
              {delta !== null && (
                <div style={{ fontSize:11, color: delta > 0 ? T.green : delta < 0 ? T.red : T.slate500, marginTop:4 }}>
                  {delta > 0 ? "▲" : delta < 0 ? "▼" : "·"} {Math.abs(delta).toLocaleString()} vs {priorDate}
                </div>
              )}
            </Card>
          );
        })}
        <Card style={{ padding:"12px 14px", background:T.slate50 }}>
          <div style={{ fontSize:11, color:T.slate500 }}>Total accounts</div>
          <div style={{ fontSize:22, fontWeight:700, color:T.slate900, lineHeight:1.1, marginTop:2 }}>
            {Number(grandTotal || 0).toLocaleString()}
          </div>
          <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>{currentRows.length} buckets</div>
        </Card>
      </div>

      {editing ? (
        <BucketEditor buckets={allBuckets} draft={draft} setDraft={setDraft} teamList={teamList} />
      ) : (
        <Card>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(140px, 1fr))", gap:8 }}>
            {allBuckets.map(b => {
              const r = findRow(currentRows, b);
              const m = memberById(r?.team_member_id);
              const p = findRow(priorRows, b);
              const delta = priorDate && p ? (Number(r?.account_count) || 0) - (Number(p.account_count) || 0) : null;
              return (
                <div key={b} style={{ border:`1px solid ${T.slate200}`, borderRadius:8, padding:"8px 10px", background:T.white }}>
                  <div style={{ display:"flex", justifyContent:"space-between", alignItems:"baseline" }}>
                    <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>{b}</div>
                    <div style={{ fontSize:15, fontWeight:600, color:T.slate800 }}>
                      {Number(r?.account_count || 0).toLocaleString()}
                    </div>
                  </div>
                  <div style={{ fontSize:10, color: m ? T.slate600 : T.slate400, marginTop:2 }}>
                    {m ? producerLabel(m) : "Unassigned"}
                  </div>
                  {delta !== null && delta !== 0 && (
                    <div style={{ fontSize:9, color: delta > 0 ? T.green : T.red, marginTop:1 }}>
                      {delta > 0 ? "+" : ""}{delta} vs {priorDate}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </Card>
      )}

      {!editing && allDates.length > 0 && (
        <div style={{ marginTop:16, textAlign:"right" }}>
          <button onClick={deleteSnapshot} style={bookBtnDanger} disabled={saving}>Delete this snapshot</button>
        </div>
      )}

      {error && (
        <div style={{ marginTop:10, padding:"8px 12px", background:T.redLt, color:T.red, borderRadius:8, fontSize:12 }}>
          {error}
        </div>
      )}
    </div>
  );
};

// ─── Section: Retention Budget ───────────────────────────────
const RetentionBudgetSection = () => {
  const money = (n) => "$" + Math.round(Number(n) || 0).toLocaleString();
  const pct = (n, dec = 3) => ((Number(n) || 0) * 100).toFixed(dec) + "%";

  const [state, setState] = useState({
    loading: true,
    error: null,
    current: null,
    upcoming: [],
    agency: null,
    snapshot: null,
    receptionTeam: [],
    scorecardActuals: null,
    smvcResult: null,
  });

  useEffect(() => {
    if (!supabase || !AGENCY_ID) return;
    let cancelled = false;
    (async () => {
      try {
        const today = new Date().toISOString().slice(0, 10);
        const [currentRes, upcomingRes, agencyRes, snapshotRes, otSnapRes, teamRes] = await Promise.all([
          supabase.from("v_retention_budget_current").select("*").maybeSingle(),
          supabase.from("retention_budget_schedule")
            .select("week_end_date, multiplier, phase")
            .eq("agency_id", AGENCY_ID)
            .gte("week_end_date", today)
            .order("week_end_date", { ascending: true })
            .limit(8),
          supabase.from("agency")
            .select("id, payroll_burden_multiplier")
            .eq("id", AGENCY_ID)
            .maybeSingle(),
          supabase.from("agency_snapshot")
            .select("snapshot_date, auto_premium, fire_premium, life_premium, auto_pif, fire_pif")
            .eq("agency_id", AGENCY_ID)
            .order("snapshot_date", { ascending: false })
            .limit(1)
            .maybeSingle(),
          // YTD on-time SMVC inputs — most recent agency_snapshot row WITH YTD data.
          supabase.from("agency_snapshot")
            .select("*")
            .eq("agency_id", AGENCY_ID)
            .not("auto_new_ytd", "is", null)
            .order("snapshot_date", { ascending: false })
            .limit(1)
            .maybeSingle(),
          supabase.from("team")
            .select("id, first_name, pay_type, pay_rate, pay_frequency")
            .eq("agency_id", AGENCY_ID)
            .eq("is_active", true)
            .eq("role", "Reception"),
        ]);
        if (cancelled) return;
        const team = Array.isArray(teamRes?.data) ? teamRes.data : [];
        const teamIds = team.map(t => t?.id).filter(Boolean);

        // Trailing ~13 weeks of payroll for the Reception team
        let payrollByPerson = {};
        if (teamIds.length > 0) {
          const cutoff = new Date(Date.now() - 91 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
          const payrollRes = await supabase
            .from("payroll_detail")
            .select("team_member_id, gross_pay, payroll_runs!inner(pay_period_start, pay_period_end)")
            .eq("business_entity_id", BUSINESS_ENTITY_ID)
            .in("team_member_id", teamIds)
            .gte("payroll_runs.pay_period_end", cutoff);
          (Array.isArray(payrollRes?.data) ? payrollRes.data : []).forEach(row => {
            const pid = row?.team_member_id;
            if (!pid) return;
            const start = row?.payroll_runs?.pay_period_start;
            const end = row?.payroll_runs?.pay_period_end;
            if (!start || !end) return;
            const days = (new Date(end) - new Date(start)) / 86400000 + 1;
            const bucket = payrollByPerson[pid] || { gross: 0, days: 0 };
            bucket.gross += Number(row?.gross_pay) || 0;
            bucket.days += Math.max(1, days);
            payrollByPerson[pid] = bucket;
          });
        }

        // SMVC inputs derive from agency_snapshot YTD raw values — never stored "current" values.
        // Per the compensation_data_freshness principle, calculation happens at runtime from source data.
        const programYear = new Date().getFullYear();
        const otSnap = otSnapRes?.data;
        const otAsOf = otSnap?.snapshot_date || null;
        const autoPifGain = otSnap ? ((Number(otSnap.auto_new_ytd) || 0) - (Number(otSnap.auto_lost_ytd) || 0)) : null;
        const firePifGain = otSnap ? ((Number(otSnap.fire_new_ytd) || 0) - (Number(otSnap.fire_lost_ytd) || 0)) : null;
        const fsCredits   = otSnap ? (Number(otSnap.life_paid_for_premium_ytd) || 0) : null;
        const ipsActivity = otSnap ? (Number(otSnap.ips_new_money_ytd) || 0) : null;

        const snap = snapshotRes?.data;
        const pcProductionActual = (Number(snap?.auto_pif) || 0) + (Number(snap?.fire_pif) || 0);

        let smvcResult = null;
        try {
          const { data: rpcData, error: rpcErr } = await supabase.rpc("compute_on_time_smvc_with_better_of", {
            p_agency_id: AGENCY_ID,
            p_program_year: programYear,
            p_pc_production_actual: pcProductionActual,
            p_auto_pif_gain: autoPifGain,
            p_fire_pif_gain: firePifGain,
            p_fs_credits: fsCredits,
            p_ips_activity: ipsActivity,
          });
          if (!rpcErr) smvcResult = rpcData;
        } catch (rpcCatch) {
          // Leave smvcResult null; UI will show "awaiting input" state
        }

        if (cancelled) return;
        setState({
          loading: false,
          error: null,
          current: currentRes?.data ?? null,
          upcoming: Array.isArray(upcomingRes?.data) ? upcomingRes.data : [],
          agency: agencyRes?.data ?? null,
          snapshot: snapshotRes?.data ?? null,
          receptionTeam: team,
          payrollByPerson,
          scorecardActuals: { auto_pif_gain: autoPifGain, fire_pif_gain: firePifGain, fs_credits: fsCredits, ips_activity: ipsActivity, as_of_date: otAsOf },
          smvcResult,
        });
        return;
      } catch (e) {
        if (!cancelled) setState((s) => ({ ...s, loading: false, error: e?.message || String(e) }));
      }
    })();
    return () => { cancelled = true; };
  }, []);

  if (state.loading) {
    return <Card><div style={{ padding:12, color:T.slate500, fontSize:12 }}>Loading retention budget…</div></Card>;
  }
  if (state.error) {
    return <Card><div style={{ padding:12, color:T.red, fontSize:12 }}>Retention budget error: {state.error}</div></Card>;
  }

  const scheduledFloor = Number(state.current?.multiplier) || 0;
  // On-time SMVC computed at runtime — never stored as a "current" value (operational_rule).
  const smvc           = Number(state.smvcResult?.applied_smvc_decimal) || 0;
  const smvcBandsComplete = state.smvcResult?.bands_complete === true;
  const smvcSource     = state.smvcResult?.better_of_source || null;
  const burdenMult     = Number(state.agency?.payroll_burden_multiplier) || 1.15;

  const smvcAdd        = 0.21 * smvc;
  const effective      = scheduledFloor + smvcAdd;

  const autoPrem       = Number(state.snapshot?.auto_premium) || 0;
  const firePrem       = Number(state.snapshot?.fire_premium) || 0;
  const lifePrem       = Number(state.snapshot?.life_premium) || 0;
  const aflPremium     = autoPrem + firePrem + lifePrem;

  const annualBudget   = effective * aflPremium;
  const weeklyBudget   = annualBudget / 52;

  // Reception team annual wages — trailing ~13 weeks of payroll annualized.
  // Falls back to scheduled-rate × 40 × 52 if a member has no payroll history yet.
  const teamForWages = (state.receptionTeam || []).filter(
    (t) => (t?.first_name || "").toLowerCase() !== "test"
  );
  const wagesByPerson = teamForWages.map((t) => {
    const bucket = (state.payrollByPerson || {})[t?.id];
    if (bucket && bucket.days > 0) {
      const annualized = (bucket.gross / bucket.days) * 365;
      return { name: t?.first_name, annualized, source: "payroll", days: bucket.days };
    }
    // Fallback for members with no payroll history yet
    const rate = Number(t?.pay_rate) || 0;
    let annualized = 0;
    if (t?.pay_type === "HOURLY") annualized = rate * 40 * 52;
    else if (t?.pay_type === "SALARY") {
      const freqMult = { weekly: 52, biweekly: 26, monthly: 12, annual: 1 }[t?.pay_frequency] || 52;
      annualized = rate * freqMult;
    }
    return { name: t?.first_name, annualized, source: "scheduled", days: 0 };
  });
  const annualWageRaw    = wagesByPerson.reduce((s, w) => s + (Number(w?.annualized) || 0), 0);
  const annualWageLoaded = annualWageRaw * burdenMult;

  // Breach signal fires on RAW wages (payroll burden is paid from agency overhead,
  // not from the retention budget — see persistent_memory operational_rule).
  const marginRaw     = annualBudget - annualWageRaw;
  const marginLoaded  = annualBudget - annualWageLoaded;
  const breachRaw     = annualBudget < annualWageRaw;
  const breachLoaded  = annualBudget < annualWageLoaded;

  const trajectory = (state.upcoming || []).slice(0, 8);
  const phaseLabel = state.current?.phase === "phase_1_aa05_stepdown" ? "Phase 1 (AA05 stepdown)" :
                     state.current?.phase === "phase_2_aa28_stepdown" ? "Phase 2 (AA28 stepdown)" :
                     state.current?.phase || "—";

  const askCtx =
    `My retention budget for the week ending ${state.current?.week_end_date} is ${money(annualBudget)}/yr ` +
    `(${money(weeklyBudget)}/wk). Scheduled floor ${pct(scheduledFloor)} plus SMVC modifier ${pct(smvcAdd)} ` +
    `= effective ${pct(effective)} on ${money(aflPremium)} A+F+L premium. ` +
    `Reception team annualized wages from payroll: ${money(annualWageRaw)}. ` +
    `Margin vs wages: ${money(marginRaw)}. Loaded cost (× ${burdenMult.toFixed(2)}): ${money(annualWageLoaded)}. ` +
    `Phase: ${phaseLabel}. Is the budget healthy this week?`;

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:16 }}>

      <Card style={{ borderLeft: `4px solid ${T.purple}` }}>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:10 }}>
          <div>
            <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>
              Retention Budget — Week ending {state.current?.week_end_date || "—"}
            </div>
            <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>
              {phaseLabel} · Schedule is a permanent ramp; current on-time SMVC adds to the floor each week.
            </div>
          </div>
          
        </div>

        <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(170px, 1fr))", gap:10 }}>
          <div style={{ background:T.purpleLt, padding:"10px 12px", borderRadius:8 }}>
            <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>Annual Budget</div>
            <div style={{ fontSize:18, fontWeight:700, color:T.slate900 }}>{money(annualBudget)}</div>
            <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>{money(weeklyBudget)} / wk</div>
          </div>
          <div style={{ background:T.slate50, padding:"10px 12px", borderRadius:8 }}>
            <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>Effective Multiplier</div>
            <div style={{ fontSize:18, fontWeight:700, color:T.slate900 }}>{pct(effective)}</div>
            <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>floor + 0.21 × SMVC</div>
          </div>
          <div style={{ background: breachRaw ? T.redLt : T.greenLt, padding:"10px 12px", borderRadius:8 }}>
            <div style={{ fontSize:10, color:T.slate500, marginBottom:4 }}>Margin vs Wages</div>
            <div style={{ fontSize:18, fontWeight:700, color: breachRaw ? "#991B1B" : "#065F46" }}>
              {breachRaw ? "−" : ""}{money(Math.abs(marginRaw))}
            </div>
            <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>
              {breachRaw ? "BUDGET BELOW WAGE COMMITMENT" : "above wage commitment"}
            </div>
          </div>
        </div>

        <div style={{ marginTop:12, padding:12, background:T.slate50, borderRadius:8 }}>
          <div style={{ fontSize:11, fontWeight:600, color:T.slate700, marginBottom:8 }}>Formula breakdown</div>
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width:"100%", fontSize:12, color:T.slate700 }}>
            <tbody>
              <tr>
                <td style={{ padding:"3px 0" }}>Scheduled floor (zero-SMVC)</td>
                <td style={{ textAlign:"right", fontFamily:"ui-monospace, monospace" }}>{pct(scheduledFloor)}</td>
              </tr>
              <tr>
                <td style={{ padding:"3px 0" }}>+ 0.21 × on-time SMVC ({pct(smvc, 2)})</td>
                <td style={{ textAlign:"right", fontFamily:"ui-monospace, monospace" }}>+ {pct(smvcAdd)}</td>
              </tr>
              <tr style={{ borderTop:`1px solid ${T.slate200}` }}>
                <td style={{ padding:"3px 0", fontWeight:600 }}>= Effective multiplier</td>
                <td style={{ textAlign:"right", fontFamily:"ui-monospace, monospace", fontWeight:600 }}>{pct(effective)}</td>
              </tr>
              <tr>
                <td style={{ padding:"3px 0" }}>× Auto + Fire + Life premium</td>
                <td style={{ textAlign:"right", fontFamily:"ui-monospace, monospace" }}>{money(aflPremium)}</td>
              </tr>
              <tr style={{ borderTop:`1px solid ${T.slate200}` }}>
                <td style={{ padding:"3px 0", fontWeight:600 }}>= Annual retention budget</td>
                <td style={{ textAlign:"right", fontFamily:"ui-monospace, monospace", fontWeight:600, color:T.purple }}>{money(annualBudget)}</td>
              </tr>
            </tbody>
          </table>
          </div>
          <div style={{ fontSize:10, color:T.slate500, marginTop:8 }}>
            Premium snapshot: {state.snapshot?.snapshot_date || "no snapshot on file"} — Auto {money(autoPrem)}, Fire {money(firePrem)}, Life {money(lifePrem)}. Health excluded by design.
          </div>
        </div>

        <div style={{ marginTop:12, padding:12, background: breachRaw ? T.redLt : T.greenLt, borderRadius:8 }}>
          <div style={{ fontSize:11, fontWeight:600, color: breachRaw ? "#991B1B" : "#065F46", marginBottom:6 }}>
            {breachRaw ? "⚠ BUDGET BREACH — body cut signal" : "Wage commitment"}
          </div>
          <div style={{ fontSize:12, color:T.slate700, lineHeight:1.6, marginBottom:8 }}>
            Reception team (active, non-test) annualized wages from trailing-13-week payroll:
            {" "}<strong>{money(annualWageRaw)}</strong>.{" "}
            {breachRaw
              ? <>Budget is short of wages by <strong>{money(Math.abs(marginRaw))}</strong> — body cut or rate intervention needed.</>
              : <>Budget is <strong>{money(marginRaw)}</strong> above wages — that is the room for service surge and bonus accruals.</>}
          </div>
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width:"100%", fontSize:11, color:T.slate600 }}>
            <thead>
              <tr style={{ color:T.slate500, fontSize:10, textTransform:"uppercase", letterSpacing:"0.04em" }}>
                <th style={{ textAlign:"left", padding:"4px 6px" }}>Person</th>
                <th style={{ textAlign:"right", padding:"4px 6px" }}>Annualized gross</th>
                <th style={{ textAlign:"left", padding:"4px 6px" }}>Source</th>
              </tr>
            </thead>
            <tbody>
              {wagesByPerson.map((w, idx) => (
                <tr key={(w?.name || "") + idx} style={{ borderTop:`1px solid ${T.slate100}` }}>
                  <td style={{ padding:"4px 6px" }}>{w?.name || "—"}</td>
                  <td style={{ padding:"4px 6px", textAlign:"right", fontFamily:"ui-monospace, monospace" }}>{money(w?.annualized)}</td>
                  <td style={{ padding:"4px 6px", color:T.slate500 }}>
                    {w?.source === "payroll" ? `payroll (${w?.days}d covered)` : "scheduled rate × 40h"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:8, lineHeight:1.5 }}>
            Payroll burden (×{burdenMult.toFixed(2)}) adds <strong>{money(annualWageLoaded - annualWageRaw)}</strong> on top
            ({money(annualWageLoaded)} fully loaded) — that's paid from agency overhead, not from this budget.
          </div>
        </div>
      </Card>

      <Card>
        <div style={{ fontSize:13, fontWeight:700, color:T.slate900, marginBottom:6 }}>Upcoming weeks</div>
        <div style={{ fontSize:11, color:T.slate500, marginBottom:10 }}>
          Schedule shows the zero-SMVC floor. Effective + budget assume current SMVC of {pct(smvc, 2)} holds.
        </div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ width:"100%", fontSize:12 }}>
          <thead>
            <tr style={{ color:T.slate500, fontSize:10, textTransform:"uppercase", letterSpacing:"0.04em" }}>
              <th style={{ textAlign:"left", padding:"6px 8px" }}>Week ending</th>
              <th style={{ textAlign:"right", padding:"6px 8px" }}>Floor</th>
              <th style={{ textAlign:"right", padding:"6px 8px" }}>Effective</th>
              <th style={{ textAlign:"right", padding:"6px 8px" }}>Annual budget</th>
              <th style={{ textAlign:"left", padding:"6px 8px" }}>Phase</th>
            </tr>
          </thead>
          <tbody>
            {trajectory.map((row, idx) => {
              const floor = Number(row?.multiplier) || 0;
              const eff = floor + smvcAdd;
              const budget = eff * aflPremium;
              const isCurrent = row?.week_end_date === state.current?.week_end_date;
              const phaseShort = row?.phase === "phase_1_aa05_stepdown" ? "AA05" :
                                 row?.phase === "phase_2_aa28_stepdown" ? "AA28" :
                                 row?.phase || "—";
              return (
                <tr key={row?.week_end_date || idx} style={{ background: isCurrent ? T.purpleLt : "transparent", borderTop:`1px solid ${T.slate100}` }}>
                  <td style={{ padding:"6px 8px", fontWeight: isCurrent ? 600 : 400, color:T.slate900 }}>
                    {row?.week_end_date}{isCurrent ? " (this week)" : ""}
                  </td>
                  <td style={{ padding:"6px 8px", textAlign:"right", fontFamily:"ui-monospace, monospace" }}>{pct(floor)}</td>
                  <td style={{ padding:"6px 8px", textAlign:"right", fontFamily:"ui-monospace, monospace" }}>{pct(eff)}</td>
                  <td style={{ padding:"6px 8px", textAlign:"right", fontFamily:"ui-monospace, monospace", color:T.slate900 }}>{money(budget)}</td>
                  <td style={{ padding:"6px 8px", color:T.slate500, fontSize:11 }}>{phaseShort}</td>
                </tr>
              );
            })}
            {trajectory.length === 0 && (
              <tr><td colSpan={5} style={{ padding:"10px 8px", color:T.slate500, fontSize:12, textAlign:"center" }}>No upcoming weeks on file.</td></tr>
            )}
          </tbody>
        </table>
        </div>
      </Card>

      <Card style={{ background:T.slate50 }}>
        <div style={{ fontSize:11, color:T.slate600, lineHeight:1.6 }}>
          <div style={{ fontWeight:600, color:T.slate700, marginBottom:4 }}>Formula reference</div>
          <code style={{ fontFamily:"ui-monospace, monospace", fontSize:11, color:T.slate800 }}>
            budget = (scheduled_floor + 0.21 × on_time_SMVC) × (Auto + Fire + Life premium)
          </code>
          <div style={{ marginTop:6 }}>
            Stored schedule is the zero-SMVC floor (Path B). The SMVC modifier (0.21 × on-time SMVC) is added on top each week.
            Full doc: persistent_memory → operational_rule → "Retention budget formula — permanent".
            On-time SMVC is computed at runtime via <code>compute_on_time_smvc_with_better_of()</code> from the latest
            <code>agency_snapshot</code> YTD values and <code>sf_program_targets</code> SMVC bands — never stored as a "current" value.
            Update weekly by writing a new <code>agency_snapshot</code> row.
            {!smvcBandsComplete && (
              <div style={{ marginTop:6, padding:8, background:T.amberLt, border:`1px solid ${T.amber}`, borderRadius:6, color:T.slate800, fontSize:11 }}>
                ⚠️ SMVC bands not yet configured for {new Date().getFullYear()} in <code>sf_program_targets</code> (program=&apos;smvc&apos;).
                Until Peter enters the Min/Max thresholds (and P&amp;C Production Minimum gate) from the corporate OT dashboard,
                this calculator treats on-time SMVC as 0%.
              </div>
            )}
            {smvcSource && (
              <div style={{ marginTop:4, color:T.slate600, fontSize:11 }}>
                Applied rate source: <strong>{smvcSource === "current_year" ? "current-year earned" : "rolling average (Better Of)"}</strong>
              </div>
            )}
          </div>
        </div>
      </Card>

    </div>
  );
};

// ─── Growth Budget Section ───────────────────────────────────
// Per-ramping-teammate breakdown + agency summary + forecasting UI.
// Reads: v_growth_budget_current, v_growth_budget_ytd,
//        get_growth_budget_ceiling RPC, get_growth_budget_forecast RPC.
// See op-rule "New team integration + Growth budget" for canonical mechanics.
const GrowthBudgetSection = () => {
  const [roster, setRoster]           = useState([]);
  const [ytd, setYtd]                 = useState(0);
  const [ceilingInfo, setCeilingInfo] = useState(null);
  const [loading, setLoading]         = useState(true);

  // Forecast form state
  const [fcAnnualBase, setFcAnnualBase] = useState("");
  const [fcStartDate, setFcStartDate]   = useState(new Date().toISOString().split("T")[0]);
  const [fcResult, setFcResult]         = useState(null);
  const [fcLoading, setFcLoading]       = useState(false);
  const [fcError, setFcError]           = useState(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      const [curRes, ytdRes, ceilingRes] = await Promise.allSettled([
        supabase.from("v_growth_budget_current").select("*").eq("agency_id", AGENCY_ID),
        supabase.from("v_growth_budget_ytd").select("growth_budget_ytd").eq("agency_id", AGENCY_ID),
        supabase.rpc("get_growth_budget_ceiling", { p_agency_id: AGENCY_ID }),
      ]);
      if (cancelled) return;
      setRoster(curRes.status === "fulfilled" ? (curRes.value.data || []) : []);
      const ytdRows = ytdRes.status === "fulfilled" ? (ytdRes.value.data || []) : [];
      setYtd(ytdRows.reduce((s, r) => s + parseFloat(r.growth_budget_ytd || 0), 0));
      setCeilingInfo(ceilingRes.status === "fulfilled" ? (ceilingRes.value.data || null) : null);
      setLoading(false);
    }
    load();
    return () => { cancelled = true; };
  }, []);

  const runForecast = async () => {
    setFcError(null);
    const base = parseFloat(fcAnnualBase);
    if (!base || base <= 0) {
      setFcError("Enter a valid annual base salary (e.g. 40000)");
      return;
    }
    setFcLoading(true);
    const { data, error } = await supabase.rpc("get_growth_budget_forecast", {
      p_annual_base: base,
      p_start_date: fcStartDate,
      p_forecast_weeks: 78,
    });
    setFcLoading(false);
    if (error) { setFcError(error.message); return; }
    setFcResult(data);
  };

  const $ = (n) => "$" + (parseFloat(n)||0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  const ceiling      = parseFloat(ceilingInfo?.ceiling_annual || 0);
  const weeklyTotal  = roster.reduce((s, r) => s + parseFloat(r.growth_budget_weekly || 0), 0);
  const rampingCount = roster.length;

  const yearStart       = new Date(new Date().getFullYear(), 0, 1);
  const daysElapsed     = Math.max(1, Math.floor((new Date() - yearStart) / 86400000) + 1);
  const proratedCeiling = ceiling * (daysElapsed / 365);
  const status = ceiling <= 0 ? "info"
    : ytd > ceiling ? "danger"
    : ytd > proratedCeiling ? "warning"
    : "success";
  const statusColor = status==="danger" ? T.red : status==="warning" ? T.amber : status==="success" ? T.green : T.blue;

  if (loading) return <Card><div style={{ padding:12, color:T.slate500, fontSize:13 }}>Loading growth budget…</div></Card>;

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:14 }}>

      {/* Agency-level summary */}
      <Card>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:14, flexWrap:"wrap", gap:8 }}>
          <div>
            <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>Growth Budget</div>
            <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>Shielded portion of new-hire cost during 52-wk tenure ramp — real $ paid, not weighing on residual pool</div>
          </div>
        </div>

        <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(120px, 1fr))", gap:12, marginBottom:14 }}>
          <div>
            <div style={{ fontSize:10, color:T.slate600, fontWeight:600, marginBottom:4 }}>YTD SPEND</div>
            <div style={{ fontSize:18, fontWeight:800, color:statusColor }}>{$(ytd)}</div>
          </div>
          <div>
            <div style={{ fontSize:10, color:T.slate600, fontWeight:600, marginBottom:4 }}>ANNUAL CEILING</div>
            <div style={{ fontSize:18, fontWeight:800, color:T.slate900 }}>{ceiling>0 ? $(ceiling) : "—"}</div>
          </div>
          <div>
            <div style={{ fontSize:10, color:T.slate600, fontWeight:600, marginBottom:4 }}>WEEKLY NOW</div>
            <div style={{ fontSize:18, fontWeight:800, color:T.slate900 }}>{$(weeklyTotal)}</div>
          </div>
          <div>
            <div style={{ fontSize:10, color:T.slate600, fontWeight:600, marginBottom:4 }}>RAMPING</div>
            <div style={{ fontSize:18, fontWeight:800, color:T.slate900 }}>{rampingCount}</div>
          </div>
        </div>

        {ceiling > 0 && (
          <div style={{ marginBottom:6 }}>
            <div style={{ display:"flex", justifyContent:"space-between", fontSize:10, color:T.slate600, marginBottom:4 }}>
              <span>YTD vs annual ceiling</span>
              <span style={{ fontWeight:700, color:statusColor }}>{pct(ytd, ceiling)}%</span>
            </div>
            <ProgressBar value={ytd} max={ceiling} color={statusColor} height={8} />
            <div style={{ fontSize:10, color:T.slate500, marginTop:6 }}>
              Prorated pace at today: {$(proratedCeiling)}
              {status==="danger" && " · Over annual ceiling"}
              {status==="warning" && " · Above prorated pace"}
              {status==="success" && " · Within pace"}
            </div>
            {ceilingInfo?.pct_of_on_time_annual_gross && (
              <div style={{ fontSize:10, color:T.slate400, marginTop:4 }}>
                Basis: {(parseFloat(ceilingInfo.pct_of_on_time_annual_gross)*100).toFixed(0)}% of on-time annual gross ex-Scorecard ({$(ceilingInfo.on_time_annual_gross)}) · Scorecard excluded: {$(ceilingInfo.scorecard_ytd_excluded)} · Anchor: {ceilingInfo.comp_anchor_date}
              </div>
            )}
          </div>
        )}
      </Card>

      {/* Per-teammate breakdown */}
      <Card>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:12 }}>
          <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>Active Ramping Teammates</div>
          <div style={{ fontSize:10, color:T.slate500 }}>tenure &lt; 52 weeks</div>
        </div>
        {roster.length === 0 ? (
          <div style={{ padding:"20px 0", textAlign:"center", color:T.slate400, fontSize:12 }}>
            No teammates currently in ramp. Growth budget = $0.
          </div>
        ) : (
          <div style={{ display:"flex", flexDirection:"column", gap:14 }}>
            {roster.map(p => {
              const tenurePct = parseFloat(p.tenure_multiplier || 0) * 100;
              const weeksIn   = parseInt(p.weeks_since_start || 0);
              const weeksLeft = parseInt(p.weeks_remaining_in_ramp || 0);
              return (
                <div key={p.team_member_id} style={{ padding:"12px 0", borderTop:`1px solid ${T.slate100}` }}>
                  <div style={{ display:"flex", justifyContent:"space-between", alignItems:"baseline", marginBottom:8, flexWrap:"wrap", gap:6 }}>
                    <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{p.full_name}</div>
                    <div style={{ fontSize:11, color:T.slate500 }}>
                      Started {p.start_date} · Week {weeksIn} of 52 · {weeksLeft} weeks left in ramp
                    </div>
                  </div>

                  <div style={{ display:"flex", justifyContent:"space-between", fontSize:10, color:T.slate600, marginBottom:4 }}>
                    <span>Tenure ramp</span>
                    <span style={{ fontWeight:700, color:T.slate800 }}>{tenurePct.toFixed(1)}%</span>
                  </div>
                  <ProgressBar value={tenurePct} max={100} color={T.blue} height={6} />

                  <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(110px, 1fr))", gap:10, marginTop:10 }}>
                    <div>
                      <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Annual base</div>
                      <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>{$(p.annual_base)}</div>
                    </div>
                    <div>
                      <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Fully loaded/wk</div>
                      <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>{$(p.fully_loaded_weekly)}</div>
                    </div>
                    <div>
                      <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Pool weight/wk</div>
                      <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>{$(p.pool_weight_weekly)}</div>
                    </div>
                    <div>
                      <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Growth budget/wk</div>
                      <div style={{ fontSize:13, fontWeight:700, color:T.green }}>{$(p.growth_budget_weekly)}</div>
                    </div>
                    <div>
                      <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Remaining</div>
                      <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>{$(p.growth_budget_remaining_annualized)}</div>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </Card>

      {/* Forecast: hypothetical hire */}
      <Card>
        <div style={{ marginBottom:12 }}>
          <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>Forecast a Hypothetical Hire</div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>See growth budget by quarter for planning</div>
        </div>

        <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(160px, 1fr))", gap:10, marginBottom:12 }}>
          <div>
            <label style={{ fontSize:10, color:T.slate600, fontWeight:600, display:"block", marginBottom:4 }}>ANNUAL BASE SALARY ($)</label>
            <input
              type="number"
              value={fcAnnualBase}
              onChange={e => setFcAnnualBase(e.target.value)}
              placeholder="e.g. 40000"
              style={{ width:"100%", padding:"8px 10px", fontSize:13, border:`1px solid ${T.slate200}`, borderRadius:8, background:T.white }}
            />
          </div>
          <div>
            <label style={{ fontSize:10, color:T.slate600, fontWeight:600, display:"block", marginBottom:4 }}>PLANNED START DATE</label>
            <input
              type="date"
              value={fcStartDate}
              onChange={e => setFcStartDate(e.target.value)}
              style={{ width:"100%", padding:"8px 10px", fontSize:13, border:`1px solid ${T.slate200}`, borderRadius:8, background:T.white }}
            />
          </div>
          <div style={{ display:"flex", alignItems:"flex-end" }}>
            <button
              onClick={runForecast}
              disabled={fcLoading}
              style={{ padding:"9px 16px", fontSize:12, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:8, cursor:fcLoading?"wait":"pointer", width:"100%" }}
            >
              {fcLoading ? "Forecasting…" : "Forecast"}
            </button>
          </div>
        </div>

        {fcError && (
          <div style={{ padding:10, background:T.redLt, color:T.red, borderRadius:8, fontSize:12, marginBottom:10 }}>
            {fcError}
          </div>
        )}

        {fcResult && (
          <div style={{ borderTop:`1px solid ${T.slate100}`, paddingTop:12 }}>
            <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(140px, 1fr))", gap:10, marginBottom:14 }}>
              <div>
                <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Fully loaded/yr</div>
                <div style={{ fontSize:14, fontWeight:700, color:T.slate800 }}>{$(fcResult.summary?.fully_loaded_annual)}</div>
              </div>
              <div>
                <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Year-1 growth budget</div>
                <div style={{ fontSize:14, fontWeight:700, color:T.green }}>{$(fcResult.summary?.year_1_growth_budget_total)}</div>
              </div>
              <div>
                <div style={{ fontSize:10, color:T.slate500, marginBottom:2 }}>Ramp complete</div>
                <div style={{ fontSize:13, fontWeight:700, color:T.slate800 }}>{fcResult.summary?.ramp_complete_date}</div>
              </div>
            </div>

            <div style={{ fontSize:11, fontWeight:700, color:T.slate700, marginBottom:8 }}>By Quarter</div>
            <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
              {(fcResult.quarters || []).map(q => (
                <div key={q.quarter_num} style={{ display:"grid", gridTemplateColumns:"70px 1fr 1fr 1fr", gap:8, alignItems:"center", padding:"8px 10px", background:T.slate100, borderRadius:8 }}>
                  <div style={{ fontSize:12, fontWeight:700, color:T.slate800 }}>Q{q.quarter_num}</div>
                  <div>
                    <div style={{ fontSize:9, color:T.slate500 }}>Window</div>
                    <div style={{ fontSize:11, color:T.slate700 }}>{q.quarter_start} → {q.quarter_end}</div>
                  </div>
                  <div>
                    <div style={{ fontSize:9, color:T.slate500 }}>Growth budget</div>
                    <div style={{ fontSize:12, fontWeight:700, color:T.green }}>{$(q.growth_budget)}</div>
                  </div>
                  <div>
                    <div style={{ fontSize:9, color:T.slate500 }}>Pool weight</div>
                    <div style={{ fontSize:12, fontWeight:700, color:T.slate800 }}>{$(q.pool_weight)}</div>
                  </div>
                </div>
              ))}
            </div>

            {ceiling > 0 && fcResult.summary && (
              <div style={{ marginTop:12, padding:10, background:T.blueLt, borderRadius:8, fontSize:11, color:T.slate700 }}>
                <strong style={{ color:T.slate900 }}>Ceiling impact:</strong>{" "}
                Year-1 forecast of {$(fcResult.summary.year_1_growth_budget_total)} +
                current YTD spend {$(ytd)} =
                {" "}{$(parseFloat(fcResult.summary.year_1_growth_budget_total || 0) + ytd)} projected combined.
                {(parseFloat(fcResult.summary.year_1_growth_budget_total || 0) + ytd) > ceiling
                  ? <span style={{ color:T.red, fontWeight:700 }}> Would exceed ceiling ({$(ceiling)}).</span>
                  : <span style={{ color:T.green, fontWeight:700 }}> Within ceiling ({$(ceiling)}).</span>}
              </div>
            )}
          </div>
        )}
      </Card>

    </div>
  );
};

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
    { id:"members",     label:"Members"     },
    { id:"onboarding",  label:"Onboarding"  },
    { id:"growth",      label:"Growth"      },
    { id:"performance", label:"Performance" },
    { id:"retention",   label:"Retention"   },
    { id:"commissions", label:"Commissions" },
    { id:"book",        label:"Book"        },
  ];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Team</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            {(roi?.allActiveStaff || []).length} active staff · {applicants.filter(a=>!["hired","rejected"].includes(a.status)).length} applicants in pipeline · Resume scanner active
          </div>
        </div>
        
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
      {section === "members"     && <StaffDirectory     staff={roi?.allActiveStaff || []} />}
      {section === "onboarding"  && <OnboardingSection  onboarding={[]} />}
      {section === "growth"      && <GrowthBudgetSection />}
      {section === "performance" && <PerformanceSection  roi={roi} />}
      {section === "retention"   && <RetentionBudgetSection />}
      {section === "commissions" && <CommissionsSection  commissions={[]} />}
      {section === "book"        && <BookAssignmentsSection />}
    </div>
  );
}
