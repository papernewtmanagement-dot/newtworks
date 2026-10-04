import {
  expandTransclusions, expandSelector, scanSelector, isPipeRow, isPipeSep, splitTableRow,
  buildIncludeLookup, makeIncludeResolver, buildExcerptLookup, makeExcerptResolver,
  buildFaqLookup, makeFaqResolver, extractTransclusionMarkers, excerptMarkerTitle,
  OPENER_MARK_RE, ENGAGED_MARK_RE, ENGAGED_END_RE, ENGAGED_CHOICES, ENGAGED_TITLE,
} from "./markdown.js";
import { CARD_PARTS } from "./fitParts.js";
import { RELATIONSHIPS, REVIEW_SITES } from "./logChoices.js";

// ============================================================
// Live tab — the call walker (Peter 2026-10-04).
//
// ONE SOURCE. Peter 2026-10-04: "Make sure the scripts can't drift. There
// should be one source of scripts that is accessed by the processes manual and
// the live tab." The Processes manual is that source. The walker holds no
// script of its own:
//   * it loads the manual's own rows through the manual's own loader
//     (manualSources.js) and renders them with the manual's own renderer
//     (markdown.js), every time the tab opens
//   * every word a step shows is the manual's
//   * every list a choice offers is the manual's, named the way the manual
//     names it: the FIT pages are every page under FIT Conversations, in its
//     order and under its folders, the Outbound call types are those pages
//     and the expanders on Retention > Outbound and Retention > Appointments,
//     the Inbound call types are the sections of Inbound Calls, and the
//     touches, late-pay counts, pivots, openers, lead contacts and products
//     are whatever those scripts hold today
//   * it only plays a shared script that some manual page shows, so it can
//     never play one the manual has dropped
// The walker's own words are its questions ("Did they say yes?") and the
// answers that decide what gets logged. Nothing else.
//
// Where the walker hooks into the manual is one short list (the LIVE SOURCES
// block below). liveSourceProblems() checks every entry against the manual as
// it stands. Anything that no longer resolves is named at the top of the Live
// tab and at the top of every Processes page, and a call that reaches the gap
// says so in place of the step. An edit to the manual can't break the Live
// tab quietly.
//
// What else lives here:
//   * the step splitter: a step ends at every 🙊 (ask, then let them answer),
//     a pair of "If …" expanders becomes a choice, and expanders that follow a
//     question ride along with it
//   * buildCall: turns the call so far (the choices made) into the steps and
//     choices to show, and works out what the call has recorded: pivots,
//     quotes, sales, saves, reviews
//
// The walker never saves anything itself. The Live tab hands what it recorded
// to the Log tab's own form at the end of the call, so every rule the Log
// enforces holds here too, and rp_log_entry stays the one save.
// ============================================================

// Who sees the Live tab: Peter, until he says it is finished (2026-10-04). The
// Dashboard tab, its open-call dot and the warning in the Processes manual all
// ask this one question.
export const canSeeLive = (userRole) => userRole === "owner";

// ---------- LIVE SOURCES: where the walker hooks into the manual ----------
// Pages by id (an id survives a rename); shared scripts by the title every
// manual page embeds them by; sections of Inbound Calls by the manual's words.
export const FIT_PAGE_ID = "2124251137";   // Processes > FIT Conversations: the ten parts, and every page under it
// The two checklists of calls we start. Their expanders are the Outbound list.
const CALL_LISTS = [
  { page: "newtworks-native-outbound-touches-2026-09-04", name: "Retention > Outbound" },
  { page: "1747025922", name: "Retention > Appointments" },
];
// Shared scripts the walker builds a question around, and what is lost without each.
const SCRIPT = {
  inbound:  "Inbound Calls",
  save:     "Save Household",
  review:   "Review Policy",
  claims:   "Claims Touches",
  late:     "Late Pay Process",
  referral: "Review & Referral",
  schedule: "Appointments Set & Create",
  car:      "Added/Replaced Auto Details",
};
const SCRIPT_NEED = {
  inbound:  "Inbound calls have no script, and no call gets the wrap-up or the pivot question.",
  save:     "Live can't ask whether a customer stayed, so saves and cancelations aren't logged from a call.",
  review:   "Live can't run a policy review, so policy reviews aren't logged from a call.",
  claims:   "The claim follow-up call can't pick a touch.",
  late:     "The late-pay call can't pick how many times they've been late.",
  referral: "Live can't ask for the review, so online reviews aren't logged from a call.",
  schedule: "Live can't walk setting a time.",
  car:      "Live can't log an added car from an inbound call.",
};
// Inside Inbound Calls, in the manual's own words.
const INBOUND_MARK = {
  sales: "sales",               // the section that leads to a quote or a cancelation
  other: "other",               // the help steps and the wrap-up every call ends with
  wrap: "wrap up the call",
  byTheWay: "by the way",       // its labeled items are the pivots
  fpp: "other pivots",          // so are the labeled parts of this expander
  logCall: "log the call",      // shown on the finish screen
};
const PIVOT_KIND = [
  ["fpp", /family protection/i],   // leads to HI, DI or Life
  ["life", /\blife\b/i],           // leads to the Life FIT
  ["review", /generic/i],          // an account review, nothing to log
];
// What each FIT product page sells, in the Log's own terms, by page id. A
// "Simple … FIT" page that is not listed still walks; liveSourceProblems names
// it until it is added here.
const PRODUCT_BY_PAGE = {
  "2583035905": { line: "auto", type: "private_passenger" },                        // Simple Auto FIT
  "2514124801": { line: "fire", type: "home" },                                     // Simple Home FIT
  "2588770314": { line: "fire", type: "plup" },                                     // Simple Liability FIT
  "1975844866": { line: "fire", type: "pap" },                                      // Simple Valuables FIT
  "1567227905": { line: "fire", type: "boat" },                                     // Simple Boatowners FIT
  "1730674692": { line: "fire", type: "business_insurance" },                       // Simple Business FIT
  "1702035459": { line: "life", type: "" },                                         // Simple Life FIT: the type is picked when it's logged
  "2588246020": { line: "health", type: "hospital_income" },                        // Simple HI FIT
  "2588770305": { line: "health", type: "disability_short_term" },                  // Simple DI FIT
  "newtworks-native-simple-motorcycle-fit": { line: "auto", type: "motorcycle" },    // Simple Motorcycle FIT
  "newtworks-native-simple-rv-fit": { line: "auto", type: "rv" },                    // Simple RV FIT
  "newtworks-native-simple-classic-car-fit": { line: "auto", type: "classic" },      // Simple Classic Car FIT
  // These never log a quote:
  "1530134531": { line: "variable", type: "", quotable: false },                    // Simple Investing FIT: a meeting with Peter
  "2588770324": { line: "", type: "", quotable: false },                            // Simple Retirement Insurance FIT: a meeting with Peter
  "newtworks-native-simple-us-bank-fit": { line: "bank", type: "", quotable: false }, // Simple US Bank FIT: Bank counts when funded, not at the close (Peter 2026-09-11)
};

const MONKEY = "🙊";
const LIST_RE = /^(\s*)([-*]|\d+\.)\s+/;
const LABEL_LINE_RE = /^\s*\*\*([^*\n]+)\*\*\s*$/;   // a bold label alone on its line
const SENTINEL_RE = /^\s*\[\[live:([a-z_:]+)\]\]\s*$/;
const PART_BY_EXCERPT = new Map(CARD_PARTS.map((p) => [p.excerpt.toLowerCase(), p.key]));

