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

import { useState, createContext, useContext } from "react";
import { T } from "./theme.js";
import { supabase } from "./supabase.js";
import InfoDot from "../components/InfoDot.jsx";
import TeamForms from "../components/TeamForms.jsx";

// A link to a site form opens that form in a pop-up over the page instead of
// leaving it. FormPopupProvider supplies the opener; LabelText uses it.
const FormLinkContext = createContext(null);

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

// "Oct 5, 2026". Takes a date or a timestamp.
export function fmtDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso + (iso.length === 10 ? "T00:00:00" : ""));
  if (isNaN(d)) return iso;
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

// The one place a card is ticked or unticked by hand. Returns { error }.
export async function setStepDone(stepId, done, userId) {
  return supabase.from("team_onboarding_steps")
    .update({ completed_at: done ? new Date().toISOString() : null, completed_by: done ? (userId || null) : null })
    .eq("id", stepId);
}

// The one place a sub-item is ticked or unticked by hand. Ticking the last
// one completes the card; unticking any reopens it. Returns { error }.
export async function setSubstepDone(step, label, done, userId) {
  const cur = Array.isArray(step.substeps_done) ? step.substeps_done : [];
  const next = done ? (cur.includes(label) ? cur : [...cur, label]) : cur.filter(l => l !== label);
  const allDone = subProgress(step.substeps, next).complete;
  const patch = { substeps_done: next };
  if (allDone && !step.completed_at) {
    patch.completed_at = new Date().toISOString();
    patch.completed_by = userId || null;
  } else if (!allDone && step.completed_at) {
    patch.completed_at = null;
    patch.completed_by = null;
  }
  return supabase.from("team_onboarding_steps").update(patch).eq("id", step.id);
}

// ─── orientation ────────────────────────────────────
// An onboarding_instructions row with kind "orientation" is Peter's
// orientation. Its (i) sits next to the sub-item with that label (the
// Orientation line on Review With Peter) and only the owner sees it. It opens
// OrientationPopup: his talking points, which he can edit there, and a
// checkmark per new hire that ticks that line on their card. Only the owner
// can tick that line; onboarding_step_complete_gate enforces it. For this
// kind, body_md holds the talking points in the sub-item text format.
export const ORIENTATION_KIND = "orientation";

// ─── sub-item helpers ───────────────────────────────
// Sub-items arrive either as a flat list of strings or as groups the old
// paper checklists used ({ group, items }). Normalize both to groups.
// Two extra keys a group can carry:
//   alt_for  — the group is another way to do that one line (the archived
//              login process, say). Shown in place of the line on request.
//   fill     — the database puts the current team's names at the top of the
//              group when it copies the step onto a plan; the group's own
//              lines follow. "team_list" = the office list (nicknames, minus
//              anyone marked off it); "team_list_sf" = full names from their
//              State Farm emails, which is how Jabber finds people.
//   info     — lines shown when the (i) on the heading is opened. How-to
//              detail, not checkboxes; they never count toward finishing.
export function subGroups(substeps, { keepEmpty = false } = {}) {
  if (!Array.isArray(substeps)) return [];
  const out = [];
  let flat = null;
  substeps.forEach(s => {
    if (s && typeof s === "object" && Array.isArray(s.items)) {
      out.push({
        group: s.group || null,
        items: s.items.filter(x => typeof x === "string"),
        altFor: s.alt_for || null,
        fill: s.fill || null,
        info: Array.isArray(s.info) ? s.info.filter(x => typeof x === "string") : [],
        itemInfo: s.item_info && typeof s.item_info === "object" ? s.item_info : {},
      });
    } else if (typeof s === "string") {
      if (!flat) { flat = { group: null, items: [], altFor: null, fill: null, info: [], itemInfo: {} }; out.push(flat); }
      flat.items.push(s);
    }
  });
  return out.filter(g => g.items.length || g.info.length || (keepEmpty && g.fill));
}

// How far a step's sub-items are. A line that has an alternative counts as
// done when it is ticked, or when every line of the alternative is ticked.
// Mirrors onboarding_substeps_missing() in the database, which is what
// actually decides whether the step can be completed.
export function subProgress(substeps, done) {
  const groups = subGroups(substeps);
  const d = Array.isArray(done) ? done : [];
  const alts = groups.filter(g => g.altFor);
  const required = groups.filter(g => !g.altFor).reduce((acc, g) => acc.concat(g.items), []);
  const ok = (label) => d.includes(label)
    || alts.some(a => a.altFor === label && a.items.length && a.items.every(i => d.includes(i)));
  const doneCount = required.filter(ok).length;
  return { total: required.length, done: doneCount, complete: required.length > 0 && doneCount === required.length };
}

