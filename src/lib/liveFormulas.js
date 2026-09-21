// src/lib/liveFormulas.js
//
// The handbook shows the pay formulas as the system actually pays them
// (Peter 2026-09-21): never typed into the page, always read live. A page puts
// a {{live:...}} token where a number or table belongs; fillLiveFormulas swaps
// it for the current value before the markdown renders.
//
// The numbers come from handbook_live_formulas in the database, which reads the
// same sources the pay math does: compute_sp_from_production (sales rates),
// rp_chargeback_window_months, retention_point_values, marketing_point_values.
// Change a rate there and every page that shows it changes with it.
//
// Tokens:
//   {{live:sales-rates-table}}      P&C and L&H: starting rate, cap, what moves it
//   {{live:sales-tier-caps}}        how many times each tier step can repeat
//   {{live:chargeback-windows}}     "6 months for Auto, 12 for everything else"
//   {{live:retention-points-table}} every activity that earns retention points
//   {{live:retention-step}}         "1%"
//   {{live:retention-cap}}          "99"
//   {{live:retention-example}}      a worked example of the step
//   {{live:marketing-points-table}} every event that earns marketing points
//   {{live:marketing-cap}}          "99"

const pct = (x, digits = 2) => {
  const n = Number(x) * 100;
  return `${Number.isFinite(n) ? String(Number(n.toFixed(digits))) : "?"}%`;
};
const money = (x) => {
  const n = Number(x);
  if (!Number.isFinite(n)) return "?";
  return Number.isInteger(n) ? `$${n}` : `$${n.toFixed(2)}`;
};
const num = (x) => {
  const n = Number(x);
  return Number.isFinite(n) ? (Number.isInteger(n) ? String(n) : String(Number(n.toFixed(2)))) : "?";
};
const LINE = { auto: "Auto", fire: "Fire", life: "Life", health: "Health" };

function salesRatesTable(f) {
  const r = f?.sales?.rates || {};
  const t = f?.sales?.tiers || {};
  return [
    "| Rate | Starts at | Cap | What moves it up |",
    "| --- | --- | --- | --- |",
    `| P&C | ${pct(r.pc_base_pct)} | ${pct(r.pc_cap)} | +${pct(r.pc_step_pct)} for every ${money(t.life_dollar_step)} Life premium, every ${t.auto_app_step} Auto cars, every ${t.fire_app_step} Fire policies |`,
    `| L&H | ${pct(r.lh_base_pct)} | ${pct(r.lh_cap)} | +${pct(r.lh_step_pct)} for every ${money(t.life_dollar_step)} Life premium |`,
  ].join("\n");
}

function salesTierCaps(f) {
  const t = f?.sales?.tiers || {};
  return `The tier steps repeat up to a cap: Auto ${t.auto_rep_cap} times (${t.auto_rep_cap * t.auto_app_step} cars), `
    + `Fire ${t.fire_rep_cap} times (${t.fire_rep_cap * t.fire_app_step} policies), Life ${t.life_rep_cap} times.`;
}

function chargebackWindows(f) {
  const m = f?.chargeback_months || {};
  const groups = new Map();
  Object.keys(LINE).forEach((k) => {
    if (m[k] == null) return;
    if (!groups.has(m[k])) groups.set(m[k], []);
    groups.get(m[k]).push(LINE[k]);
  });
  // The most common window reads as "everything else".
  const sorted = [...groups.entries()].sort((a, b) => b[1].length - a[1].length);
  if (!sorted.length) return "the chargeback window";
  const [common, ...rest] = sorted;
  const parts = rest.map(([months, lines]) => `${months} months for ${lines.join(" and ")}`);
  parts.push(`${common[0]} for everything else`);
  return parts.join(", ");
}

function retentionTable(f) {
  const rows = (f?.retention || []).map((v) => `| ${v.label} | ${money(v.points)} |`);
  return ["| What you did | Earns |", "| --- | --- |", ...rows].join("\n");
}

// The step and cap most activities share; flat ones (no step) are left out.
function retentionStepAndCap(f) {
  const stepped = (f?.retention || []).filter((v) => Number(v.step_pct) > 0 && Number(v.cap) > 0);
  const v = stepped[0] || {};
  return { step: Number(v.step_pct || 0), cap: Number(v.cap || 0), stepped };
}

function retentionExample(f) {
  const { stepped } = retentionStepAndCap(f);
  const v = stepped.slice().sort((a, b) => Number(b.points) - Number(a.points))[0];
  if (!v) return "";
  const factor = 1 + (Number(v.step_pct) / 100) * Math.min(Number(v.cap), 4);
  return `Example: your fifth ${v.label} of the quarter pays ${money(v.points)} × ${num(factor)} = ${money(Math.round(Number(v.points) * factor * 100) / 100)}.`;
}

function marketingTable(f) {
  const rows = (f?.marketing || []).map((m) =>
    `| ${m.label} | ${num(m.points)} | ${Number(m.step) > 0 ? num(m.step) : "—"} |`);
  return ["| What happened | Points | Each earlier one this quarter adds |", "| --- | --- | --- |", ...rows].join("\n");
}

export function fillLiveFormulas(md, f) {
  const text = String(md || "");
  if (!text.includes("{{live:")) return text;
  const { step, cap } = retentionStepAndCap(f);
  const mcap = Math.max(0, ...((f?.marketing || []).map((m) => Number(m.cap) || 0)));
  const fill = {
    "sales-rates-table": () => salesRatesTable(f),
    "sales-tier-caps": () => salesTierCaps(f),
    "chargeback-windows": () => chargebackWindows(f),
    "retention-points-table": () => retentionTable(f),
    "retention-step": () => `${num(step)}%`,
    "retention-cap": () => num(cap),
    "retention-example": () => retentionExample(f),
    "marketing-points-table": () => marketingTable(f),
    "marketing-cap": () => num(mcap),
  };
  return text.replace(/\{\{live:([a-z-]+)\}\}/g, (whole, key) => {
    if (!f) return "…";
    const fn = fill[key];
    return fn ? fn() : whole;
  });
}
