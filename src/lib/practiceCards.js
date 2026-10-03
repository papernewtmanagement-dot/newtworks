import { supabase, AGENCY_ID } from "./supabase.js";
import { withRoleplayBlocks } from "./markdown.js";

// src/lib/practiceCards.js
//
// The Daily Kickoff draws each week straight from the onboarding training
// (Peter 2026-10-02): same names, same pieces, same days. Nothing about the
// week's practice is typed into the kickoff page. The page holds tokens and the
// role play decks; this file fills the tokens before the markdown renders.
//
// Tokens:
//   {{practice-week: 3}}         "Week 3 — " plus the onboarding week's name.
//   {{practice: 3 | Monday}}     that day's role play items (🎭) from the
//                                onboarding week's Practice card, in order. Under
//                                each item go the decks its onboarding pop-up
//                                names, each deck once per day.
//
// Sources: onboarding_phases (week name), onboarding_step_templates (the
// Practice card's day items), onboarding_instructions (the pop-up on each item,
// matched by its exact label, which names the decks with {{roleplay: id}}).
// A deck that lives in another week of the kickoff page is copied in at render
// time by withRoleplayBlocks, so the page keeps one copy of every deck.

const WEEK_TOKEN_RE = /\{\{practice-week:\s*(\d+)\s*\}\}/gi;
const DAY_TOKEN_RE = /\{\{practice:\s*(\d+)\s*\|\s*([A-Za-z]+)\s*\}\}/gi;
const RP_TOKEN_RE = /\{\{roleplay:\s*([a-z0-9_-]+)\s*\}\}/gi;
const WEEK_OPEN_RE = /^[ \t]*\*?\[Week:\s*([^\]\n]+?)\s*\]\*?[ \t]*$/i;
const WEEK_END_RE = /^[ \t]*\*?\[Week end\]\*?[ \t]*$/i;
const ZWSP_RE = /\u200b/g;

export function usesPractice(md) {
  return /\{\{practice(-week)?:/i.test(String(md || ""));
}

let practicePromise = null;
export function loadPractice() {
  if (!practicePromise) {
    practicePromise = Promise.all([
      supabase.from("onboarding_phases").select("phase, name")
        .eq("agency_id", AGENCY_ID).eq("is_active", true),
      supabase.from("onboarding_step_templates").select("phase, substeps")
        .eq("agency_id", AGENCY_ID).eq("is_active", true).eq("title", "Practice"),
      supabase.from("onboarding_instructions").select("substep_label, body_md")
        .eq("agency_id", AGENCY_ID),
    ]).then(([ph, st, ins]) => {
      const weeks = {};
      (ph.data || []).forEach((p) => {
        const m = /^Week\s+(\d+)\s*:?\s*(.*)$/i.exec(String(p?.name || "").trim());
        if (m) weeks[Number(m[1])] = { phase: p.phase, title: m[2].trim(), days: {} };
      });
      const byPhase = {};
      Object.values(weeks).forEach((w) => { byPhase[w.phase] = w; });
      (st.data || []).forEach((row) => {
        const w = byPhase[row?.phase];
        if (!w || !Array.isArray(row?.substeps)) return;
        row.substeps.forEach((g) => {
          const day = String(g?.group || "").trim().toLowerCase();
          if (day) w.days[day] = Array.isArray(g?.items) ? g.items : [];
        });
      });
      const popups = {};
      (ins.data || []).forEach((r) => { if (r?.substep_label) popups[r.substep_label] = r.body_md || ""; });
      return { weeks, popups };
    }, () => null).then((d) => { if (!d) practicePromise = null; return d; });
  }
  return practicePromise;
}

// "🎭 Intro x3. [Simple Auto FIT](/processes/…)" → bold name, then the link.
function itemLine(label) {
  const text = String(label).replace(ZWSP_RE, "").trim();
  const at = text.indexOf("[");
  if (at <= 0) return `**${text}**`;
  const name = text.slice(0, at).trim();
  return `**${name}** ${text.slice(at).trim()}`;
}

function isShuffleDeck(id, md) {
  const re = new RegExp(`^[ \\t]*\\*?\\[Roleplay:\\s*${id.replace(/[-]/g, "\\-")}\\s*\\|\\s*shuffle\\s*\\]`, "im");
  return re.test(md);
}

function dayBlock(data, week, day, md) {
  const w = data?.weeks?.[week];
  const items = (w?.days?.[String(day).toLowerCase()] || []).filter((it) => /^\s*🎭/.test(String(it || "")));
  if (!items.length) return "";
  const shown = new Set();
  const parts = [];
  items.forEach((label) => {
    parts.push(itemLine(label));
    const body = data.popups?.[label] || "";
    Array.from(body.matchAll(RP_TOKEN_RE), (m) => m[1].toLowerCase()).forEach((id) => {
      if (shown.has(id)) return;
      shown.add(id);
      parts.push(`${isShuffleDeck(id, md) ? "**Objection:**" : "**Role play:**"} {{roleplay: ${id}}}`);
    });
  });
  return parts.join("\n\n");
}

export function fillPractice(md, data) {
  const src = String(md || "");
  if (!usesPractice(src)) return src;
  let out = src.replace(WEEK_TOKEN_RE, (_m, n) => {
    const w = data?.weeks?.[Number(n)];
    return w ? `Week ${Number(n)} — ${w.title}` : `Week ${Number(n)}`;
  });
  const filledWeeks = new Set();
  out = out.replace(DAY_TOKEN_RE, (_m, n, day) => {
    filledWeeks.add(String(Number(n)));
    return data ? dayBlock(data, Number(n), day, src) : "";
  });
  if (!data || !filledWeeks.size) return out;
  // A deck from another week would be dropped by the week filter, so copy it
  // into the week that names it, just before that week's end.
  const lines = out.split("\n");
  const result = [];
  let start = -1;
  let wk = null;
  for (let i = 0; i < lines.length; i++) {
    const open = WEEK_OPEN_RE.exec(lines[i]);
    if (open) { start = result.length; wk = open[1].trim(); }
    if (WEEK_END_RE.test(lines[i]) && start >= 0 && filledWeeks.has(wk)) {
      const seg = result.splice(start).join("\n");
      result.push(withRoleplayBlocks(seg, out));
      start = -1; wk = null;
    }
    result.push(lines[i]);
  }
  return result.join("\n");
}
