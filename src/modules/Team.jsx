import { Fragment, useState, useMemo, useEffect } from "react";
import { supabase, AGENCY_ID, BUSINESS_ENTITY_ID } from "../lib/supabase.js";
import CandidateDetail from "../components/CandidateDetail.jsx";


// Returns true if a staff member holds any one of the three license types.
const hasAnyLicense = (m) => !!(m && (m.license_pc || m.license_lh || m.license_ips));
// ============================================================
// Newtworks TEAM MODULE v1.1
// Newtworks — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// SECTIONS:
//   1. Overview      — Pipeline summary, team snapshot, alerts
//   2. Recruiting    — Kanban: Assessed→EmailScreen→Interview→RefCheck→Offer→Hired
//   3. Candidate Detail — CTS scores, resume, scorecards (new: click a card)
//   4. Staff         — Current team directory with licensing status
//   5. Performance   — Monthly KPI tracking per staff member
//   6. Commissions   — Commission structures and monthly calculations
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
// DATA: Reads hiring_candidates (people table), staff, team_performance,
//       commission_structures tables
// ============================================================


// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

import { useTabParam } from "../lib/routing.jsx";
// ─── Pipeline Stage Config ────────────────────────────────────
const STAGES = {
  applied:         { label:"Applied",        color:T.slate500, bg:T.slate100, order:0 },
  assessed:        { label:"Assessed",       color:T.slate500, bg:T.slate100, order:1 },
  email_screen:    { label:"Email Screen",   color:T.slate600, bg:T.slate100, order:2 },
  interview:       { label:"Interview",      color:T.amber,    bg:T.amberLt,  order:3 },
  reference_check: { label:"Ref Check",      color:T.blue,     bg:T.blueLt,   order:4 },
  offer:           { label:"Offer",          color:T.purple,   bg:T.purpleLt, order:5 },
  hired:           { label:"Hired",          color:T.green,    bg:T.greenLt,  order:6 },
  declined:        { label:"Declined",       color:T.red,      bg:T.redLt,    order:7 },
  archived:        { label:"Archived",       color:T.slate500, bg:T.slate100, order:8 },
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
          supabase.from("team").select("id, user_id, first_name, last_name, role, role_category, role_level, category, archived_at, start_date, pay_rate, pay_type, pay_frequency, annual_benefits_value, weekly_life_benefit_agency_paid, weekly_health_benefit_agency_paid, employment_type, is_active, email_personal, phone_personal, sf_alias, account_alpha, email_sf, phone_extension, notes, license_pc, license_lh, license_ips, license_states, compliance_flag, nickname, is_admin_backoffice").eq("agency_id", AGENCY_ID),
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
const scoreColor = (s) => s >= 70 ? T.green : s >= 50 ? T.amber : T.red;
const scoreBg    = (s) => s >= 70 ? T.greenLt : s >= 50 ? T.amberLt : T.redLt;
const pct = (a, t) => t ? Math.min(100, Math.round((a/t)*100)) : 0;
const fmt = (n, unit) => unit === "dollars" ? "$"+n.toLocaleString() : unit === "percentage" ? n+"%" : n.toString();

// ─── Seat Profitability helpers (folded in from SeatProfitabilitySection 2026-07-09) ──
const fmt$ = (n) => "$" + Math.round(parseFloat(n) || 0).toLocaleString();
const profStatusColor = (s) => {
  if (s === 'green')  return { bg: T.greenLt, fg: '#065F46' };
  if (s === 'yellow') return { bg: T.amberLt, fg: '#92400E' };
  if (s === 'red')    return { bg: T.redLt,   fg: '#991B1B' };
  return { bg: T.slate100, fg: T.slate500 };
};
const ProfBadge = ({ status, pctValue, label }) => {
  const c = profStatusColor(status);
  const num = pctValue != null ? Math.round(parseFloat(pctValue)) : null;
  const body = num != null ? num + "%" : (status || 'na').toUpperCase();
  return (
    <span title={label ? label + " " + body : body} style={{ display:"inline-flex", alignItems:"center", gap:4, fontSize:10, fontWeight:700, padding:"3px 8px", borderRadius:20, background:c.bg, color:c.fg, minWidth:50, justifyContent:"center" }}>
      {label && <span style={{ opacity:0.75, fontWeight:600 }}>{label}</span>}
      {body}
    </span>
  );
};
const fmtSeatDate = (d) => {
  if (!d) return null;
  const dt = new Date(d + 'T00:00:00');
  return dt.toLocaleDateString('en-US', { month:'short', year:'numeric' });
};
const seatMonthsLabel = (m) => {
  if (m == null) return '';
  if (m === 0) return 'now';
  if (m < 12) return `${m} mo`;
  const y = Math.floor(m / 12);
  const r = m - y * 12;
  return r === 0 ? `${y} yr` : `${y} yr ${r} mo`;
};
const sevColor = (s) => {
  if (s === 'positive') return { border: T.green,   bg: T.greenLt,  fg: '#065F46' };
  if (s === 'concern')  return { border: T.amber,   bg: T.amberLt,  fg: '#92400E' };
  if (s === 'critical') return { border: T.red,     bg: T.redLt,    fg: '#991B1B' };
  if (s === 'action')   return { border: T.blue,    bg: T.blueLt,   fg: '#1E40AF' };
  return { border: T.slate200, bg: T.slate50, fg: T.slate700 };
};
const generateSeatInsights = (row, projection) => {
  if (!row || !projection) return [];
  const cat = row.role_category;
  const covPct = parseFloat(row.coverage_pct) || 0;
  const covMonths = projection.coverage_green_est_months;
  const profMonths = projection.profitability_green_est_months;
  const rqm = parseFloat(row.retention_quality_multiplier) || 0;
  const fully = parseFloat(row.fully_loaded_annual) || 0;
  const attr = parseFloat(row.attributed_revenue_annual) || 0;
  const stackCredited = parseFloat(row.own_renewal_stack_credited) || 0;
  const ownNew = parseFloat(row.own_new_business_annualized) || 0;
  const retPool = parseFloat(row.retention_pool_share_annual) || 0;
  const gap = fully - attr;
  const money = (n) => '$' + Math.round(n).toLocaleString();
  const out = [];
  if (covPct >= 100) {
    out.push({ severity:'positive', title:'Covering seat', detail:`Attributed ${money(attr)} exceeds fully-loaded ${money(fully)}. This seat pays for itself.` });
  } else if (covPct >= 80) {
    out.push({ severity:'concern', title:'Nearly covering', detail:`Attributed ${money(attr)} vs ${money(fully)} fully-loaded. Gap of ${money(gap)}/yr — close, but the seat is still costing the agency money.` });
  } else {
    out.push({ severity:'critical', title:'Not covering seat', detail:`Attributed ${money(attr)} vs ${money(fully)} fully-loaded. Losing ${money(gap)}/yr on this seat.` });
  }
  if (cat === 'Sales') {
    if (covMonths == null) {
      out.push({ severity:'critical', title:'Book decaying faster than replaced', detail:`Under current new-business pace (${money(ownNew)}/yr commission), existing stack is decaying faster than new production replenishes it. Check trailing quarter vs prior quarters — if pace has dropped, that's the driver.` });
      out.push({ severity:'action', title:'Next action', detail:`Diagnose the pace drop. Compare this quarter's issued premium to previous 4 quarters. Have an activity conversation: prospecting, quoting, closing — where's the bottleneck?` });
    } else if (covMonths <= 12) {
      out.push({ severity:'positive', title:'On trajectory', detail:`Coverage projected in ${covMonths} month${covMonths === 1 ? '' : 's'}. Book is compounding — year-1 cohorts are aging into renewal territory.` });
      out.push({ severity:'action', title:'Next action', detail:`Keep doing what they're doing. Confirm the trajectory in ${Math.min(covMonths, 3)} months.` });
    } else if (covMonths <= 36) {
      out.push({ severity:'concern', title:'Long path to coverage', detail:`${covMonths} months out. Book is compounding but slowly at current pace. Growing new-business production would compress this timeline significantly.` });
      out.push({ severity:'action', title:'Next action', detail:`Set a stretch goal on quarterly new-business premium. Even modest growth (+20%) meaningfully accelerates the timeline.` });
    } else {
      out.push({ severity:'concern', title:'Very long path', detail:`${covMonths} months. At current pace the numbers eventually work but the seat runs at a loss for years.` });
      out.push({ severity:'action', title:'Next action', detail:`Set a stretch goal on quarterly new-business premium. Even modest growth (+20%) meaningfully accelerates the timeline.` });
    }
    if (profMonths == null) {
      out.push({ severity:'info', title:'Profitability (2.5×) not within 5-year horizon', detail:`Getting to 2.5× fully-loaded requires book compounding AND growing new business. Long-term goal, not a short-term signal.` });
    }
  } else {
    if (covMonths == null) {
      const potentialRetPool = rqm > 0.01 ? retPool * (1.0 / rqm) : retPool;
      const potentialAttr = ownNew + stackCredited + potentialRetPool;
      const potentialCovPct = fully > 0 ? (potentialAttr / fully) * 100 : 0;
      out.push({ severity:'critical', title:'Attributed revenue is static', detail:`Retention seats don't grow their own book — they share the agency's renewal pool. At current lapse, RQM is ${rqm.toFixed(2)}, discounting the pool by ${Math.round((1-rqm)*100)}%.` });
      out.push({ severity:'info', title:'Lever: lower agency lapse', detail:`If lapse hit benchmark 12%, RQM would jump to 1.0. This seat's attributed would reach ${money(potentialAttr)}/yr — that's ${potentialCovPct.toFixed(0)}% Coverage. Lapse investigation is the single biggest lever for this role.` });
    } else {
      out.push({ severity:'concern', title:'Coverage reachable', detail:`Projected in ${covMonths} months. Own small book gradually adds to attributed revenue over years.` });
      out.push({ severity:'info', title:'Faster path: reduce agency lapse', detail:`Any improvement in agency lapse rate scales retention pool share directly. At benchmark 12%, RQM = 1.0 doubles this seat's attribution overnight.` });
    }
    out.push({ severity:'action', title:'Next action', detail:`Prioritize a lapse investigation — segment the book by cohort age and LOB, identify the churn drivers, then target intervention. This seat's future depends on it.` });
  }
  return out;
};

// ─── Coaching insights: cross-references assessment traits × seat profitability ──
// Returns up to 3 severity-ranked insights (critical > action > concern > positive > info).
// Each insight ties a trait pattern to a specific coaching action, framed around either
// making the seat more profitable or matching work to the person's natural strengths.
const generateCoachingHints = (seat, assessment) => {
  if (!assessment) return [];

  const anl = parseInt(assessment.analytical);
  const opt = parseInt(assessment.optimism);
  const ego = parseInt(assessment.ego_drive_score);
  const emp = parseInt(assessment.empathy_score);
  const asr = parseInt(assessment.assertiveness);
  const ind = parseInt(assessment.independent_spirit);
  const bel = parseInt(assessment.belief_in_others);
  const com = parseInt(assessment.compassion);
  const rec = parseInt(assessment.recognition_drive);
  const dl  = parseInt(assessment.deadline_motivation);
  const sp  = parseInt(assessment.self_promotion);
  const traits = [anl, opt, ego, emp, asr, ind, bel, com, rec, dl, sp];
  const anyTraitPresent = traits.some(v => Number.isFinite(v) && v > 0);
  if (!anyTraitPresent) return [];  // Phase-2 placeholder rows have all traits null

  const covPct = seat ? (parseFloat(seat.coverage_pct) || 0) : null;
  const rqm    = seat ? (parseFloat(seat.retention_quality_multiplier) || 0) : null;
  // Role category comes from the seat (functional role). The prior fallback to
  // assessment_type was removed when that column was dropped — role fit is now
  // a function-based projection (see cts_best_fit_role).
  const cat    = seat?.role_category || null;
  const reliability = (assessment.reliability || "").toLowerCase();
  const distortion  = (assessment.response_distortion || "").toLowerCase();
  const lssMath = parseInt(assessment.lss_math_speed_seconds);
  const lssVerb = parseInt(assessment.lss_verbal_speed_seconds);
  const lssPS   = parseInt(assessment.lss_problem_solving_speed_seconds);
  const lssAcc  = parseInt(assessment.lss_total_accuracy);
  const lssIdeal= parseInt(assessment.lss_total_ideal_min);
  // recommended_coaching_hours_min/max were dropped — coaching guidance is now
  // provided contextually per candidate rather than as a static hrs/mo band.

  const hints = [];

  // ─── Sales-role patterns ───
  if (cat === "Sales") {
    if (opt >= 70 && anl < 20 && covPct != null && covPct < 90) {
      hints.push({
        severity:"critical",
        title:"Complacency archetype",
        detail:`High Optimism (${opt}) + low Analytical (${anl}) = blind spot to own pace drops. Rides good stretches, misses declines. Coaching lever: external mirror (weekly data reviews with witnesses, immediate feedback). Do NOT confront as personality — it's structural.`,
      });
    } else if (ego >= 60 && covPct != null && covPct >= 100) {
      hints.push({
        severity:"positive",
        title:"Producer archetype",
        detail:`Ego Drive ${ego} + Coverage ${Math.round(covPct)}%. Protect autonomy, reward with stretch goals not micromanagement. Growth path (Section/Unit Manager) worth exploring.`,
      });
    }
    if (bel >= 85 && com < 25 && asr < 45 && ind >= 80) {
      hints.push({
        severity:"concern",
        title:"Broken-trust has no graceful recovery",
        detail:`Belief ${bel} + Compassion ${com} + Assertiveness ${asr} + Independent ${ind}: extends trust freely, no softening on violation, won't confront, doesn't self-repair. When a rupture occurs, YOU must reset the trust signal explicitly — silence festers into withdrawal + covert resistance.`,
      });
    }
    if (asr < 25 && covPct != null && covPct < 90) {
      hints.push({
        severity:"action",
        title:"Under-negotiates on close",
        detail:`Assertiveness ${asr} caps ask-strength. Direct coaching move: role-play push-back scenarios and objection-handling. This trait responds measurably to structured reps.`,
      });
    }
    if (rec < 20 && ego >= 30 && ego < 60) {
      hints.push({
        severity:"info",
        title:"Peer-parity is the money lever",
        detail:`Recognition ${rec} means public leaderboards fall flat. Ego Drive ${ego} activates on peer comparison ("they earn what I earn"). Frame comp math against peer parity, not against absolute targets.`,
      });
    }
    if (ind >= 85) {
      hints.push({
        severity:"info",
        title:"Autonomy-driven",
        detail:`Independent Spirit ${ind}: highly resistant to close supervision. Delegate outcomes, not process. Light check-in cadence, expect autonomous execution.`,
      });
    }
  }

  // ─── Retention-role patterns ───
  if (cat === "Retention") {
    if (com >= 60 && bel >= 60 && rqm != null && rqm < 0.6) {
      hints.push({
        severity:"action",
        title:"Right person, wrong environment",
        detail:`Compassion ${com} + Belief ${bel} = strong retention base. Coverage gap is agency-lapse-driven (RQM ${rqm.toFixed(2)}), NOT coaching-intensity-driven. Lapse investigation is what moves the needle for this seat.`,
      });
    }
    if (com < 25) {
      hints.push({
        severity:"critical",
        title:"Compassion mismatch for retention",
        detail:`Compassion ${com} — this is the base skill of retention work. More coaching hours won't unlock what isn't there. Role-fit conversation warranted, not intensity increase.`,
      });
    }
    if (dl < 30) {
      hints.push({
        severity:"concern",
        title:"Slow-pace tolerance",
        detail:`Deadline Motivation ${dl}: won't self-drive on time-sensitive work. Match to non-cadence tasks (policy audits, deep-service review). Don't put on outbound rhythms — they'll fall behind.`,
      });
    }
    if (anl >= 70) {
      hints.push({
        severity:"info",
        title:"Analytical strength underused",
        detail:`Analytical ${anl}: naturally fits policy-review + coverage-audit work. Route complex service tasks here — this profile is often underutilized in pure inbound answering.`,
      });
    }
  }

  // ─── Cross-cutting patterns ───
  // (Prior "High-touch profile" hint keyed off recommended_coaching_hours_max — column dropped.
  //  Coaching-effort guidance is now delivered contextually per candidate.)
  if (distortion === "high") {
    hints.push({
      severity:"info",
      title:"Trust behavior over self-report",
      detail:`Response distortion tagged high — assessment scores may be inflated. Weight behavioral evidence over the numbers on this row.`,
    });
  }
  if (reliability === "low") {
    hints.push({
      severity:"info",
      title:"Assessment reliability is low",
      detail:`Reliability tagged low — cross-check trait interpretation against multiple observations before acting.`,
    });
  }
  if (Number.isFinite(lssMath) && Number.isFinite(lssVerb) && Number.isFinite(lssPS)
      && lssMath > 60 && lssVerb > 45 && lssPS > 120) {
    hints.push({
      severity:"concern",
      title:"Productivity ceiling from LSS",
      detail:`LSS speeds slow across math (${lssMath}s), verbal (${lssVerb}s), problem-solving (${lssPS}s). Per-day throughput is constrained regardless of coaching. Match to deep-detail work with fewer per-day transactions.`,
    });
  }
  if (Number.isFinite(lssAcc) && Number.isFinite(lssIdeal) && lssAcc <= lssIdeal + 2) {
    hints.push({
      severity:"concern",
      title:"Cognitive baseline",
      detail:`LSS total accuracy ${lssAcc} just clears ideal min ${lssIdeal}. Multi-step compound tasks (complex policy work) will be error-prone. Break work into smaller, checkable steps.`,
    });
  }

  // Rank & cap
  const rank = { critical:0, action:1, concern:2, positive:3, info:4 };
  hints.sort((a, b) => (rank[a.severity] || 5) - (rank[b.severity] || 5));
  return hints.slice(0, 3);
};

// ─── Trait rendering for Assessment panel ──
const TraitBar = ({ label, value }) => {
  const v = Math.max(0, Math.min(100, parseInt(value)));
  if (!Number.isFinite(v) || value == null) return null;
  const barColor = v >= 70 ? T.green : v >= 40 ? T.blue : v >= 20 ? T.amber : T.red;
  return (
    <div style={{ display:"flex", alignItems:"center", gap:8, fontSize:10 }}>
      <div style={{ flex:"0 0 110px", color:T.slate700 }}>{label}</div>
      <div style={{ flex:1, height:6, background:T.slate100, borderRadius:3, overflow:"hidden" }}>
        <div style={{ width:v+"%", height:"100%", background:barColor, borderRadius:3 }} />
      </div>
      <div style={{ flex:"0 0 26px", textAlign:"right", fontWeight:700, color:T.slate900 }}>{v}</div>
    </div>
  );
};

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
  const s = STAGES[status] || STAGES.applied;
  return <span style={{ fontSize:10, fontWeight:600, padding:"3px 8px", borderRadius:20, background:s.bg, color:s.color }}>{s.label}</span>;
};