export function subAll(substeps) {
  return subGroups(substeps).reduce((acc, g) => acc.concat(g.items), []);
}

// Sub-items as plain text for editing. One item per line. A heading line
// ends with a colon and starts a group.
// Typed on its own line under a heading, this makes the group fill itself
// with the current team.
export const TEAM_LIST_TOKEN = "[Team list]";
// Same, but full names from their State Farm emails (for Jabber).
export const TEAM_LIST_SF_TOKEN = "[Team list by SF email]";
const FILL_TOKENS = { team_list: TEAM_LIST_TOKEN, team_list_sf: TEAM_LIST_SF_TOKEN };
function fillFromToken(line) {
  const l = String(line || "").toLowerCase();
  return Object.keys(FILL_TOKENS).find(k => FILL_TOKENS[k].toLowerCase() === l) || null;
}

// A line that starts with this goes behind the (i) on the heading above it.
export const INFO_PREFIX = "> ";

// Leading spaces nest a sub-item under the line above it: two per level (a
// tab counts as two). They stay part of the saved line.
export function splitIndent(label) {
  const indent = (/^[ \t]*/.exec(String(label || ""))[0] || "").replace(/\t/g, "  ");
  return { indent, level: Math.floor(indent.length / 2), text: String(label || "").trim() };
}

// A sub-item that would read as markup (ends in a colon, starts with > or \,
// or is --- or the team-list token) is written with a leading \ so it comes
// back as the same plain line.
function escapeSubItem(it) {
  return (it.endsWith(":") || it.startsWith(">") || it.startsWith("\\") || it === "---"
    || fillFromToken(it)) ? `\\${it}` : it;
}
export function substepsToText(substeps) {
  const lines = [];
  subGroups(substeps, { keepEmpty: true }).forEach(g => {
    if (g.group || g.altFor || g.fill) {
      if (lines.length) lines.push("");
      const name = g.group || (g.altFor ? "Archived" : "Team");
      lines.push(g.altFor ? `${name} (instead of: ${g.altFor}):` : `${name}:`);
    } else if (lines.length) {
      // Plain lines after a heading: --- ends the heading above.
      lines.push("", "---");
    }
    g.info.forEach(it => lines.push(`${INFO_PREFIX}${it}`));
    if (FILL_TOKENS[g.fill]) lines.push(FILL_TOKENS[g.fill]);
    g.items.forEach(it => {
      const { indent, text } = splitIndent(it);
      lines.push(indent + escapeSubItem(text));
      (g.itemInfo[it] || []).forEach(l => lines.push(`${INFO_PREFIX}${l}`));
    });
  });
  return lines.join("\n");
}
// Inverse of substepsToText. Keeps the flat shape when no headings were
// used so a plain list never silently turns into a one-group object.
export function textToSubsteps(text) {
  const lines = String(text || "").split("\n").map(l => l.replace(/\s+$/, ""));
  const groups = [];
  let cur = null;
  let sawHeading = false;
  const push = (item) => {
    if (!cur) { cur = { group: null, items: [] }; groups.push(cur); }
    cur.items.push(item);
  };
  lines.forEach(raw => {
    const line = raw.trim();
    if (!line) return;
    const { indent } = splitIndent(raw);
    if (line.startsWith("\\")) { push(indent + line.slice(1)); return; }
    if (line.startsWith(">")) {
      // Right under a heading it goes behind the heading's (i); under a line,
      // behind that line's (i).
      sawHeading = true;
      const text = line.replace(/^>\s?/, "");
      if (!cur) { cur = { group: null, items: [] }; groups.push(cur); }
      if (cur.items.length) {
        const last = cur.items[cur.items.length - 1];
        cur.item_info = { ...(cur.item_info || {}) };
        cur.item_info[last] = [...(cur.item_info[last] || []), text];
      } else {
        cur.info = (cur.info || []).concat(text);
      }
      return;
    }
    if (line === "---") {
      sawHeading = true;
      cur = { group: null, items: [] };
      groups.push(cur);
      return;
    }
    if (line.length > 1 && line.endsWith(":")) {
      sawHeading = true;
      const head = line.slice(0, -1).trim();
      const alt = /^(.*?)\s*\(instead of:\s*(.+)\)$/.exec(head);
      cur = alt
        ? { group: alt[1].trim() || "Archived", alt_for: alt[2].trim(), items: [] }
        : { group: head, items: [] };
      groups.push(cur);
      return;
    }
    if (fillFromToken(line)) {
      sawHeading = true;
      if (!cur) { cur = { group: "Team", items: [] }; groups.push(cur); }
      cur.fill = fillFromToken(line);
      return;
    }
    push(indent + line);
  });
  const kept = groups.filter(g => g.items.length || g.fill || (g.info && g.info.length));
  if (!kept.length) return null;
  if (!sawHeading) return kept[0].items;
  return kept;
}

