import { useState, useEffect, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { useViewport } from "../lib/hooks.js";
import { fmtMoney } from "../lib/format.jsx";

// Team > Earning Potential. Read-only. One chart: production across the
// bottom (weekly sales points; annual life premium for the Life Specialist
// seat), dollars up the side. Three lines — dashed base pay stepping up at
// each pay-band raise, base plus commission, and total pay with the team
// bonus on top — climbing from the bottom to the top. Shaded background bands
// mark the performance ranges (sales: the Sales Points rating bands, fed
// by the pay_scale table through the projection). Everything comes from one
// call to compute_role_earnings_projection — nothing here is stored as a
// "current" value, and nothing on this page writes.

const ROLE_ORDER = ["sales", "retention", "life_specialist"];

// Colours escalate with the tier. Brand supporting accents only (theme.js).
// Band names and performer-tier names are the same vocabulary as of
// 2026-08-28 (Peter): Danger / Casual / Rock / Rockstar / Rock Legend.
// Keys arrive lower-cased, so "Rock Legend" reaches here as "rock legend"
// from the band config and as "rock_legend" from the tier table.
const TIER_COLORS = {
  danger:        T.red,
  casual:        T.amber,
  rock:          T.green,
  rock_n_roll:   T.teal,
  rockstar:      T.gold,
  rock_legend:   T.purple,
  "rock legend": T.purple,
};
const TIER_BAND_FILLS = {
  danger:        T.redLt,
  casual:        T.amberLt,
  rock:          T.greenLt,
  rock_n_roll:   T.tealLt,
  rockstar:      T.goldLt,
  rock_legend:   T.purpleLt,
  "rock legend": T.purpleLt,
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

// Three lines (Peter 2026-08-28): base pay on its own, base plus
// commission on its own, and the full total with the team bonus on top.
// "place" is which side of its own line that line's dollar labels sit on.
const CURVE_LINES = [
  { key: "base",      label: "Base pay",          color: T.slate500, dash: "5 4", w: 1.75, place: "below" },
  { key: "base_comm", label: "Base + commission", color: T.teal,     dash: null,  w: 2.25, place: "below" },
  { key: "total",     label: "Total pay",         color: T.blue,     dash: null,  w: 2.75, place: "above" },
];

// Dotted vertical every 100 weekly sales points, with the dollar figure at
// every crossing on every line (Peter 2026-08-28). Point axes only — the
// Life Specialist axis is premium dollars, where a line every 100 would be
// meaningless.
const GRID_POINT_STEP = 100;

const EarningsCurveChart = ({ curve, tiers, highlighted, isPhone }) => {
  const points = Array.isArray(curve?.points) ? curve.points : [];
  const bands  = Array.isArray(curve?.bands)  ? curve.bands  : [];
  const xMax   = Number(curve?.x_max) || 0;
  const isPremium = curve?.x_kind === "annual_life_premium";

  const W = isPhone ? 400 : 1100;
  const H = isPhone ? 500 : 600;
  const padL = isPhone ? 40 : 56, padR = isPhone ? 14 : 20;
  const padT = 28;
  const padB = isPhone ? 40 : 44;
  const chartW = W - padL - padR;
  const chartH = H - padT - padB;

  // Base + commission is sent by the projection; fall back to adding the
  // two parts for any older payload that predates the field.
  const valOf = (p, key) => {
    if (key === "base_comm" && p?.base_comm == null) {
      return (Number(p?.base) || 0) + (Number(p?.commission) || 0);
    }
    return Number(p?.[key]) || 0;
  };

  const allY = points.flatMap(p => [valOf(p, "total"), valOf(p, "base"), valOf(p, "base_comm")]);
  const { max: maxY, step: tickStep } = axisFor(Math.max(0, ...allY));
  const yTicks = [];
  for (let v = 0; v <= maxY; v += tickStep) yTicks.push(v);

  const xStep = xStepFor(xMax, isPremium);
  const xTicks = [];
  for (let v = 0; v <= xMax; v += xStep) xTicks.push(v);

  // Dotted verticals every 100 points.
  const gridXs = useMemo(() => {
    if (isPremium || !(xMax > 0)) return [];
    const out = [];
    for (let v = GRID_POINT_STEP; v <= xMax + 0.001; v += GRID_POINT_STEP) out.push(v);
    return out;
  }, [xMax, isPremium]);

  const xFor = (x) => padL + (Math.max(0, Number(x) || 0) / (xMax || 1)) * chartW;
  const yFor = (v) => padT + chartH - (Math.max(0, Number(v) || 0) / maxY) * chartH;
  const pathFor = (key) => points.map((p, i) => (i === 0 ? "M " : " L ") + xFor(p.x).toFixed(1) + " " + yFor(valOf(p, key)).toFixed(1)).join("");
  // Any line's value at any x, interpolated between the two nearest points.
  const valueAt = (key, x) => {
    if (points.length === 0) return 0;
    let lo = points[0], hi = points[points.length - 1];
    for (let i = 0; i < points.length - 1; i++) {
      const a = points[i], b = points[i + 1];
      if ((Number(a.x) || 0) <= x && x <= (Number(b.x) || 0)) { lo = a; hi = b; break; }
    }
    const x0 = Number(lo.x) || 0, x1 = Number(hi.x) || 0;
    const t0 = valOf(lo, key), t1 = valOf(hi, key);
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
  const fontDot  = isPhone ? 8 : 9;

  // Where each line gets a dollar figure. Band transitions on the base and
  // base-plus-commission lines, every 100-point crossing on all three. Keep
  // a minimum gap so nothing stacks up on a phone — the further-left label
  // wins, and the total line yields to the band markers it already carries.
  const bandXs = bands.map(b => Number(b.from_x) || 0).filter(v => v > 0);
  const minGapPx = isPhone ? 30 : 34;
  const thin = (xs, seed) => {
    const kept = [...(seed || [])];
    const out = [];
    for (const x of [...new Set(xs)].sort((a, b) => a - b)) {
      const px = xFor(x);
      if (kept.some(k => Math.abs(xFor(k) - px) < minGapPx)) continue;
      kept.push(x);
      out.push(x);
    }
    return out;
  };
  const labelXs = {
    base:      thin([...gridXs, ...bandXs]),
    base_comm: thin([...gridXs, ...bandXs]),
    total:     thin(gridXs, bandXs),
  };

  // Which performer tier sits in which band (Peter 2026-08-28): a tier's
  // production level is its multiplier against the role's weekly target, so
  // it falls inside whichever band covers that level. On the computed
  // curves the band IS the tier, so only the percentage gets added.
  const tierTargetX = curve?.source === "pay_scale" ? 100 : null;
  const tiersInBand = (bandKey, fromX, toX) => {
    const list = Array.isArray(tiers) ? tiers : [];
    return list.filter(t => {
      const norm = (v) => String(v || "").replace(/[\s_]+/g, "");
      if (norm(t.tier_key) === norm(bandKey)) return true;
      if (tierTargetX == null) return false;
      const tx = tierTargetX * (Number(t.multiplier) || 1);
      return tx >= fromX && tx < toX;
    }).map(t => ({
      key: t.tier_key,
      text: String(t.tier_label || "").replace(/[\s_]+/g, "").toLowerCase() === String(bandKey || "").replace(/[\s_]+/g, "")
               ? fmtPct(t.applicant_pct)
               : t.tier_label + " " + fmtPct(t.applicant_pct),
    }));
  };

  // Legend runs left to right; widths are rough but stable at both sizes.
  const legendStep = (label) => 24 + label.length * (isPhone ? 4.4 : 5.0) + 12;
  let legendAcc = 0;
  const legendAt = CURVE_LINES.map(l => {
    const at = legendAcc;
    legendAcc += legendStep(l.label);
    return at;
  });

  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" style={{ display: "block" }} role="img" aria-label="Projected annual pay by production level: base pay, base plus commission, and total pay, with performance bands shaded">
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
              <>
                <text x={x0 + wPx / 2} y={padT + 12} textAnchor="middle" fontSize={9} fontWeight={hot ? 800 : 700} fill={tierColor(m.key)} letterSpacing="0.3">{m.label}</text>
                {tiersInBand(m.key, m.fromX, m.toX).map((tb, ti) => (
                  <text key={"tb-" + m.key + "-" + tb.key} x={x0 + wPx / 2} y={padT + 24 + ti * 11}
                    textAnchor="middle" fontSize={8.5} fontWeight={600} fill={tierColor(m.key)} opacity="0.85">{tb.text}</text>
                ))}
              </>
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
      {/* Every-100-points dotted verticals */}
      {gridXs.map(v => (
        <line key={"gx" + v} x1={xFor(v)} y1={padT} x2={xFor(v)} y2={padT + chartH}
          stroke={T.slate400} strokeWidth="1.25" strokeDasharray="3 4" opacity="0.45" />
      ))}
      {/* X ticks + axis title */}
      {xTicks.map(v => (
        <text key={"x" + v} x={xFor(v)} y={padT + chartH + 13} textAnchor="middle" fontSize={fontTick} fill={T.slate500}>
          {isPremium ? fmtK(v) : Math.round(v)}
        </text>
      ))}
      <text x={padL + chartW / 2} y={H - 6} textAnchor="middle" fontSize={fontTick} fontWeight={600} fill={T.slate400}>{curve.x_label}</text>
      {/* The three pay lines */}
      {CURVE_LINES.map(l => (
        <path key={"line-" + l.key} d={pathFor(l.key)} stroke={l.color}
          strokeWidth={isPhone ? Math.max(1.5, l.w - 0.25) : l.w}
          strokeDasharray={l.dash || undefined}
          fill="none" strokeLinejoin="round" strokeLinecap="round"
          opacity={l.key === "base" ? 0.9 : 1} />
      ))}
      {/* Dollar figures where the lines cross the markers */}
      {CURVE_LINES.map(l => (
        <g key={"lab-" + l.key}>
          {labelXs[l.key].map(x => {
            const v = valueAt(l.key, x);
            const px = xFor(x), py = yFor(v);
            const anchor = px > padL + chartW - 30 ? "end" : px < padL + 26 ? "start" : "middle";
            const dy = l.place === "above" ? -7 : 12;
            return (
              <g key={l.key + "-" + x}>
                <circle cx={px} cy={py} r={2.4} fill={l.color} stroke={T.white} strokeWidth="1" />
                <text x={px} y={py + dy} textAnchor={anchor} fontSize={fontDot} fontWeight={600} fill={l.color}>{fmtK(v)}</text>
              </g>
            );
          })}
        </g>
      ))}
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
      {/* Legend */}
      <g>
        {CURVE_LINES.map((l, i) => (
          <g key={"lg-" + l.key}>
            <line x1={padL + legendAt[i]} y1={9} x2={padL + legendAt[i] + 18} y2={9}
              stroke={l.color} strokeWidth={l.w} strokeDasharray={l.dash || undefined} />
            <text x={padL + legendAt[i] + 22} y={12.5} fontSize={fontTick} fill={T.slate500}>{l.label}</text>
          </g>
        ))}
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


// ─── First year path to $100k (Sales) ───────────────────────
// Replaces the tier-by-year grid for Sales. Each rung is a weekly
// sales-point pace read live off the published pay scale, so the table
// moves with the scale. The closing note is the point of the table: the
// timeline belongs to the person, not the plan.
const YearOnePath = ({ path, isPhone }) => {
  const rungs = Array.isArray(path?.rungs) ? path.rungs : [];
  if (rungs.length === 0) return null;
  const th = { padding: "6px 10px", fontSize: 10, fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.4, color: T.slate500, textAlign: "right", borderBottom: `1px solid ${T.slate200}`, whiteSpace: "nowrap" };
  const td = { padding: "8px 10px", fontSize: 12, color: T.slate700, textAlign: "right", borderBottom: `1px solid ${T.slate100}`, whiteSpace: "nowrap" };
  const rows = [
    { k: "weekly_sales_points", label: "Weekly sales points", fmt: v => Number(v).toLocaleString() },
    { k: "base_annual",  label: "Base pay",   fmt: v => fmtMoney(v), sub: r => r.rate_label },
    { k: "commission",   label: "Commission", fmt: v => fmtMoney(v) },
    { k: "bonus",        label: "Team bonus", fmt: v => fmtMoney(v) },
    { k: "total",        label: "Annual pay at that pace", fmt: v => fmtMoney(v), bold: true },
  ];
  return (
    <div>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ borderCollapse: "collapse", width: "100%", minWidth: isPhone ? 460 : 560 }}>
          <thead>
            <tr>
              <th style={{ ...th, textAlign: "left" }}>Milestone</th>
              {rungs.map(r => (
                <th key={r.step} style={th}>
                  <div>{r.step_label}</div>
                  <div style={{ fontSize: 11, fontWeight: 800, color: T.slate900, marginTop: 2, textTransform: "none", letterSpacing: 0 }}>
                    {r.pace_label} {fmtMoney(r.target_annual)}
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map(row => (
              <tr key={row.k} style={row.bold ? { background: T.slate50 } : undefined}>
                <td style={{ ...td, textAlign: "left", fontWeight: row.bold ? 700 : 500, color: row.bold ? T.slate900 : T.slate700 }}>{row.label}</td>
                {rungs.map(r => (
                  <td key={r.step} style={{ ...td, fontWeight: row.bold ? 700 : 400, color: row.bold ? T.slate900 : T.slate700 }}>
                    {row.fmt(r[row.k])}
                    {row.sub && row.sub(r) && (
                      <div style={{ fontSize: 9.5, color: T.slate400, fontWeight: 400, marginTop: 1 }}>{row.sub(r)}</div>
                    )}
                  </td>
                ))}
              </tr>
            ))}
            <tr>
              <td style={{ ...td, textAlign: "left", fontWeight: 500, borderBottom: "none" }}>Range at that pace</td>
              {rungs.map(r => (
                <td key={r.step} style={{ ...td, borderBottom: "none" }}>
                  <span style={{ display: "inline-block", padding: "2px 8px", borderRadius: 999, fontSize: 11, fontWeight: 700, color: T.slate700, background: T.slate100 }}>{r.band}</span>
                </td>
              ))}
            </tr>
          </tbody>
        </table>
      </div>
      {path?.note && (
        <div style={{ marginTop: 12, fontSize: 12, lineHeight: 1.55, color: T.slate700, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "10px 12px" }}>
          {path.note}
        </div>
      )}
    </div>
  );
};

// ─── Tab ─────────────────────────────────────────────────────
export default function EarningPotentialTab() {
  const _vp = useViewport();
  const [roleKey, setRoleKey, roleHref] = useTabParam("erole", "sales", ROLE_ORDER);
  const [highlighted, setHighlighted] = useState("rock");
  const [data, setData] = useState(null);
  const [y1, setY1] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);

  const load = async () => {
    setLoading(true); setErr(null);
    const { data: d, error } = await supabase.rpc("compute_role_earnings_projection", { p_agency_id: AGENCY_ID });
    if (error) { console.error("compute_role_earnings_projection failed:", error); setErr(error.message || "Request failed"); setData(null); }
    else setData(d || null);
    const { data: p1, error: e1 } = await supabase.rpc("year_one_path_to_100k", { p_agency_id: AGENCY_ID });
    if (e1) { console.error("year_one_path_to_100k failed:", e1); setY1(null); }
    else setY1(p1 || null);
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
          <div style={{ fontSize: 11, color: T.slate500 }}>Three lines: dashed is base pay, the middle line adds commission, the top line adds the team bonus. Dotted verticals mark every hundred weekly points, with the dollars at each crossing. Shaded bands mark the performance ranges, with the performer tier that lands in each.</div>
        </div>
        {curve ? (
          <EarningsCurveChart curve={curve} tiers={tiers} highlighted={hotTier?.tier_key} isPhone={_vp.isPhone} />
        ) : (
          <div style={{ fontSize: 12, color: T.slate500, padding: "14px 0" }}>No curve data returned for this role.</div>
        )}
        <div style={{ marginTop: 4, fontSize: 10.5, color: T.slate400 }}>
          {role.role_key === "sales" ? "Held at a steady production pace. The table below shows how a first year can build up to it." : "Held at a steady production pace. Years one and two typically run lower — the year-by-year table below shows the ramp."}
        </div>
        {role.role_key === "life_specialist" && extrasNote && (
          <div style={{ marginTop: 8, fontSize: 11.5, color: T.slate700, background: T.goldLt, border: `1px solid ${T.gold}`, borderRadius: 7, padding: "7px 10px" }}>
            {extrasPrefix}{extrasNote}
          </div>
        )}
      </div>

      {/* Sales: first-year path to $100k. Other roles keep the tier grid. */}
      {role.role_key === "sales" && y1 && (
        <div style={card}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900, marginBottom: 2 }}>
            A first year to a hundred thousand
          </div>
          {y1.headline && (
            <div style={{ fontSize: 11, color: T.slate500, marginBottom: 8 }}>{y1.headline}</div>
          )}
          <YearOnePath path={y1} isPhone={_vp.isPhone} />
        </div>
      )}
      {role.role_key !== "sales" && hotTier && (
        <div style={card}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, flexWrap: "wrap", marginBottom: 6 }}>
            <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900 }}>
              Year-by-year for {hotTier.tier_label}
            </div>
            <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
              {tiers.map(t => (
                <button key={t.tier_key} onClick={() => setHighlighted(t.tier_key)}
                  style={{ padding: "3px 8px", fontSize: 11, fontWeight: t.tier_key === hotTier.tier_key ? 700 : 500,
                    color: t.tier_key === hotTier.tier_key ? T.white : T.slate600,
                    background: t.tier_key === hotTier.tier_key ? tierColor(t.tier_key) : T.white,
                    border: `1px solid ${t.tier_key === hotTier.tier_key ? tierColor(t.tier_key) : T.slate200}`,
                    borderRadius: 6, cursor: "pointer" }}>{t.tier_label}</button>
              ))}
            </div>
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
            <div>Share of agency earnings funding the pool: <b style={{ color: T.slate700 }}>{fmtPct(a.pool_pct_used)}</b></div>
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
