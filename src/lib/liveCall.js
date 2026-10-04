import {
  expandTransclusions, expandSelector, scanSelector, isPipeRow, isPipeSep, splitTableRow,
  buildIncludeLookup, makeIncludeResolver, buildExcerptLookup, makeExcerptResolver,
  buildFaqLookup, makeFaqResolver, OPENER_MARK_RE, ENGAGED_MARK_RE, ENGAGED_END_RE,
} from "./markdown.js";
import { CARD_PARTS } from "./fitParts.js";

// ============================================================
// Live tab — the call walker (Peter 2026-10-04).
//
// Every word the walker shows comes from the Processes manual: the FIT
// Conversations pages and the Retention pages, through the same shared
// fragments the manual pages embed. Nothing is copied. Edit a script in the
// manual and the Live tab says the new words on the next call.
//
// What lives here, and only here:
//   * makeScriptLibrary — loads the manual rows into one object the walker reads
//   * the step splitter — cuts a script into "the next thing to say": a step
//     ends at every 🙊 (ask, then let them answer), a pair of "If …" expanders
//     becomes a choice, and expanders that follow a question ride along with it
//   * buildCall — turns the call so far (the choices made) into the list of
//     steps and choices, and works out what the call has recorded: pivots,
//     quotes, sales, saves, reviews
//
// The walker never saves anything itself. The Live tab hands what it recorded
// to the Log tab's own form at the end of the call, so every rule the Log
// enforces holds here too, and rp_log_entry stays the one save.
// ============================================================

export const FIT_PAGE_ID = "2124251137";   // Processes > FIT Conversations: the ten parts, in order
const MONKEY = "🙊";
const LIST_RE = /^(\s*)([-*]|\d+\.)\s+/;
const SENTINEL_RE = /^\s*\[\[live:([a-z_:]+)\]\]\s*$/;
const PART_BY_EXCERPT = new Map(CARD_PARTS.map((p) => [p.excerpt.toLowerCase(), p.key]));

// What each FIT page quotes, keyed by the name in its title ("Simple <name> FIT").
// A page whose name is not listed still walks; it just has nothing to quote.
// Investing and Retirement Insurance set a meeting with Peter, so they never quote.
const PRODUCT_LINES = {
  "auto":                 { line: "auto",     type: "private_passenger" },
  "home":                 { line: "fire",     type: "home" },
  "liability":            { line: "fire",     type: "plup" },
  "valuables":            { line: "fire",     type: "pap" },
  "boatowners":           { line: "fire",     type: "boat" },
  "business":             { line: "fire",     type: "business_insurance" },
  "life":                 { line: "life",     type: "" },
  "hi":                   { line: "health",   type: "hospital_income" },
  "di":                   { line: "health",   type: "disability_short_term" },
  "motorcycle":           { line: "auto",     type: "motorcycle" },
  "rv":                   { line: "auto",     type: "rv" },
  "classic car":          { line: "auto",     type: "classic" },
  "investing":            { line: "variable", type: "", quotable: false },
  "retirement insurance": { line: "",         type: "", quotable: false },
};

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
const indentOf = (l) => (/^(\s*)/.exec(l) || ["", ""])[1].length;
const dedent = (lines, n) => lines.map((l) => (l.slice(0, n).trim() === "" ? l.slice(n) : l.trimStart()));
const join = (...parts) => parts.filter((p) => p && String(p).trim()).join("\n\n");
// A reference expander the walker made itself. data-live-ref keeps it from ever
// being read as a choice, even when its label starts with "If".
export const refDetails = (summary, md) => (md && String(md).trim()
  ? `<details data-live-ref>\n<summary>${summary}</summary>\n\n${String(md).trim()}\n\n</details>` : "");

