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
  const [loading, setLoading] = useState(true);
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
        const { data, error } = await supabase.rpc('compute_warning_trigger', {
          p_agency_id: AGENCY_ID,
          p_week_end_date: weekEnd,
        });
        if (cancelled) return;
        if (error) throw error;
        setRows(data || []);
      } catch (e) {
        console.error('Seat profitability load error:', e);
        if (!cancelled) setRows([]);
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

  const first = rows[0];
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
        {rows.length === 0 ? (
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
                {rows.map(r => (
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
          {rows.map(r => (
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
