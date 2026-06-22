import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";

// ============================================================
// BCC HANDBOOK MODULE v1.0
// Business Command Center — State Farm Agent Edition
//
// PURPOSE:
// Read-only viewer for the team handbook. Source of truth
// lives in Confluence (pjsagency.atlassian.net); BCC mirrors
// it into public.handbook for offline reference and quick
// in-app lookup.
//
// DATA SHAPE (public.handbook):
//   - one row per Confluence page
//   - tree via parent_page_id (NULL = root)
//   - content stored as Markdown with embedded HTML for
//     <details>/<summary> expand sections, <blockquote>
//     callouts, and tables that contain expands
//   - versioned: is_active=true for the current version,
//     prior versions kept with archived_at set
//
// THIS MODULE IS READ-ONLY BY DESIGN.
// Edits happen in Confluence. The mirror is one-way.
// ============================================================

// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

// ─── Section icon picker ──────────────────────────────────────
// Map page title to a small emoji glyph so the sidebar reads at a glance.
function iconForTitle(title) {
  const t = String(title || "").toLowerCase();
  if (/^handbook\b/.test(t))                  return "📘";
  if (/benefits/.test(t))                     return "💼";
  if (/hours|time\s*off|pto|vacation/.test(t))return "⏰";
  if (/bonus|pay|compensation/.test(t))       return "💵";
  if (/win the week|wtw/.test(t))             return "🏆";
  if (/development|training/.test(t))         return "🎓";
  if (/culture|professional/.test(t))         return "🤝";
  if (/employment|termination|hire|fire/.test(t)) return "📝";
  if (/health|safety|security/.test(t) && !/info/.test(t)) return "🛡️";
  if (/information security|spi|privacy/.test(t)) return "🔒";
  if (/meeting|review|report/.test(t))        return "📊";
  if (/property|system|information/.test(t))  return "🖥️";
  if (/vehicle/.test(t))                      return "🚗";
  if (/protecting spi/.test(t))               return "🔐";
  if (/personal information/.test(t))         return "🪪";
  return "📄";
}

