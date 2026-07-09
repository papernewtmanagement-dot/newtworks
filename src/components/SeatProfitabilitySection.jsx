import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);

// ─── Section: Seat Profitability ──────────────────────────────────
// Renders the compute_warning_trigger output as a per-seat table:
//   Coverage % · Profitability % · Lapse %
// Unified attribution: own_new × 4 + own_stack × 0.65 (Wk52+) + retention_pool_share.
// Retention pool = agency_renewal_TTM × 0.35 × person's weighted hours share.
export default function SeatProfitabilitySection() {
  const [rows, setRows] = useState([]);
  const [projections, setProjections] = useState([]);
  const [scenarioRows, setScenarioRows] = useState([]);
  const [scenarioProjections, setScenarioProjections] = useState([]);
  const [scenarioActive, setScenarioActive] = useState(false);
  const [loading, setLoading] = useState(true);
  const SCENARIO_LAPSE = 0.12;
  const [weekEnd, setWeekEnd] = useState(() => {
    // Default: nearest upcoming Saturday (or today if Saturday)
    const today = new Date();
    const day = today.getDay(); // 0=Sun ... 6=Sat
    const daysUntilSaturday = day === 6 ? 0 : (6 - day);
    const saturday = new Date(today);
    saturday.setDate(today.getDate() + daysUntilSaturday);
    return saturday.toISOString().slice(0, 10);
  });

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      try {
        const [wtRes, projRes, wtScenRes, projScenRes] = await Promise.all([
          supabase.rpc('compute_warning_trigger', {
            p_agency_id: AGENCY_ID,
            p_week_end_date: weekEnd,
          }),
          supabase.rpc('compute_seat_projections_for_agency', {
            p_agency_id: AGENCY_ID,
            p_baseline_date: weekEnd,
            p_max_months: 60,
          }),
          supabase.rpc('compute_warning_trigger', {
            p_agency_id: AGENCY_ID,
            p_week_end_date: weekEnd,
            p_override_lapse: SCENARIO_LAPSE,
          }),
          supabase.rpc('compute_seat_projections_for_agency', {
            p_agency_id: AGENCY_ID,
            p_baseline_date: weekEnd,
            p_max_months: 60,
            p_override_lapse: SCENARIO_LAPSE,
          }),
        ]);
        if (cancelled) return;
        if (wtRes.error) throw wtRes.error;
        setRows(wtRes.data || []);
        if (!projRes.error) setProjections(projRes.data || []);
        if (!wtScenRes.error) setScenarioRows(wtScenRes.data || []);
        if (!projScenRes.error) setScenarioProjections(projScenRes.data || []);
      } catch (e) {
        console.error('Seat profitability load error:', e);
        if (!cancelled) { setRows([]); setProjections([]); setScenarioRows([]); setScenarioProjections([]); }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [weekEnd]);

  if (loading) {
    return (
      <Card>
        <div style={{ padding: "20px 0", textAlign: "center", fontSize: 13, color: T.slate500 }}>
          Loading seat profitability…
        </div>
      </Card>
    );
  }

  // Effective data set (actual vs. scenario)
  const effectiveRows = scenarioActive ? scenarioRows : rows;
  const effectiveProjections = scenarioActive ? scenarioProjections : projections;
  const first = effectiveRows[0];
  const diag = first?.diag || {};
  const agencyRenewalTTM = parseFloat(diag.agency_renewal_ttm || 0);
  const lapseRate = parseFloat(first?.lapse_rate_used || 0);
  const lapseStatus = first?.lapse_status || 'na';

  const fmt$ = (n) => "$" + Math.round(parseFloat(n) || 0).toLocaleString();

  const statusColor = (s) => {
    if (s === 'green')  return { bg: T.greenLt, fg: '#065F46' };
    if (s === 'yellow') return { bg: T.amberLt, fg: '#92400E' };
    if (s === 'red')    return { bg: T.redLt,   fg: '#991B1B' };
    return { bg: T.slate100, fg: T.slate500 };
  };

  // Generate diagnostic insights per person based on their data.
  // Each insight: { severity: 'positive'|'concern'|'critical'|'info', title, detail }
  const generateInsights = (row, projection) => {
    if (!row || !projection) return [];
    const cat = row.role_category;
    const covPct = parseFloat(row.coverage_pct) || 0;
    const profPct = parseFloat(row.profitability_pct) || 0;
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
    const insights = [];

    // 1) Where they stand right now
    if (covPct >= 100) {
      insights.push({
        severity: 'positive',
        title: 'Covering seat',
        detail: `Attributed ${money(attr)} exceeds fully-loaded ${money(fully)}. This seat pays for itself.`,
      });
    } else if (covPct >= 80) {
      insights.push({
        severity: 'concern',
        title: 'Nearly covering',
        detail: `Attributed ${money(attr)} vs ${money(fully)} fully-loaded. Gap of ${money(gap)}/yr \u2014 close, but the seat is still costing the agency money.`,
      });
    } else {
      insights.push({
        severity: 'critical',
        title: 'Not covering seat',
        detail: `Attributed ${money(attr)} vs ${money(fully)} fully-loaded. Losing ${money(gap)}/yr on this seat.`,
      });
    }

    // 2) Root cause + lever, branched by role
    if (cat === 'Sales') {
      if (covMonths === null || covMonths === undefined) {
        insights.push({
          severity: 'critical',
          title: 'Book decaying faster than replaced',
          detail: `Under current new-business pace (${money(ownNew)}/yr commission), existing stack is decaying faster than new production replenishes it. Check trailing quarter vs prior quarters \u2014 if pace has dropped, that's the driver.`,
        });
        insights.push({
          severity: 'info',
          title: 'What moves this',
          detail: `Increase new-business pace. Every $10K additional annualized premium \u2248 $800 immediate commission + ${'~'}$500 future stack credit at maturity. Returning to prior-quarter pace would materially reshape this projection.`,
        });
      } else if (covMonths <= 12) {
        insights.push({
          severity: 'positive',
          title: 'On trajectory',
          detail: `Coverage projected in ${covMonths} month${covMonths === 1 ? '' : 's'}. Book is compounding \u2014 year-1 cohorts are aging into renewal territory.`,
        });
        insights.push({
          severity: 'info',
          title: 'What moves this',
          detail: `Time + maintained pace. Stack grows automatically as monthly cohorts cross the 12-month mark. No coaching needed on activity.`,
        });
      } else if (covMonths <= 36) {
        insights.push({
          severity: 'concern',
          title: 'Long path to coverage',
          detail: `${covMonths} months out. Book is compounding but slowly at current pace. Growing new-business production would compress this timeline significantly.`,
        });
      } else {
        insights.push({
          severity: 'concern',
          title: 'Very long path',
          detail: `${covMonths} months. At current pace the numbers eventually work but the seat runs at a loss for years.`,
        });
      }
      if (profMonths === null || profMonths === undefined) {
        insights.push({
          severity: 'info',
          title: 'Profitability (2.5\u00d7) not within 5-year horizon',
          detail: `Getting to 2.5\u00d7 fully-loaded requires book compounding AND growing new business. Long-term goal, not a short-term signal.`,
        });
      }
    } else {
      // Retention role
      if (covMonths === null || covMonths === undefined) {
        const potentialRetPool = rqm > 0.01 ? retPool * (1.0 / rqm) : retPool;
        const potentialAttr = ownNew + stackCredited + potentialRetPool;
        const potentialCovPct = fully > 0 ? (potentialAttr / fully) * 100 : 0;
        insights.push({
          severity: 'critical',
          title: 'Attributed revenue is static',
          detail: `Retention seats don't grow their own book \u2014 they share the agency's renewal pool. At current 27% lapse, RQM is ${rqm.toFixed(2)}, discounting the pool by ${Math.round((1-rqm)*100)}%.`,
        });
        insights.push({
          severity: 'info',
          title: 'Lever: lower agency lapse',
          detail: `If lapse hit benchmark 12%, RQM would jump to 1.0. This seat's attributed would reach ${money(potentialAttr)}/yr \u2014 that's ${potentialCovPct.toFixed(0)}% Coverage. Lapse investigation is the single biggest lever for this role.`,
        });
      } else {
        insights.push({
          severity: 'concern',
          title: 'Coverage reachable',
          detail: `Projected in ${covMonths} months. Own small book gradually adds to attributed revenue over years.`,
        });
        insights.push({
          severity: 'info',
          title: 'Faster path: reduce agency lapse',
          detail: `Any improvement in agency lapse rate scales retention pool share directly. At benchmark 12%, RQM = 1.0 doubles this seat's attribution overnight.`,
        });
      }
    }

    // 3) Actionable next step
    if (cat === 'Sales') {
      if (covMonths === null) {
        insights.push({
          severity: 'action',
          title: 'Next action',
          detail: `Diagnose the pace drop. Compare this quarter's issued premium to previous 4 quarters. Have an activity conversation: prospecting, quoting, closing \u2014 where's the bottleneck?`,
        });
      } else if (covMonths > 12) {
        insights.push({
          severity: 'action',
          title: 'Next action',
          detail: `Set a stretch goal on quarterly new-business premium. Even modest growth (+20%) meaningfully accelerates the timeline.`,
        });
      } else {
        insights.push({
          severity: 'action',
          title: 'Next action',
          detail: `Keep doing what they're doing. Confirm the trajectory in ${Math.min(covMonths, 3)} months.`,
        });
      }
    } else {
      insights.push({
        severity: 'action',
        title: 'Next action',
        detail: `Prioritize a lapse investigation \u2014 segment the book by cohort age and LOB, identify the churn drivers, then target intervention. This seat's future depends on it.`,
      });
    }

    return insights;
  };

  const Badge = ({ status, pctValue, showPct = true }) => {
    const c = statusColor(status);
    const num = pctValue != null ? Math.round(parseFloat(pctValue)) : null;
    const label = showPct && num != null ? num + "%" : (status || 'na').toUpperCase();
    return (
      <span style={{ display: "inline-block", fontSize: 10, fontWeight: 700, padding: "3px 8px", borderRadius: 20, background: c.bg, color: c.fg, minWidth: 44, textAlign: "center" }}>
        {label}
      </span>
    );
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>

      {/* ─── AGENCY-LEVEL HEADER ──────────────────────────────── */}
      <Card style={{ borderLeft: `4px solid ${T.blue}` }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 10, flexWrap: "wrap", gap: 10 }}>
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Seat Profitability — week ending {weekEnd}</div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2, maxWidth: 620, lineHeight: 1.5 }}>
              <strong>Coverage</strong> = does the seat cover its own fully-loaded cost. <strong>Profitability</strong> = does the seat generate 2.5× its cost (SF 40% payroll target). No tenure ramp — measured against full paid salary. Retention credit scaled by book quality (RQM): high lapse shrinks their attributed revenue.
            </div>
          </div>
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 10 }}>
          <div style={{ background: T.slate50, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Agency Renewal Income TTM</div>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{fmt$(agencyRenewalTTM)}</div>
            <div style={{ fontSize: 10, color: T.slate500, marginTop: 4 }}>trailing 12 months, all lines</div>
          </div>
          <div style={{ background: T.slate50, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Retention Pool (35%)</div>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{fmt$(agencyRenewalTTM * 0.35)}</div>
            <div style={{ fontSize: 10, color: T.slate500, marginTop: 4 }}>split by weighted hours</div>
          </div>
          <div style={{ background: statusColor(lapseStatus).bg, padding: "10px 12px", borderRadius: 8 }}>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Blended Lapse Rate</div>
            <div style={{ fontSize: 16, fontWeight: 700, color: statusColor(lapseStatus).fg }}>
              {(lapseRate * 100).toFixed(1)}%
            </div>
            <div style={{ fontSize: 10, color: T.slate500, marginTop: 4 }}>green ≤12% · yellow ≤20% · red &gt;20%</div>
          </div>
        </div>
      </Card>

      {/* ─── TEAM TABLE ─────────────────────────────────────── */}
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ padding: "12px 16px", borderBottom: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Team — this week's assessment</div>
        </div>
        {effectiveRows.length === 0 ? (
          <div style={{ padding: 20, textAlign: "center", fontSize: 13, color: T.slate500 }}>No team members found for this week.</div>
        ) : (
          <div style={{ overflowX: "auto" }}>
            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
              <thead>
                <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
                  <th style={{ padding: "10px 12px", textAlign: "left",  fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }}>Name</th>
                  <th style={{ padding: "10px 12px", textAlign: "left",  fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }}>Role</th>
                  <th style={{ padding: "10px 12px", textAlign: "right", fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }} title="Displayed for context only — no longer applied to Coverage/Profitability bar">Tenure</th>
                  <th style={{ padding: "10px 12px", textAlign: "right", fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }}>Fully-Loaded</th>
                  <th style={{ padding: "10px 12px", textAlign: "right", fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }}>Attributed</th>
                  <th style={{ padding: "10px 12px", textAlign: "center", fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }}>Coverage</th>
                  <th style={{ padding: "10px 12px", textAlign: "center", fontWeight: 600, color: T.slate500, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" }}>Profitability</th>
                </tr>
              </thead>
              <tbody>
                {effectiveRows.map(r => (
                  <tr key={r.team_member_id} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                    <td style={{ padding: "12px", fontWeight: 600, color: T.slate900 }}>{r.full_name}</td>
                    <td style={{ padding: "12px", color: T.slate700 }}>
                      <div>{r.role}</div>
                      <div style={{ fontSize: 10, color: T.slate500 }}>{r.role_category}</div>
                    </td>
                    <td style={{ padding: "12px", textAlign: "right", color: T.slate700 }}>{(parseFloat(r.tenure_multiplier) || 0).toFixed(2)}×</td>
                    <td style={{ padding: "12px", textAlign: "right", color: T.slate700 }}>{fmt$(r.fully_loaded_annual)}</td>
                    <td style={{ padding: "12px", textAlign: "right", color: T.slate900, fontWeight: 600 }}>{fmt$(r.attributed_revenue_annual)}</td>
                    <td style={{ padding: "12px", textAlign: "center" }}><Badge status={r.coverage_status}      pctValue={r.coverage_pct}      /></td>
                    <td style={{ padding: "12px", textAlign: "center" }}><Badge status={r.profitability_status} pctValue={r.profitability_pct} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {/* ─── ATTRIBUTION BREAKDOWN ───────────────────────────────── */}
      <Card>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Attribution breakdown</div>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {effectiveRows.map(r => (
            <div key={r.team_member_id} style={{ padding: "10px 12px", background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, marginBottom: 6 }}>{r.full_name}</div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 12, fontSize: 11, color: T.slate700 }}>
                <span>Own new × 4: <strong style={{ color: T.slate900 }}>{fmt$(r.own_new_business_annualized)}</strong></span>
                <span>Own stack (× 0.65, Wk52+): <strong style={{ color: T.slate900 }}>{fmt$(r.own_renewal_stack_credited)}</strong></span>
                {r.role_category === 'Retention' && (
                  <span>Retention pool share (× RQM {(parseFloat(r.retention_quality_multiplier) || 0).toFixed(2)}): <strong style={{ color: T.slate900 }}>{fmt$(r.retention_pool_share_annual)}</strong></span>
                )}
                <span style={{ marginLeft: "auto", color: T.slate500 }}>= <strong style={{ color: T.slate900 }}>{fmt$(r.attributed_revenue_annual)}</strong></span>
              </div>
            </div>
          ))}
        </div>
      </Card>

      {/* ─── PROJECTION ─────────────────────────────────── */}
      <Card>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Path to green</div>
        <div style={{ fontSize: 11, color: T.slate500, marginBottom: 10, lineHeight: 1.5 }}>
          Under current conditions (new-business pace, lapse rate, retention pool held constant). 5-year horizon.
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {effectiveProjections.map(p => {
            const fmtDate = (d) => {
              if (!d) return null;
              const dt = new Date(d + 'T00:00:00');
              return dt.toLocaleDateString('en-US', { month: 'short', year: 'numeric' });
            };
            const covDate = fmtDate(p.coverage_green_est_date);
            const profDate = fmtDate(p.profitability_green_est_date);
            const covMonths = p.coverage_green_est_months;
            const profMonths = p.profitability_green_est_months;
            const monthsLabel = (m) => {
              if (m == null) return '';
              if (m === 0) return 'now';
              if (m < 12) return `${m} mo`;
              const y = Math.floor(m / 12);
              const r = m - y * 12;
              return r === 0 ? `${y} yr` : `${y} yr ${r} mo`;
            };
            return (
              <div key={p.team_member_id} style={{ padding: "10px 12px", background: T.slate50, borderRadius: 8 }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", flexWrap: "wrap", gap: 8 }}>
                  <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900 }}>{p.full_name}</div>
                  <div style={{ fontSize: 10, color: T.slate500 }}>{p.role_category} · {p.role}</div>
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginTop: 8 }}>
                  <div>
                    <div style={{ fontSize: 10, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em" }}>Coverage green</div>
                    {covDate ? (
                      <div>
                        <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{covDate}</div>
                        <div style={{ fontSize: 10, color: T.slate500 }}>{monthsLabel(covMonths)}</div>
                      </div>
                    ) : (
                      <div style={{ fontSize: 12, color: '#991B1B', fontWeight: 600 }}>no path under current conditions</div>
                    )}
                  </div>
                  <div>
                    <div style={{ fontSize: 10, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em" }}>Profitability green</div>
                    {profDate ? (
                      <div>
                        <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{profDate}</div>
                        <div style={{ fontSize: 10, color: T.slate500 }}>{monthsLabel(profMonths)}</div>
                      </div>
                    ) : (
                      <div style={{ fontSize: 12, color: '#991B1B', fontWeight: 600 }}>not within 5 years</div>
                    )}
                  </div>
                </div>
                {(() => {
                  const row = effectiveRows.find(r => r.team_member_id === p.team_member_id);
                  if (!row) return null;
                  const insights = generateInsights(row, p);
                  if (insights.length === 0) return null;
                  const sevColor = (s) => {
                    if (s === 'positive') return { border: T.green, bg: T.greenLt, fg: '#065F46', tag: 'Good' };
                    if (s === 'concern')  return { border: T.amber, bg: T.amberLt, fg: '#92400E', tag: 'Watch' };
                    if (s === 'critical') return { border: T.red, bg: T.redLt, fg: '#991B1B', tag: 'Fix' };
                    if (s === 'action')   return { border: T.blue, bg: T.blueLt, fg: '#1E40AF', tag: 'Do' };
                    return { border: T.slate200, bg: T.slate50, fg: T.slate700, tag: 'Info' };
                  };
                  return (
                    <details style={{ marginTop: 10 }}>
                      <summary style={{ fontSize: 11, fontWeight: 600, color: T.blue, cursor: "pointer", userSelect: "none", padding: "4px 0" }}>
                        What this means & what to do →
                      </summary>
                      <div style={{ marginTop: 8, display: "flex", flexDirection: "column", gap: 6 }}>
                        {insights.map((ins, i) => {
                          const c = sevColor(ins.severity);
                          return (
                            <div key={i} style={{ padding: "8px 10px", background: c.bg, borderLeft: `3px solid ${c.border}`, borderRadius: 4 }}>
                              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8, marginBottom: 3 }}>
                                <div style={{ fontSize: 11, fontWeight: 700, color: c.fg }}>{ins.title}</div>
                                <div style={{ fontSize: 9, fontWeight: 700, color: c.fg, background: T.white, padding: "1px 6px", borderRadius: 10, letterSpacing: "0.05em", textTransform: "uppercase" }}>{c.tag}</div>
                              </div>
                              <div style={{ fontSize: 11, color: T.slate700, lineHeight: 1.5 }}>{ins.detail}</div>
                            </div>
                          );
                        })}
                      </div>
                    </details>
                  );
                })()}
              </div>
            );
          })}
        </div>
        <div style={{ marginTop: 10, padding: "8px 10px", background: T.blueLt, borderRadius: 6, fontSize: 10, color: T.slate700, lineHeight: 1.5 }}>
          <strong>What moves these dates:</strong> Sales roles — grow new-business pace, cohorts age past 12mo. Retention roles — lower lapse (bigger RQM → bigger pool share). &quot;No path&quot; means the person's current pace + agency lapse combine such that attributed revenue never crosses their fully-loaded cost within 5 years.
        </div>
      </Card>

            {/* ─── METHODOLOGY FOOTER ─────────────────────────────────── */}
      <Card style={{ background: T.slate50, border: `1px dashed ${T.slate200}` }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: T.slate700, marginBottom: 8 }}>How this is calculated</div>
        <div style={{ fontSize: 11, color: T.slate600, lineHeight: 1.7 }}>
          <div>• <strong>Fully-Loaded:</strong> annual base × 1.08 (TX payroll burden). No tenure ramp — seats evaluated against what we actually pay them.</div>
          <div>• <strong>Attributed Revenue:</strong> own new × 4 + own renewal stack × 0.65 + retention pool share</div>
          <div>• <strong>Retention pool share:</strong> agency renewal TTM × 0.35 × person&apos;s weighted-hours share × <strong>Retention Quality Multiplier (RQM)</strong></div>
          <div>• <strong>RQM:</strong> LEAST(1.0, 12% / actual_lapse_rate). At benchmark (12%) RQM = 1.0. At 27% lapse RQM = 0.44. Retention only gets full credit when the book is being retained at benchmark.</div>
          <div>• <strong>Coverage bar:</strong> fully-loaded. Green ≥100%, Yellow ≥80%, Red &lt;80%.</div>
          <div>• <strong>Profitability bar:</strong> fully-loaded × 2.5 (SF 40% payroll target). Same thresholds.</div>
          <div style={{ marginTop: 6, fontStyle: "italic" }}>65/35 split per core principle: renewal income requires both production and continuous retention. Sales get 100% of new business + 65% of their own stack (stack already decays with actual lapse). Retention gets 35% of agency-wide renewal book, scaled by RQM — so retention pay is tied to how well the book is actually being retained.</div>
        </div>
      </Card>
    </div>
  );
}