// ---------- pulling one piece out of a script (raw manual text) ----------
// The section under a heading, up to the next heading of the same or a higher
// level. Headings inside an expander are not section breaks.
export function sectionByHeading(md, test) {
  const lines = String(md || "").split(/\r?\n/);
  let start = -1, level = 0, depth = 0;
  for (let i = 0; i < lines.length; i++) {
    const h = depth === 0 ? /^(#{1,6})\s+(.*)$/.exec(lines[i]) : null;
    if (h) {
      if (start < 0) {
        if (matches(plainText(h[2]), test)) { start = i; level = h[1].length; }
      } else if (h[1].length <= level) {
        return lines.slice(start + 1, i).join("\n").trim();
      }
    }
    depth = Math.max(0, depth + (lines[i].match(/<details\b/gi) || []).length - (lines[i].match(/<\/details\s*>/gi) || []).length);
  }
  return start < 0 ? null : lines.slice(start + 1).join("\n").trim();
}

// Every top-level expander in a script: its label, what is inside it, and the whole block.
function detailsBlocks(md) {
  const lines = String(md || "").split(/\r?\n/);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s*<details\b/i.test(lines[i])) continue;
    let depth = 0, j = i;
    for (; j < lines.length; j++) {
      depth += (lines[j].match(/<details\b/gi) || []).length - (lines[j].match(/<\/details\s*>/gi) || []).length;
      if (depth <= 0) break;
    }
    const block = lines.slice(i, j + 1).join("\n");
    const sm = /<summary\b[^>]*>([\s\S]*?)<\/summary\s*>/i.exec(block);
    let inner = block.replace(/^\s*<details\b[^>]*>/i, "").replace(/<\/details\s*>\s*$/i, "");
    if (sm) inner = inner.replace(sm[0], "");
    out.push({ label: sm ? plainText(sm[1]) : "", inner: inner.trim(), block });
    i = j;
  }
  return out;
}
export function detailsBySummary(md, test) {
  const hit = detailsBlocks(md).find((d) => matches(d.label, test));
  return hit ? hit.inner : null;
}
const detailsBlockBySummary = (md, test) => (detailsBlocks(md).find((d) => matches(d.label, test)) || {}).block || "";
// A section that is nothing but one expander is that expander's content.
export function unwrap(md) {
  const t = String(md || "").trim();
  const d = detailsBlocks(t);
  return d.length === 1 && t.startsWith(d[0].block.trim()) && t.endsWith(d[0].block.trim()) ? d[0].inner : t;
}