// ─── Markdown → HTML (lightweight, with HTML passthrough) ─────
// Handles the subset of markdown the handbook ingestion produces:
//   #..######, paragraphs, - and * bullets, 1. ordered lists,
//   **bold**, *italic*, `code`, [text](url), --- hr, ``` fences.
// Plus: passes through block HTML for <details>, <summary>,
// <blockquote>, <table>, <div>, <figure>, <aside>.
// Unescapes backslash-escaped asterisks/underscores so labels
// like \*\*Info:\*\* render bold (the ingestion over-escaped them).
function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function inlineMd(s) {
  if (!s) return "";
  let out = String(s);

  // Unescape \* \_ before inline parsing so escaped bold/italic still renders.
  out = out.replace(/\\([*_`\[\]])/g, "$1");

  // Links [text](url) — guard against javascript: scheme.
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, txt, url) => {
    const safe = /^(https?:|mailto:|#|\/)/i.test(url) ? url : "#";
    return `<a href="${safe}" target="_blank" rel="noreferrer noopener">${txt}</a>`;
  });

  // Bold (** or __)
  out = out.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");

  // Italic (* or _), not consuming **
  out = out.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
  out = out.replace(/(^|[^_])_([^_\n]+)_(?!_)/g, "$1<em>$2</em>");

  // Inline code
  out = out.replace(/`([^`\n]+)`/g, "<code>$1</code>");

  return out;
}

const PASSTHROUGH_TAGS = ["details", "summary", "blockquote", "table", "div", "figure", "aside"];

export function mdToHtml(md) {
  const src = String(md || "");
  if (!src.trim()) return "";

  const lines = src.split(/\r?\n/);
  const out = [];
  let i = 0;
  let inCode = false;
  let codeBuf = [];
  let listType = null; // "ul" | "ol"
  let paraBuf = [];

  const flushPara = () => {
    if (paraBuf.length) {
      out.push("<p>" + inlineMd(paraBuf.join(" ")) + "</p>");
      paraBuf = [];
    }
  };
  const flushList = () => {
    if (listType) {
      out.push(`</${listType}>`);
      listType = null;
    }
  };

  while (i < lines.length) {
    const line = lines[i];

    // Code fence
    if (/^```/.test(line)) {
      if (inCode) {
        out.push(`<pre><code>${escapeHtml(codeBuf.join("\n"))}</code></pre>`);
        codeBuf = [];
        inCode = false;
      } else {
        flushPara(); flushList();
        inCode = true;
      }
      i++; continue;
    }
    if (inCode) { codeBuf.push(line); i++; continue; }

    // HTML block passthrough
    const htmlOpen = new RegExp(`^\\s*<(${PASSTHROUGH_TAGS.join("|")})\\b`, "i").exec(line);
    if (htmlOpen) {
      flushPara(); flushList();
      const tag = htmlOpen[1].toLowerCase();
      const closeRe = new RegExp(`</\\s*${tag}\\s*>`, "i");
      // Single-line self-contained block
      if (closeRe.test(line)) {
        out.push(line);
        i++; continue;
      }
      // Multi-line: consume until matching close
      const buf = [line];
      i++;
      let depth = 1;
      const openRe = new RegExp(`<\\s*${tag}\\b`, "gi");
      while (i < lines.length && depth > 0) {
        buf.push(lines[i]);
        const ln = lines[i];
        const opens = (ln.match(openRe) || []).length;
        const closes = (ln.match(new RegExp(`</\\s*${tag}\\s*>`, "gi")) || []).length;
        depth += opens - closes;
        i++;
        if (depth <= 0) break;
      }
      out.push(buf.join("\n"));
      continue;
    }

    // Blank line
    if (!line.trim()) {
      flushPara(); flushList();
      i++; continue;
    }

    // Heading
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      flushPara(); flushList();
      const lvl = h[1].length;
      out.push(`<h${lvl}>${inlineMd(h[2])}</h${lvl}>`);
      i++; continue;
    }

    // Horizontal rule
    if (/^[-*_]{3,}\s*$/.test(line)) {
      flushPara(); flushList();
      out.push("<hr/>");
      i++; continue;
    }

    // Markdown blockquote (single-line style: "> text")
    const bq = /^>\s?(.*)$/.exec(line);
    if (bq) {
      flushPara(); flushList();
      const buf = [bq[1]];
      i++;
      while (i < lines.length) {
        const nxt = /^>\s?(.*)$/.exec(lines[i]);
        if (!nxt) break;
        buf.push(nxt[1]);
        i++;
      }
      // Render inner as markdown paragraphs (light) inside the blockquote
      const inner = buf
        .map(seg => seg.trim() ? `<p>${inlineMd(seg)}</p>` : "")
        .filter(Boolean)
        .join("");
      out.push(`<blockquote>${inner}</blockquote>`);
      continue;
    }

    // Unordered list
    const ul = /^[-*]\s+(.*)$/.exec(line);
    if (ul) {
      flushPara();
      if (listType !== "ul") { flushList(); out.push("<ul>"); listType = "ul"; }
      out.push("<li>" + inlineMd(ul[1]) + "</li>");
      i++; continue;
    }

    // Ordered list
    const ol = /^\d+\.\s+(.*)$/.exec(line);
    if (ol) {
      flushPara();
      if (listType !== "ol") { flushList(); out.push("<ol>"); listType = "ol"; }
      out.push("<li>" + inlineMd(ol[1]) + "</li>");
      i++; continue;
    }

    // Paragraph
    flushList();
    paraBuf.push(line);
    i++;
  }
  flushPara(); flushList();
  if (inCode) out.push(`<pre><code>${escapeHtml(codeBuf.join("\n"))}</code></pre>`);
  return out.join("\n");
}

// ─── Strip markdown to a short preview for sidebar ────────────
function previewText(content, n = 90) {
  if (!content) return "";
  const stripped = String(content)
    .replace(/<[^>]+>/g, " ")
    .replace(/[#>*_`\[\]\(\)\\]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return stripped.length > n ? stripped.slice(0, n - 1).trimEnd() + "…" : stripped;
}

// ─── Build tree from flat rows ────────────────────────────────
function buildTree(rows) {
  const byId = new Map();
  for (const r of (rows || [])) {
    byId.set(r.confluence_page_id, { ...r, children: [] });
  }
  const roots = [];
  for (const node of byId.values()) {
    const parent = node.parent_page_id ? byId.get(node.parent_page_id) : null;
    if (parent) parent.children.push(node);
    else roots.push(node);
  }
  // Natural-ish sort: numeric prefixes first (01, 02…), then alpha
  const cmp = (a, b) => {
    const at = (a?.title || "");
    const bt = (b?.title || "");
    const an = /^(\d+)/.exec(at);
    const bn = /^(\d+)/.exec(bt);
    if (an && bn) return parseInt(an[1], 10) - parseInt(bn[1], 10);
    if (an && !bn) return -1;
    if (!an && bn) return 1;
    return at.localeCompare(bt);
  };
  const sortRec = (node) => {
    if (Array.isArray(node?.children)) {
      node.children.sort(cmp);
      node.children.forEach(sortRec);
    }
  };
  roots.sort(cmp);
  roots.forEach(sortRec);
  return roots;
}

// ─── Flatten tree for keyboard / next-prev nav (V2) ───────────
function flattenTree(roots) {
  const out = [];
  const walk = (n, d) => {
    out.push({ node: n, depth: d });
    (n?.children || []).forEach(c => walk(c, d + 1));
  };
  (roots || []).forEach(r => walk(r, 0));
  return out;
}

// ─── Ask Claude button (mirrors CorePrinciples) ───────────────
const AskBtn = ({ context, label = "Ask Claude about this" }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context); window.open("https://claude.ai", "_blank"); }}
    style={{
      display: "inline-flex", alignItems: "center", gap: 6,
      background: T.blue, color: T.white,
      border: "none", borderRadius: 7,
      padding: "8px 14px",
      fontSize: 12, fontWeight: 600, cursor: "pointer",
      transition: "background 0.15s",
    }}
    onMouseOver={(e) => { e.currentTarget.style.background = T.slate900; }}
    onMouseOut={(e) => { e.currentTarget.style.background = T.blue; }}
    title="Copy this page to clipboard and open Claude.ai"
  >
    💬 {label}
  </button>
);

// ─── Module ───────────────────────────────────────────────────
export default function Handbook() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [search, setSearch] = useState("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setLoading(true);
        if (!supabase) {
          if (!cancelled) { setError("Supabase client not initialized."); setRows([]); }
          return;
        }
        const { data, error: qErr } = await supabase
          .from("handbook")
          .select("id, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, fetched_at, updated_at, notes")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true);
        if (cancelled) return;
        if (qErr) { setError(qErr.message); setRows([]); }
        else {
          const list = Array.isArray(data) ? data : [];
          setRows(list);
          // Default selection: root (no parent), or first row if no root
          if (list.length && !selectedId) {
            const root = list.find(r => !r.parent_page_id);
            setSelectedId(root?.confluence_page_id || list[0]?.confluence_page_id);
          }
        }
      } catch (e) {
        if (!cancelled) { setError(e?.message || "Failed to load handbook."); setRows([]); }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const tree = useMemo(() => buildTree(rows), [rows]);
  const flat = useMemo(() => flattenTree(tree), [tree]);

  // Search filter — match on title or content (case-insensitive)
  const visibleIds = useMemo(() => {
    const q = (search || "").trim().toLowerCase();
    if (!q) return null; // null = show all
    const set = new Set();
    for (const r of (rows || [])) {
      const hay = ((r?.title || "") + " " + (r?.content || "")).toLowerCase();
      if (hay.includes(q)) set.add(r.confluence_page_id);
    }
    // Also include ancestors of matches so the tree path stays visible
    const byId = new Map((rows || []).map(r => [r.confluence_page_id, r]));
    const withAncestors = new Set(set);
    for (const id of set) {
      let cur = byId.get(id);
      while (cur && cur.parent_page_id) {
        withAncestors.add(cur.parent_page_id);
        cur = byId.get(cur.parent_page_id);
      }
    }
    return withAncestors;
  }, [search, rows]);

  const selected = useMemo(
    () => (rows || []).find(r => r.confluence_page_id === selectedId) || null,
    [rows, selectedId]
  );

  // ─── Loading / Error / Empty ──────────────────────────────
  if (loading) {
    return (
      <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
        Loading handbook…
      </div>
    );
  }
  if (error) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.redLt, color: T.red, padding: 16, borderRadius: 10, fontSize: 13, border: `1px solid ${T.red}33` }}>
          <strong>Could not load the handbook.</strong><br />
          {error}
        </div>
      </div>
    );
  }
  if (!rows.length) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.slate50, padding: 24, borderRadius: 12, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>No handbook pages yet</div>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            The handbook table is empty. The Confluence ingestion pipeline writes here — ask Claude to run a fresh pull.
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={{ display: "flex", height: "100%", background: T.slate50 }}>
      {/* ─── Sidebar ──────────────────────────────────────── */}
      <div style={{
        width: 320, flexShrink: 0,
        borderRight: `1px solid ${T.slate200}`,
        background: T.white,
        display: "flex", flexDirection: "column",
      }}>
        <div style={{ padding: "20px 20px 14px 20px", borderBottom: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 4 }}>
            Team Reference
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            Handbook
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
            Mirrored from Confluence. Read-only here — edits happen in Confluence.
          </div>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search handbook…"
            style={{
              width: "100%", marginTop: 12,
              padding: "8px 12px",
              border: `1px solid ${T.slate200}`,
              borderRadius: 8,
              fontSize: 13, color: T.slate900,
              outline: "none",
              background: T.slate50,
            }}
            onFocus={(e) => { e.currentTarget.style.borderColor = T.blue; }}
            onBlur={(e) => { e.currentTarget.style.borderColor = T.slate200; }}
          />
        </div>

        {/* Tree */}
        <div style={{ flex: 1, overflowY: "auto", padding: "8px 0" }}>
          {flat.map(({ node, depth }) => {
            const isActive = node.confluence_page_id === selectedId;
            const hidden = visibleIds && !visibleIds.has(node.confluence_page_id);
            if (hidden) return null;
            const icon = iconForTitle(node.title);
            return (
              <button
                key={node.confluence_page_id}
                onClick={() => setSelectedId(node.confluence_page_id)}
                style={{
                  width: "100%",
                  textAlign: "left",
                  background: isActive ? T.blueLt : "transparent",
                  border: "none",
                  borderLeft: isActive ? `3px solid ${T.blue}` : "3px solid transparent",
                  padding: `10px 16px 10px ${16 + depth * 16}px`,
                  cursor: "pointer",
                  display: "flex",
                  gap: 10,
                  alignItems: "flex-start",
                  transition: "background 0.12s",
                }}
                onMouseOver={(e) => { if (!isActive) e.currentTarget.style.background = T.slate50; }}
                onMouseOut={(e) => { if (!isActive) e.currentTarget.style.background = "transparent"; }}
              >
                <div style={{ fontSize: 16, lineHeight: 1.2, marginTop: 1 }}>{icon}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{
                    fontSize: 13, fontWeight: depth === 0 ? 700 : 600,
                    color: isActive ? T.slate900 : T.slate900,
                    letterSpacing: "-0.01em",
                    lineHeight: 1.3,
                  }}>
                    {node.title || "Untitled"}
                  </div>
                  {depth === 0 && (
                    <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.4, marginTop: 2 }}>
                      {previewText(node.content, 70) || "—"}
                    </div>
                  )}
                </div>
              </button>
            );
          })}
        </div>

        {/* Footer */}
        <div style={{ padding: "12px 18px", borderTop: `1px solid ${T.slate200}`, background: T.slate50 }}>
          <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.5 }}>
            <strong style={{ color: T.slate700 }}>{rows.length} pages.</strong> Source of truth: Confluence.
          </div>
        </div>
      </div>

      {/* ─── Main pane ─────────────────────────────────────── */}
      <div style={{ flex: 1, overflowY: "auto" }}>
        {selected ? <HandbookPage page={selected} /> : (
          <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
            Select a page from the sidebar.
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Page detail view ─────────────────────────────────────────
function HandbookPage({ page }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "20px 16px 48px" : _vp.isTablet ? "26px 24px 60px" : "32px 40px 80px 40px";

  const html = useMemo(() => mdToHtml(page?.content || ""), [page?.content]);
  const askContext = useMemo(() => {
    return `I'm looking at this page from our team handbook:

TITLE: ${page?.title}
SOURCE: ${page?.source_url || "(no source url)"}
VERSION: ${page?.version ?? "—"}

CONTENT:
${page?.content || ""}

What I'd like to discuss:
`;
  }, [page]);

  const updated = page?.fetched_at ? new Date(page.fetched_at) : null;
  const updatedStr = updated && !isNaN(updated)
    ? updated.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" })
    : null;

  const icon = iconForTitle(page?.title);

  return (
    <div style={{ maxWidth: 880, margin: "0 auto", padding: _pad }}>
      {/* Inline style block for HTML-rendered handbook content.
          Scoped via a wrapper class so it can't bleed into other modules. */}
      <style>{`
        .bcc-handbook-body { font-size: 14px; line-height: 1.75; color: ${T.slate700}; }
        .bcc-handbook-body h1 { font-size: 24px; font-weight: 800; color: ${T.slate900}; margin: 28px 0 12px 0; letter-spacing: -0.02em; }
        .bcc-handbook-body h2 { font-size: 19px; font-weight: 700; color: ${T.slate900}; margin: 26px 0 10px 0; letter-spacing: -0.015em; border-left: 3px solid ${T.blue}; padding-left: 10px; }
        .bcc-handbook-body h3 { font-size: 16px; font-weight: 700; color: ${T.slate900}; margin: 22px 0 8px 0; }
        .bcc-handbook-body h4 { font-size: 14px; font-weight: 700; color: ${T.slate800}; margin: 18px 0 6px 0; }
        .bcc-handbook-body p { margin: 0 0 14px 0; }
        .bcc-handbook-body ul, .bcc-handbook-body ol { margin: 8px 0 16px 0; padding-left: 24px; }
        .bcc-handbook-body li { margin-bottom: 6px; }
        .bcc-handbook-body strong { font-weight: 700; color: ${T.slate900}; }
        .bcc-handbook-body em { font-style: italic; }
        .bcc-handbook-body code { background: ${T.slate100}; padding: 1px 6px; border-radius: 4px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; color: ${T.slate800}; }
        .bcc-handbook-body pre { background: ${T.slate100}; padding: 14px 16px; border-radius: 8px; overflow-x: auto; margin: 14px 0; }
        .bcc-handbook-body pre code { background: transparent; padding: 0; }
        .bcc-handbook-body a { color: ${T.blue}; text-decoration: underline; text-decoration-color: ${T.blue}66; }
        .bcc-handbook-body a:hover { text-decoration-color: ${T.blue}; }
        .bcc-handbook-body hr { border: 0; border-top: 1px solid ${T.slate200}; margin: 24px 0; }
        .bcc-handbook-body blockquote {
          background: ${T.blueLt};
          border-left: 4px solid ${T.blue};
          padding: 12px 16px;
          margin: 14px 0;
          border-radius: 6px;
          color: ${T.slate700};
        }
        .bcc-handbook-body blockquote p { margin: 0 0 6px 0; }
        .bcc-handbook-body blockquote p:last-child { margin-bottom: 0; }
        .bcc-handbook-body table {
          border-collapse: collapse;
          margin: 16px 0;
          width: 100%;
          font-size: 13px;
        }
        .bcc-handbook-body th, .bcc-handbook-body td {
          border: 1px solid ${T.slate200};
          padding: 8px 12px;
          text-align: left;
          vertical-align: top;
        }
        .bcc-handbook-body th { background: ${T.slate50}; font-weight: 700; color: ${T.slate900}; }
        .bcc-handbook-body details {
          background: ${T.slate50};
          border: 1px solid ${T.slate200};
          border-radius: 8px;
          padding: 10px 14px;
          margin: 12px 0;
        }
        .bcc-handbook-body details[open] { background: ${T.white}; }
        .bcc-handbook-body summary {
          cursor: pointer;
          font-weight: 600;
          color: ${T.slate900};
          padding: 2px 0;
          user-select: none;
        }
        .bcc-handbook-body details > *:not(summary) { margin-top: 10px; }
        .bcc-handbook-body img { max-width: 100%; height: auto; border-radius: 6px; }
      `}</style>

      {/* Title block */}
      <div style={{ display: "flex", gap: 16, alignItems: "flex-start", marginBottom: 20 }}>
        <div style={{ fontSize: 40, lineHeight: 1 }}>{icon}</div>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6, flexWrap: "wrap" }}>
            <div style={{
              fontSize: 10, fontWeight: 800, color: T.blue,
              textTransform: "uppercase", letterSpacing: "0.1em",
              background: T.blueLt, padding: "3px 10px", borderRadius: 999,
            }}>
              Handbook
            </div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500 }}>
              v{page?.version ?? "—"}
            </div>
            {updatedStr && (
              <div style={{ fontSize: 11, color: T.slate400 }}>
                • Mirrored {updatedStr}
              </div>
            )}
            {page?.notes && (
              <div style={{ fontSize: 11, color: T.amber, fontStyle: "italic" }}>
                • {page.notes}
              </div>
            )}
          </div>
          <h1 style={{ fontSize: 28, fontWeight: 800, color: T.slate900, margin: 0, letterSpacing: "-0.025em", lineHeight: 1.25 }}>
            {page?.title || "Untitled page"}
          </h1>
        </div>
      </div>

      {/* Accent bar */}
      <div style={{ height: 4, background: T.blue, borderRadius: 2, marginBottom: 24, opacity: 0.85 }} />

      {/* Action row */}
      <div style={{ display: "flex", gap: 10, marginBottom: 22, flexWrap: "wrap" }}>
        {page?.source_url && (
          <a
            href={page.source_url}
            target="_blank"
            rel="noreferrer noopener"
            style={{
              display: "inline-flex", alignItems: "center", gap: 6,
              background: T.white, color: T.slate700,
              border: `1px solid ${T.slate200}`, borderRadius: 7,
              padding: "8px 14px",
              fontSize: 12, fontWeight: 600,
              textDecoration: "none",
              transition: "all 0.15s",
            }}
            onMouseOver={(e) => { e.currentTarget.style.borderColor = T.blue; e.currentTarget.style.color = T.blue; }}
            onMouseOut={(e) => { e.currentTarget.style.borderColor = T.slate200; e.currentTarget.style.color = T.slate700; }}
            title="Open this page in Confluence (source of truth)"
          >
            ↗ Edit in Confluence
          </a>
        )}
        <AskBtn context={askContext} />
      </div>

      {/* Content */}
      <div style={{
        background: T.white,
        padding: "28px 32px",
        borderRadius: 14,
        border: `1px solid ${T.slate200}`,
        boxShadow: "0 1px 3px rgba(15, 23, 42, 0.04)",
      }}>
        {(page?.content || "").trim() ? (
          <div className="bcc-handbook-body" dangerouslySetInnerHTML={{ __html: html }} />
        ) : (
          <div style={{ color: T.slate500, fontStyle: "italic", fontSize: 13 }}>
            This page has no text content. {page?.notes ? `(${page.notes})` : "It may be an attachment-only page in Confluence."}
            {page?.source_url && (
              <> View it directly at <a href={page.source_url} target="_blank" rel="noreferrer noopener" style={{ color: T.blue }}>Confluence</a>.</>
            )}
          </div>
        )}
      </div>

      {/* Footer note */}
      <div style={{ marginTop: 22, fontSize: 11, color: T.slate400, lineHeight: 1.6 }}>
        Source of truth: Confluence (page id {page?.confluence_page_id || "—"}). Changes made here would not persist — edit the page in Confluence and the next mirror sync will refresh it.
      </div>
    </div>
  );
}