// A phase with more than one track draws one column per track — the two
// offer-stage columns both have to finish before the next milestone opens.
// Goals and other full-width subcards: a highlighted band across the top of
// a major card, above the columns.
export const bannerStyle = {
  display: "grid", gap: 10, marginBottom: 12, padding: 10, borderRadius: 10,
  gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))", alignItems: "start",
  background: T.amberLt, borderLeft: `4px solid ${T.amber}`, boxSizing: "border-box",
};

// "Every week", "Week 5", "Weeks 5, 7" — which weeks of a combined card a
// subcard is in (weeks = null means all of them).
export function weeksLabel(weeks) {
  if (!Array.isArray(weeks) || !weeks.length) return "";
  return weeks.length === 1 ? `Week ${weeks[0]}` : `Weeks ${weeks.join(", ")}`;
}

// One column of a card. Columns alternate white and a faint gray, starting
// white, so they read as separate lanes. Used by the plan and the template.
export function columnStyle(index) {
  return {
    display: "grid", gap: 10, alignContent: "start", minWidth: 0,
    background: index % 2 ? T.slate50 : T.white,
    borderRadius: 10, padding: 8, boxSizing: "border-box",
  };
}

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
// Sub-items carry long unbreakable URLs. Without this they set the
// min-content width of their grid track, the track grows past the screen,
// and the whole page slides sideways. overflowWrap is inherited, so putting
// it on a step card covers the title, the detail line and every sub-item
// under it. minWidth:0 is what actually lets a grid or flex child shrink.
export const wrapLongText = {
  minWidth: 0,
  overflowWrap: "anywhere",
  wordBreak: "break-word",
};

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

// A sub-item that links to a site form (…?form=<id>) ticks itself when that
// form is done. Mirrors onboarding_substep_form_id() in the database.
export function formIdOf(label) {
  const m = /[?&]form=([a-z0-9_]+)/.exec(String(label || ""));
  return m ? m[1] : null;
}

// ─── sub-item text ───────────────────────────────────
// Renders one sub-item label. [text](url) and bare web addresses become
// links. A click path written with " > " (File > Options > Mail) is shown in
// its own colour so it reads as a path. An icon, when one is on file for the
// label, sits right after the text.
const LINK_RE = /\[([^\]]+)\]\(([^)\s]+)\)|(https?:\/\/[^\s)]+)/g;

function pathPieces(text) {
  const first = text.indexOf(" > ");
  if (first < 0) return null;
  const head = text.slice(0, first);
  const cut = Math.max(head.lastIndexOf(": "), head.lastIndexOf(" - "), head.lastIndexOf("go to "));
  const at = cut < 0 ? 0 : cut + (head.slice(cut).startsWith("go to ") ? 6 : 2);
  return { lead: text.slice(0, at), path: text.slice(at).split(" > ") };
}

