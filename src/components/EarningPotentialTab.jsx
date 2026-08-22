import { useState, useEffect, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useTabParam } from "../lib/routing.jsx";
import { useViewport } from "../lib/hooks.js";
import { fmtMoney } from "../lib/format.jsx";

// Growth > Earning Potential. Read-only. One chart: years of employment
// (1-5) across the bottom, dollars up the side. Four total-pay lines, one
// per performer tier, plus a dashed base-pay line for the tier that is
// highlighted in the legend. Everything comes from one call to
// compute_role_earnings_projection — nothing here is stored as a "current"
// value, and nothing on this page writes.

const ROLE_ORDER = ["sales", "retention", "life_specialist"];

// Colours escalate with the tier. Brand supporting accents only (theme.js).
const TIER_COLORS = {
  rock:        T.slate500,
  rock_n_roll: T.teal,
  rockstar:    T.gold,
  rock_legend: T.purple,
};
const tierColor = (key) => TIER_COLORS[key] || T.blue;

const fmtK = (n) => {
  const v = Number(n) || 0;
  if (Math.abs(v) >= 1000) return "$" + Math.round(v / 1000) + "K";
  return "$" + Math.round(v);
};
const fmtPct = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "";
  return (Number.isInteger(v) ? v : v.toFixed(1)) + "%";
};
const fmtWeekEnd = (iso) => {
  if (!iso) return "";
  const [y, m, d] = String(iso).split("-").map(Number);
  if (!y || !m || !d) return String(iso);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
};

// Pick a clean dollar step for the gridlines ($10K / $25K / $50K depending
// on the spread) and round the axis ceiling up to it, with a little headroom
// so the top line never kisses the frame.
const axisFor = (max) => {
  if (!(max > 0)) return { max: 50000, step: 10000 };
  const step = max > 150000 ? 50000 : max > 60000 ? 25000 : 10000;
  const ceil = Math.ceil(max / step) * step;
  return { max: ceil - max < step * 0.15 ? ceil + step : ceil, step };
};

