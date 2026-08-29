// Server-renders the Earning Potential chart at both breakpoints and asserts
// the things that have actually broken in production. See README.md.
import React from "react";
import { renderToString } from "react-dom/server";
import { EarningsCurveChart } from "../../src/components/EarningPotentialTab.jsx";

const X_MAX = 750;
const LADDER = [];
for (let t = 0; t <= 14; t++) {
  LADDER.push({
    tier: t, hourly: 15 + t, weekly: (15 + t) * 40, annual: (15 + t) * 2080,
    threshold: t === 0 ? null : 100 + (t - 1) * 50,
    lookback_quarters: t === 0 ? null : Math.min(t, 4),
  });
}
const stepBase = (x) => {
  let v = LADDER[0].annual;
  for (const r of LADDER) if (r.threshold !== null && x >= r.threshold) v = r.annual;
  return v;
};

// Bonus is deliberately lumpy here: the real one is solved per row against a
// commission rate curve that steps, and that raggedness is what the smoothing
// has to absorb.
const points = [];
for (let x = 0; x <= X_MAX; x += 10) {
  const base = stepBase(x), commission = x * 52;
  const bonus = Math.round(x * 70 + (Math.floor(x / 70) % 3) * 900);
  points.push({ x, base, commission, base_comm: base + commission, bonus,
                total: base + commission + bonus });
}

const curve = {
  x_kind: "weekly_sales_points", x_label: "Weekly sales points", x_max: X_MAX,
  entry_base: 31200, source: "pay_scale", points,
  bands: [
    { tier_key: "danger",  tier_label: "Danger",  from_x: 0,   nickname: null,          applicant_pct: null, traits: null },
    { tier_key: "caution", tier_label: "Caution", from_x: 50,  nickname: "Casual",      applicant_pct: 75,   traits: null },
    { tier_key: "good",    tier_label: "Good",    from_x: 150, nickname: "Rock",        applicant_pct: 19,   traits: "Consistent" },
    { tier_key: "great",   tier_label: "Great",   from_x: 300, nickname: "Rockstar",    applicant_pct: 5,    traits: "Consistent, Having Fun" },
    { tier_key: "elite",   tier_label: "Elite",   from_x: 500, nickname: "Rock Legend", applicant_pct: 1,    traits: "Consistent, Having Fun, Obsessed" },
  ],
};

const draw = (ladder, isPhone) =>
  renderToString(React.createElement(EarningsCurveChart, { curve, ladder, highlighted: "good", isPhone }))
    .replace(/<!--[\s\S]*?-->/g, "");   // SSR splits adjacent text nodes with comments

const moneyLabels = (html) =>
  [...html.matchAll(/<text[^>]*>(\$[0-9,.]+K?)<\/text>/g)].map((m) => m[1]);

// The bug was two identical figures on the SAME line — grouping by fill
// keeps the three pay lines and the band markers from being counted
// together, which would either hide a real repeat or invent a fake one.
const repeated = (html, isPhone) => {
  const padL = isPhone ? 40 : 56;
  const byColour = {};
  for (const m of html.matchAll(/<text x="([\d.]+)"[^>]*fill="([^"]+)"[^>]*>(\$[0-9,.]+K?)<\/text>/g)) {
    // The y-axis scale sits in the left gutter and shares the base line's
    // colour — it is the axis, not a repeated point label.
    if (parseFloat(m[1]) <= padL) continue;
    (byColour[m[2]] ||= {});
    byColour[m[2]][m[3]] = (byColour[m[2]][m[3]] || 0) + 1;
  }
  const out = [];
  for (const [colour, counts] of Object.entries(byColour)) {
    for (const [text, n] of Object.entries(counts)) {
      if (n > 1) out.push(`${text} x${n} on ${colour}`);
    }
  }
  return out;
};

// Sign flips in the second difference of the drawn total path = visible zigzag.
const kinks = (html) => {
  const d = (html.match(/<path d="([^"]+)"[^>]*stroke-width="2.75"/) || [])[1] || "";
  const ys = [...d.matchAll(/[ML] [\d.]+ ([\d.]+)/g)].map((m) => parseFloat(m[1]));
  let n = 0;
  for (let i = 2; i < ys.length; i++) {
    if (ys[i] - ys[i - 1] - (ys[i - 1] - ys[i - 2]) > 0.6) n++;
  }
  return n;
};