// ─── Section: Recruiting Pipeline ──────────────────────────── 
const RecruitingPipeline = ({ applicants, onUpdate, stages: stagesProp }) => {
  // Persist selected candidate in URL query (?candidate=<uuid>) so refresh
  // returns to the same detail view. useTabParam without an allowlist just
  // syncs the value bidirectionally with the URL query string.
  const [selected, setSelected] = useTabParam("candidate", null);
  // Default = full pipeline. GrowthTab passes a subset for the split Recruiting/Closing views.
  const stages = stagesProp || ["applied","assessed","email_screen","interview","reference_check","offer","hired"]; // archived hidden by default


  const selectedApp = applicants.find(a => a.id === selected);

  // Full-view candidate detail (replaces kanban when a card is clicked)
  if (selectedApp) {
    return (
      <CandidateDetail
        candidate={selectedApp}
        onBack={() => setSelected(null)}
        onUpdate={onUpdate}
      />
    );
  }

  return (
    <div>
      {/* Pipeline Kanban (horizontally scrollable on narrow viewports) */}
      <div style={{ overflowX:"auto", marginBottom:16, marginLeft:-4, marginRight:-4, paddingLeft:4, paddingRight:4 }}>
      <div style={{ display:"grid", gridTemplateColumns:`repeat(${stages.length},minmax(120px,1fr))`, gap:8, minWidth:`${Math.max(360, stages.length * 120)}px` }}>
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
                  <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginTop:4, gap:6 }}>
                    <span style={{ fontSize:9, color:T.slate400, flexShrink:1, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{app.position?.split(" ")?.slice(-1)?.[0] || ""}</span>
                    <div style={{ display:"flex", gap:6, flexShrink:0 }}>
                      {app.resume_avg != null && (
                        <span style={{ fontSize:10, fontWeight:700, color:scoreColor(Number(app.resume_avg)) }}>R {Math.round(Number(app.resume_avg))}</span>
                      )}
                      {app.overall_score != null && (
                        <span style={{ fontSize:10, fontWeight:700, color:scoreColor(Number(app.overall_score)) }}>A {app.overall_score}</span>
                      )}
                      {app.resume_avg == null && app.overall_score == null && (
                        <span style={{ fontSize:9, color:T.slate400 }}>—</span>
                      )}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          );
        })}
      </div>
      </div>
    </div>
  );
};

