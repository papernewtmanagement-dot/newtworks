import { useState, useEffect, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { useViewport } from "../lib/hooks.js";
import { fmtMoney } from "../lib/format.jsx";

// Team > Earning Potential. Read-only. One chart: production across the
// bottom (weekly sales points; annual life premium for the Life Specialist
// seat), dollars up the side. Two lines — dashed base pay stepping up at
// each pay-band raise, solid total pay (base + commission + bonuses)
// climbing smoothly from the bottom to the top. Shaded background bands
// mark the performance ranges (sales: the Sales Points rating bands, fed
// by the pay_scale table through the projection). Everything comes from one
// call to compute_role_earnings_projection — nothing here is stored as a
// "current" value, and nothing on this page writes.

const ROLE_ORDER = ["sales", "retention", "life_specialist"];

// Colours escalate with the tier. Brand supporting accents only (theme.js).
const TIER_COLORS = {
  rock:        T.slate500,
  rock_n_roll: T.teal,
  rockstar:    T.gold,
  rock_legend: T.purple,
  danger:      T.red,
  caution:     T.amber,
  good:        T.green,
  great:       T.gold,
  elite:       T.purple,
};
const TIER_BAND_FILLS = {
  rock:        T.slate200,
  rock_n_roll: T.tealLt,
  rockstar:    T.goldLt,
  rock_legend: T.purpleLt,
  danger:      T.redLt,
  caution:     T.amberLt,
  good:        T.greenLt,
  great:       T.goldLt,
  elite:       T.purpleLt,
};
const tierColor = (key) => TIER_COLORS[key] || T.blue;
const tierBandFill = (key) => TIER_BAND_FILLS[key] || T.slate100;

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
  // Every $25k on the y axis (Peter 2026-08-28).
  if (!(max > 0)) return { max: 50000, step: 25000 };
  const step = 25000;
  const ceil = Math.ceil(max / step) * step;
  return { max: ceil - max < step * 0.15 ? ceil + step : ceil, step };
};

// Clean step for the production axis. Sales-point axes get round point
// counts; the Life premium axis gets round dollar amounts.
const xStepFor = (xMax, isPremium) => {
  if (isPremium) return xMax > 300000 ? 100000 : xMax > 120000 ? 50000 : 25000;
  // Every 100 points on the sales x axis (Peter 2026-08-28).
  return xMax > 400 ? 100 : xMax > 160 ? 50 : 25;
};

// ─── Chart ───────────────────────────────────────────────────
// Inline SVG, same approach as the CPR sparkline. viewBox + width 100% so
// it fills the full available width and scales on a phone without a chart
// library.

// Temporary comparison overlay (Peter, 2026-08-28): the locked band
// concept — starts at 1x / 3x / 6x / 10x of the Danger width — drawn a
// second time at the width below, as a ribbon above the sales chart.
// Remove once the Danger width is decided.
const COMPARE_DANGER_WIDTH = 60;
const BAND_SEQ = [
  { key: "danger",  label: "Danger"  },
  { key: "caution", label: "Caution" },
  { key: "good",    label: "Good"    },
  { key: "great",   label: "Great"   },
  { key: "elite",   label: "Elite"   },
];