// ─── Chart ───────────────────────────────────────────────────
// Inline SVG, same approach as the CPR sparkline. viewBox + width 100% so
// it fills its card and scales on a phone without a chart library.
const EarningsLineChart = ({ tiers, highlighted, baseMode, isPhone }) => {
  const W = isPhone ? 400 : 680;
  const H = isPhone ? 240 : 280;
  const padL = isPhone ? 40 : 50, padR = isPhone ? 56 : 74, padT = 28, padB = 30;
  const chartW = W - padL - padR;
  const chartH = H - padT - padB;

  const years = [1, 2, 3, 4, 5];
  const allTotals = (tiers || []).flatMap(t => (t.years || []).map(y => Number(y.total) || 0));
  const allBases  = (tiers || []).flatMap(t => (t.years || []).map(y => Number(y.base) || 0));
  const { max: maxY, step: tickStep } = axisFor(Math.max(0, ...allTotals, ...allBases));
  const ticks = [];
  for (let v = 0; v <= maxY; v += tickStep) ticks.push(v);

  const xFor = (yr) => padL + ((yr - 1) / 4) * chartW;
  const yFor = (v)  => padT + chartH - (Math.max(0, Number(v) || 0) / maxY) * chartH;
  const pathFor = (vals) => vals.map((v, i) => (i === 0 ? "M " : " L ") + xFor(i + 1).toFixed(1) + " " + yFor(v).toFixed(1)).join("");

  const seriesOf = (t, key) => years.map(yr => {
    const row = (t.years || []).find(y => Number(y.year) === yr);
    return row ? Number(row[key]) || 0 : 0;
  });

  // Year-5 labels to the right of each line, nudged apart so they never overlap.
  const endLabels = useMemo(() => {
    const items = (tiers || []).map(t => {
      const tot = seriesOf(t, "total");
      return { key: t.tier_key, label: fmtK(tot[4]), y: yFor(tot[4]), color: tierColor(t.tier_key) };
    }).sort((a, b) => a.y - b.y);
    const minGap = 12;
    for (let i = 1; i < items.length; i++) {
      if (items[i].y - items[i - 1].y < minGap) items[i].y = items[i - 1].y + minGap;
    }
    // If the bottom label was pushed below the plot, shove the stack back up.
    const overflow = items.length ? items[items.length - 1].y - (padT + chartH + 4) : 0;
    if (overflow > 0) items.forEach(it => { it.y -= overflow; });
    return items;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tiers, W, H]);

  if (!Array.isArray(tiers) || tiers.length === 0) return null;

  const fontTick = isPhone ? 9 : 10;
  const fontEnd  = isPhone ? 9.5 : 11;

  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" style={{ display: "block", maxWidth: 820 }} role="img" aria-label="Projected total pay by year of employment and performer tier">
      {/* Y gridlines + labels */}
      {ticks.map(v => (
        <g key={v}>
          <line x1={padL} y1={yFor(v)} x2={padL + chartW} y2={yFor(v)} stroke={T.slate200} strokeWidth="1" />
          <text x={padL - 5} y={yFor(v) + 3.5} textAnchor="end" fontSize={fontTick} fill={T.slate500}>{fmtK(v)}</text>
        </g>
      ))}
      {/* X axis labels */}
      {years.map(yr => (
        <text key={yr} x={xFor(yr)} y={H - 9} textAnchor="middle" fontSize={fontTick} fill={T.slate500}>
          {isPhone ? "Yr " + yr : "Year " + yr}
        </text>
      ))}
      {/* Base pay: dashed. Either one line for the highlighted tier, or all four muted. */}
      {tiers.map(t => {
        const show = baseMode === "all" || t.tier_key === highlighted;
        if (!show) return null;
        const muted = baseMode === "all";
        return (
          <path key={"base-" + t.tier_key}
            d={pathFor(seriesOf(t, "base"))}
            stroke={muted ? T.slate400 : tierColor(t.tier_key)}
            strokeWidth={muted ? 1.25 : 1.75}
            strokeDasharray="5 4"
            fill="none"
            opacity={muted ? 0.55 : 0.8} />
        );
      })}
      {/* Total pay: one solid line per tier. Highlighted tier drawn last and thicker. */}
      {[...tiers].sort((a, b) => (a.tier_key === highlighted) - (b.tier_key === highlighted)).map(t => {
        const hot = t.tier_key === highlighted;
        const tot = seriesOf(t, "total");
        const c = tierColor(t.tier_key);
        return (
          <g key={"tot-" + t.tier_key} opacity={hot ? 1 : 0.85}>
            <path d={pathFor(tot)} stroke={c} strokeWidth={hot ? 3 : 2} fill="none" strokeLinejoin="round" strokeLinecap="round" />
            {tot.map((v, i) => (
              <circle key={i} cx={xFor(i + 1)} cy={yFor(v)} r={hot ? 3.5 : 2.75} fill={c} />
            ))}
          </g>
        );
      })}
      {/* Year-5 value labels */}
      {endLabels.map(it => (
        <text key={"end-" + it.key} x={padL + chartW + 6} y={it.y + 3.5} fontSize={fontEnd} fontWeight={it.key === highlighted ? 700 : 600} fill={it.color}>
          {it.label}
        </text>
      ))}
      {/* Legend for the dashed line */}
      <g>
        <line x1={padL} y1={9} x2={padL + 18} y2={9} stroke={T.slate400} strokeWidth="1.5" strokeDasharray="5 4" />
        <text x={padL + 22} y={12.5} fontSize={fontTick} fill={T.slate500}>Base pay</text>
        <line x1={padL + 76} y1={9} x2={padL + 94} y2={9} stroke={T.slate700} strokeWidth="2.25" />
        <text x={padL + 98} y={12.5} fontSize={fontTick} fill={T.slate500}>Total pay</text>
      </g>
    </svg>
  );
};