// The list item whose text matches, with everything nested under it.
export function listItem(md, test) {
  const lines = String(md || "").split(/\r?\n/);
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
    return dedent(lines.slice(i, j), ind).join("\n");
  }
  return null;
}
// What is nested under a list item, stopping at the child that matches stopTest.
function childrenOf(itemMd, stopTest) {
  const lines = String(itemMd || "").split(/\r?\n/).slice(1);
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
const cutBefore = (md, re) => {
  const lines = String(md || "").split(/\r?\n/);
  const i = lines.findIndex((l) => re.test(l));
  return i < 0 ? String(md || "") : lines.slice(0, i).join("\n").trim();
};
// A bold label on its own line ("**First time they're late:**") and what follows it.
function labelSection(md, test) {
  const lines = String(md || "").split(/\r?\n/);
  const isLabel = (l) => /^\*\*[^*]+\*\*\s*$/.test(l.trim());
  const i = lines.findIndex((l) => isLabel(l) && matches(plainText(l), test));
  if (i < 0) return null;
  let j = i + 1;
  while (j < lines.length && !isLabel(lines[j]) && !/^\s*<details\b/i.test(lines[j])) j++;
  return lines.slice(i, j).join("\n").trim();
}

// ---------- the FIT page split into its ten parts ----------
// [Engaged: no] / [Engaged: yes] blocks become the same pair of "If …" expanders
// the rest of the manual uses, so the walker asks it as one choice.
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
      out.push(`<details data-live-pair="e${pair}">`, `<summary>${m[1].toLowerCase() === "yes" ? "If they're engaged and have time" : "If they DON'T have time"}</summary>`, "");
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
  text = expandSelector(text, { openerState: { value: opener, mode, engaged: "notime" } });
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
    b.summary = sm ? plainText(sm[1]) : "";
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
const TIME_RE = /time|engaged/i;
function branchTitle(opts) {
  return opts.every((o) => TIME_RE.test(o.label)) ? "Do they have time right now?" : "Which fits?";
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
// with column headings reads down each column; one without reads row by row.
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
    if (head.some((h) => h)) {
      head.forEach((h, c) => {
        const col = rows.map((r) => r[c] || "").filter(Boolean);
        if (!h && !col.length) return;
        if (h) out.push(/^\*\*.*\*\*$/.test(h) ? h : `**${h}**`, "");
        col.forEach((x) => out.push(x, ""));
      });
    } else {
      rows.forEach((r, n) => {
        if (n) out.push("---", "");
        r.filter(Boolean).forEach((x) => out.push(x, ""));
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
  const isFolder = (p) => {
    const c = String(p.content || "").trim();
    return /^this section contains/i.test(c) || (c.length < 120 && c.indexOf("[Embedded") === -1);
  };
  // Every "Simple <name> FIT" page under FIT Conversations, in the manual's order.
  const products = [];
  const walk = (id) => {
    for (const p of kids(id)) {
      const m = /^Simple\s+(.+?)\s+FIT$/i.exec(String(p.title || "").trim());
      if (m && !isFolder(p)) {
        const name = m[1].trim();
        const map = PRODUCT_LINES[name.toLowerCase()] || { line: "", type: "", quotable: false };
        products.push({ page: p.confluence_page_id, name, label: name, line: map.line, type: map.type,
          quotable: map.quotable !== false && !!map.line });
      }
      walk(p.confluence_page_id);
    }
  };
  walk(FIT_PAGE_ID);

  const expand = (md) => expandTransclusions(String(md || ""), { resolveInclude, resolveExcerpt }, new Set(), 0);
  const excerptRaw = (title) => { const r = resolveExcerpt(title); return r && r.status === "ok" ? r.md : ""; };
  const fitCache = new Map();
  const stepCache = new Map();
  let inboundCache = null;
  const lib = {
    inbound: () => inboundCache || (inboundCache = inboundParts(lib)),
    resolveFaq,
    products,
    product: (id) => products.find((p) => p.page === id) || null,
    productByName: (n) => products.find((p) => p.name.toLowerCase() === String(n).toLowerCase()) || null,
    isProductPage: (id) => products.some((p) => p.page === id),
    expand,
    excerptRaw,
    excerpt: (title) => expand(excerptRaw(title)),
    pageRaw: (id) => (byId.get(id) || {}).content || "",
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

// ---------- the call ----------
export const INBOUND_TOPICS = [
  { key: "claim",   label: "A claim" },
  { key: "billing", label: "A billing question" },
  { key: "payment", label: "Making a payment" },
  { key: "car",     label: "Adding or replacing a car" },
  { key: "cancel",  label: "Canceling" },
  { key: "quote",   label: "A quote" },
  { key: "other",   label: "Something else" },
];
export const OUTBOUND_TOPICS = [
  { key: "quote",   label: "A quote" },
  { key: "renewal", label: "Renewal or price change" },
  { key: "claim",   label: "Claim follow-up" },
  { key: "late",    label: "Late payment" },
  { key: "save",    label: "Saving a cancelation" },
  { key: "review",  label: "Policy review" },
  { key: "appt",    label: "Another appointment" },
  { key: "other",   label: "Something else" },
];
// Peter's three relationship values, the same ones the Log uses.
const RELATIONSHIPS = [
  { key: "new", label: "New" },
  { key: "existing", label: "Existing" },
  { key: "winback", label: "Winback" },
];
const REVIEW_SITES = [
  { key: "google", label: "Google" },
  { key: "facebook", label: "Facebook" },
  { key: "yelp", label: "Yelp" },
  { key: "no", label: "Not yet" },
];

class Builder {
  constructor(st, lib) {
    this.st = st;
    this.lib = lib;
    this.nodes = [];
    this.stopped = false;
    this.part = null;
    this.fromParent = false;
    this.more = "";
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
        this.nodes.push({ id: `${id}.${i}`, kind: "step", md: it.md, olStart: it.olStart, part: this.part, fromParent: this.fromParent, more: this.more });
      } else if (it.kind === "branch") {
        const pick = this.ask(`${id}.${i}`, it.title, it.options.map((o, k) => ({ key: String(k), label: o.label })), { lead: it.lead });
        if (pick != null) this.say(`${id}.${i}.${pick}`, it.options[Number(pick)].md, ctx);
      } else if (it.kind === "opener" && ctx.page) {
        this.ask(`op.${ctx.page}`, "Which opener?", (ctx.openers || []).map((g) => ({ key: g.slug, label: g.label })), { lead: it.lead, many: true });
      }
    }
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
  // An existing customer called about a home: the manual's outreach script for
  // auto customers with no home is the opener (Retention > Outbound).
  const homeOutreach = via === "quote" && st.mode === "outbound" && b.rec.relationship === "existing"
    && (L.product(first) || {}).type === "home" ? L.excerpt("Auto no Home") : "";
  if (p1.pre) { b.part = start[0]; b.say(`fit.${first}.pre`, p1.pre); }
  for (const key of start) {
    if (key === "intro_score" && homeOutreach) { b.part = key; b.say(`fit.${first}.${key}.home`, homeOutreach); continue; }
    walk(key, `fit.${first}.${key}`, p1, { page: first, openers: p1.openers });
  }
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

function reviewLeft(b) {
  const r = b.ask("rr.left", "Did they leave a review?", REVIEW_SITES);
  if (r && r !== "no") addActivity(b, { key: "google_review", site: r });
}
function reviewAndReferral(b) {
  b.say("rr", b.lib.excerpt("Review & Referral"));
  reviewLeft(b);
}

function productOptions(L, onlyWithLine) {
  return L.products.filter((p) => !onlyWithLine || p.line).map((p) => ({ key: p.page, label: p.label }));
}

function quote(b, pre) {
  const st = b.st;
  const rel = b.ask(`${pre}.rel`, "Relationship", RELATIONSHIPS.map((r) => ({ ...r, hint: r.key === "existing" && st.onFile > 0 ? "on file" : "" })));
  if (!rel) return;
  b.rec.relationship = rel;
  const first = b.ask("fit.product", "Which product?", productOptions(b.lib));
  if (!first) return;
  fit(b, { first, via: "quote" });
}

// Inbound Calls, cut into the pieces the walker uses. Anything it cannot find
// falls back to the whole section, so no words are ever dropped.
function inboundParts(L) {
  const raw = L.excerptRaw("Inbound Calls");
  const other = sectionByHeading(raw, "other") || "";
  const wrap = listItem(other, "wrap up the call");
  const helpRaw = wrap ? cutBefore(other, /^\s*[-*]\s+Wrap up the call/i) : other;
  const refs = ["authorize info/access", "referring a customer"].map((t) => detailsBlockBySummary(other, t)).filter(Boolean).join("\n\n");
  const firstHeading = raw.split(/\r?\n/).findIndex((l) => /^#{1,6}\s/.test(l));
  const greet = firstHeading < 0 ? raw : raw.split(/\r?\n/).slice(0, firstHeading).join("\n");
  return {
    raw,
    greet: join(greet,
      refDetails("If another call comes in", sectionByHeading(raw, "if another call comes in")),
      refDetails("If we received a VM", sectionByHeading(raw, "if we received a vm"))),
    claim: unwrap(sectionByHeading(raw, "claim") || ""),
    billing: sectionByHeading(raw, "billing") || "",
    sales: sectionByHeading(raw, "sales") || "",
    car: unwrap(sectionByHeading(raw, "added/replaced auto") || ""),
    help: wrap ? join(helpRaw, refs) : other,
    wrapLines: wrap ? childrenOf(wrap, "by the way") : "",
    generic: listItem(other, /^generic pivot/) || "",
    life: listItem(other, /^life pivot/) || "",
    fpp: detailsBySummary(other, "other pivots") || "",
    logCall: detailsBySummary(other, "log the call") || "",
    hasWrap: !!wrap,
  };
}

// The end of every service call: anything else, the pivot, then the review and
// referral. A pivot into a product is recorded the moment it is chosen.
function wrapUp(b) {
  const L = b.lib;
  const ib = L.inbound();
  if (ib.hasWrap) b.say("wrap", ib.wrapLines);
  const p = b.ask("wrap.pivot", "Any pivot?", [
    { key: "life", label: "Life" },
    { key: "fpp", label: "Family Protection Plan" },
    { key: "product", label: "Another product" },
    { key: "review", label: "Account review" },
    { key: "none", label: "No pivot" },
  ]);
  if (!p) return;
  const later = (id) => b.say(id, join("Now schedule a time", L.excerpt("Appointments Set & Create")));
  const pivotTo = (line) => {
    addActivity(b, { key: "pivot", line });
    if (!b.rec.source) b.rec.source = "service_pivot";
    if (!b.rec.relationship) b.rec.relationship = "existing";
  };
  if (p === "life") {
    b.say("wrap.life", L.expand(ib.life));
    pivotTo("life");
    const w = b.ask("wrap.life.when", "Talk about it now?", [
      { key: "now", label: "Yes, now" }, { key: "later", label: "Set a time" }, { key: "no", label: "Not interested" }]);
    if (!w) return;
    const life = L.productByName("life");
    if (w === "now" && life) { fit(b, { first: life.page, via: "pivot" }); return; }
    if (w === "later") later("wrap.life.later");
    reviewAndReferral(b);
    return;
  }
  if (p === "fpp") {
    b.say("wrap.fpp", L.expand(ib.fpp));
    const f = b.ask("wrap.fpp.which", "Where does it go from here?", [
      { key: "hi", label: "HI" }, { key: "di", label: "DI" }, { key: "life", label: "Life" },
      { key: "later", label: "Set a time" }, { key: "no", label: "Not interested" }]);
    if (!f) return;
    const pg = ["hi", "di", "life"].includes(f) ? L.productByName(f) : null;
    pivotTo(pg ? pg.line : "health");
    if (pg) { fit(b, { first: pg.page, via: "pivot" }); return; }
    if (f === "later") later("wrap.fpp.later");
    reviewAndReferral(b);
    return;
  }
  if (p === "product") {
    const id = b.ask("wrap.product", "Which product?", productOptions(L, true));
    if (!id) return;
    pivotTo(L.product(id).line);
    fit(b, { first: id, via: "pivot" });
    return;
  }
  if (p === "review") b.say("wrap.review", L.expand(ib.generic));
  reviewAndReferral(b);
}

function save(b) {
  b.say("save", b.lib.excerpt("Save Household"));
  const o = b.ask("save.outcome", "Are they staying?", [
    { key: "stay", label: "They're staying" }, { key: "cancel", label: "They're canceling" }, { key: "open", label: "Still deciding" }]);
  if (o === "stay") { addActivity(b, { key: "cancelation_saved" }); wrapUp(b); }
  if (o === "cancel") b.rec.allowCancel = true;
  if (o === "open") wrapUp(b);
}

function inbound(b) {
  const L = b.lib;
  const ib = L.inbound();
  b.say("in.greet", L.expand(ib.greet));
  const topic = b.ask("in.topic", "What are they calling about?", INBOUND_TOPICS);
  if (!topic) return;
  if (topic !== "quote") b.rec.relationship = "existing";
  switch (topic) {
    case "claim": b.say("in.claim", L.expand(ib.claim)); wrapUp(b); break;
    case "billing": b.say("in.billing", L.expand(detailsBySummary(ib.billing, "billing details") || ib.billing)); wrapUp(b); break;
    case "payment": b.say("in.payment", L.expand(detailsBySummary(ib.billing, "taking a payment") || L.excerptRaw("Payment Script"))); wrapUp(b); break;
    case "car": {
      b.say("in.car", L.expand(ib.car));
      const c = b.ask("in.car.kind", "Adding a car or replacing one?", [{ key: "add", label: "Adding a car" }, { key: "replace", label: "Replacing a car" }]);
      if (c === "add") b.rec.policies.push({ line: "auto", type: "private_passenger", status: "sold", vehicles: "1", addedToExisting: true });
      if (c === "replace") addActivity(b, { key: "service_task" });   // Policy Change: covers a replacement vehicle
      if (c) wrapUp(b);
      break;
    }
    case "cancel": b.say("in.cancel", L.expand(ib.sales)); save(b); break;
    case "quote": b.say("in.quote", L.expand(ib.sales)); quote(b, "in"); break;
    default: b.say("in.other", L.expand(ib.help)); wrapUp(b); break;
  }
}

function outbound(b) {
  const L = b.lib;
  const topic = b.ask("out.topic", "Why are you calling?", OUTBOUND_TOPICS);
  if (!topic) return;
  if (topic !== "quote") b.rec.relationship = "existing";
  switch (topic) {
    case "quote": quote(b, "out"); break;
    case "renewal":
      b.say("out.renewal", join(L.excerpt("Premium Change Script"), refDetails("Renewal texts", L.excerpt("Renewal"))));
      wrapUp(b);
      break;
    case "claim": {
      const raw = L.excerptRaw("Claims Touches");
      const t = b.ask("out.claim.touch", "Which check-in?", [{ key: "t2", label: "Seven days after" }, { key: "t3", label: "Thirty days after" }]);
      if (!t) return;
      const about = cutBefore(raw, /^\s*<details\b/i);
      b.say(`out.claim.${t}`, L.expand(join(detailsBySummary(raw, t === "t2" ? "touch 2" : "touch 3") || raw, refDetails("About claim follow-ups", about))));
      wrapUp(b);
      break;
    }
    case "late": {
      const raw = L.excerptRaw("Late Pay Process");
      const n = b.ask("out.late.n", "How many times have they been late?", [
        { key: "first", label: "First time" }, { key: "second", label: "Second time" }, { key: "third", label: "Third time" }]);
      if (!n) return;
      const about = cutBefore(raw, /^\*\*First time/i);
      b.say(`out.late.${n}`, L.expand(join(labelSection(raw, `${n} time`) || raw, refDetails("How late pays work", about),
        detailsBlockBySummary(raw, "late payment"))));
      wrapUp(b);
      break;
    }
    case "save": save(b); break;
    case "review": {
      b.say("out.review", L.excerpt("Review Policy"));
      const which = b.ask("out.review.line", "Which policy?", [{ key: "auto", label: "Auto" }, { key: "home", label: "Home" }]);
      if (!which) return;
      const pg = L.productByName(which);
      if (pg) {
        addActivity(b, { key: "policy_review", line: pg.line, type: pg.type });
        b.rec.source = "policy_review";   // anything quoted out of a review came from the review
        const e = L.fitPage(pg.page, {});
        b.say(`out.review.${which}.uncover`, (e.parts.uncover_gap_score || {}).md);
        b.say(`out.review.${which}.bridge`, (e.parts.bridge_gap_score || {}).md);
      }
      wrapUp(b);
      break;
    }
    case "appt": {
      const k = b.ask("out.appt", "Which appointment?", [
        { key: "welcome", label: "Welcome" }, { key: "young", label: "Young driver review" },
        { key: "life", label: "Life review" }, { key: "set", label: "Setting one up" }]);
      if (!k) return;
      const md = k === "welcome" ? L.excerpt("Welcome")
        : k === "young" ? L.excerpt("Review New Young Driver")
        : k === "life" ? L.excerpt("Life Review")
        : join(L.excerpt("Appointment Setting"), L.excerpt("Appointments Set & Create"));
      b.say(`out.appt.${k}`, md);
      wrapUp(b);
      break;
    }
    default: b.say("out.other", L.expand(L.inbound().help)); wrapUp(b); break;
  }
}

// The whole call so far: every step and choice in order (stopping at the first
// choice not made yet), and what it has recorded.
export function buildCall(st, lib) {
  const b = new Builder(st || {}, lib);
  if ((st || {}).mode === "outbound") outbound(b); else inbound(b);
  if (!b.stopped) b.nodes.push({ id: "finish", kind: "finish", part: null });
  return { nodes: b.nodes, rec: b.rec, logCall: lib.inbound().logCall };
}