const EarningsCurveChart = ({ curve, highlighted, isPhone }) => {
  const points = Array.isArray(curve?.points) ? curve.points : [];
  const bands  = Array.isArray(curve?.bands)  ? curve.bands  : [];
  const xMax   = Number(curve?.x_max) || 0;
  const isPremium = curve?.x_kind === "annual_life_premium";

  // Comparison bands at COMPARE_DANGER_WIDTH — sales pay-scale chart only.
  const compare = useMemo(() => {
    if (curve?.source !== "pay_scale" || !(xMax > 0)) return null;
    const d = COMPARE_DANGER_WIDTH;
    const starts = [0, d, 3 * d, 6 * d, 10 * d];
    return BAND_SEQ.map((b, i) => ({
      key: b.key, label: b.label,
      fromX: starts[i],
      toX: i < starts.length - 1 ? Math.min(starts[i + 1], xMax) : xMax,
    })).filter(s => s.fromX < xMax);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [curve]);

  const W = isPhone ? 400 : 1100;
  const H = isPhone ? 500 : 600;
  const padL = isPhone ? 40 : 56, padR = isPhone ? 14 : 20;
  const padT = compare ? 46 : 28;
  const padB = isPhone ? 40 : 44;
  const chartW = W - padL - padR;
  const chartH = H - padT - padB;

  const allY = points.flatMap(p => [Number(p.total) || 0, Number(p.base) || 0]);
  const { max: maxY, step: tickStep } = axisFor(Math.max(0, ...allY));
  const yTicks = [];
  for (let v = 0; v <= maxY; v += tickStep) yTicks.push(v);

  const xStep = xStepFor(xMax, isPremium);
  const xTicks = [];
  for (let v = 0; v <= xMax; v += xStep) xTicks.push(v);

  const xFor = (x) => padL + (Math.max(0, Number(x) || 0) / (xMax || 1)) * chartW;
  const yFor = (v) => padT + chartH - (Math.max(0, Number(v) || 0) / maxY) * chartH;
  const pathFor = (key) => points.map((p, i) => (i === 0 ? "M " : " L ") + xFor(p.x).toFixed(1) + " " + yFor(p[key]).toFixed(1)).join("");
  // Total pay at any x, interpolated between the two nearest curve points.
  const totalAt = (x) => {
    if (points.length === 0) return 0;
    let lo = points[0], hi = points[points.length - 1];
    for (let i = 0; i < points.length - 1; i++) {
      const a = points[i], b = points[i + 1];
      if ((Number(a.x) || 0) <= x && x <= (Number(b.x) || 0)) { lo = a; hi = b; break; }
    }
    const x0 = Number(lo.x) || 0, x1 = Number(hi.x) || 0;
    const t0 = Number(lo.total) || 0, t1 = Number(hi.total) || 0;
    if (x1 === x0) return t0;
    const f = Math.min(1, Math.max(0, (x - x0) / (x1 - x0)));
    return t0 + f * (t1 - t0);
  };

  // Total pay at each band's production level, for the threshold markers.
  const markers = useMemo(() => bands.map((b, i) => {
    const fx = Number(b.from_x) || 0;
    let best = null;
    for (const p of points) {
      const d = Math.abs((Number(p.x) || 0) - fx);
      if (!best || d < best.d) best = { d, total: Number(p.total) || 0 };
    }
    const next = bands[i + 1];
    return {
      key: b.tier_key,
      label: b.tier_label,
      fromX: fx,
      toX: next ? Number(next.from_x) || xMax : xMax,
      total: best ? best.total : 0,
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [curve]);

  if (points.length === 0 || bands.length === 0) return null;

  const fontTick = isPhone ? 9 : 10;
  const fontMark = isPhone ? 9 : 10;
  const ribbonY = 24, ribbonH = 16;

  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" style={{ display: "block" }} role="img" aria-label="Projected annual pay by production level, with performance bands shaded">
      {/* Performance bands */}
      {markers.map(m => {
        const x0 = xFor(m.fromX), x1 = xFor(m.toX);
        const wPx = Math.max(0, x1 - x0);
        const hot = m.key === highlighted;
        const labelHoriz = wPx >= (isPhone ? 58 : 66);
        return (
          <g key={"band-" + m.key}>
            <rect x={x0} y={padT} width={wPx} height={chartH} fill={tierBandFill(m.key)} opacity={hot ? 0.85 : 0.45} />
            <line x1={x0} y1={padT} x2={x0} y2={padT + chartH} stroke={tierColor(m.key)} strokeWidth="1" opacity="0.5" strokeDasharray="2 3" />
            {wPx >= 22 && (labelHoriz ? (
              <text x={x0 + wPx / 2} y={padT + 12} textAnchor="middle" fontSize={9} fontWeight={hot ? 800 : 700} fill={tierColor(m.key)} letterSpacing="0.3">{m.label}</text>
            ) : (
              <text x={x0 + wPx / 2} y={padT + chartH / 2} textAnchor="middle" fontSize={8.5} fontWeight={hot ? 800 : 700} fill={tierColor(m.key)} letterSpacing="0.3"
                transform={`rotate(-90 ${(x0 + wPx / 2).toFixed(1)} ${(padT + chartH / 2).toFixed(1)})`}>{m.label}</text>
            ))}
          </g>
        );
      })}
      {/* Y gridlines + labels */}
      {yTicks.map(v => (
        <g key={"y" + v}>
          <line x1={padL} y1={yFor(v)} x2={padL + chartW} y2={yFor(v)} stroke={T.slate200} strokeWidth="1" opacity="0.8" />
          <text x={padL - 5} y={yFor(v) + 3.5} textAnchor="end" fontSize={fontTick} fill={T.slate500}>{fmtK(v)}</text>
        </g>
      ))}
      {/* X ticks + axis title */}
      {xTicks.map(v => (
        <text key={"x" + v} x={xFor(v)} y={padT + chartH + 13} textAnchor="middle" fontSize={fontTick} fill={T.slate500}>
          {isPremium ? fmtK(v) : Math.round(v)}
        </text>
      ))}
      <text x={padL + chartW / 2} y={H - 6} textAnchor="middle" fontSize={fontTick} fontWeight={600} fill={T.slate400}>{curve.x_label}</text>
      {/* Comparison drop lines */}
      {compare && compare.map(c => c.fromX > 0 && (
        <line key={"cd-" + c.key} x1={xFor(c.fromX)} y1={ribbonY + ribbonH} x2={xFor(c.fromX)} y2={padT + chartH}
          stroke={tierColor(c.key)} strokeWidth="1.25" strokeDasharray="3 4" opacity="0.5" />
      ))}
      {/* Base pay: dashed step line */}
      <path d={pathFor("base")} stroke={T.slate500} strokeWidth="1.75" strokeDasharray="5 4" fill="none" opacity="0.9" />
      {/* Total pay: solid line */}
      <path d={pathFor("total")} stroke={T.blue} strokeWidth={isPhone ? 2.5 : 2.75} fill="none" strokeLinejoin="round" strokeLinecap="round" />
      {/* Band threshold markers on the total line */}
      {markers.map(m => {
        if (!(m.fromX > 0)) return null;
        const hot = m.key === highlighted;
        const px = xFor(m.fromX), py = yFor(m.total);
        const anchor = px > padL + chartW - 34 ? "end" : "middle";
        return (
          <g key={"mk-" + m.key}>
            <circle cx={px} cy={py} r={hot ? 4.5 : 3.5} fill={tierColor(m.key)} stroke={T.white} strokeWidth="1.5" />
            <text x={anchor === "end" ? px + 4 : px} y={py - 8} textAnchor={anchor} fontSize={fontMark} fontWeight={hot ? 800 : 700} fill={tierColor(m.key)}>{fmtK(m.total)}</text>
          </g>
        );
      })}
      {/* Total pay at the comparison transitions: hollow markers, label below the line */}
      {compare && compare.map(c => {
        if (!(c.fromX > 0)) return null;
        const tv = totalAt(c.fromX);
        const px = xFor(c.fromX), py = yFor(tv);
        const anchor = px > padL + chartW - 34 ? "end" : "middle";
        return (
          <g key={"cmk-" + c.key}>
            <circle cx={px} cy={py} r={3.5} fill={T.white} stroke={tierColor(c.key)} strokeWidth="2" />
            <text x={anchor === "end" ? px + 4 : px} y={py + 15} textAnchor={anchor} fontSize={fontMark} fontWeight={700} fill={tierColor(c.key)}>{fmtK(tv)}</text>
          </g>
        );
      })}
      {/* Comparison ribbon */}
      {compare && (
        <g>
          <text x={padL} y={21} fontSize={9} fontWeight={700} fill={T.slate500}>If Danger = {COMPARE_DANGER_WIDTH}</text>
          {compare.map(c => {
            const x0 = xFor(c.fromX), wPx = Math.max(0, xFor(c.toX) - x0);
            return (
              <g key={"cr-" + c.key}>
                <rect x={x0} y={ribbonY} width={wPx} height={ribbonH} fill={tierBandFill(c.key)} opacity="0.9" stroke={tierColor(c.key)} strokeWidth="0.5" strokeOpacity="0.4" />
                {wPx >= 44 && (
                  <text x={x0 + wPx / 2} y={ribbonY + ribbonH / 2 + 2.8} textAnchor="middle" fontSize={8} fontWeight={700} fill={tierColor(c.key)}>{c.label}</text>
                )}
                {c.fromX > 0 && (
                  <text x={x0} y={padT - 3} textAnchor="middle" fontSize={8.5} fontWeight={600} fill={tierColor(c.key)}>{Math.round(c.fromX)}</text>
                )}
              </g>
            );
          })}
        </g>
      )}
      {/* Legend */}
      <g>
        <line x1={padL} y1={9} x2={padL + 18} y2={9} stroke={T.slate500} strokeWidth="1.5" strokeDasharray="5 4" />
        <text x={padL + 22} y={12.5} fontSize={fontTick} fill={T.slate500}>Base pay</text>
        <line x1={padL + 76} y1={9} x2={padL + 94} y2={9} stroke={T.blue} strokeWidth="2.25" />
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
  const [roleKey, setRoleKey, roleHref] = useTabParam("erole", "sales", ROLE_ORDER);
  const [highlighted, setHighlighted] = useState("rock");
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
  const curve = role?.curve || null;
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
            <TabLink key={r.role_key} href={roleHref(r.role_key)} onSelect={() => setRoleKey(r.role_key)} style={btn(r.role_key === role.role_key)}>{r.role_label}</TabLink>
          ))}
        </div>
        <div style={{ fontSize: 11, color: T.slate500 }}>
          Based on the week ending {fmtWeekEnd(data?.as_of_week)}
        </div>
      </div>

      {/* Chart */}
      <div style={card}>
        <div style={{ marginBottom: 6 }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{role.role_label} — projected annual pay by {curve?.x_label ? curve.x_label.toLowerCase() : "production level"}</div>
          <div style={{ fontSize: 11, color: T.slate500 }}>Solid line is total pay, dashed is base pay. Shaded bands mark the performance ranges. Tap a tier below to highlight it.</div>
        </div>
        {curve ? (
          <EarningsCurveChart curve={curve} highlighted={hotTier?.tier_key} isPhone={_vp.isPhone} />
        ) : (
          <div style={{ fontSize: 12, color: T.slate500, padding: "14px 0" }}>No curve data returned for this role.</div>
        )}
        <div style={{ marginTop: 4, fontSize: 10.5, color: T.slate400 }}>
          Held at a steady production pace. Years one and two typically run lower — the year-by-year table below shows the ramp.
        </div>
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
            <div>Weekly bonus pool (quarter average): <b style={{ color: T.slate700 }}>{fmtMoney(a.weekly_bonus_pool, { decimals: 2 })}</b></div>
            <div>Rest of team, weekly sales points: <b style={{ color: T.slate700 }}>{Number(a.rest_of_team_weekly_sp || 0).toLocaleString()}</b></div>
            <div>Team weighted retention hours, weekly: <b style={{ color: T.slate700 }}>{Number(a.team_weighted_hours_weekly || 0).toLocaleString()}</b></div>
            <div>Weekly sales-point targets: <b style={{ color: T.slate700 }}>Sales {a.sales_points_target_weekly?.sales ?? "—"} · Retention {a.sales_points_target_weekly?.retention ?? "—"}</b></div>
          </div>
        </details>
      </div>
    </div>
  );
}