// ─── Declined Candidates Table ────────────────────────────────
// Read-only summary view of every candidate we walked away from (status='archived'
// AND is_team_member=false). Row tap opens CandidateDetail with full history and
// the option to re-activate to any pipeline stage.
const DECLINE_REASON_LABEL = {
  active_applicant: "Active — declined",
  offer_rescinded:  "Offer rescinded",
  calibration_only: "Calibration",
  former_team:      "Former team",
};

const trim = (s, n) => {
  if (!s) return "";
  const clean = String(s).replace(/\s+/g, " ").trim();
  return clean.length > n ? clean.slice(0, n - 1) + "…" : clean;
};

const overallBandColor = (v) => {
  if (v == null) return T.slate400;
  if (v >= 70) return T.green;
  if (v >= 55) return T.amber;
  return T.red;
};

const DeclinedTable = ({ declined, onUpdate }) => {
  // URL-persisted candidate selection so refresh keeps the same candidate open.
  // Same param name as RecruitingPipeline uses; the two are conditionally
  // rendered (gtab picks one) so there's no collision.
  const [selected, setSelected] = useTabParam("candidate", null);
  const selectedApp = declined.find(a => a.id === selected);
  // sortKey ∈ {name, source, resume, cts, recent}; direction ∈ {asc, desc}
  const [sortKey, setSortKey] = useState("recent");
  const [sortDir, setSortDir] = useState("desc");

  const toggleSort = (k, defaultDir = "desc") => {
    if (sortKey === k) setSortDir(sortDir === "asc" ? "desc" : "asc");
    else { setSortKey(k); setSortDir(defaultDir); }
  };

  const sorted = useMemo(() => {
    const arr = [...declined];
    const dir = sortDir === "asc" ? 1 : -1;
    const num = (v) => (v == null ? -Infinity : v);
    const str = (v) => (v || "").toLowerCase();
    if (sortKey === "cts")         arr.sort((a,b) => (num(a.overall_score) - num(b.overall_score)) * dir);
    else if (sortKey === "resume") arr.sort((a,b) => (num(a.resume_avg)    - num(b.resume_avg))    * dir);
    else if (sortKey === "name")   arr.sort((a,b) => str(a.last_name).localeCompare(str(b.last_name)) * dir);
    else if (sortKey === "source") arr.sort((a,b) => str(a.decline_reason).localeCompare(str(b.decline_reason)) * dir);
    else                           arr.sort((a,b) => (new Date(a.created_at) - new Date(b.created_at)) * dir);
    return arr;
  }, [declined, sortKey, sortDir]);

  if (selectedApp) {
    return (
      <CandidateDetail
        candidate={selectedApp}
        onBack={() => setSelected(null)}
        onUpdate={onUpdate}
      />
    );
  }

  if (declined.length === 0) {
    return (
      <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:8, padding:"18px 14px", textAlign:"center" }}>
        <div style={{ fontSize:11, color:T.slate500 }}>No declined candidates on file.</div>
      </div>
    );
  }

  const arrow = (k) => sortKey === k ? (sortDir === "asc" ? " ▲" : " ▼") : "";
  const thBase = {
    fontSize: 9,
    fontWeight: 700,
    color: T.slate600,
    textTransform: "uppercase",
    letterSpacing: "0.04em",
    padding: "6px 6px",
    background: T.slate50,
    borderBottom: `1px solid ${T.slate200}`,
    whiteSpace: "nowrap",
    cursor: "pointer",
    userSelect: "none",
  };
  const tdBase = {
    fontSize: 11,
    color: T.slate800,
    padding: "6px 6px",
    borderBottom: `1px solid ${T.slate100}`,
    verticalAlign: "top",
  };

  return (
    <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, overflow: "hidden" }}>
      <div style={{ overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse", tableLayout: "auto" }}>
          <thead>
            <tr>
              <th style={{ ...thBase, textAlign: "left"  }} onClick={() => toggleSort("name",   "asc")}>Name{arrow("name")}</th>
              <th style={{ ...thBase, textAlign: "left"  }} onClick={() => toggleSort("source", "asc")}>Source{arrow("source")}</th>
              <th style={{ ...thBase, textAlign: "right" }} onClick={() => toggleSort("resume", "desc")}>Res{arrow("resume")}</th>
              <th style={{ ...thBase, textAlign: "right" }} onClick={() => toggleSort("cts",    "desc")}>CTS{arrow("cts")}</th>
              <th style={{ ...thBase, textAlign: "left"  }}>Notes</th>
            </tr>
          </thead>
          <tbody>
            {sorted.map(app => {
              const preview = trim(app.notes || app.claude_summary, 180);
              const sourceLbl = DECLINE_REASON_LABEL[app.decline_reason] || app.decline_reason || "—";
              return (
                <tr
                  key={app.id}
                  onClick={() => setSelected(app.id)}
                  style={{ cursor: "pointer" }}
                >
                  <td style={{ ...tdBase, fontWeight: 600, color: T.slate900, whiteSpace: "nowrap" }}>
                    {app.first_name} {app.last_name}
                  </td>
                  <td style={{ ...tdBase, fontSize: 10, color: T.slate600, whiteSpace: "nowrap" }}>{sourceLbl}</td>
                  <td style={{ ...tdBase, textAlign: "right", fontWeight: 700, color: app.resume_avg != null ? scoreColor(Number(app.resume_avg)) : T.slate400 }}>
                    {app.resume_avg != null ? Math.round(Number(app.resume_avg)) : "—"}
                  </td>
                  <td style={{ ...tdBase, textAlign: "right", fontWeight: 700, color: overallBandColor(app.overall_score) }}>
                    {app.overall_score != null ? app.overall_score : "—"}
                  </td>
                  <td style={{ ...tdBase, color: T.slate600, minWidth: 200, lineHeight: 1.35 }}>
                    {preview || "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
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

  // ── Seat profitability (folded into roster 2026-07-09) ──
  // Fetches compute_warning_trigger + compute_seat_projections_for_agency for the current
  // week, keyed by team_member_id. Scenario toggle re-fetches with p_override_lapse=0.12.
  const SEAT_SCENARIO_LAPSE_A = 0.15;
  const SEAT_SCENARIO_LAPSE_B = 0.20;
  const [seatWeekEnd] = useState(() => {
    const t = new Date();
    const daysUntilSat = t.getDay() === 6 ? 0 : (6 - t.getDay());
    const sat = new Date(t); sat.setDate(t.getDate() + daysUntilSat);
    return sat.toISOString().slice(0, 10);
  });
  const [seatRows, setSeatRows] = useState([]);
  const [seatProjections, setSeatProjections] = useState([]);
  const [seatScenARows, setSeatScenARows] = useState([]);
  const [seatScenAProjections, setSeatScenAProjections] = useState([]);
  const [seatScenBRows, setSeatScenBRows] = useState([]);
  const [seatScenBProjections, setSeatScenBProjections] = useState([]);
  // 'off' | 'a' (lapse=15%) | 'b' (lapse=20%)
  const [seatScenarioActive, setSeatScenarioActive] = useState('off');
  const [seatLoading, setSeatLoading] = useState(true);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      setSeatLoading(true);
      try {
        const [wt, pr, wtA, prA, wtB, prB] = await Promise.all([
          supabase.rpc('compute_warning_trigger', { p_agency_id: AGENCY_ID, p_week_end_date: seatWeekEnd }),
          supabase.rpc('compute_seat_projections_for_agency', { p_agency_id: AGENCY_ID, p_baseline_date: seatWeekEnd, p_max_months: 60 }),
          supabase.rpc('compute_warning_trigger', { p_agency_id: AGENCY_ID, p_week_end_date: seatWeekEnd, p_override_lapse: SEAT_SCENARIO_LAPSE_A }),
          supabase.rpc('compute_seat_projections_for_agency', { p_agency_id: AGENCY_ID, p_baseline_date: seatWeekEnd, p_max_months: 60, p_override_lapse: SEAT_SCENARIO_LAPSE_A }),
          supabase.rpc('compute_warning_trigger', { p_agency_id: AGENCY_ID, p_week_end_date: seatWeekEnd, p_override_lapse: SEAT_SCENARIO_LAPSE_B }),
          supabase.rpc('compute_seat_projections_for_agency', { p_agency_id: AGENCY_ID, p_baseline_date: seatWeekEnd, p_max_months: 60, p_override_lapse: SEAT_SCENARIO_LAPSE_B }),
        ]);
        if (cancelled) return;
        if (!wt.error) setSeatRows(wt.data || []);
        if (!pr.error) setSeatProjections(pr.data || []);
        if (!wtA.error) setSeatScenARows(wtA.data || []);
        if (!prA.error) setSeatScenAProjections(prA.data || []);
        if (!wtB.error) setSeatScenBRows(wtB.data || []);
        if (!prB.error) setSeatScenBProjections(prB.data || []);
      } catch (e) {
        console.error('Seat profitability load error:', e);
        if (!cancelled) { setSeatRows([]); setSeatProjections([]); setSeatScenARows([]); setSeatScenAProjections([]); setSeatScenBRows([]); setSeatScenBProjections([]); }
      } finally {
        if (!cancelled) setSeatLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [seatWeekEnd]);

  // ── Assessment / production / behavioral note lookups for expanded row ──
  // All three pulled in one Promise.all keyed by team_member_id. Displayed only inside
  // the admin-only Members view — no team-tier exposure per the Newtworks visibility rule.
  const [asmtByMember, setAsmtByMember] = useState({});
  const [prodByMember, setProdByMember] = useState({});
  const [behavioralByMember, setBehavioralByMember] = useState({});
  const [trajectoryByMember, setTrajectoryByMember] = useState({});
  const [trajectoryRecomputing, setTrajectoryRecomputing] = useState({});
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const activeIds = (staff || []).filter(s => s && s.is_active).map(s => s.id);
      if (activeIds.length === 0) return;
      try {
        const [asRes, prRes, bnRes, trRes] = await Promise.all([
          supabase.from("hiring_candidates").select("*").eq("agency_id", AGENCY_ID).in("team_member_id", activeIds).order("assessment_date", { ascending: false }),
          supabase.from("producer_production").select("team_member_id, period_year, period_month, line_of_business, premium_issued, policies_issued").eq("agency_id", AGENCY_ID).in("team_member_id", activeIds),
          supabase.from("team_behavioral_notes").select("id, team_member_id, observation_date, observation_text, pattern_type, is_resolved").eq("agency_id", AGENCY_ID).in("team_member_id", activeIds).neq("pattern_type", "termination").order("observation_date", { ascending: false }).limit(120),
          supabase.from("team_trajectory_summaries").select("team_member_id, summary, notes_analyzed_count, notes_range_start, notes_range_end, model_used, updated_at").eq("agency_id", AGENCY_ID).in("team_member_id", activeIds),
        ]);
        if (cancelled) return;
        // Latest assessment per member (query already sorted by date desc)
        const aMap = {};
        (asRes.data || []).forEach(row => { if (!aMap[row.team_member_id]) aMap[row.team_member_id] = row; });
        setAsmtByMember(aMap);
        // Behavioral notes grouped, cap 5 shown later
        const bMap = {};
        (bnRes.data || []).forEach(row => { (bMap[row.team_member_id] = bMap[row.team_member_id] || []).push(row); });
        setBehavioralByMember(bMap);
        // Production: trailing 12 months from today, by LOB + by month
        const now = new Date();
        const cutoffYear  = now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
        const cutoffMonth = now.getMonth() === 0 ? 1 : now.getMonth() + 1; // inclusive lower bound = same month prior year
        // Equivalent numeric compare key
        const cutoffKey = (now.getFullYear() - 1) * 100 + (now.getMonth() + 2 > 12 ? 1 : now.getMonth() + 2);
        // NOTE: last 12 completed months. If today is Jul 2026, include Aug 2025 → Jul 2026 (13 months buffer,
        // clamp on display side). Off-by-one small; keep simple.
        const pMap = {};
        (prRes.data || []).forEach(row => {
          const key = row.period_year * 100 + row.period_month;
          if (key < cutoffKey) return;
          const prem = parseFloat(row.premium_issued) || 0;
          const pols = parseInt(row.policies_issued) || 0;
          const bucket = pMap[row.team_member_id] = pMap[row.team_member_id] || { total_prem:0, total_pols:0, byLob:{}, byMonth:{} };
          bucket.total_prem += prem;
          bucket.total_pols += pols;
          const line = (row.line_of_business || "Other");
          const lineLabel = line.charAt(0).toUpperCase() + line.slice(1);
          bucket.byLob[line] = bucket.byLob[line] || { line:lineLabel, prem:0, pols:0 };
          bucket.byLob[line].prem += prem;
          bucket.byLob[line].pols += pols;
          const mKey = row.period_year + "-" + String(row.period_month).padStart(2, "0");
          bucket.byMonth[mKey] = bucket.byMonth[mKey] || { key:mKey, prem:0, pols:0 };
          bucket.byMonth[mKey].prem += prem;
          bucket.byMonth[mKey].pols += pols;
        });
        Object.values(pMap).forEach(b => {
          b.byLob = Object.values(b.byLob).sort((x, y) => y.prem - x.prem);
          b.byMonth = Object.values(b.byMonth).sort((x, y) => x.key.localeCompare(y.key));
        });
        setProdByMember(pMap);
        // Trajectory summaries keyed by team_member_id
        const tMap = {};
        (trRes.data || []).forEach(row => { tMap[row.team_member_id] = row; });
        setTrajectoryByMember(tMap);
      } catch (e) {
        console.error("StaffDirectory extended fetches failed:", e);
      }
    })();
    return () => { cancelled = true; };
  }, [staff]);

  // Recompute one member's trajectory summary. Fires the SQL RPC (which invokes the
  // team-trajectory-summarize edge function via net.http_post), then re-fetches
  // this member's row after a short delay. Owner/manager only in practice
  // (Members tab is admin-gated at the app layer).
  const recomputeTrajectory = async (memberId) => {
    setTrajectoryRecomputing(prev => ({ ...prev, [memberId]: true }));
    try {
      const { error: rpcErr } = await supabase.rpc("team_trajectory_recompute", {
        p_team_member_id: memberId, p_all_active: false,
      });
      if (rpcErr) throw rpcErr;
      // Edge fn is async through pg_net; poll for the updated_at bump.
      const before = trajectoryByMember[memberId]?.updated_at || "";
      for (let i = 0; i < 15; i++) {
        await new Promise(r => setTimeout(r, 2000));
        const { data } = await supabase.from("team_trajectory_summaries")
          .select("team_member_id, summary, notes_analyzed_count, notes_range_start, notes_range_end, model_used, updated_at")
          .eq("team_member_id", memberId).maybeSingle();
        if (data && data.updated_at && data.updated_at !== before) {
          setTrajectoryByMember(prev => ({ ...prev, [memberId]: data }));
          break;
        }
      }
    } catch (e) {
      console.error("recomputeTrajectory failed:", e);
    } finally {
      setTrajectoryRecomputing(prev => { const n = { ...prev }; delete n[memberId]; return n; });
    }
  };

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
  const [view, setView] = useTabParam("mtab", "active", ["active","archived"]); // "active" or "archived"
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
      annual_benefits_value: member.annual_benefits_value ?? "",
      weekly_life_benefit_agency_paid: member.weekly_life_benefit_agency_paid ?? "",
      weekly_health_benefit_agency_paid: member.weekly_health_benefit_agency_paid ?? "",
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
      annual_benefits_value: form.annual_benefits_value === "" || form.annual_benefits_value == null ? 0 : Number(form.annual_benefits_value),
      weekly_life_benefit_agency_paid: form.weekly_life_benefit_agency_paid === "" || form.weekly_life_benefit_agency_paid == null ? 0 : Number(form.weekly_life_benefit_agency_paid),
      weekly_health_benefit_agency_paid: form.weekly_health_benefit_agency_paid === "" || form.weekly_health_benefit_agency_paid == null ? 0 : Number(form.weekly_health_benefit_agency_paid),
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
    if (!Number.isFinite(payload.annual_benefits_value) || payload.annual_benefits_value < 0) {
      setSaveError("Annual benefits value must be a non-negative number.");
      setSaving(false);
      return;
    }
    if (!Number.isFinite(payload.weekly_life_benefit_agency_paid) || payload.weekly_life_benefit_agency_paid < 0) {
      setSaveError("Weekly life benefit must be a non-negative number.");
      setSaving(false);
      return;
    }
    if (!Number.isFinite(payload.weekly_health_benefit_agency_paid) || payload.weekly_health_benefit_agency_paid < 0) {
      setSaveError("Weekly health benefit must be a non-negative number.");
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
  // Owner (Peter) + admin back-office (Marie) sit at the bottom of the active list,
  // divided from the team above. Stable sort preserves existing order for everyone else.
  const bottomRank = (m) => (m?.is_admin_backoffice ? 2 : (m?.role_level === "Owner" ? 1 : 0));
  const sortedActive = [...mergedActive].sort((a, b) => bottomRank(a) - bottomRank(b));
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
                const rc = (r === "Outbound" || r === "Inbound" || r === "In-Book") ? "Sales"
                         : (r === "Reception" || r === "Escalation" || r === "Support") ? "Retention"
                         : addForm.role_category;
                setAddForm(f => ({ ...f, role: r, role_category: rc }));
              }}>
                <option value="">—</option>
                <option value="Outbound">Outbound</option>
                <option value="Inbound">Inbound</option>
                <option value="In-Book">In-Book</option>
                <option value="Reception">Reception</option>
                <option value="Escalation">Escalation</option>
                <option value="Support">Support</option>
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

      {/* ============== AGENCY-WIDE SEAT AGGREGATE + SCENARIO TOGGLE ============== */}
      {view === "active" && (() => {
        const rows = seatScenarioActive === 'a' ? seatScenARows : seatScenarioActive === 'b' ? seatScenBRows : seatRows;
        if (seatLoading) {
          return (
            <Card style={{ padding:"10px 14px" }}>
              <div style={{ fontSize:11, color:T.slate500 }}>Loading seat profitability…</div>
            </Card>
          );
        }
        if (!rows || rows.length === 0) return null;
        const totalAttr  = rows.reduce((s,r) => s + (parseFloat(r.attributed_revenue_annual) || 0), 0);
        const totalFully = rows.reduce((s,r) => s + (parseFloat(r.fully_loaded_annual) || 0), 0);
        const totalProfBar = rows.reduce((s,r) => s + (parseFloat(r.profitability_bar) || 0), 0);
        const covPctAgency  = totalFully   > 0 ? (totalAttr / totalFully)   * 100 : 0;
        const profPctAgency = totalProfBar > 0 ? (totalAttr / totalProfBar) * 100 : 0;
        const gap = totalFully - totalAttr;
        const covC  = covPctAgency  >= 100 ? { bg:T.greenLt, fg:'#065F46' } : covPctAgency  >= 80 ? { bg:T.amberLt, fg:'#92400E' } : { bg:T.redLt, fg:'#991B1B' };
        const profC = profPctAgency >= 100 ? { bg:T.greenLt, fg:'#065F46' } : profPctAgency >= 80 ? { bg:T.amberLt, fg:'#92400E' } : { bg:T.redLt, fg:'#991B1B' };
        const first = rows[0] || {};
        const lapseRate = parseFloat(first.lapse_rate_used) || 0;
        const lapseStatus = first.lapse_status || 'na';
        const agencyRenewalTTM = parseFloat(first.diag?.agency_renewal_ttm) || 0;
        return (
          <Card style={{ borderLeft:`4px solid ${seatScenarioActive !== 'off' ? T.purple : T.slate900}`, padding:"12px 16px" }}>
            <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", gap:12, flexWrap:"wrap", marginBottom:10 }}>
              <div>
                <div style={{ fontSize:12, fontWeight:700, color:T.slate900 }}>Seat profitability — agency-wide</div>
                <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>
                  {seatScenarioActive === 'a' ? "Scenario: if lapse rose to 15%" : seatScenarioActive === 'b' ? "Scenario: if lapse rose to 20%" : "Actual: current conditions"} · week ending {seatWeekEnd}
                </div>
              </div>
              <div style={{ display:"flex", gap:6, flexWrap:"wrap" }}>
                <button
                  onClick={() => setSeatScenarioActive(v => v === 'a' ? 'off' : 'a')}
                  style={{ padding:"6px 12px", fontSize:11, fontWeight:700, color:seatScenarioActive === 'a' ? T.white : T.slate700, background:seatScenarioActive === 'a' ? T.purple : T.white, border:`1px solid ${seatScenarioActive === 'a' ? T.purple : T.slate200}`, borderRadius:8, cursor:"pointer" }}
                >
                  {seatScenarioActive === 'a' ? "✓ Lapse = 15%" : "What if lapse = 15%?"}
                </button>
                <button
                  onClick={() => setSeatScenarioActive(v => v === 'b' ? 'off' : 'b')}
                  style={{ padding:"6px 12px", fontSize:11, fontWeight:700, color:seatScenarioActive === 'b' ? T.white : T.slate700, background:seatScenarioActive === 'b' ? T.purple : T.white, border:`1px solid ${seatScenarioActive === 'b' ? T.purple : T.slate200}`, borderRadius:8, cursor:"pointer" }}
                >
                  {seatScenarioActive === 'b' ? "✓ Lapse = 20%" : "What if lapse = 20%?"}
                </button>
              </div>
            </div>
            <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(140px, 1fr))", gap:8 }}>
              <div style={{ background:T.slate50, padding:"8px 10px", borderRadius:8 }}>
                <div style={{ fontSize:9, color:T.slate500, marginBottom:2 }}>Attributed / Loaded</div>
                <div style={{ fontSize:12, fontWeight:700, color:T.slate900 }}>{fmt$(totalAttr)} / {fmt$(totalFully)}</div>
                <div style={{ fontSize:9, color: gap > 0 ? '#991B1B' : '#065F46', marginTop:3 }}>
                  {gap > 0 ? `losing ${fmt$(gap)}/yr` : `surplus ${fmt$(-gap)}/yr`}
                </div>
              </div>
              <div style={{ background:covC.bg, padding:"8px 10px", borderRadius:8 }}>
                <div style={{ fontSize:9, color:T.slate500, marginBottom:2 }}>Coverage</div>
                <div style={{ fontSize:18, fontWeight:800, color:covC.fg }}>{covPctAgency.toFixed(0)}%</div>
              </div>
              <div style={{ background:profC.bg, padding:"8px 10px", borderRadius:8 }}>
                <div style={{ fontSize:9, color:T.slate500, marginBottom:2 }}>Profitability</div>
                <div style={{ fontSize:18, fontWeight:800, color:profC.fg }}>{profPctAgency.toFixed(0)}%</div>
              </div>
              <div style={{ background:T.slate50, padding:"8px 10px", borderRadius:8 }}>
                <div style={{ fontSize:9, color:T.slate500, marginBottom:2 }}>Lapse · Renewal TTM</div>
                <div style={{ fontSize:11, fontWeight:600, color:profStatusColor(lapseStatus).fg }}>{(lapseRate * 100).toFixed(1)}%</div>
                <div style={{ fontSize:10, color:T.slate600, marginTop:2 }}>{fmt$(agencyRenewalTTM)}</div>
              </div>
            </div>
          </Card>
        );
      })()}

      {/* ============== ACTIVE VIEW (existing card list) ============== */}
      {view === "active" && (() => {
        const _activeItems = sortedActive.filter(s => s.is_active && !terminatedIds.has(s.id));
        const _firstBottomIdx = _activeItems.findIndex(s => bottomRank(s) > 0);
        return _activeItems.map((raw, _idx) => {
        // Merge any saved override on top of the loaded row.
        const member = overrides[raw.id] ? { ...raw, ...overrides[raw.id] } : raw;
        const isExpanded = expanded === member.id;
        const isEditing = editingId === member.id;
        // Seat profitability lookup for this member (respects scenario toggle).
        const seatSrcRows = seatScenarioActive === 'a' ? seatScenARows : seatScenarioActive === 'b' ? seatScenBRows : seatRows;
        const seatSrcProj = seatScenarioActive === 'a' ? seatScenAProjections : seatScenarioActive === 'b' ? seatScenBProjections : seatProjections;
        const seat = seatSrcRows.find(r => r.team_member_id === member.id) || null;
        const seatProj = seat ? (seatSrcProj.find(p => p.team_member_id === member.id) || null) : null;
        const _showDivider = _firstBottomIdx > 0 && _idx === _firstBottomIdx;
        return (
          <Fragment key={member.id}>
          {_showDivider && (
            <div style={{ marginTop:14, marginBottom:2, paddingBottom:6, borderBottom:`1px solid ${T.slate200}`, fontSize:11, fontWeight:700, color:T.slate500, textTransform:"uppercase", letterSpacing:"0.06em" }}>
              Back Office
            </div>
          )}
          <Card style={{ border:`1px solid ${isExpanded?T.blue:T.slate200}` }}>
            <div style={{ display:"flex", alignItems:"center", gap:14, cursor:"pointer" }} onClick={() => { if (!isEditing) setExpanded(isExpanded?null:member.id); }}>
              {/* Avatar */}
              <div style={{ width:48, height:48, borderRadius:12, background:hasAnyLicense(member)?T.slate900:T.slate200, display:"flex", alignItems:"center", justifyContent:"center", fontSize:16, fontWeight:700, color:hasAnyLicense(member)?T.white:T.slate500, flexShrink:0 }}>
                {(member.first_name?.[0] || "?")}{(member.last_name?.[0] || "")}
              </div>

              <div style={{ flex:1 }}>
                <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:4, flexWrap:"wrap" }}>
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
                  {seat && (
                    <div style={{ display:"flex", gap:4, flexWrap:"wrap", marginLeft:"auto" }}>
                      <ProfBadge label="Cov" status={seat.coverage_status} pctValue={seat.coverage_pct} />
                      <ProfBadge label="Prof" status={seat.profitability_status} pctValue={seat.profitability_pct} />
                    </div>
                  )}
                </div>
                <div style={{ fontSize:12, color:T.slate500 }}>
                  {member.role || "-"}{member.role_level ? ` · ${member.role_level}` : ""} · {member.employment_type === "w2" ? "W-2 Employee" : member.employment_type === "family" ? "Family Employee (W-2)" : member.employment_type === "1099" ? "1099 Contractor" : (member.employment_type || "Employee")} · Since {member.start_date || "-"}
                  {seat && (
                    <span style={{ marginLeft:8, color:T.slate600 }}>· Attributed <strong style={{ color:T.slate900 }}>{fmt$(seat.attributed_revenue_annual)}</strong>/yr</span>
                  )}
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
                {(() => {
                  const asmt = asmtByMember[member.id];
                  if (!asmt) return null;
                  const traits = [
                    ["Ego Drive",           asmt.ego_drive_score],
                    ["Empathy",             asmt.empathy_score],
                    ["Analytical",          asmt.analytical],
                    ["Assertiveness",       asmt.assertiveness],
                    ["Independent Spirit",  asmt.independent_spirit],
                    ["Optimism",            asmt.optimism],
                    ["Deadline Motivation", asmt.deadline_motivation],
                    ["Recognition Drive",   asmt.recognition_drive],
                    ["Self-Promotion",      asmt.self_promotion],
                    ["Belief in Others",    asmt.belief_in_others],
                    ["Compassion",          asmt.compassion],
                  ];
                  // Competency lookup will be rebuilt against the cts_<role>_competencies
                  // SQL functions + cts_best_fit_role. Legacy JSONB columns (sales_competencies,
                  // service_competencies) don't exist, and assessment_type was dropped.
                  // Panel renders empty for now — replaced when the role-fit UI ships.
                  //
                  // overall_score_band + recommended_coaching_hours_min/max were also dropped:
                  // bands are trivially derivable from overall_score if needed, and coaching
                  // guidance is now provided contextually per-candidate instead of static hrs/mo.
                  const compEntries = [];
                  return (
                    <div style={{ marginBottom:12, padding:"10px 12px", background:T.slate50, borderRadius:8, fontSize:11, color:T.slate700, lineHeight:1.6 }}>
                      <div style={{ fontSize:10, fontWeight:700, color:T.slate900, textTransform:"uppercase", letterSpacing:"0.04em", marginBottom:6 }}>Assessment &amp; coaching</div>
                      <div style={{ marginBottom:8, fontSize:11 }}>
                        {asmt.assessment_date && <span style={{ color:T.slate600 }}>{asmt.assessment_date}</span>}
                        {asmt.overall_score != null && <span>{asmt.assessment_date ? " · " : ""}Overall <strong style={{ color:T.slate900 }}>{asmt.overall_score}/100</strong></span>}
                      </div>
                      {(asmt.reliability || asmt.response_distortion) && (
                        <div style={{ marginBottom:8, display:"flex", gap:6, flexWrap:"wrap" }}>
                          {asmt.reliability && (
                            <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.white, border:`1px solid ${T.slate200}`, color:T.slate700 }}>
                              Reliability: <strong style={{ color:T.slate900 }}>{asmt.reliability}</strong>
                            </span>
                          )}
                          {asmt.response_distortion && (
                            <span style={{ fontSize:10, fontWeight:600, padding:"2px 8px", borderRadius:20, background:T.white, border:`1px solid ${T.slate200}`, color:T.slate700 }}>
                              Distortion: <strong style={{ color:T.slate900 }}>{asmt.response_distortion}</strong>
                            </span>
                          )}
                        </div>
                      )}
                      {(() => {
                        const coachingHints = generateCoachingHints(seat, asmt);
                        if (coachingHints.length === 0) return null;
                        return (
                          <div style={{ display:"flex", flexDirection:"column", gap:6, marginBottom:10 }}>
                            {coachingHints.map((h, i) => {
                              const c = sevColor(h.severity);
                              return (
                                <div key={i} style={{ padding:"7px 10px", background:c.bg, borderLeft:`3px solid ${c.border}`, borderRadius:4, fontSize:11, color:T.slate700, lineHeight:1.5 }}>
                                  <strong style={{ color:c.fg }}>{h.title}:</strong> {h.detail}
                                </div>
                              );
                            })}
                          </div>
                        );
                      })()}
                      {(() => {
                        const traj = trajectoryByMember[member.id];
                        const recomputing = !!trajectoryRecomputing[member.id];
                        if (!traj && !recomputing) {
                          return (
                            <div style={{ padding:"7px 10px", marginBottom:10, background:T.slate50, border:`1px dashed ${T.slate200}`, borderRadius:4, fontSize:11, color:T.slate500, display:"flex", justifyContent:"space-between", alignItems:"center", gap:8 }}>
                              <span>No recent trajectory summary yet.</span>
                              <button
                                onClick={(e) => { e.stopPropagation(); recomputeTrajectory(member.id); }}
                                style={{ padding:"3px 10px", fontSize:10, fontWeight:600, color:T.blue, background:T.white, border:`1px solid ${T.blue}`, borderRadius:4, cursor:"pointer" }}
                              >
                                Compute now
                              </button>
                            </div>
                          );
                        }
                        return (
                          <div style={{ padding:"8px 12px", marginBottom:10, background:"#F5F3FF", borderLeft:`3px solid #7C3AED`, borderRadius:4, fontSize:11, color:T.slate700, lineHeight:1.5 }}>
                            <div style={{ display:"flex", justifyContent:"space-between", alignItems:"baseline", gap:8, marginBottom:4 }}>
                              <strong style={{ color:"#5B21B6", fontSize:10, textTransform:"uppercase", letterSpacing:"0.04em" }}>Recent trajectory</strong>
                              <button
                                onClick={(e) => { e.stopPropagation(); if (!recomputing) recomputeTrajectory(member.id); }}
                                disabled={recomputing}
                                style={{ padding:"2px 8px", fontSize:9, fontWeight:600, color:recomputing ? T.slate400 : "#5B21B6", background:"transparent", border:"none", borderRadius:3, cursor:recomputing ? "wait" : "pointer" }}
                              >
                                {recomputing ? "Recomputing…" : "↻ Refresh"}
                              </button>
                            </div>
                            {traj && <div>{traj.summary}</div>}
                            {traj && (
                              <div style={{ fontSize:9, color:T.slate500, marginTop:4 }}>
                                {traj.notes_analyzed_count} note{traj.notes_analyzed_count === 1 ? "" : "s"} analyzed
                                {traj.notes_range_start && traj.notes_range_end && traj.notes_range_start !== traj.notes_range_end && (
                                  <span> · {traj.notes_range_start} → {traj.notes_range_end}</span>
                                )}
                                {traj.notes_range_start && traj.notes_range_start === traj.notes_range_end && (
                                  <span> · {traj.notes_range_start}</span>
                                )}
                                {traj.updated_at && (
                                  <span> · summarized {new Date(traj.updated_at).toLocaleDateString("en-US", { month:"short", day:"numeric" })}</span>
                                )}
                              </div>
                            )}
                          </div>
                        );
                      })()}
                      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(220px, 1fr))", gap:6, marginBottom:8 }}>
                        {traits.map(([label, val]) => <TraitBar key={label} label={label} value={val} />)}
                      </div>
                      {compEntries.length > 0 && (
                        <details style={{ marginBottom:6 }}>
                          <summary style={{ fontSize:10, color:T.blue, cursor:"pointer" }}>{compKind === "sales_competencies" ? "Sales" : "Service"} competencies ({compEntries.length}) ▾</summary>
                          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(220px, 1fr))", gap:6, marginTop:6 }}>
                            {compEntries.map(([k, v]) => {
                              const nice = k.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase());
                              return <TraitBar key={k} label={nice} value={v} />;
                            })}
                          </div>
                        </details>
                      )}
                      {(asmt.lss_total_accuracy != null || asmt.lss_math_speed_seconds != null) && (
                        <div style={{ fontSize:11, color:T.slate600, marginBottom:8 }}>
                          <strong style={{ color:T.slate900 }}>LSS:</strong>
                          {asmt.lss_total_accuracy != null && <span> Accuracy <strong style={{ color:T.slate900 }}>{asmt.lss_total_accuracy}{asmt.lss_total_ideal_min ? " (ideal ≥"+asmt.lss_total_ideal_min+")" : ""}</strong></span>}
                          {asmt.lss_math_speed_seconds != null && <span> · Math <strong style={{ color:T.slate900 }}>{asmt.lss_math_speed_seconds}s</strong></span>}
                          {asmt.lss_verbal_speed_seconds != null && <span> · Verbal <strong style={{ color:T.slate900 }}>{asmt.lss_verbal_speed_seconds}s</strong></span>}
                          {asmt.lss_problem_solving_speed_seconds != null && <span> · Problem-solving <strong style={{ color:T.slate900 }}>{asmt.lss_problem_solving_speed_seconds}s</strong></span>}
                        </div>
                      )}
                      {asmt.notes && (
                        <details style={{ marginBottom:6 }}>
                          <summary style={{ fontSize:10, color:T.blue, cursor:"pointer" }}>Detailed observations ▾</summary>
                          <div style={{ marginTop:6, whiteSpace:"pre-wrap", fontSize:11, color:T.slate700, lineHeight:1.6, padding:"8px 10px", background:T.white, borderRadius:6, border:`1px solid ${T.slate200}` }}>
                            {asmt.notes}
                          </div>
                        </details>
                      )}
                      {(behavioralByMember[member.id] || []).length > 0 && (
                        <details>
                          <summary style={{ fontSize:10, color:T.blue, cursor:"pointer" }}>Recent behavioral notes ({(behavioralByMember[member.id] || []).length}) ▾</summary>
                          <div style={{ marginTop:6, display:"flex", flexDirection:"column", gap:6 }}>
                            {(behavioralByMember[member.id] || []).slice(0, 5).map(n => (
                              <div key={n.id} style={{ padding:"6px 8px", background:T.white, borderRadius:6, border:`1px solid ${T.slate200}` }}>
                                <div style={{ fontSize:9, color:T.slate500, marginBottom:2 }}>{n.observation_date} · {n.pattern_type || "note"}</div>
                                <div style={{ fontSize:11, color:T.slate700, whiteSpace:"pre-wrap" }}>{n.observation_text}</div>
                              </div>
                            ))}
                          </div>
                        </details>
                      )}
                    </div>
                  );
                })()}
                {(() => {
                  const prod = prodByMember[member.id];
                  if (!prod || prod.total_prem <= 0) return null;
                  const monthLabel = (key) => {
                    const [y, m] = key.split("-");
                    return new Date(parseInt(y), parseInt(m) - 1, 1).toLocaleDateString("en-US", { month:"short", year:"2-digit" });
                  };
                  return (
                    <div style={{ marginBottom:12, padding:"10px 12px", background:T.slate50, borderRadius:8, fontSize:11, color:T.slate700, lineHeight:1.6 }}>
                      <div style={{ fontSize:10, fontWeight:700, color:T.slate900, textTransform:"uppercase", letterSpacing:"0.04em", marginBottom:6 }}>Production — trailing 12 months</div>
                      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(120px, 1fr))", gap:8, marginBottom:8 }}>
                        {prod.byLob.map(lob => (
                          <div key={lob.line} style={{ background:T.white, padding:"6px 8px", borderRadius:6, border:`1px solid ${T.slate200}` }}>
                            <div style={{ fontSize:9, color:T.slate500, marginBottom:2 }}>{lob.line}</div>
                            <div style={{ fontSize:12, fontWeight:700, color:T.slate900 }}>{fmt$(lob.prem)}</div>
                            <div style={{ fontSize:9, color:T.slate500, marginTop:2 }}>{lob.pols} polic{lob.pols === 1 ? "y" : "ies"}</div>
                          </div>
                        ))}
                      </div>
                      <div style={{ fontSize:11, color:T.slate600, marginBottom:6 }}>
                        Trailing 12 mo total: <strong style={{ color:T.slate900 }}>{fmt$(prod.total_prem)}</strong> issued premium · <strong style={{ color:T.slate900 }}>{prod.total_pols}</strong> policies
                      </div>
                      <details>
                        <summary style={{ fontSize:10, color:T.blue, cursor:"pointer" }}>Month-by-month ({prod.byMonth.length}) ▾</summary>
                        <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(100px, 1fr))", gap:6, marginTop:6 }}>
                          {prod.byMonth.map(m => (
                            <div key={m.key} style={{ background:T.white, padding:"5px 8px", borderRadius:6, border:`1px solid ${T.slate200}` }}>
                              <div style={{ fontSize:9, color:T.slate500 }}>{monthLabel(m.key)}</div>
                              <div style={{ fontSize:11, fontWeight:600, color:T.slate900 }}>{fmt$(m.prem)}</div>
                              <div style={{ fontSize:9, color:T.slate500 }}>{m.pols} pol</div>
                            </div>
                          ))}
                        </div>
                      </details>
                    </div>
                  );
                })()}
                {seat && (
                  <div style={{ marginBottom:12, padding:"10px 12px", background:T.slate50, borderRadius:8, fontSize:11, color:T.slate700, lineHeight:1.6 }}>
                    <div style={{ fontSize:10, fontWeight:700, color:T.slate900, textTransform:"uppercase", letterSpacing:"0.04em", marginBottom:6 }}>Seat profitability</div>
                    <div style={{ marginBottom:3 }}>
                      Loaded <strong style={{ color:T.slate900 }}>{fmt$(seat.fully_loaded_annual)}</strong>
                      {" · "}Prof bar <strong style={{ color:T.slate900 }}>{fmt$(seat.profitability_bar)}</strong>
                      {" · "}Tenure <strong style={{ color:T.slate900 }}>{(parseFloat(seat.tenure_multiplier) || 0).toFixed(2)}×</strong>
                    </div>
                    <div style={{ marginBottom:3 }}>
                      Attribution:{" "}
                      <strong style={{ color:T.slate900 }}>{fmt$(seat.own_new_business_annualized)}</strong> new×4
                      {" + "}<strong style={{ color:T.slate900 }}>{fmt$(seat.own_renewal_stack_credited)}</strong> stack×0.65
                      {seat.role_category === 'Retention' && (
                        <span>{" + "}<strong style={{ color:T.slate900 }}>{fmt$(seat.retention_pool_share_annual)}</strong> pool×RQM {(parseFloat(seat.retention_quality_multiplier) || 0).toFixed(2)}</span>
                      )}
                      {" = "}<strong style={{ color:T.slate900 }}>{fmt$(seat.attributed_revenue_annual)}</strong>
                    </div>
                    {seatProj && (
                      <div style={{ marginBottom:8 }}>
                        Green: Cov =<span> </span>
                        {seatProj.coverage_green_est_date ? <strong style={{ color:T.slate900 }}>{fmtSeatDate(seatProj.coverage_green_est_date)} ({seatMonthsLabel(seatProj.coverage_green_est_months)})</strong> : <strong style={{ color:'#991B1B' }}>no path</strong>}
                        {" · "}Prof =<span> </span>
                        {seatProj.profitability_green_est_date ? <strong style={{ color:T.slate900 }}>{fmtSeatDate(seatProj.profitability_green_est_date)} ({seatMonthsLabel(seatProj.profitability_green_est_months)})</strong> : <strong style={{ color:'#991B1B' }}>{'>'}5yr</strong>}
                      </div>
                    )}
                    {(() => {
                      const insights = generateSeatInsights(seat, seatProj);
                      const primary = insights.find(i => i.severity === 'action') || insights.find(i => i.severity === 'critical') || insights[0];
                      if (!primary) return null;
                      const c = sevColor(primary.severity);
                      return (
                        <div style={{ padding:"7px 10px", background:c.bg, borderLeft:`3px solid ${c.border}`, borderRadius:4, fontSize:11, color:T.slate700, lineHeight:1.5 }}>
                          <strong style={{ color:c.fg }}>{primary.title}:</strong> {primary.detail}
                        </div>
                      );
                    })()}
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
                      <option value="Outbound">Outbound</option>
                      <option value="Inbound">Inbound</option>
                      <option value="In-Book">In-Book</option>
                      <option value="Reception">Reception</option>
                      <option value="Escalation">Escalation</option>
                      <option value="Support">Support</option>
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
                  <div><label style={labelStyle}>Annual benefits value ($/yr, agency-paid)</label><input style={inputStyle} type="number" step="0.01" min="0" value={form.annual_benefits_value} onChange={e=>setForm({...form, annual_benefits_value:e.target.value})} placeholder="0.00" /></div>
                  <div><label style={labelStyle}>Weekly life benefit ($/wk, agency-paid)</label><input style={inputStyle} type="number" step="0.01" min="0" value={form.weekly_life_benefit_agency_paid} onChange={e=>setForm({...form, weekly_life_benefit_agency_paid:e.target.value})} placeholder="0.00" /></div>
                  <div><label style={labelStyle}>Weekly health benefit ($/wk, agency-paid)</label><input style={inputStyle} type="number" step="0.01" min="0" value={form.weekly_health_benefit_agency_paid} onChange={e=>setForm({...form, weekly_health_benefit_agency_paid:e.target.value})} placeholder="0.00" /></div>
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
          </Fragment>
        );
        });
      })()}
    </div>
  );
};