// Each raise rung must sit on its own weekly pace on the axis.
const worstRungDrift = (html, isPhone) => {
  const vb = html.match(/viewBox="0 0 (\d+) (\d+)"/);
  const W = Number(vb[1]);
  const padL = isPhone ? 40 : 56, padR = isPhone ? 14 : 20;
  const chartW = W - padL - padR;
  const rungs = [...html.matchAll(/<text x="([\d.]+)"[^>]*font-weight="800"[^>]*>\$(\d+)\/hr</g)]
    .map((m) => ({ px: parseFloat(m[1]), hourly: Number(m[2]) }));
  if (rungs.length === 0) return { drift: 999, count: 0 };
  const drift = rungs.map((r) => {
    const row = LADDER.find((l) => l.hourly === r.hourly);
    const x = row.threshold === null ? 0 : row.threshold;
    return Math.abs(r.px - (padL + (x / X_MAX) * chartW));
  });
  return { drift: Math.max(...drift), count: rungs.length };
};

// The 50-point spacing in use today happens not to collide, so the
// duplicate-label guard needs the spacing that actually produced the bug:
// uneven rungs, where two label positions on one sloped run both rounded to
// $35K and both drew.
const UNEVEN = [0, 100, 180, 250, 300, 330, 360, 390, 430, 470, 510, 560, 610, 660, 720];
const unevenLadder = UNEVEN.map((t, i) => ({
  tier: i, hourly: 15 + i, weekly: (15 + i) * 40, annual: (15 + i) * 2080,
  threshold: i === 0 ? null : t, lookback_quarters: i === 0 ? null : Math.min(i, 4),
}));
const unevenCurve = {
  ...curve,
  points: points.map((p) => {
    let base = unevenLadder[0].annual;
    for (const r of unevenLadder) if (r.threshold !== null && p.x >= r.threshold) base = r.annual;
    return { ...p, base, base_comm: base + p.commission, total: base + p.commission + p.bonus };
  }),
};

export function run() {
  let failed = 0;
  const fail = (m) => { console.log("  FAIL " + m); failed++; };

  for (const isPhone of [false, true]) {
    const label = isPhone ? "phone  " : "desktop";
    const html = draw(LADDER, isPhone);

    const wanted = ["Danger", "Casual 75%", "Rock 19%", "Consistent",
                    "Rockstar 5%", "Rock Legend 1%", "Obsessed",
                    "Base", "Commission", "Bonuses", "Raises", "$15/hr", "$29/hr"];
    const missing = wanted.filter((t) => !html.includes(t));
    if (missing.length) fail(`${label}: missing text — ${missing.join(", ")}`);

    if (/>(800|900|1000)</.test(html)) fail(`${label}: axis runs past the band pattern`);
    if (/\$1[5-9]<\/text>|\$2[0-9]<\/text>/.test(html)) fail(`${label}: bare hourly rate on the plot`);

    const dupes = repeated(html, isPhone);
    if (dupes.length) fail(`${label}: repeated money labels — ${dupes.join(", ")}`);

    const k = kinks(html);
    if (k > 0) fail(`${label}: ${k} kink(s) in the total line`);

    const { drift, count } = worstRungDrift(html, isPhone);
    if (count === 0) fail(`${label}: no raise rungs drawn`);
    if (drift > 0.6) fail(`${label}: rung off its axis position by ${drift.toFixed(2)}px`);

    console.log(`  ${label}  ${count} rungs, ${drift.toFixed(2)}px drift, ${k} kinks, ` +
                `${dupes.length} repeats, ${missing.length} missing`);
  }

  // Duplicate-label guard, on the spacing that produced the bug.
  const unevenHtml = renderToString(React.createElement(EarningsCurveChart,
    { curve: unevenCurve, ladder: unevenLadder, highlighted: "good", isPhone: false }))
    .replace(/<!--[\s\S]*?-->/g, "");
  const unevenDupes = repeated(unevenHtml, false);
  if (unevenDupes.length) fail(`uneven spacing: repeated money labels — ${unevenDupes.join(", ")}`);
  console.log(`  uneven   ${unevenDupes.length} repeats (guard against the $35K duplicate)`);

  console.log(failed ? `\nchart checks: ${failed} FAILED` : "\nchart checks: all passed");
  return failed === 0;
}