export function LabelText({ text, icon = null, pathColor, linkColor }) {
  const openForm = useContext(FormLinkContext);
  const parts = [];
  let last = 0;
  let m;
  LINK_RE.lastIndex = 0;
  while ((m = LINK_RE.exec(text))) {
    if (m.index > last) parts.push({ t: text.slice(last, m.index) });
    parts.push(m[3] ? { href: m[3], t: m[3] } : { href: m[2], t: m[1] });
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push({ t: text.slice(last) });

  const renderPlain = (t, key) => {
    const pp = pathPieces(t);
    if (!pp) return <span key={key}>{t}</span>;
    return (
      <span key={key}>
        {pp.lead}
        <span style={{ color: pathColor, fontWeight: 600 }}>
          {pp.path.map((seg, i) => (
            <span key={i}>{i > 0 && <span style={{ opacity: 0.7 }}> &gt; </span>}{seg}</span>
          ))}
        </span>
      </span>
    );
  };

  return (
    <>
      {parts.map((p, i) => p.href ? (
        <a key={i} href={p.href} target={p.href.startsWith("/") ? undefined : "_blank"} rel="noreferrer"
          onClick={(e) => {
            e.stopPropagation();
            const fid = formIdOf(p.href);
            if (fid && openForm) { e.preventDefault(); openForm(fid); }
          }}
          style={{ color: linkColor, textDecoration: "underline" }}>{p.t}</a>
      ) : renderPlain(p.t, i))}
      {icon && (
        <img src={icon} alt="" style={{ height: 14, width: 14, marginLeft: 5, verticalAlign: "-2px" }} />
      )}
    </>
  );
}

// ─── a sub-item heading ──────────────────────────────
// The heading of a group of sub-items. When the group carries info lines it
// gets the (i); opening it shows those lines under the heading. extra is
// anything else that sits on the heading line (the archived-process link).
export function GroupHead({ label, info = [], extra = null, labelStyle = {}, style = {}, pathColor, linkColor }) {
  const [open, setOpen] = useState(false);
  const hasInfo = info.length > 0;
  if (!label && !hasInfo && !extra) return null;
  return (
    <div style={style}>
      <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap", minWidth: 0 }}>
        {label && <span style={labelStyle}><LabelText text={label} pathColor={pathColor} linkColor={linkColor} /></span>}
        {extra}
        {hasInfo && (
          <InfoDot open={open} title="How to"
            onClick={(e) => { e.stopPropagation(); setOpen(o => !o); }} />
        )}
      </div>
      {hasInfo && open && <InfoBox lines={info} pathColor={pathColor} linkColor={linkColor} />}
    </div>
  );
}

// The opened (i): how-to lines under a heading or a line.
export function InfoBox({ lines = [], pathColor, linkColor }) {
  return (
    <div style={{
      margin: "5px 0 8px", padding: "8px 10px", boxSizing: "border-box",
      background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 6,
      fontSize: 12, color: T.slate700, lineHeight: 1.5, display: "grid", gap: 3,
      textTransform: "none", letterSpacing: 0,
    }}>
      {lines.map((line, i) => line.trim().endsWith(":") ? (
        <div key={i} style={{ fontWeight: 600 }}>
          <LabelText text={line} pathColor={pathColor} linkColor={linkColor} />
        </div>
      ) : (
        <div key={i} style={{ display: "flex", gap: 6, minWidth: 0 }}>
          <span style={{ color: T.slate400 }}>•</span>
          <span style={{ minWidth: 0 }}>
            <LabelText text={line} pathColor={pathColor} linkColor={linkColor} />
          </span>
        </div>
      ))}
    </div>
  );
}

// A sub-item line with its own (i): children is the line, lines open under it.
export function ItemInfo({ lines = [], children, pathColor, linkColor }) {
  const [open, setOpen] = useState(false);
  if (!lines.length) return children;
  return (
    <div style={{ minWidth: 0 }}>
      <div style={{ display: "flex", gap: 6, alignItems: "flex-start", minWidth: 0 }}>
        <div style={{ flex: 1, minWidth: 0 }}>{children}</div>
        <InfoDot open={open} title="How to"
          onClick={(e) => { e.stopPropagation(); setOpen(o => !o); }} />
      </div>
      {open && <InfoBox lines={lines} pathColor={pathColor} linkColor={linkColor} />}
    </div>
  );
}

// ─── pop-up frame ────────────────────────────────────
// The frame the onboarding pop-ups share: the page dims, a white card sits
// on top with an × in the corner, and a click outside closes it.
export function PopupShell({ onClose, children, maxWidth = 820 }) {
  return (
    <div onClick={onClose} style={{
      position: "fixed", inset: 0, zIndex: 1000, background: "rgba(15,23,42,0.45)",
      display: "flex", alignItems: "flex-start", justifyContent: "center",
      padding: "5vh 12px", boxSizing: "border-box", overflowY: "auto",
    }}>
      <div role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()} style={{
        position: "relative", width: "100%", maxWidth, background: T.white,
        borderRadius: 12, boxShadow: "0 20px 50px rgba(15,23,42,0.25)", minWidth: 0,
      }}>
        <button onClick={onClose} aria-label="Close" style={{
          position: "absolute", top: 10, right: 12, border: "none", background: "none",
          fontSize: 22, lineHeight: 1, cursor: "pointer", color: T.slate500, zIndex: 1,
        }}>×</button>
        {children}
      </div>
    </div>
  );
}

// ─── form pop-up ─────────────────────────────────────
// teamId: whose forms. null = not on the team yet (a candidate's plan);
// left out = the person signed in (the template page).
export function FormPopupProvider({ teamId, onClosed, children }) {
  const [formId, setFormId] = useState(null);
  const close = () => { setFormId(null); if (onClosed) onClosed(); };
  return (
    <FormLinkContext.Provider value={setFormId}>
      {children}
      {formId && (
        <PopupShell onClose={close}>
          {teamId === null ? (
            <div style={{ padding: 24, fontSize: 13, color: T.slate600 }}>
              The forms open once they are on the team.
            </div>
          ) : (
            <TeamForms teamId={teamId || undefined} onlyForm={formId} onClose={close} embedded
              preview={teamId === undefined} />
          )}
        </PopupShell>
      )}
    </FormLinkContext.Provider>
  );
}
