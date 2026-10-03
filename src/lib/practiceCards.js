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
//   {{practice-videos: 3 | Monday}}  every video that onboarding week shows on
//                                that day, with its link (Peter 2026-10-03).
//                                Stairs & Buckets is left out. A Watch group
//                                that names no day ("Rejection") goes on Monday.
//   {{practice: 3 | Monday}}     that day's role play items (🎭) from the
//                                onboarding week's Practice card, in order. Under
//                                each item go the decks its onboarding pop-up
//                                names, each deck once per day.
//
// Sources: onboarding_phases (week name), onboarding_step_templates (the
// Practice card's day items, and the videos on every card of the week),
// onboarding_instructions (the pop-up on each item, matched by its exact label,
// which names the decks with {{roleplay: id}}).
// A deck that lives in another week of the kickoff page is copied in at render
// time by withRoleplayBlocks, so the page keeps one copy of every deck.

const WEEK_TOKEN_RE = /\{\{practice-week:\s*(\d+)\s*\}\}/gi;
const VIDEO_TOKEN_RE = /\{\{practice-videos:\s*(\d+)\s*\|\s*([A-Za-z]+)\s*\}\}/gi;
const VIDEO_URL_RE = /\]\((https?:\/\/[^)]*(youtube\.com|youtu\.be|vimeo\.com|facebook\.com|fb\.watch|instagram\.com)[^)]*)\)/i;
const STAIRS_RE = /stairs\s*&\s*buckets/i;
const WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday"];
const DAY_TOKEN_RE = /\{\{practice:\s*(\d+)\s*\|\s*([A-Za-z]+)\s*\}\}/gi;
const RP_TOKEN_RE = /\{\{roleplay:\s*([a-z0-9_-]+)\s*\}\}/gi;
const WEEK_OPEN_RE = /^[ \t]*\*?\[Week:\s*([^\]\n]+?)\s*\]\*?[ \t]*$/i;
const WEEK_END_RE = /^[ \t]*\*?\[Week end\]\*?[ \t]*$/i;
const ZWSP_RE = /​/g;

export function usesPractice(md) {
  return /\{\{practice(-week|-videos)?:/i.test(String(md || ""));
}

let practicePromise = null;
export function loadPractice() {
  if (!practicePromise) {
    practicePromise = Promise.all([
      supabase.from("onboarding_phases").select("phase, name")
        .eq("agency_id", AGENCY_ID).eq("is_active", true),
      supabase.from("onboarding_step_templates").select("phase, title, substeps, track_order, sort_order")
        .eq("agency_id", AGENCY_ID).eq("is_active", true)
        .order("track_order", { ascending: true }).order("sort_order", { ascending: true }),
      supabase.from("onboarding_instructions").select("substep_label, body_md")
        .eq("agency_id", AGENCY_ID),
    ]).then(([ph, st, ins]) => buildPractice(ph, st, ins), () => null)
      .then((d) => { if (!d) practicePromise = null; return d; });
  }
  return practicePromise;
}

export function buildPractice(ph, st, ins) {
  const weeks = {};
  (ph?.data || []).forEach((p) => {
    const m = /^Week\s+(\d+)\s*:?\s*(.*)$/i.exec(String(p?.name || "").trim());
    if (m) weeks[Number(m[1])] = { phase: p.phase, title: m[2].trim(), days: {}, videos: {} };
  });
  const byPhase = {};
  Object.values(weeks).forEach((w) => { byPhase[w.phase] = w; });
  (st?.data || []).forEach((row) => {
    const w = byPhase[row?.phase];
    if (!w || !Array.isArray(row?.substeps)) return;
    const isPractice = String(row?.title || "").trim() === "Practice";
    row.substeps.forEach((g) => {
      if (!g || typeof g !== "object") return;
      const name = String(g.group || "").trim();
      const items = Array.isArray(g.items) ? g.items : [];
      if (isPractice && name) w.days[name.toLowerCase()] = items;
      addVideos(w, name, items);
    });
  });
  const popups = {};
  (ins?.data || []).forEach((r) => { if (r?.substep_label) popups[r.substep_label] = r.body_md || ""; });
  return { weeks, popups };
}

// Videos in a week's cards, by the day they belong to. A group named for a day
// ("Monday Videos", "Friday") goes on that day; any other group (a Watch topic
// such as "Rejection") goes on Monday under its own name.
function addVideos(w, groupName, items) {
  if (STAIRS_RE.test(groupName)) return;
  const vids = items.filter((it) => VIDEO_URL_RE.test(String(it || "")) && !STAIRS_RE.test(String(it || "")));
  if (!vids.length) return;
  const lower = groupName.toLowerCase();
  const named = WEEKDAYS.find((d) => lower.startsWith(d));
  const day = named || "monday";
  const heading = named ? "" : groupName.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
  (w.videos[day] = w.videos[day] || []).push({ heading, items: vids });
}

function videoBlock(data, week, day) {
  const groups = data?.weeks?.[week]?.videos?.[String(day).toLowerCase()] || [];
  if (!groups.length) return "";
  const parts = ["**Videos**"];
  groups.forEach((g) => {
    const list = g.items.map((it) => `- ${String(it).replace(ZWSP_RE, "").trim()}`).join("\n");
    parts.push(g.heading ? `*${g.heading}*\n\n${list}` : list);
  });
  return parts.join("\n\n");
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
  out = out.replace(VIDEO_TOKEN_RE, (_m, n, day) => (data ? videoBlock(data, Number(n), day) : ""));
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
