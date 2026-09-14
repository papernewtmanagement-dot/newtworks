// =========================================================================
// onboardingUi.jsx
// =========================================================================
// Small pieces shared by the onboarding module and the template editor:
// the card/pill/button atoms, the colour maps, and the helpers that read
// and write a step's sub-items.
//
// These all used to live inside Onboarding.jsx. They moved here so the
// editor can use the same ones instead of growing a second copy that
// slowly drifts.
// =========================================================================

import { T } from "./theme.js";

// ─── colour maps ────────────────────────────────────
export const STAGE_LABELS = {
  offer:     { label: "Offer stage", fg: T.purple, bg: T.purpleLt },
  pre_start: { label: "Before Day 1", fg: T.gold,  bg: T.goldLt },
  ramp:      { label: "On the job",   fg: T.blue,  bg: T.blueLt },
};

export const CATEGORY_COLORS = {
  licensing:      { fg: T.green,  bg: T.greenLt,  label: "Licensing" },
  documents:      { fg: T.blue,   bg: T.blueLt,   label: "Documents" },
  compliance:     { fg: T.red,    bg: T.redLt,    label: "Compliance" },
  systems:        { fg: T.teal,   bg: T.tealLt,   label: "Systems" },
  training:       { fg: T.purple, bg: T.purpleLt, label: "Training" },
  physical_setup: { fg: T.gold,   bg: T.goldLt,   label: "Physical setup" },
  role_specific:  { fg: T.pink,   bg: T.pinkLt,   label: "Role-specific" },
};

// Order the picker shows them in. Must stay inside the database check
// constraint on onboarding_step_templates.category.
export const CATEGORY_KEYS = [
  "documents", "systems", "licensing", "compliance",
  "training", "physical_setup", "role_specific",
];

export const STATUS_COLORS = {
  active:    { fg: T.green,    bg: T.greenLt,  label: "Active" },
  paused:    { fg: T.amber,    bg: T.amberLt,  label: "Paused" },
  completed: { fg: T.slate600, bg: T.slate100, label: "Completed" },
  archived:  { fg: T.slate500, bg: T.slate100, label: "Archived" },
};

// ─── sub-item helpers ───────────────────────────────
// Sub-items arrive either as a flat list of strings or as groups the old
// paper checklists used ({ group, items }). Normalize both to groups.
export function subGroups(substeps) {
  if (!Array.isArray(substeps)) return [];
  const out = [];
  let flat = null;
  substeps.forEach(s => {
    if (s && typeof s === "object" && Array.isArray(s.items)) {
      out.push({ group: s.group || null, items: s.items.filter(x => typeof x === "string") });
    } else if (typeof s === "string") {
      if (!flat) { flat = { group: null, items: [] }; out.push(flat); }
      flat.items.push(s);
    }
  });
  return out.filter(g => g.items.length);
}

export function subAll(substeps) {
  return subGroups(substeps).reduce((acc, g) => acc.concat(g.items), []);
}

// Sub-items as plain text for editing. One item per line. A heading line
// ends with a colon and starts a group.
export function substepsToText(substeps) {
  const groups = subGroups(substeps);
  const lines = [];
  groups.forEach(g => {
    if (g.group) {
      if (lines.length) lines.push("");
      lines.push(`${g.group}:`);
    }
    g.items.forEach(it => lines.push(it));
  });
  return lines.join("\n");
}

// Inverse of substepsToText. Keeps the flat shape when no headings were
// used so a plain list never silently turns into a one-group object.
export function textToSubsteps(text) {
  const lines = String(text || "").split("\n").map(l => l.trim());
  const groups = [];
  let cur = null;
  let sawHeading = false;
  lines.forEach(line => {
    if (!line) return;
    if (line.length > 1 && line.endsWith(":")) {
      sawHeading = true;
      cur = { group: line.slice(0, -1).trim(), items: [] };
      groups.push(cur);
      return;
    }
    if (!cur) { cur = { group: null, items: [] }; groups.push(cur); }
    cur.items.push(line);
  });
  const kept = groups.filter(g => g.items.length);
  if (!kept.length) return null;
  if (!sawHeading) return kept[0].items;
  return kept;
}

// A phase with more than one track draws one column per track — the two
// offer-stage columns both have to finish before the next milestone opens.
export function trackColumns(steps) {
  const names = [];
  steps.forEach(s => {
    const t = s.track || null;
    if (!names.includes(t)) names.push(t);
  });
  if (names.length <= 1) return null;
  // track_order decides which column sits on the left.
  const rank = (n) => {
    const hit = steps.find(s => (s.track || null) === n);
    return hit && typeof hit.track_order === "number" ? hit.track_order : 0;
  };
  names.sort((a, b) => rank(a) - rank(b));
  return names.map(n => ({
    name: n,
    steps: steps
      .filter(s => (s.track || null) === n)
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0)),
  }));
}

// ─── shared UI primitives ───────────────────────────
export const trackHeadStyle = {
  fontSize: 11, fontWeight: 700, color: T.slate600,
  textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 2,
};

export const Card = ({ children, style = {} }) => (
  <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: "16px 18px", boxSizing: "border-box", ...style }}>
    {children}
  </div>
);

export const Pill = ({ children, fg = T.slate700, bg = T.slate100, style = {} }) => (
  <span style={{
    display: "inline-block", fontSize: 10, fontWeight: 600,
    color: fg, background: bg,
    padding: "3px 8px", borderRadius: 4, letterSpacing: 0.3,
    textTransform: "uppercase", ...style,
  }}>{children}</span>
);

export const Button = ({ children, onClick, variant = "primary", disabled = false, style = {}, title = undefined }) => {
  const styles = {
    primary:   { bg: T.blue,    fg: T.white,    border: T.blue },
    secondary: { bg: T.white,   fg: T.slate800, border: T.slate300 },
    danger:    { bg: T.white,   fg: T.red,      border: T.red },
    ghost:     { bg: "transparent", fg: T.slate600, border: "transparent" },
  }[variant] || {};
  return (
    <button
      onClick={onClick} disabled={disabled} title={title}
      style={{
        padding: "8px 14px", fontSize: 12, fontWeight: 600,
        color: styles.fg, background: styles.bg,
        border: `1px solid ${styles.border}`, borderRadius: 8,
        boxSizing: "border-box",
        cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.55 : 1,
        transition: "all 0.12s",
        ...style,
      }}
    >{children}</button>
  );
};

export const fieldLabel = {
  fontSize: 11, fontWeight: 600, color: T.slate700,
  textTransform: "uppercase", letterSpacing: 0.4,
  marginBottom: 6, display: "block",
};

export const inputBase = {
  width: "100%", boxSizing: "border-box", padding: "9px 11px", fontSize: 13,
  color: T.slate900, background: T.white,
  border: `1px solid ${T.slate300}`, borderRadius: 8,
  outline: "none",
};
