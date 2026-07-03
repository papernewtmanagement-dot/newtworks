import { useState, useEffect, useMemo, useCallback } from "react";
import { useViewport } from "../lib/hooks.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// ============================================================
// BCC ADMIN MODULE v1.1
// Business Command Center — State Farm Agent Edition
//
// PURPOSE:
// Viewer for back-office and owner-only pages. BCC is the
// source of truth; content lives in public.admin_pages.
// The original Confluence tree was ingested here and Confluence
// is deprecated for writes.
//
// GATED: this module is visible only to users with role='owner'
// via the nav array in BCCApp.jsx. The select itself is
// scoped by agency_id (RLS-friendly) but the route is the
// effective access control.
//
// DATA SHAPE (public.admin_pages):
//   - one row per page
//   - tree via parent_page_id (NULL = root)
//   - content stored as Markdown with embedded HTML for
//     <details>/<summary> expand sections, <blockquote>
//     callouts, and tables that contain expands
//   - confluence_page_id is retained as the stable page key /
//     routing slug (works for both legacy Confluence-sourced
//     rows and BCC-native rows; native rows use a
//     "bcc-native-*" slug)
//   - versioned: is_active=true for the current version,
//     prior versions kept with archived_at set
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

    // Markdown pipe table (GFM-style)
    //   | h1 | h2 |
    //   | --- | --- |
    //   | c1 | c2 |
    // Detected by current line being a pipe row AND next line being a separator.
    const _isPipeRow = (s) => /^\s*\|.*\|\s*$/.test(s);
    const _isPipeSep = (s) => /^\s*\|[\s\-:|]+\|\s*$/.test(s);
    if (_isPipeRow(line) && i + 1 < lines.length && _isPipeSep(lines[i + 1])) {
      flushPara(); flushList();

      const splitRow = (s) => {
        const inner = s.trim().replace(/^\|/, "").replace(/\|$/, "");
        const parts = [];
        let buf = "";
        for (let k = 0; k < inner.length; k++) {
          if (inner[k] === "\\" && inner[k + 1] === "|") { buf += "|"; k++; continue; }
          if (inner[k] === "|") { parts.push(buf.trim()); buf = ""; continue; }
          buf += inner[k];
        }
        parts.push(buf.trim());
        return parts;
      };

      const sepCells = splitRow(lines[i + 1]);
      const align = sepCells.map(c => {
        const L = c.startsWith(":");
        const R = c.endsWith(":");
        if (L && R) return "center";
        if (R) return "right";
        if (L) return "left";
        return null;
      });

      const headerCells = splitRow(line);
      i += 2;
      const bodyRows = [];
      while (i < lines.length && _isPipeRow(lines[i]) && !_isPipeSep(lines[i])) {
        bodyRows.push(splitRow(lines[i]));
        i++;
      }

      const cell = (tag, txt, idx) => {
        const a = align[idx];
        const styleAttr = a ? ` style="text-align:${a}"` : "";
        return `<${tag}${styleAttr}>${inlineMd(txt)}</${tag}>`;
      };

      let html = `<div style="overflow-x:auto;-webkit-overflow-scrolling:touch;"><table>`;
      html += "<thead><tr>";
      headerCells.forEach((c, idx) => { html += cell("th", c, idx); });
      html += "</tr></thead><tbody>";
      bodyRows.forEach(row => {
        html += "<tr>";
        for (let k = 0; k < headerCells.length; k++) {
          html += cell("td", row[k] ?? "", k);
        }
        html += "</tr>";
      });
      html += "</tbody></table></div>";
      out.push(html);
      continue;
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


// ─── Module ───────────────────────────────────────────────────
export default function Admin() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  // ── URL ↔ selectedId sync ─────────────────────────────────────────
  // Page id is carried in the URL as /admin/<confluence_page_id>.
  // Refresh keeps you on the same page; back/forward navigates between visits.
  const _initialSelectedId = (typeof window !== "undefined")
    ? (/^\/admin\/([^/]+)\/?$/.exec(window.location.pathname || "")?.[1] || null)
    : null;
  const [selectedId, setSelectedId] = useState(_initialSelectedId);
  const selectPage = useCallback((id, replace = false) => {
    setSelectedId(id);
    if (typeof window === "undefined" || !id) return;
    const desired = `/admin/${encodeURIComponent(id)}`;
    if (window.location.pathname === desired) return;
    if (replace) window.history.replaceState({}, "", desired);
    else window.history.pushState({}, "", desired);
  }, []);
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const onPop = () => {
      const m = /^\/admin\/([^/]+)\/?$/.exec(window.location.pathname || "");
      setSelectedId(m ? decodeURIComponent(m[1]) : null);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const _vp = useViewport();
  const [drawerOpen, setDrawerOpen] = useState(false);
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
          .from("admin_pages")
          .select("id, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, fetched_at, updated_at, notes")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true);
        if (cancelled) return;
        if (qErr) { setError(qErr.message); setRows([]); }
        else {
          const list = Array.isArray(data) ? data : [];
          setRows(list);
          // Default selection: root (no parent), or first row if no root
          // Default selection deferred to the auto-default useEffect below,
          // which fires once rows are loaded AND selectedId is still null.
          // This avoids stomping the URL-derived initial selectedId.
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

  // Auto-default selection: once rows are loaded and selectedId is still
  // null (i.e. URL was bare /admin), pick the root page and
  // replaceState so the address bar reflects what is being shown without
  // adding a spurious history entry.
  useEffect(() => {
    if (!rows.length || selectedId) return;
    const root = rows.find(r => !r.parent_page_id);
    const defaultId = root?.confluence_page_id || rows[0]?.confluence_page_id;
    if (defaultId) selectPage(defaultId, true);
  }, [rows, selectedId, selectPage]);

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
        Loading admin…
      </div>
    );
  }
  if (error) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.redLt, color: T.red, padding: 16, borderRadius: 10, fontSize: 13, border: `1px solid ${T.red}33` }}>
          <strong>Could not load admin pages.</strong><br />
          {error}
        </div>
      </div>
    );
  }
  if (!rows.length) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.slate50, padding: 24, borderRadius: 12, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>No admin pages yet</div>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            The admin_pages table is empty. Author rows directly via SQL (Confluence deprecated for writes).
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={{ display: "flex", height: "100%", background: T.slate50 }}>
      {/* Backdrop (phone drawer only) */}
      {_vp.isPhone && (
        <div
          style={{
            position: "fixed", top: 58, bottom: 0, left: 0, right: 0,
            background: "rgba(15, 23, 42, 0.45)",
            opacity: drawerOpen ? 1 : 0,
            pointerEvents: drawerOpen ? "auto" : "none",
            transition: "opacity 0.18s ease",
            zIndex: 140,
          }}
          onClick={() => setDrawerOpen(false)}
          aria-hidden={!drawerOpen}
        />
      )}

      {/* ─── Sidebar ──────────────────────────────────────── */}
      {/* Desktop/tablet: persistent 320px panel.                          */}
      {/* Phone: slide-over drawer mirroring the main-nav drawer pattern.  */}
      <div
        style={_vp.isPhone ? {
          position: "fixed", top: 58, bottom: 0, left: 0,
          width: 280, maxWidth: "85vw",
          background: T.white,
          borderRight: `1px solid ${T.slate200}`,
          display: "flex", flexDirection: "column",
          transform: drawerOpen ? "translateX(0)" : "translateX(-100%)",
          transition: "transform 0.22s ease",
          boxShadow: drawerOpen ? "4px 0 16px rgba(0,0,0,0.18)" : "none",
          overflow: "hidden",
          zIndex: 150,
        } : {
          width: 320, flexShrink: 0,
          borderRight: `1px solid ${T.slate200}`,
          background: T.white,
          display: "flex", flexDirection: "column",
        }}
        aria-hidden={_vp.isPhone && !drawerOpen}
      >
        <div style={{ padding: "20px 20px 14px 20px", borderBottom: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 4 }}>
            Owner Tools
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            Admin
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
            Back-office and internal notes. Owner-only access.
          </div>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search admin…"
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
                onClick={() => { selectPage(node.confluence_page_id); if (_vp.isPhone) setDrawerOpen(false); }}
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
      {/* Always rendered. On phone, a sticky top bar opens the section  */}
      {/* drawer so the user can pop to anywhere directly.               */}
      <div style={{ flex: 1, overflowY: "auto" }}>
        {_vp.isPhone && (
          <div style={{
            position: "sticky", top: 0, zIndex: 10,
            background: T.white,
            borderBottom: `1px solid ${T.slate200}`,
            padding: "8px 12px",
            display: "flex", alignItems: "center", gap: 10,
          }}>
            <button
              type="button"
              onClick={() => setDrawerOpen(true)}
              aria-label="Open sections"
              style={{
                display: "flex", alignItems: "center", gap: 6,
                background: T.white,
                border: `1px solid ${T.slate200}`,
                borderRadius: 8,
                padding: "7px 12px",
                fontSize: 13, fontWeight: 600,
                color: T.slate700, cursor: "pointer",
                flexShrink: 0,
              }}
            >
              <span style={{ fontSize: 16, lineHeight: 1 }} aria-hidden="true">☰</span>
              Sections
            </button>
            <div style={{
              fontSize: 12, fontWeight: 600, color: T.slate500,
              overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
            }}>
              {selected?.title || "Pick a section"}
            </div>
          </div>
        )}
        {selected ? <AdminPage page={selected} /> : (
          <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
            {_vp.isPhone ? 'Tap "Sections" to choose a page.' : 'Select a page from the sidebar.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Page detail view ─────────────────────────────────────────
function AdminPage({ page }) {
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
    <div style={{ maxWidth: 880, margin: "0 auto", padding: "32px 40px 80px 40px" }}>
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