const GrowthBudgetHeader = () => {
  const [roster, setRoster]           = useState([]);
  const [ytd, setYtd]                 = useState(0);
  const [ceilingInfo, setCeilingInfo] = useState(null);
  const [loading, setLoading]         = useState(true);

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

  const $ = (n) => "$" + Math.round(parseFloat(n)||0).toLocaleString();
  const ceiling         = parseFloat(ceilingInfo?.ceiling_annual || 0);
  const yearStart       = new Date(new Date().getFullYear(), 0, 1);
  const daysElapsed     = Math.max(1, Math.floor((new Date() - yearStart) / 86400000) + 1);
  const proratedCeiling = ceiling * (daysElapsed / 365);
  const status = ceiling <= 0 ? "info"
    : ytd > ceiling ? "danger"
    : ytd > proratedCeiling ? "warning"
    : "success";
  const statusColor = status==="danger" ? T.red : status==="warning" ? T.amber : status==="success" ? T.green : T.blue;

  if (loading) {
    return <Card style={{ padding:"10px 16px", marginBottom:14 }}><div style={{ fontSize:12, color:T.slate500 }}>Growth Budget…</div></Card>;
  }

  return (
    <Card style={{ padding:"10px 16px", marginBottom:14 }}>
      {/* Compressed header line */}
      <div style={{ display:"flex", alignItems:"center", gap:14, flexWrap:"wrap" }}>
        <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>Growth Budget</div>
        <div style={{ fontSize:13, fontWeight:700 }}>
          <span style={{ color:statusColor }}>{$(ytd)}</span>
          <span style={{ color:T.slate400, fontWeight:400, margin:"0 4px" }}>/</span>
          <span style={{ color:T.slate800 }}>{ceiling > 0 ? $(ceiling) : "—"}</span>
        </div>
        <div style={{ flex:"1 1 200px", minWidth:120, maxWidth:340 }}>
          {ceiling > 0 && <ProgressBar value={ytd} max={ceiling} color={statusColor} height={6} />}
        </div>
        <div style={{ fontSize:12, fontWeight:700, color:statusColor, minWidth:38, textAlign:"right" }}>
          {ceiling > 0 ? `${pct(ytd, ceiling)}%` : "—"}
        </div>
      </div>

      {/* Ramping list — one compact line per teammate, always visible */}
      <div style={{ marginTop:10, paddingTop:10, borderTop:`1px solid ${T.slate100}`, display:"flex", flexDirection:"column", gap:6 }}>
        {roster.length === 0 ? (
          <div style={{ fontSize:11, color:T.slate400 }}>No teammates currently in ramp.</div>
        ) : (
          roster.map(p => {
              const tenurePct = parseFloat(p.tenure_multiplier || 0) * 100;
              const weeksIn   = parseInt(p.weeks_since_start || 0);
              return (
                <div key={p.team_member_id} style={{ display:"flex", alignItems:"baseline", gap:12, fontSize:11, color:T.slate600, flexWrap:"wrap" }}>
                  <span style={{ fontWeight:700, color:T.slate800, minWidth:110 }}>{p.full_name}</span>
                  <span>Wk {weeksIn}/52</span>
                  <span>{tenurePct.toFixed(0)}% ramp</span>
                  <span>{$(p.growth_budget_weekly)}/wk shield</span>
                  <span style={{ color:T.slate400 }}>{$(p.growth_budget_remaining_annualized)} left</span>
                </div>
              );
            })
        )}
      </div>
    </Card>
  );
};