// ---------- text helpers ----------
export function plainText(s) {
  return String(s || "")
    .replace(/<[^>]+>/g, "")
    .replace(/\{\{(?:say|them):\s*([\s\S]*?)\s*\}\}/g, "$1")
    .replace(/[*_`#>]/g, "")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}
const matches = (text, test) => {
  const t = String(text || "").replace(/[:.\s]+$/, "").toLowerCase();
  return test instanceof RegExp ? test.test(t) : t.startsWith(String(test).toLowerCase());
};
const cleanTitle = (t) => plainText(t).replace(/[:\s]+$/, "");
// An expander's label as the manual shows it: tags and paired markup gone, a
// lone "*" or "#" kept ("*Contact 01a: text, 2x dial, text", "#Quotes Missing Data").
const labelText = (s) => String(s || "")
  .replace(/<[^>]+>/g, "")
  .replace(/\{\{(?:say|them):\s*([\s\S]*?)\s*\}\}/g, "$1")
  .replace(/(\*\*|__|\*|_|`)(?=\S)([\s\S]*?\S)\1/g, "$2")
  .replace(/&amp;/g, "&")
  .replace(/\s+/g, " ")
  .trim();
const slug = (s) => String(s || "").toLowerCase().replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "x";
// Keys that stay unique when two labels slug the same.
const keyed = (items, keyOf) => {
  const seen = new Map();
  return items.map((it) => {
    let k = keyOf(it);
    const n = (seen.get(k) || 0) + 1;
    seen.set(k, n);
    if (n > 1) k = `${k}-${n}`;
    return { ...it, key: k };
  });
};
const indentOf = (l) => (/^(\s*)/.exec(l) || ["", ""])[1].length;
const dedent = (lines, n) => lines.map((l) => (l.slice(0, n).trim() === "" ? l.slice(n) : l.trimStart()));
const join = (...parts) => parts.filter((p) => p && String(p).trim()).join("\n\n");
const linesOf = (md) => String(md || "").split(/\r?\n/);
// A reference expander the walker folds manual text into, under the manual's
// own label. data-live-ref keeps it from ever being read as a choice, even
// when the label starts with "If".
export const refDetails = (summary, md) => (md && String(md).trim()
  ? `<details data-live-ref>\n<summary>${summary}</summary>\n\n${String(md).trim()}\n\n</details>` : "");

// ---------- reading a script's shape (raw manual text) ----------
// The script line by line at the top level: plain lines, and whole expanders
// (label, what is inside, the block) wherever one opens.
function topLevel(md) {
  const lines = linesOf(md);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s*<details\b/i.test(lines[i])) { out.push({ kind: "line", text: lines[i], start: i, end: i }); continue; }
    let depth = 0, j = i;
    for (; j < lines.length; j++) {
      depth += (lines[j].match(/<details\b/gi) || []).length - (lines[j].match(/<\/details\s*>/gi) || []).length;
      if (depth <= 0) break;
    }
    if (j >= lines.length) j = lines.length - 1;
    const block = lines.slice(i, j + 1).join("\n");
    const sm = /<summary\b[^>]*>([\s\S]*?)<\/summary\s*>/i.exec(block);
    let inner = block.replace(/^\s*<details\b[^>]*>/i, "").replace(/<\/details\s*>\s*$/i, "");
    if (sm) inner = inner.replace(sm[0], "");
    out.push({ kind: "details", label: sm ? labelText(sm[1]) : "", inner: inner.trim(), block, start: i, end: j });
    i = j;
  }
  return out;
}
const detailsBlocks = (md) => topLevel(md).filter((u) => u.kind === "details");
export function detailsBySummary(md, test) {
  const hit = detailsBlocks(md).find((d) => matches(d.label, test));
  return hit ? hit.inner : null;
}
// A section that is nothing but one expander is that expander's content.
export function unwrap(md) {
  const t = String(md || "").trim();
  const d = detailsBlocks(t);
  return d.length === 1 && t.startsWith(d[0].block.trim()) && t.endsWith(d[0].block.trim()) ? d[0].inner : t;
}
// A section that is nothing but two or more expanders: the expanders.
function onlyExpanders(md) {
  const units = topLevel(md);
  const items = units.filter((u) => u.kind === "details");
  return items.length >= 2 && !units.some((u) => u.kind === "line" && u.text.trim()) ? items : null;
}
// The sections under a script's top headings (headings inside an expander do
// not count), in order, and what comes before the first one.
export function sectionsOf(md) {
  const lines = linesOf(md);
  const heads = topLevel(md)
    .filter((u) => u.kind === "line" && /^#{1,6}\s/.test(u.text))
    .map((u) => ({ i: u.start, level: /^(#+)/.exec(u.text)[1].length, title: cleanTitle(u.text.replace(/^#+\s*/, "")) }));
  if (!heads.length) return { intro: String(md || "").trim(), sections: [] };
  const top = Math.min(...heads.map((h) => h.level));
  const tops = heads.filter((h) => h.level === top);
  return {
    intro: lines.slice(0, tops[0].i).join("\n").trim(),
    sections: tops.map((h, k) => ({ title: h.title, md: lines.slice(h.i + 1, k + 1 < tops.length ? tops[k + 1].i : lines.length).join("\n").trim() })),
  };
}
// The list item whose text matches, with everything nested under it.
function listItemRange(md, test) {
  const lines = linesOf(md);
  for (let i = 0; i < lines.length; i++) {
    const m = LIST_RE.exec(lines[i]);
    if (!m || !matches(plainText(lines[i].slice(m[0].length)), test)) continue;
    const ind = m[1].length;
    let j = i + 1;
    while (j < lines.length) {
      if (!lines[j].trim()) {
        let k = j + 1;
        while (k < lines.length && !lines[k].trim()) k++;
        if (k < lines.length && indentOf(lines[k]) > ind) { j = k; continue; }
        break;
      }
      if (indentOf(lines[j]) <= ind) break;
      j++;
    }
    return { start: i, end: j, ind, lines };
  }
  return null;
}
export function listItem(md, test) {
  const r = listItemRange(md, test);
  return r ? dedent(r.lines.slice(r.start, r.end), r.ind).join("\n") : null;
}
// What is nested under a list item, stopping at the child that matches stopTest.
function childrenOf(itemMd, stopTest) {
  const lines = linesOf(itemMd).slice(1);
  const real = lines.filter((l) => l.trim());
  if (!real.length) return "";
  const base = Math.min(...real.map(indentOf));
  const out = [];
  for (const l of lines) {
    const m = LIST_RE.exec(l);
    if (stopTest && m && m[1].length === base && matches(plainText(l.slice(m[0].length)), stopTest)) break;
    out.push(l);
  }
  return dedent(out, base).join("\n").trim();
}
// The items directly under a list item, each with what is nested under it.
function listChildren(itemMd) {
  const out = [];
  for (const l of linesOf(childrenOf(itemMd))) {
    const m = LIST_RE.exec(l);
    if (m && m[1].length === 0) out.push([l]);
    else if (out.length) out[out.length - 1].push(l);
  }
  return out.map((x) => x.join("\n").trim());
}
// The bold label an item or line opens with ("**Life Pivot:** I noticed…" → "Life Pivot").
function boldLabel(text) {
  const m = /^\*\*([^*\n]+?)\*\*/.exec(String(text || "").replace(LIST_RE, "").trim());
  return m ? cleanTitle(m[1]) : "";
}
// Bold labels alone on their lines ("**First time they're late:**"), each with
// what follows it up to the next one. The last runs up to the first expander
// after it; `tail` is from there to the end. `intro` comes before the first.
function labelSections(md) {
  const lines = linesOf(md);
  const units = topLevel(md);
  const labels = units.filter((u) => u.kind === "line" && LABEL_LINE_RE.test(u.text));
  if (!labels.length) return { intro: String(md || "").trim(), sections: [], tail: "" };
  const sections = labels.map((u, k) => {
    let end = k + 1 < labels.length ? labels[k + 1].start : lines.length;
    if (k + 1 === labels.length) {
      const det = units.find((x) => x.kind === "details" && x.start > u.start);
      if (det) end = det.start;
    }
    return { label: cleanTitle(LABEL_LINE_RE.exec(u.text)[1]), md: lines.slice(u.start, end).join("\n").trim(), end };
  });
  return {
    intro: lines.slice(0, labels[0].start).join("\n").trim(),
    sections,
    tail: lines.slice(sections[sections.length - 1].end).join("\n").trim(),
  };
}
// A script's expanders: what comes before the first (intro), and each expander
// with any text that follows it before the next one.
function expanderRun(md) {
  const lines = linesOf(md);
  const items = detailsBlocks(md);
  if (!items.length) return { intro: String(md || "").trim(), items: [] };
  return {
    intro: lines.slice(0, items[0].start).join("\n").trim(),
    items: items.map((d, k) => ({ ...d, more: lines.slice(d.end + 1, k + 1 < items.length ? items[k + 1].start : lines.length).join("\n").trim() })),
  };
}
// A page of expanders under bold lines, read the way the manual lays it out:
// each expander is one item, under the bold line above it ("**Day 1:**",
// "**Keeping the business**"). `prose` says the page has other text at the
// top level too, so it reads as a script rather than as a list.
function expanderList(md) {
  let group = "";
  let prose = false;
  const items = [];
  for (const u of topLevel(md)) {
    if (u.kind === "details") { items.push({ label: u.label, group, md: u.inner }); continue; }
    const lab = LABEL_LINE_RE.exec(u.text);
    if (lab) group = cleanTitle(lab[1]);
    else if (u.text.trim()) prose = true;
  }
  return { items, prose };
}
// The shared scripts a piece of text embeds directly, by lowercase title.
const embedsIn = (md) => extractTransclusionMarkers(md).filter((m) => m.kind === "excerpt").map((m) => m.title.toLowerCase());
// The text before and after the line that embeds one shared script.
function aroundEmbed(md, title) {
  const lines = linesOf(md);
  const i = lines.findIndex((l) => (excerptMarkerTitle(l) || "").toLowerCase() === title.toLowerCase());
  return i < 0 ? { before: String(md || "").trim(), after: "" }
    : { before: lines.slice(0, i).join("\n").trim(), after: lines.slice(i + 1).join("\n").trim() };
}

// ---------- the FIT page split into its ten parts ----------
// [Engaged: no] / [Engaged: yes] blocks become the same pair of "If …"
// expanders the rest of the manual uses, labeled the way the page's own picker
// labels them, so the walker asks it as one choice.
function engagedToDetails(text) {
  if (text.indexOf("[Engaged:") === -1) return text;
  const out = [];
  let open = false;
  let pair = 0;
  for (const line of text.split(/\r?\n/)) {
    const m = ENGAGED_MARK_RE.exec(line);
    if (m) {
      if (open) out.push("", "</details>", "");
      else pair += 1;
      const c = ENGAGED_CHOICES.find((x) => x.mark === m[1].toLowerCase()) || ENGAGED_CHOICES[0];
      out.push(`<details data-live-pair="e${pair}">`, `<summary>If ${c.label}</summary>`, "");
      open = true;
      continue;
    }
    if (ENGAGED_END_RE.test(line)) {
      if (open) { out.push("", "</details>", ""); open = false; }
      continue;
    }
    out.push(line);
  }
  if (open) out.push("", "</details>");
  return out.join("\n");
}
function markOpenerPick(text) {
  const lines = text.split(/\r?\n/);
  const i = lines.findIndex((l) => OPENER_MARK_RE.test(l));
  if (i < 0) return text;
  lines.splice(i, 0, "[[live:opener]]", "");
  return lines.join("\n");
}
function splitFitPage(raw, resolvers, { opener = null, mode = "pivot" } = {}) {
  const { resolveInclude, resolveExcerpt } = resolvers;
  // Each part starts where its opening fragment is embedded, at any depth.
  const marking = (title) => {
    const key = PART_BY_EXCERPT.get(String(title).trim().toLowerCase());
    const r = resolveExcerpt(title);
    if (!key) return r;
    return { status: "ok", md: `\n[[live:part:${key}]]\n\n${r && r.status === "ok" ? r.md : ""}` };
  };
  let text = expandTransclusions(String(raw || ""), { resolveInclude, resolveExcerpt: marking }, new Set(), 0);
  text = engagedToDetails(text);
  const openers = scanSelector(text).groups;
  if (openers.length) text = markOpenerPick(text);
  text = expandSelector(text, { openerState: { value: opener, mode, engaged: ENGAGED_CHOICES[0].value } });
  const chunks = { _pre: [] };
  let cur = "_pre";
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*\[\[live:part:([a-z_]+)\]\]\s*$/.exec(line);
    if (m) { cur = m[1]; if (!chunks[cur]) chunks[cur] = []; else chunks[cur].push(""); continue; }
    chunks[cur].push(line);
  }
  const parts = {};
  for (const [k, lines] of Object.entries(chunks)) {
    if (k === "_pre") continue;
    let body = lines.join("\n").replace(/^\s+/, "");
    let caption = "";
    // The part's own big heading goes; the tag on the side names the part. Its
    // aim, the words in brackets, is shown small on the tag.
    const h = /^##[ \t]+([^\n]+)\n?/.exec(body);
    if (h) { caption = ((/\(([^)]*)\)\s*$/.exec(h[1]) || [])[1] || "").trim(); body = body.slice(h[0].length); }
    parts[k] = { md: body.trim(), caption };
  }
  return { parts, pre: chunks._pre.join("\n").trim(), openers, hasParts: Object.keys(parts).length > 0 };
}

// ---------- the step splitter ----------
function toBlock(lines) {
  const text = lines.join("\n");
  const first = lines[0] || "";
  const b = { text, ask: text.includes(MONKEY) };
  if (/^\s*<details\b/i.test(first)) {
    b.details = true;
    const sm = /<summary\b[^>]*>([\s\S]*?)<\/summary\s*>/i.exec(text);
    b.summary = sm ? labelText(sm[1]) : "";
    let inner = text.replace(/^\s*<details\b[^>]*>/i, "").replace(/<\/details\s*>\s*$/i, "");
    if (sm) inner = inner.replace(sm[0], "");
    b.inner = inner.trim();
    b.isIf = !/data-live-ref/i.test(first) && /^if\b/i.test(b.summary);
    b.pair = (/data-live-pair="([^"]+)"/i.exec(first) || [])[1] || "";
  } else if (/^#{1,6}\s/.test(first)) {
    b.heading = true;
  } else if (SENTINEL_RE.test(first)) {
    b.sentinel = SENTINEL_RE.exec(first)[1];
  } else if (LIST_RE.test(first)) {
    b.list = true;
  } else if (lines.length === 1 && /:\s*$/.test(plainText(first)) && plainText(first).length < 120) {
    b.leadIn = true;    // "Go to other products here if applicable:"
  }
  return b;
}
function splitBlocks(md) {
  const out = [];
  let cur = [];
  let depth = 0;
  const flush = () => { if (cur.some((l) => l.trim())) out.push(toBlock(cur)); cur = []; };
  for (const line of String(md || "").split(/\r?\n/)) {
    const opens = (line.match(/<details\b/gi) || []).length;
    const closes = (line.match(/<\/details\s*>/gi) || []).length;
    if (depth === 0) {
      if (!line.trim()) { flush(); continue; }
      if (/^#{1,6}\s/.test(line) || SENTINEL_RE.test(line)) { flush(); out.push(toBlock([line])); continue; }
      if (/^\s*<details\b/i.test(line) && cur.length) flush();
    }
    cur.push(line);
    depth = Math.max(0, depth + opens - closes);
    if (depth === 0 && closes > 0 && /^\s*<details\b/i.test(cur[0] || "")) flush();
  }
  flush();
  return out;
}
// A list with questions in it is one step per item, so each question gets its own beat.
function splitListItems(b, listId) {
  const lines = b.text.split(/\r?\n/);
  const base = indentOf(lines[0]);
  const items = [];
  for (const line of lines) {
    const m = LIST_RE.exec(line);
    if ((m && m[1].length === base) || !items.length) items.push([line]);
    else items[items.length - 1].push(line);
  }
  return items.map((it) => {
    const nb = toBlock(it);
    nb.listId = listId;
    const n = /^\s*(\d+)\./.exec(it[0]);
    if (n) nb.olStart = Number(n[1]);
    return nb;
  });
}
function branchLabel(summary) {
  const s = String(summary || "").replace(/^if\s+/i, "").trim();
  return s ? s[0].toUpperCase() + s.slice(1) : String(summary || "");
}
// A pair about whether they have time is the page's own "how the call is
// going" question, asked in the page picker's words.
const TIME_RE = /time|engaged/i;
function branchTitle(opts) {
  return opts.every((o) => TIME_RE.test(o.label)) ? ENGAGED_TITLE : "Which fits?";
}
export function splitSteps(md) {
  const blocks = [];
  let lid = 0;
  for (const b of splitBlocks(md)) {
    if (b.list && b.ask) blocks.push(...splitListItems(b, ++lid)); else blocks.push(b);
  }
  const items = [];
  let cur = [];
  let asked = false;
  const text = (list) => list.reduce((s, b, i) => (i === 0 ? b.text
    : s + ((list[i - 1].listId && list[i - 1].listId === b.listId) ? "\n" : "\n\n") + b.text), "");
  const flush = () => {
    if (!cur.length) return;
    // A heading with nothing under it yet waits for what follows.
    if (cur.every((b) => b.heading)) return;
    items.push({ kind: "say", md: text(cur), olStart: cur[0].olStart || null });
    cur = [];
    asked = false;
  };
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    if (b.sentinel === "opener") { flush(); items.push({ kind: "opener", lead: text(cur) }); cur = []; asked = false; continue; }
    if (b.sentinel) continue;
    if (b.details && b.isIf) {
      let j = i;
      const group = [];
      // One choice is one pair of expanders. A third "If …" right after a time
      // pair ("If they're hesitating") is advice, not a third way to go.
      const timePair = () => group.length >= 2 && group.every((g) => TIME_RE.test(g.summary));
      while (j < blocks.length && blocks[j].details && blocks[j].isIf && blocks[j].pair === b.pair
             && !(timePair() && !TIME_RE.test(blocks[j].summary))) { group.push(blocks[j]); j++; }
      if (group.length >= 2) {
        // A lead-in line ("Go to other products here if applicable:") and any
        // heading waiting above it travel with the choice.
        const lead = [];
        while (cur.length && (cur[cur.length - 1].leadIn || cur[cur.length - 1].heading)) lead.unshift(cur.pop());
        flush();
        if (cur.length && cur.every((x) => x.heading)) { lead.unshift(...cur); cur = []; }
        const options = group.map((g) => ({ label: branchLabel(g.summary), md: g.inner }));
        items.push({ kind: "branch", title: branchTitle(options), lead: text(lead), options });
        asked = false;
        i = j - 1;
        continue;
      }
    }
    if (asked) {
      if (b.details) { cur.push(b); continue; }   // the expander under a question rides with it
      flush();
    }
    if (b.heading && cur.length && !cur.every((x) => x.heading)) flush();
    cur.push(b);
    if (b.ask) asked = true;
  }
  if (cur.length) { items.push({ kind: "say", md: text(cur), olStart: cur[0].olStart || null }); }
  return items;
}

// On a phone a table becomes stacked text, so nothing scrolls sideways. A table
// of side-by-side choices (bold headings, the way the FIT pages set out "First
// Chance | Last Chance", or a single row) reads down each column. A table of
// records (plain headings over several rows: one objection or one apartment
// complex to a row) reads row by row, each cell under its heading. A table
// without headings reads row by row.
const BOLD_RE = /^\*\*.*\*\*$/;
export function stackTables(md) {
  const lines = String(md || "").split(/\r?\n/);
  const isRow = isPipeRow, isSep = isPipeSep, cells = splitTableRow;
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (!(isRow(lines[i]) && i + 1 < lines.length && isSep(lines[i + 1]))) { out.push(lines[i]); continue; }
    const head = cells(lines[i]);
    i += 2;
    const rows = [];
    while (i < lines.length && isRow(lines[i]) && !isSep(lines[i])) { rows.push(cells(lines[i])); i++; }
    i--;
    out.push("");
    const named = head.filter(Boolean);
    if (named.length && (rows.length <= 1 || named.every((h) => BOLD_RE.test(h)))) {
      head.forEach((h, c) => {
        const col = rows.map((r) => r[c] || "").filter(Boolean);
        if (!h && !col.length) return;
        if (h) out.push(BOLD_RE.test(h) ? h : `**${h}**`, "");
        col.forEach((x) => out.push(x, ""));
      });
    } else {
      rows.forEach((r, n) => {
        if (n) out.push("---", "");
        r.forEach((x, c) => {
          if (!x) return;
          const h = String(head[c] || "").replace(/^\*\*|\*\*$/g, "").replace(/:\s*$/, "").trim();
          out.push(h ? `**${h}:** ${x}` : x, "");
        });
      });
    }
  }
  return out.join("\n");
}

// ---------- the library the walker reads ----------
export function makeScriptLibrary({ pages, excerpts, faqs }) {
  const pageRows = (pages || []).filter((p) => p && p.is_active !== false);
  const resolveInclude = makeIncludeResolver(buildIncludeLookup(pageRows));
  const resolveExcerpt = makeExcerptResolver(buildExcerptLookup(excerpts || []));
  const resolveFaq = makeFaqResolver(buildFaqLookup(faqs || []));
  const byId = new Map(pageRows.map((p) => [p.confluence_page_id, p]));
  const kids = (id) => pageRows.filter((p) => p.parent_page_id === id).sort((a, b) => {
    const ao = a.sort_order, bo = b.sort_order;
    if ((ao == null) !== (bo == null)) return ao == null ? 1 : -1;
    if (ao != null && ao !== bo) return ao - bo;
    return String(a.title || "").localeCompare(String(b.title || ""));
  });
  // A folder holds pages and says nothing of its own ("This section contains: …").
  const isFolder = (p) => {
    const c = String(p.content || "").trim();
    return kids(p.confluence_page_id).length > 0
      && (/^this section contains/i.test(c) || (c.length < 120 && c.indexOf("[Embedded") === -1));
  };
  const safe = (fn, title) => { try { return fn(title); } catch { return null; } };

  // Every shared script some manual page shows, at any depth. The walker only
  // plays a script from this set, so it can never play one the manual dropped.
  const shown = new Set();
  const shownPages = new Set();
  const visit = (md) => {
    for (const m of extractTransclusionMarkers(md)) {
      const key = m.title.toLowerCase();
      const seen = m.kind === "excerpt" ? shown : shownPages;
      if (seen.has(key)) continue;
      seen.add(key);
      const r = safe(m.kind === "excerpt" ? resolveExcerpt : resolveInclude, m.title);
      if (r && r.status === "ok") visit(r.md);
    }
  };
  for (const p of pageRows) visit(p.content);

  // Every page under FIT Conversations, in the manual's order: the product
  // pages (each walks as a FIT conversation) and every other page there (the
  // lead process, the specifications, the mortgage sales process). A folder
  // is not a page to open; its name heads the pages inside it.
  const products = [];
  const fitPages = [];
  const walk = (id, group, path) => {
    for (const p of kids(id)) {
      const pid = p.confluence_page_id;
      const title = String(p.title || "").trim();
      if (isFolder(p)) { walk(pid, title, [...path, pid]); continue; }
      const known = PRODUCT_BY_PAGE[pid];
      const m = /^Simple\s+(.+?)\s+FIT$/i.exec(title);
      if (known || m) {
        const name = m ? m[1].trim() : title;
        const map = known || { line: "", type: "", quotable: false, unmapped: true };
        products.push({ page: pid, name, label: name, line: map.line, type: map.type,
          quotable: map.quotable !== false && !!map.line, unmapped: !!map.unmapped });
      }
      fitPages.push({ key: pid, label: title, group, parent: id, path, product: !!(known || m) });
      walk(pid, group, [...path, pid]);
    }
  };
  walk(FIT_PAGE_ID, String((byId.get(FIT_PAGE_ID) || {}).title || "").trim(), [FIT_PAGE_ID]);

  const expand = (md) => expandTransclusions(String(md || ""), { resolveInclude, resolveExcerpt }, new Set(), 0);
  const script = (title) => {
    if (!shown.has(String(title).toLowerCase())) return "";
    const r = safe(resolveExcerpt, title);
    return r && r.status === "ok" ? r.md : "";
  };
  const fitCache = new Map();
  const stepCache = new Map();
  let inboundCache;
  let callListCache;
  const lib = {
    resolveFaq,
    products,
    fitPages,
    product: (id) => products.find((p) => p.page === id) || null,
    isProductPage: (id) => products.some((p) => p.page === id),
    page: (id) => byId.get(id) || null,
    pageTitle: (id) => String((byId.get(id) || {}).title || "").trim(),
    expand,
    script,
    inbound: () => (inboundCache === undefined ? (inboundCache = inboundParts(lib)) : inboundCache),
    callList: () => callListCache || (callListCache = callList(lib)),
    fitPage(id, opts = {}) {
      const key = `${id}|${opts.opener || ""}|${opts.mode || "pivot"}`;
      if (!fitCache.has(key)) fitCache.set(key, splitFitPage((byId.get(id) || {}).content || "", { resolveInclude, resolveExcerpt }, opts));
      return fitCache.get(key);
    },
    steps(md) {
      const k = String(md || "");
      if (!stepCache.has(k)) stepCache.set(k, splitSteps(k));
      return stepCache.get(k);
    },
  };
  return lib;
}

// Inbound Calls, cut along its own headings. Its sections are the Inbound call
// types; an "If …" section (another call coming in, a voicemail) folds under
// the greeting. Returns null when the manual no longer shows the script.
function inboundParts(L) {
  const raw = L.script(SCRIPT.inbound);
  if (!raw) return null;
  const { intro, sections } = sectionsOf(raw);
  const isRef = (s) => /^if\b/i.test(s.title);
  const kindOf = (s) => (matches(s.title, INBOUND_MARK.other) ? "other"
    : matches(s.title, INBOUND_MARK.sales) ? "sales"
    : embedsIn(s.md).includes(SCRIPT.car.toLowerCase()) ? "car" : "plain");
  const topics = keyed(sections.filter((s) => !isRef(s)).map((s) => ({ ...s, kind: kindOf(s) })), (s) => slug(s.title));
  const other = (topics.find((t) => t.kind === "other") || {}).md || "";
  // The wrap-up: the "Wrap up the call" item, the pivots under "By the way",
  // and the expanders after it. The ones the walker plays itself (the review
  // and referral, the other pivots, how to log the call) are not repeated as
  // reference; the rest ride with the help steps.
  const wr = listItemRange(other, INBOUND_MARK.wrap);
  const wrap = wr ? dedent(wr.lines.slice(wr.start, wr.end), wr.ind).join("\n") : "";
  const before = wr ? wr.lines.slice(0, wr.start).join("\n").trim() : other;
  const after = wr ? detailsBlocks(wr.lines.slice(wr.end).join("\n")) : [];
  const used = (d) => matches(d.label, INBOUND_MARK.fpp) || matches(d.label, INBOUND_MARK.logCall)
    || embedsIn(d.inner).includes(SCRIPT.referral.toLowerCase());
  const btw = wrap ? listItem(childrenOf(wrap), INBOUND_MARK.byTheWay) : null;
  const fppMd = detailsBySummary(other, INBOUND_MARK.fpp);
  const pivots = keyed([
    ...(btw ? listChildren(btw).map((md) => ({ label: boldLabel(md), md })).filter((p) => p.label) : []),
    ...(fppMd ? labelSections(fppMd).sections.map((s) => ({ label: s.label, md: s.md })) : []),
  ].map((p) => ({ ...p, kind: (PIVOT_KIND.find(([, re]) => re.test(p.label)) || ["plain"])[0] })), (p) => slug(p.label));
  return {
    greet: join(intro, ...sections.filter(isRef).map((s) => refDetails(s.title, s.md))),
    topics,
    help: join(before, ...after.filter((d) => !used(d)).map((d) => d.block)),
    wrapLines: wrap ? childrenOf(wrap, INBOUND_MARK.byTheWay) : "",
    pivots,
    logCall: detailsBySummary(other, INBOUND_MARK.logCall) || "",
    found: { sales: topics.some((t) => t.kind === "sales"), other: !!other, wrap: !!wrap, byTheWay: !!btw, logCall: !!detailsBySummary(other, INBOUND_MARK.logCall) },
  };
}

// Retention's checklists of calls we start, as the manual lists them: one per
// expander, labeled the way the manual labels it, grouped under the page and
// the bold line above it ("Outbound · Keeping the business").
function callList(L) {
  const tasks = [];
  for (const cl of CALL_LISTS) {
    const page = L.page(cl.page);
    if (!page) continue;
    const title = L.pageTitle(cl.page);
    for (const it of expanderList(page.content).items) {
      tasks.push({ label: it.label, group: it.group ? `${title} · ${it.group}` : title, md: it.md, embeds: embedsIn(it.md), page: slug(title) });
    }
  }
  return keyed(tasks, (t) => `${t.page}-${slug(t.label)}`);
}

// FIT product pages a script names ("see **Simple Auto FIT**") or links to.
function productsNamedIn(L, md) {
  const text = plainText(md).toLowerCase();
  return L.products.filter((p) => {
    const t = L.pageTitle(p.page).toLowerCase();
    return (t && text.includes(t)) || String(md || "").includes(`/processes/${p.page}`);
  });
}

// ---------- the call ----------
class Builder {
  constructor(st, lib) {
    this.st = st;
    this.lib = lib;
    this.nodes = [];
    this.stopped = false;
    this.part = null;
    this.fromParent = false;
    this.more = "";
    this.moreFrom = lib.pageTitle(FIT_PAGE_ID);
    this.rec = { relationship: "", source: "", activities: [], policies: [], products: [], fit: false, allowCancel: false };
  }
  // A choice. The walk stops here until it is made.
  ask(id, title, options, extra = {}) {
    if (this.stopped) return null;
    const pick = this.st.picks ? this.st.picks[id] : undefined;
    const ok = options.some((o) => o.key === pick);
    this.nodes.push({ id, kind: "decide", title, options, pick: ok ? pick : null, part: this.part, ...extra });
    if (!ok) { this.stopped = true; return null; }
    return pick;
  }
  // A script: its steps, and its own "If …" choices answered as they come.
  say(id, md, ctx = {}) {
    if (this.stopped || !md || !String(md).trim()) return;
    const items = this.lib.steps(md);
    for (let i = 0; i < items.length && !this.stopped; i++) {
      const it = items[i];
      if (it.kind === "say") {
        this.nodes.push({ id: `${id}.${i}`, kind: "step", md: it.md, olStart: it.olStart, part: this.part, fromParent: this.fromParent, more: this.more, moreFrom: this.moreFrom });
      } else if (it.kind === "branch") {
        const pick = this.ask(`${id}.${i}`, it.title, it.options.map((o, k) => ({ key: String(k), label: o.label })), { lead: it.lead });
        if (pick != null) this.say(`${id}.${i}.${pick}`, it.options[Number(pick)].md, ctx);
      } else if (it.kind === "opener" && ctx.page) {
        this.ask(`op.${ctx.page}`, "Which opener?", (ctx.openers || []).map((g) => ({ key: g.slug, label: g.label })), { lead: it.lead, many: true });
      }
    }
  }
  // A shared script the walker needs is not in the manual any more: the call
  // says so where the step would be, and carries on.
  missing(id, what) {
    if (this.stopped) return;
    this.nodes.push({ id, kind: "missing", what, part: this.part });
  }
  // One of the shared scripts in SCRIPT, or the gap where it was.
  script(id, name) {
    const raw = this.lib.script(SCRIPT[name]);
    if (raw) this.say(id, this.lib.expand(raw)); else this.missing(id, SCRIPT[name]);
    return raw;
  }
}

function addActivity(b, a) {
  if (!b.rec.activities.some((x) => x.key === a.key && (x.line || "") === (a.line || ""))) b.rec.activities.push(a);
}

// The FIT conversation. The first product walks every part; each product
// added after it brings its own Uncover and Bridge (and its opener, when the
// page has a choice of openers, the way Life does). Customize & Close, Set FU
// and Review & Referral run once, for everything discussed. A part a page
// does not carry comes from FIT Conversations itself.
function fit(b, { first, via }) {
  const L = b.lib, st = b.st;
  const pages = [first, ...((st.extra || []).filter((id) => id !== first && L.product(id)))];
  b.rec.products = pages;
  const mode = via === "quote" && st.mode === "outbound" ? "outbound" : "pivot";
  const exp = (id) => L.fitPage(id, { opener: (st.picks || {})[`op.${id}`] || null, mode });
  const parent = L.fitPage(FIT_PAGE_ID, {});
  const p1 = exp(first);
  if (!p1.hasParts) {
    // A page with no parts of its own (Investing) is one script.
    b.say(`fit.${first}.all`, p1.pre);
    return;
  }
  b.rec.fit = true;   // a FIT conversation happened, so the scorecard is due at the end
  const walk = (key, id, page, ctx = {}, fallback = true) => {
    const own = page.parts[key] && page.parts[key].md ? page.parts[key] : null;
    const md = own ? own.md : fallback ? (parent.parts[key] || {}).md : "";
    const general = (parent.parts[key] || {}).md || "";
    b.part = key;
    b.fromParent = !own;
    // FIT Conversations' own words for this part, offered folded under each step
    // when the page says something different.
    b.more = own && general && general !== own.md ? general : "";
    b.say(id, md, ctx);
    b.fromParent = false;
    b.more = "";
  };
  const start = via === "quote"
    ? ["demeanor_score", "frogs_score", "intro_score", "eligibility_score", "setup_gnc_score"]
    : [...(p1.openers.length ? ["intro_score"] : []), "eligibility_score", "setup_gnc_score"];
  if (p1.pre) { b.part = start[0]; b.say(`fit.${first}.pre`, p1.pre); }
  for (const key of start) walk(key, `fit.${first}.${key}`, p1, { page: first, openers: p1.openers });
  walk("uncover_gap_score", `fit.${first}.uncover`, p1, {}, false);
  walk("bridge_gap_score", `fit.${first}.bridge`, p1, {}, false);
  for (const id of pages.slice(1)) {
    const e = exp(id);
    if (e.openers.length) walk("intro_score", `fit.${id}.intro`, e, { page: id, openers: e.openers }, false);
    walk("uncover_gap_score", `fit.${id}.uncover`, e, {}, false);
    walk("bridge_gap_score", `fit.${id}.bridge`, e, {}, false);
  }
  walk("customize_close_score", `fit.${first}.close`, p1);
  const quotable = pages.map((id) => L.product(id)).filter((p) => p && p.quotable);
  if (quotable.length && !b.stopped) {
    b.part = "customize_close_score";
    // The close attempt is made: whatever they say, the quote is recorded.
    const names = quotable.map((p) => p.label);
    const c = b.ask("fit.close", "Did they say yes?", [{ key: "yes", label: "Yes, they're buying" }, { key: "no", label: "Not yet" }],
      { note: `Either way, ${names.length > 1 ? names.slice(0, -1).join(", ") + " and " + names[names.length - 1] : names[0]} log${names.length > 1 ? "" : "s"} as quoted.` });
    if (c) {
      for (const p of quotable) {
        b.rec.policies.push({ line: p.line, type: p.type, status: c === "yes" ? "quoted_sold" : "quoted", vehicles: "1" });
      }
    }
  }
  walk("set_followup_score", `fit.${first}.fu`, p1);
  walk("review_referral_score", `fit.${first}.rr`, p1);
  b.part = "review_referral_score";
  reviewLeft(b);
  b.part = null;
}

// Did they leave a review: the Log's own review sites, or not yet.
function reviewLeft(b) {
  const r = b.ask("rr.left", "Did they leave a review?", [...REVIEW_SITES, { key: "no", label: "Not yet" }]);
  if (r && r !== "no") addActivity(b, { key: "google_review", site: r });
}
function reviewAndReferral(b) {
  b.script("rr", "referral");
  reviewLeft(b);
}

// The products a pivot can go to: the FIT pages that sell something the Log knows.
function productOptions(L) {
  return L.products.filter((p) => p.line).map((p) => ({ key: p.page, label: p.label }));
}

// The FIT section as a list to pick from: every page under FIT Conversations,
// under the folder it sits in.
const fitOptions = (items) => items.map(({ key, label, group }) => ({ key, label, group }));

// A sales call: anything in the FIT section.
function quote(b, pre) {
  const id = b.ask(`${pre}.fit`, "Which one?", fitOptions(b.lib.fitPages), { many: true });
  if (id) fitEntry(b, id);
}

// One page of the FIT section. A product page asks the relationship and walks
// the FIT conversation. Any other page is its own script (a page that is a
// list of expanders, the way the lead process lists its contacts, asks which
// one first). Then the call goes on: to the pages under it or after it in the
// same folder or page, into a FIT conversation, or nowhere. It only ever moves
// forward, so it can't come back round to a page it has played.
function fitEntry(b, id) {
  const L = b.lib;
  const all = L.fitPages;
  const at = all.findIndex((m) => m.key === id);
  if (at < 0) return;
  const item = all[at];
  if (item.product) {
    const rel = b.ask(`fit.${id}.rel`, "Relationship", RELATIONSHIPS.map((r) => ({ ...r, hint: r.key === "existing" && b.st.onFile > 0 ? "on file" : "" })));
    if (!rel) return;
    b.rec.relationship = rel;
    fit(b, { first: id, via: "quote" });
    return;
  }
  const md = L.expand((L.page(id) || {}).content);
  const list = expanderList(md);
  if (!list.prose && list.items.length >= 2) {
    const items = keyed(list.items, (it) => slug(it.label));
    const k = b.ask(`fit.${id}.which`, "Which one?", items.map(({ key, label, group }) => ({ key, label, group })), { many: true });
    if (!k) return;
    b.say(`fit.${id}.${k}`, items.find((it) => it.key === k).md);
  } else {
    b.say(`fit.${id}`, md);
  }
  const later = all.slice(at + 1).filter((m) => !m.product);
  const beside = later.filter((m) => m.parent === item.parent);
  const onward = later.filter((m) => m.parent === item.parent || m.path.includes(id) || beside.some((s) => m.path.includes(s.key)));
  const next = b.ask(`fit.${id}.next`, "Where does it go from here?", [
    ...fitOptions(onward),
    ...fitOptions(all.filter((m) => m.product)),
    { key: "_done", label: "Nothing more" },
  ], { many: true });
  if (next && next !== "_done") fitEntry(b, next);
}

// A pivot into a product is recorded the moment it is chosen.
function pivotTo(b, line) {
  addActivity(b, { key: "pivot", line });
  if (!b.rec.source) b.rec.source = "service_pivot";
  if (!b.rec.relationship) b.rec.relationship = "existing";
}

// The end of every call that isn't a FIT conversation: anything else, the
// pivot, then the review and referral. The pivots offered are the ones the
// manual lists, in its words, plus any product and no pivot at all.
function wrapUp(b) {
  const L = b.lib;
  const ib = L.inbound();
  if (!ib) { reviewAndReferral(b); return; }
  b.say("wrap", ib.wrapLines);
  const p = b.ask("wrap.pivot", "Any pivot?", [
    ...ib.pivots.map((x) => ({ key: x.key, label: x.label })),
    ...(L.products.some((x) => x.line) ? [{ key: "_product", label: "Another product" }] : []),
    { key: "_none", label: "No pivot" },
  ]);
  if (!p) return;
  if (p === "_none") { reviewAndReferral(b); return; }
  if (p === "_product") {
    const id = b.ask("wrap.product", "Which product?", productOptions(L));
    if (!id) return;
    pivotTo(b, L.product(id).line);
    fit(b, { first: id, via: "pivot" });
    return;
  }
  const pv = ib.pivots.find((x) => x.key === p);
  b.say(`wrap.${p}`, L.expand(pv.md));
  const later = (id) => b.script(id, "schedule");
  if (pv.kind === "life") {
    const life = L.products.find((x) => x.line === "life" && x.quotable);
    pivotTo(b, "life");
    const w = b.ask(`wrap.${p}.when`, "Talk about it now?", [
      ...(life ? [{ key: "now", label: "Yes, now" }] : []), { key: "later", label: "Set a time" }, { key: "no", label: "Not interested" }]);
    if (!w) return;
    if (w === "now" && life) { fit(b, { first: life.page, via: "pivot" }); return; }
    if (w === "later") later(`wrap.${p}.later`);
    reviewAndReferral(b);
    return;
  }
  if (pv.kind === "fpp") {
    // The Family Protection Plan is hospital income, disability and life: the
    // FIT pages that sell those.
    const goes = [
      L.products.find((x) => x.type === "hospital_income"),
      L.products.find((x) => x.type === "disability_short_term"),
      L.products.find((x) => x.line === "life" && x.quotable),
    ].filter(Boolean);
    const f = b.ask(`wrap.${p}.which`, "Where does it go from here?", [
      ...goes.map((x) => ({ key: x.page, label: x.label })), { key: "later", label: "Set a time" }, { key: "no", label: "Not interested" }]);
    if (!f) return;
    const pg = L.product(f);
    pivotTo(b, pg ? pg.line : "health");
    if (pg) { fit(b, { first: pg.page, via: "pivot" }); return; }
    if (f === "later") later(`wrap.${p}.later`);
    reviewAndReferral(b);
    return;
  }
  reviewAndReferral(b);
}

// ---------- the shared scripts the walker builds a question around ----------
// Each plays its script, the text the task page puts after it, then its question.
function saveFlow(b, id, after = "") {
  if (!b.script(`${id}.save`, "save")) { wrapUp(b); return; }
  b.say(`${id}.after`, after);
  const o = b.ask(`${id}.stay`, "Are they staying?", [
    { key: "stay", label: "They're staying" }, { key: "cancel", label: "They're canceling" }, { key: "open", label: "Still deciding" }]);
  if (o === "stay") { addActivity(b, { key: "cancelation_saved" }); wrapUp(b); }
  if (o === "cancel") b.rec.allowCancel = true;
  if (o === "open") wrapUp(b);
}
// A policy review, then the Uncover and Bridge of the product the review
// names ("Auto: see Simple Auto FIT").
function reviewFlow(b, id, after = "") {
  const L = b.lib;
  const raw = b.script(`${id}.review`, "review");
  b.say(`${id}.after`, after);
  const named = productsNamedIn(L, raw);
  if (raw && named.length) {
    const pick = b.ask(`${id}.line`, "Which policy?", named.map((x) => ({ key: x.page, label: x.label })));
    if (!pick) return;
    const pg = L.product(pick);
    addActivity(b, { key: "policy_review", line: pg.line, type: pg.type });
    b.rec.source = "policy_review";   // anything quoted out of a review came from the review
    const e = L.fitPage(pg.page, {});
    b.say(`${id}.${pick}.uncover`, (e.parts.uncover_gap_score || {}).md);
    b.say(`${id}.${pick}.bridge`, (e.parts.bridge_gap_score || {}).md);
  }
  wrapUp(b);
}
// A script made of a few expanders (the claim touches): its opening, then the
// one that fits, walked step by step.
function claimsFlow(b, id, after = "") {
  pickOneOf(b, id, after, "claims", (raw) => {
    const r = expanderRun(raw);
    return { intro: r.intro, options: r.items.map((d) => ({ label: d.label, md: join(d.inner, d.more) })), tail: "" };
  });
}
// A script made of labeled sections (first, second, third time late): its
// opening, then the one that fits, with the expanders after them alongside.
function lateFlow(b, id, after = "") {
  pickOneOf(b, id, after, "late", (raw) => {
    const r = labelSections(raw);
    return { intro: r.intro, options: r.sections.map((s) => ({ label: s.label, md: s.md })), tail: r.tail };
  });
}
function pickOneOf(b, id, after, name, shape) {
  const L = b.lib;
  const raw = L.script(SCRIPT[name]);
  if (!raw) { b.missing(`${id}.${name}`, SCRIPT[name]); wrapUp(b); return; }
  const s = shape(raw);
  if (s.options.length < 2) {
    b.say(`${id}.${name}`, L.expand(raw));
  } else {
    b.say(`${id}.${name}.about`, L.expand(s.intro));
    const opts = keyed(s.options, (o) => slug(o.label));
    const k = b.ask(`${id}.${name}.which`, "Which one?", opts.map((o) => ({ key: o.key, label: o.label })));
    if (!k) return;
    b.say(`${id}.${name}.${k}`, L.expand(join(opts.find((o) => o.key === k).md, s.tail)));
  }
  b.say(`${id}.after`, after);
  wrapUp(b);
}
const FLOWS = [
  { name: "save", run: saveFlow },
  { name: "review", run: reviewFlow },
  { name: "claims", run: claimsFlow },
  { name: "late", run: lateFlow },
];

// One call off a Retention checklist: the expander's own text, step by step.
// When it embeds one of the scripts above, that script's question comes in at
// the point the page embeds it.
function playTask(b, task) {
  const L = b.lib;
  const id = `out.${task.key}`;
  const flow = FLOWS.find((f) => task.embeds.includes(SCRIPT[f.name].toLowerCase()) && L.script(SCRIPT[f.name]));
  if (!flow) { b.say(id, L.expand(task.md)); wrapUp(b); return; }
  const { before, after } = aroundEmbed(task.md, SCRIPT[flow.name]);
  b.say(`${id}.pre`, L.expand(before));
  flow.run(b, id, L.expand(after));
}

function inbound(b) {
  const L = b.lib;
  const ib = L.inbound();
  if (!ib) { b.missing("in", SCRIPT.inbound); return; }
  b.say("in.greet", L.expand(ib.greet));
  const topic = b.ask("in.topic", "What are they calling about?", ib.topics.map((t) => ({ key: t.key, label: t.title })));
  if (!topic) return;
  const t = ib.topics.find((x) => x.key === topic);
  if (t.kind === "sales") {
    b.say("in.sales", L.expand(t.md));
    const want = b.ask("in.sales.want", "What do they want?", [{ key: "quote", label: "A quote" }, { key: "cancel", label: "To cancel" }]);
    if (want === "quote") quote(b, "in");
    if (want === "cancel") { b.rec.relationship = "existing"; saveFlow(b, "in"); }
    return;
  }
  b.rec.relationship = "existing";
  if (t.kind === "other") { b.say("in.other", L.expand(ib.help)); wrapUp(b); return; }
  // A section that is only expanders (Billing: the details, or taking a
  // payment) asks which one; a section that is one expander is its content.
  const opts = onlyExpanders(t.md);
  if (opts) {
    const items = keyed(opts, (d) => slug(d.label));
    const k = b.ask(`in.${t.key}.which`, "Which one?", items.map((d) => ({ key: d.key, label: d.label })));
    if (!k) return;
    b.say(`in.${t.key}.${k}`, L.expand(items.find((d) => d.key === k).inner));
  } else {
    b.say(`in.${t.key}`, L.expand(unwrap(t.md)));
  }
  if (t.kind === "car") {
    const c = b.ask("in.car.kind", "Adding a car or replacing one?", [{ key: "add", label: "Adding a car" }, { key: "replace", label: "Replacing a car" }]);
    if (!c) return;
    if (c === "add") b.rec.policies.push({ line: "auto", type: "private_passenger", status: "sold", vehicles: "1", addedToExisting: true });
    if (c === "replace") addActivity(b, { key: "service_task" });   // Policy Change: covers a replacement vehicle
  }
  wrapUp(b);
}

function outbound(b) {
  const L = b.lib;
  const ib = L.inbound();
  const other = ib && ib.topics.find((t) => t.kind === "other");
  const tasks = L.callList();
  const topic = b.ask("out.topic", "Why are you calling?", [
    ...fitOptions(L.fitPages),
    ...tasks.map((t) => ({ key: t.key, label: t.label, group: t.group })),
    ...(other ? [{ key: "_other", label: other.title }] : []),
  ], { many: true });
  if (!topic) return;
  if (L.fitPages.some((m) => m.key === topic)) { fitEntry(b, topic); return; }
  b.rec.relationship = "existing";
  if (topic === "_other") { b.say("out.other", L.expand(ib.help)); wrapUp(b); return; }
  playTask(b, tasks.find((t) => t.key === topic));
}

// The whole call so far: every step and choice in order (stopping at the first
// choice not made yet), and what it has recorded.
export function buildCall(st, lib) {
  const b = new Builder(st || {}, lib);
  if ((st || {}).mode === "outbound") outbound(b); else inbound(b);
  if (!b.stopped) b.nodes.push({ id: "finish", kind: "finish", part: null });
  return { nodes: b.nodes, rec: b.rec, logCall: (lib.inbound() || {}).logCall || "" };
}

// ---------- is everything the walker hooks into still in the manual? ----------
// Each problem names what is missing and what the Live tab can't do without it.
// The Live tab shows the list, and so does every Processes page, for whoever
// can see the Live tab.
export function liveSourceProblems(lib) {
  const out = [];
  const miss = (what, why) => out.push({ what, why });
  if (!lib.page(FIT_PAGE_ID)) {
    miss("The FIT Conversations page", "Live can't walk a FIT conversation.");
  } else {
    const parts = lib.fitPage(FIT_PAGE_ID, {}).parts;
    for (const p of CARD_PARTS) {
      if (!(parts[p.key] || {}).md) miss(`"${p.excerpt}" on FIT Conversations`, `Live can't tell where ${p.label} starts, so that part's tag and score don't show.`);
    }
    for (const p of lib.products) {
      if (p.unmapped) miss(lib.pageTitle(p.page), "Live doesn't know which Log product this page sells, so a yes on it isn't logged as a quote.");
    }
  }
  for (const c of CALL_LISTS) {
    if (!lib.page(c.page)) miss(`The ${c.name} page`, "Its calls are missing from Live's Outbound list.");
  }
  for (const [k, title] of Object.entries(SCRIPT)) {
    if (!lib.script(title)) miss(`"${title}"`, SCRIPT_NEED[k]);
  }
  const ib = lib.inbound();
  if (ib) {
    const f = ib.found;
    if (!f.sales) miss(`A section starting "Sales" in Inbound Calls`, "Inbound quote and cancel calls can't start.");
    if (!f.other) miss(`An "Other" section in Inbound Calls`, "Calls have no help steps and no wrap-up.");
    else {
      if (!f.wrap) miss(`"Wrap up the call" in Inbound Calls`, "Calls end without the wrap-up or the pivot question.");
      else if (!f.byTheWay) miss(`"By the way" under "Wrap up the call" in Inbound Calls`, "The manual's pivots are missing from the pivot question.");
      if (!f.logCall) miss(`"Log the call" in Inbound Calls`, "The finish screen loses How to log it in ECRM.");
    }
  }
  const claims = lib.script(SCRIPT.claims);
  if (claims && expanderRun(claims).items.length < 2) miss(`The touches in "${SCRIPT.claims}"`, "Live can't offer a choice of touch; the whole script shows instead.");
  const late = lib.script(SCRIPT.late);
  if (late && labelSections(late).sections.length < 2) miss(`The bold labels in "${SCRIPT.late}"`, "Live can't offer a choice of how many times late; the whole script shows instead.");
  const review = lib.script(SCRIPT.review);
  if (review && !productsNamedIn(lib, review).length) miss(`A FIT page named in "${SCRIPT.review}"`, "Live can't carry a policy review into that product's Uncover and Bridge.");
  return out;
}