// ─── Breakdown table for one tier ───────────────────────────
const TierBreakdown = ({ tier, roleKey }) => {
  const yrs = Array.isArray(tier?.years) ? [...tier.years].sort((a, b) => Number(a.year) - Number(b.year)) : [];
  if (yrs.length === 0) return null;
  const anyExtras = yrs.some(y => (Number(y.extras) || 0) !== 0);
  const rows = [
    { k: "base",       label: "Base pay" },
    { k: "commission", label: roleKey === "life_specialist" ? "Life commission" : "Commission" },
    { k: "bonus_pool", label: "Bonus pool share" },
    { k: "goals_bonus", label: "Goals bonus" },
    ...(anyExtras ? [{ k: "extras", label: "Year-one extras" }] : []),
    { k: "total",      label: "Total", bold: true },
  ];
  const th = { padding: "6px 10px", fontSize: 10, fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.4, color: T.slate500, textAlign: "right", borderBottom: `1px solid ${T.slate200}`, whiteSpace: "nowrap" };
  const td = { padding: "6px 10px", fontSize: 12, color: T.slate700, textAlign: "right", borderBottom: `1px solid ${T.slate100}`, whiteSpace: "nowrap" };
  return (
    <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
      <table style={{ borderCollapse: "collapse", width: "100%", minWidth: 520 }}>
        <thead>
          <tr>
            <th style={{ ...th, textAlign: "left" }}>{tier.tier_label}</th>
            {yrs.map(y => <th key={y.year} style={th}>Year {y.year}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.k} style={r.bold ? { background: T.slate50 } : undefined}>
              <td style={{ ...td, textAlign: "left", fontWeight: r.bold ? 700 : 500, color: r.bold ? T.slate900 : T.slate700 }}>{r.label}</td>
              {yrs.map(y => (
                <td key={y.year} style={{ ...td, fontWeight: r.bold ? 700 : 400, color: r.bold ? T.slate900 : T.slate700 }}>
                  {fmtMoney(y[r.k], { dashOnZero: r.k !== "base" && r.k !== "total" })}
                  {r.k === "base" && y.step_label && (
                    <div style={{ fontSize: 9.5, color: T.slate400, fontWeight: 400, marginTop: 1 }}>{y.step_label}</div>
                  )}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

// ─── Tab ─────────────────────────────────────────────────────
export default function EarningPotentialTab() {
  const _vp = useViewport();
  const [roleKey, setRoleKey] = useTabParam("erole", "sales", ROLE_ORDER);
  const [highlighted, setHighlighted] = useState("rock");
  // "selected" = dashed base line for the highlighted tier only.
  // "all" = all four base lines, muted. Toggle lives in the chart header.
  const [baseMode, setBaseMode] = useState("selected");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);

  const load = async () => {
    setLoading(true); setErr(null);
    const { data: d, error } = await supabase.rpc("compute_role_earnings_projection", { p_agency_id: AGENCY_ID });
    if (error) { console.error("compute_role_earnings_projection failed:", error); setErr(error.message || "Request failed"); setData(null); }
    else setData(d || null);
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const roles = useMemo(() => {
    const list = Array.isArray(data?.roles) ? data.roles : [];
    return [...list].sort((a, b) => ROLE_ORDER.indexOf(a.role_key) - ROLE_ORDER.indexOf(b.role_key));
  }, [data]);
  const role = roles.find(r => r.role_key === roleKey) || roles[0] || null;
  const tiers = Array.isArray(role?.tiers) ? role.tiers : [];
  const hotTier = tiers.find(t => t.tier_key === highlighted) || tiers[0] || null;

  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "14px 16px" : "16px 20px";
  const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: _pad };

  if (err) {
    return (
      <div style={{ ...card, textAlign: "center", padding: "28px 16px" }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: T.slate700, marginBottom: 4 }}>Couldn't load the earnings projection</div>
        <div style={{ fontSize: 12, color: T.slate500, marginBottom: 14 }}>{err}</div>
        <button onClick={load} style={{ padding: "7px 16px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: "pointer" }}>Retry</button>
      </div>
    );
  }
  if (loading) {
    return <div style={{ fontSize: 12, color: T.slate400, textAlign: "center", padding: "28px 16px" }}>Loading earnings projection…</div>;
  }
  if (!role || tiers.length === 0) {
    return <div style={{ ...card, fontSize: 12, color: T.slate500 }}>No projection rows yet. Add tiers and base-pay ladder rows to populate this page.</div>;
  }

  // Life Specialist year-one extras note. One distinct note → show it plainly;
  // notes that differ by tier → show the highlighted tier's with its label.
  const y1Notes = tiers.map(t => (t.years || []).find(y => Number(y.year) === 1)?.extras_note).filter(Boolean);
  const distinctNotes = [...new Set(y1Notes)];
  const hotY1Note = (hotTier?.years || []).find(y => Number(y.year) === 1)?.extras_note || null;
  const extrasNote = distinctNotes.length === 1 ? distinctNotes[0] : hotY1Note;
  const extrasPrefix = distinctNotes.length > 1 && hotTier ? hotTier.tier_label + " — " : "";

  const a = data?.assumptions || {};
  const btn = (active) => ({
    padding: "7px 14px", fontSize: 12, fontWeight: active ? 700 : 500,
    color: active ? T.white : T.slate700, background: active ? T.blue : T.white,
    border: `1px solid ${active ? T.blue : T.slate200}`, borderRadius: 7, cursor: "pointer", flexShrink: 0,
  });

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      {/* Role buttons */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {roles.map(r => (
            <button key={r.role_key} onClick={() => setRoleKey(r.role_key)} style={btn(r.role_key === role.role_key)}>{r.role_label}</button>
          ))}
        </div>
        <div style={{ fontSize: 11, color: T.slate500 }}>
          Based on the week ending {fmtWeekEnd(data?.as_of_week)}
        </div>
      </div>

      {/* Chart */}
      <div style={card}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8, flexWrap: "wrap", marginBottom: 6 }}>
          <div>
            <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{role.role_label} — projected total pay by year</div>
            <div style={{ fontSize: 11, color: T.slate500 }}>Solid lines are total pay for each tier. The dashed line is base pay. Tap a tier below to highlight it.</div>
          </div>
          <button onClick={() => setBaseMode(m => (m === "all" ? "selected" : "all"))}
            style={{ fontSize: 11, fontWeight: 600, color: T.slate600, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 6, padding: "4px 10px", cursor: "pointer", flexShrink: 0 }}>
            {baseMode === "all" ? "Show base for highlighted tier" : "Show base for all tiers"}
          </button>
        </div>
        <EarningsLineChart tiers={tiers} highlighted={hotTier?.tier_key} baseMode={baseMode} isPhone={_vp.isPhone} />
        {role.role_key === "life_specialist" && extrasNote && (
          <div style={{ marginTop: 8, fontSize: 11.5, color: T.slate700, background: T.goldLt, border: `1px solid ${T.gold}`, borderRadius: 7, padding: "7px 10px" }}>
            {extrasPrefix}{extrasNote}
          </div>
        )}
      </div>

      {/* Tier legend */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 10 }}>
        {tiers.map(t => {
          const hot = t.tier_key === hotTier?.tier_key;
          const c = tierColor(t.tier_key);
          return (
            <button key={t.tier_key} onClick={() => setHighlighted(t.tier_key)}
              style={{ textAlign: "left", background: T.white, border: `2px solid ${hot ? c : T.slate200}`, borderRadius: 10, padding: "10px 12px", cursor: "pointer", boxShadow: hot ? "0 1px 4px rgba(0,0,0,0.08)" : "none" }}>
              <span style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
                <span style={{ width: 22, height: 4, background: c, borderRadius: 2, display: "inline-block", flexShrink: 0 }} />
                <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{t.tier_label}</span>
                <span style={{ fontSize: 11, fontWeight: 600, color: c, marginLeft: "auto", whiteSpace: "nowrap" }}>{fmtPct(t.applicant_pct)} of applicants</span>
              </span>
              <span style={{ display: "block", fontSize: 11.5, color: T.slate600, lineHeight: 1.4 }}>{t.descriptor}</span>
            </button>
          );
        })}
      </div>

      {/* Year-by-year breakdown for the highlighted tier */}
      {hotTier && (
        <div style={card}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>
            Year-by-year for {hotTier.tier_label}
          </div>
          <TierBreakdown tier={hotTier} roleKey={role.role_key} />
        </div>
      )}

      {/* Assumptions */}
      <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.5 }}>
        {a.note && <div>{a.note}</div>}
        <details style={{ marginTop: 6 }}>
          <summary style={{ cursor: "pointer", color: T.slate600, fontWeight: 600 }}>Model inputs</summary>
          <div style={{ marginTop: 4, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: "4px 16px" }}>
            <div>Bonus pool basis (annual): <b style={{ color: T.slate700 }}>{fmtMoney(a.pool_basis_annual)}</b></div>
            <div>Weekly bonus pool: <b style={{ color: T.slate700 }}>{fmtMoney(a.weekly_bonus_pool, { decimals: 2 })}</b></div>
            <div>Bonus dollars per sales point: <b style={{ color: T.slate700 }}>{fmtMoney(a.bonus_dollars_per_sales_point, { decimals: 4 })}</b></div>
            <div>Bonus dollars per weighted hour, weekly: <b style={{ color: T.slate700 }}>{fmtMoney(a.bonus_dollars_per_weighted_hour_weekly, { decimals: 4 })}</b></div>
            <div>Weekly sales-point targets: <b style={{ color: T.slate700 }}>Sales {a.sales_points_target_weekly?.sales ?? "—"} · Retention {a.sales_points_target_weekly?.retention ?? "—"}</b></div>
          </div>
        </details>
      </div>
    </div>
  );
}