// ─── Hypothetical Hire Forecast ───────────────────────────────
// Rendered inside the Recruiting sub-view of the Growth tab. Runs
// get_growth_budget_forecast against annual base + start date; shows Y1
// growth budget, quarter breakdown, and ceiling impact vs current YTD.
const HypotheticalHireForecast = () => {
  const [fcAnnualBase, setFcAnnualBase] = useState("");
  const [fcStartDate, setFcStartDate]   = useState(new Date().toISOString().split("T")[0]);
  const [fcResult, setFcResult]         = useState(null);
  const [fcLoading, setFcLoading]       = useState(false);
  const [fcError, setFcError]           = useState(null);
  const [ytd, setYtd]                   = useState(0);
  const [ceiling, setCeiling]           = useState(0);

  useEffect(() => {
    let cancelled = false;
    async function loadContext() {
      const [ytdRes, ceilingRes] = await Promise.allSettled([
        supabase.from("v_growth_budget_ytd").select("growth_budget_ytd").eq("agency_id", AGENCY_ID),
        supabase.rpc("get_growth_budget_ceiling", { p_agency_id: AGENCY_ID }),
      ]);
      if (cancelled) return;
      const ytdRows = ytdRes.status === "fulfilled" ? (ytdRes.value.data || []) : [];
      setYtd(ytdRows.reduce((s, r) => s + parseFloat(r.growth_budget_ytd || 0), 0));
      const ci = ceilingRes.status === "fulfilled" ? (ceilingRes.value.data || null) : null;
      setCeiling(parseFloat(ci?.ceiling_annual || 0));
    }
    loadContext();
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

  return (
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
  );
};


// ─── Growth Tab ───────────────────────────────────────────────
// Persistent Growth Budget header (with expandable ramping list) always
// visible. Sub-nav toggles between Recruiting and Declined. Onboarding
// lives in the top-level Onboarding module. Hypothetical hire forecast
// lives inside the Recruiting sub-view.
const GrowthTab = ({ applicants, declined, onUpdate }) => {
  const [view, setView] = useTabParam("gtab", "recruiting", ["recruiting","finalists","declined"]);
  // Split the pipeline: top-of-funnel in Recruiting, reference-check-onward in Closing.
  const RECRUITING_STAGES = ["applied","assessed","email_screen","interview"];
  const CLOSING_STAGES    = ["reference_check","offer","hired"];
  const recruitingApps = applicants.filter(a => RECRUITING_STAGES.includes(a.status));
  const closingApps    = applicants.filter(a => CLOSING_STAGES.includes(a.status));
  const subs = [
    { id:"recruiting", label:`Recruiting (${recruitingApps.length})` },
    { id:"finalists",  label:`Finalists (${closingApps.length})` },
    { id:"declined",   label:`Declined (${declined.length})` },
  ];
  return (
    <div>
      {/* Persistent budget header */}
      <GrowthBudgetHeader />

      {/* Sub-nav */}
      <div style={{ display:"flex", gap:2, flexWrap:"wrap", background:T.slate100, borderRadius:8, padding:3, marginBottom:16 }}>
        {subs.map(s => (
          <button
            key={s.id}
            onClick={() => setView(s.id)}
            style={{
              padding:"6px 12px",
              fontSize:11,
              fontWeight: view === s.id ? 600 : 400,
              color: view === s.id ? T.slate900 : T.slate500,
              background: view === s.id ? T.white : "transparent",
              border:"none",
              borderRadius:6,
              cursor:"pointer",
              transition:"all 0.12s",
              boxShadow: view === s.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
            }}
          >
            {s.label}
          </button>
        ))}
      </div>

      {/* Sub-view content */}
      {view === "recruiting" && (
        <div style={{ display:"flex", flexDirection:"column", gap:14 }}>
          <RecruitingPipeline applicants={recruitingApps} onUpdate={onUpdate} stages={RECRUITING_STAGES} />
          <HypotheticalHireForecast />
        </div>
      )}
      {view === "finalists" && (
        <RecruitingPipeline applicants={closingApps} onUpdate={onUpdate} stages={CLOSING_STAGES} />
      )}
      {view === "declined"   && <DeclinedTable declined={declined} onUpdate={onUpdate} />}
    </div>
  );
};




export default function Team() {
  const { data: roi } = useProducerROI();
  const [section, setSection] = useTabParam("tab", "members", ["members","growth"]);
  const [applicants,  setApplicants]  = useState([]);

  // Load applicants from live Supabase table. Empty result yields empty pipeline.
  useEffect(() => {
    if (!supabase || !AGENCY_ID) return;
    let cancelled = false;
    supabase
      .from("hiring_candidates")
      .select("id, first_name, last_name, candidate_name, email, phone, position, status, decline_reason, claude_score, resume_avg, claude_summary, interview_focus, notes, created_at, is_team_member, team_member_id, overall_score, deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism, lss_total_accuracy, lss_math_speed_seconds, lss_verbal_speed_seconds, lss_problem_solving_speed_seconds, va_scored_at, fi_scored_at, resume_document_id, resume_url, reliability, response_distortion, ego_drive_score, empathy_score, leadership_style")
      .eq("agency_id", AGENCY_ID)
      .in("status", ["applied","assessed","email_screen","interview","reference_check","offer","hired","declined","archived"])
      .order("created_at", { ascending: false })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        const normalized = (data || []).map(a => ({
          ...a,
          // Display name fallbacks: first/last → candidate_name → "Unknown"
          first_name: a.first_name || (a.candidate_name ? a.candidate_name.split(" ")[0] : "Unknown"),
          last_name:  a.last_name  || (a.candidate_name ? a.candidate_name.split(" ").slice(1).join(" ") : ""),
          position:   a.position || "—",
          interview_notes: null,
          rating: null,
        }));
        setApplicants(normalized);
      });
    return () => { cancelled = true; };
  }, []);

  const updateApplicantStage = async (id, newStatus) => {
    // Optimistic UI update
    setApplicants(prev => prev.map(a => a.id === id ? {...a, status:newStatus} : a));
    // Persist to DB
    const { error } = await supabase
      .from("hiring_candidates")
      .update({ status: newStatus, status_updated_at: new Date().toISOString() })
      .eq("id", id)
      .select();
    if (error) {
      console.error("Failed to update candidate status:", error);
      // Optionally: revert optimistic update on failure
    }
    // Note: rows keep their place in state after status change. Kanban filters
    // visible-pipeline stages; DeclinedTable renders status='archived' rows.
  };

  const sections = [
    { id:"members",  label:"Members"  },
    { id:"growth",   label:"Growth"   },
  ];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Team</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            {(roi?.allActiveStaff || []).length} active staff · {applicants.filter(a=>!["hired","archived","declined"].includes(a.status)).length} in pipeline · {applicants.filter(a=>a.status==="declined").length} declined · Resume scanner active
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
      {section === "members"  && (
        <StaffDirectory staff={roi?.allActiveStaff || []} />
      )}
      {section === "growth"   && <GrowthTab  applicants={applicants.filter(a => a.status !== "archived" && a.status !== "declined")} declined={applicants.filter(a => a.status === "declined")} onUpdate={updateApplicantStage} />}
    </div>
  );
}
