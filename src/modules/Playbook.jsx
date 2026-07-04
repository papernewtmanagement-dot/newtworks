import { useState, useEffect, useMemo, useCallback } from "react";
import { useViewport } from "../lib/hooks.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// ============================================================
// BCC PLAYBOOK MODULE v1.0
// Business Command Center — State Farm Agent Edition
//
// PURPOSE:
// Read-only viewer for the operational playbook. Source of
// truth lives in Confluence (pjsagency.atlassian.net); BCC
// mirrors it into public.playbook for offline reference and
// quick in-app lookup.
//
// Trees: Checklists (processes), Product Knowledge, Training
// (all grouped under tree_root in the playbook table).
//
// DATA SHAPE (public.playbook):
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

  // ── Icons for moved-in ex-Techbook pages (still live in Playbook) ────
  if (/fax\b/.test(t))                                            return "📠";
  if (/spam|voicemail|attendant/.test(t))                         return "📞";
  if (/team by the minute/.test(t))                               return "⏱️";
  if (/office - systems|desk checklist/.test(t))                  return "🖥️";
  if (/policyholder list/.test(t))                                return "📋";
  if (/^dss/.test(t))                                             return "✍️";

  // ── Playbook: role/setup pages ──────────────────────────────────────
  if (/new (account manager|reception) setup/.test(t))            return "🧑\u200d💼";
  if (/^0[1-9] reception/.test(t) || /welcome.*reception/.test(t))return "🛎️";
  if (/^0[1-9] admin setup|^0[1-9] tech setup/.test(t))           return "🖥️";
  if (/daily checklist|daily rhythm|team huddle/.test(t))         return "✅";

  // ── Playbook: FIT / sales conversations ─────────────────────────────
  if (/simple .+ fit|fit opener|fit closer|fit conversations?/.test(t)) return "🎯";
  if (/objection|overcomer/.test(t))                              return "🤔";
  if (/referral/.test(t))                                         return "🤝";
  if (/prospect|lead process|lead file|get new leads/.test(t))    return "🎣";
  if (/appointment/.test(t))                                      return "📅";
  if (/icebreaker|frogs?\b/.test(t))                              return "🎤";

  // ── Playbook: LOB knowledge / tasks ─────────────────────────────────
  if (/auto (knowledge|tasks?)|farm auto|commercial auto|single line auto|auto no home/.test(t)) return "🚗";
  if (/home ?owner|fire (knowledge|tasks?)|dwelling|rental condominium|apartment specifications/.test(t)) return "🏠";
  if (/life (knowledge|tasks?|review|beneficiary|funding|proximity)|funeral|lna|birthday life|first.last chance life|cop term|no life\b|extended life/.test(t)) return "🕯️";
  if (/health (knowledge|tasks?)|medicare|medsupp|ltc\b/.test(t)) return "🩺";
  if (/investing|401k|529|jackson|ips|annuity|retirement|brokerage/.test(t)) return "📈";
  if (/mortgage|quicken|loan protection|refi/.test(t))            return "🏦";
  if (/^boat|boatowner/.test(t))                                  return "⛵";
  if (/business|commercial\b/.test(t))                            return "🏢";
  if (/liability|plup|clup|umbi|umpd|professional liability/.test(t)) return "🛡️";
  if (/valuables|jewelry/.test(t))                                return "💎";
  if (/disability|^di\b|di (bridge|fit)/.test(t))                 return "♿";
  if (/^hi\b|hi (bridge|fit)|income protection/.test(t))          return "🏥";
  if (/flood/.test(t))                                            return "🌊";
  if (/earthquake/.test(t))                                       return "🌎";
  if (/identity theft/.test(t))                                   return "🕵️";
  if (/roof/.test(t))                                             return "🏚️";
  if (/water damage/.test(t))                                     return "💧";

  // ── Playbook: service, ops, messaging ───────────────────────────────
  if (/claim/.test(t))                                            return "📋";
  if (/dss|beacon|odometer/.test(t))                              return "📡";
  if (/bridge the gap/.test(t))                                   return "🌉";
  if (/cancel|late pay|payment/.test(t))                          return "⛔";
  if (/salt (messages?)?/.test(t))                                return "🧂";
  if (/(script|template|message|opener|closer|salt|sympathy|thank you|congratulation|welcome)/.test(t)) return "💬";
  if (/task/.test(t))                                             return "✅";

  // ── Playbook: apartments / properties (fallback for named complexes) ─
  if (/\bthe\s*$|^\bthe\b|apartments?|landmark|oaks?|creek|ridge|encore|marquis|toscana|vantage|vineyard|viridian|abbey|anthony|boulevard|crest|grandview|hawthorne|montecristo|retreat|savannah|sendera|tribute|ventura|west oaks|bramblemaw/.test(t)) return "🏘️";

  // ── Handbook-style fallbacks (rare in playbook, but harmless) ───────
  if (/^handbook\b/.test(t))                                      return "📘";
  if (/benefits/.test(t))                                         return "💼";
  if (/vehicle/.test(t))                                          return "🚗";
  if (/training|course|coaching/.test(t))                         return "🎓";

  return "📄";
}

// ─── Markdown → HTML + preview helpers ────────────────────────
// Shared implementation lives in src/lib/markdown.js so all three
// books render identically, and support Confluence-style
// [Included from: X] transclusion via the resolveInclude option.
import {
  mdToHtml,
  previewText,
  buildIncludeLookup,
  makeIncludeResolver,
} from "../lib/markdown.js";

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
export default function Playbook() {
  // Playbook renders everything in the playbook table (tree_root in
  // {Checklists, Product Knowledge}). Tech Book was dismantled 2026-07-04.
  const basePath          = "/playbook";
  const moduleTitle       = "Playbook";
  const moduleSubtitle    = "Operational reference — processes, product knowledge, training. Mirrored from Confluence.";
  const searchPlaceholder = "Search playbook…";
  const emptyLabel        = "playbook";
  const urlRe             = /^\/playbook\/([^/]+)\/?$/;
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  // ── URL ↔ selectedId sync ─────────────────────────────────────────
  // Page id is carried in the URL as /playbook/<confluence_page_id>.
  // Refresh keeps you on the same page; back/forward navigates between visits.
  const _initialSelectedId = (typeof window !== "undefined")
    ? (urlRe.exec(window.location.pathname || "")?.[1] || null)
    : null;
  const [selectedId, setSelectedId] = useState(_initialSelectedId);
  const selectPage = useCallback((id, replace = false) => {
    setSelectedId(id);
    if (typeof window === "undefined" || !id) return;
    const desired = `${basePath}/${encodeURIComponent(id)}`;
    if (window.location.pathname === desired) return;
    if (replace) window.history.replaceState({}, "", desired);
    else window.history.pushState({}, "", desired);
  }, []);
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const onPop = () => {
      const m = urlRe.exec(window.location.pathname || "");
      setSelectedId(m ? decodeURIComponent(m[1]) : null);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const _vp = useViewport();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [search, setSearch] = useState("");
  // Collapse state — Set of confluence_page_ids whose children are shown.
  // Top-level pages are always visible; children hidden unless parent is here.
  const [expandedIds, setExpandedIds] = useState(() => new Set());
  const toggleExpand = useCallback((id) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setLoading(true);
        if (!supabase) {
          if (!cancelled) { setError("Supabase client not initialized."); setRows([]); }
          return;
        }
        let q = supabase
          .from("playbook")
          .select("id, title, content, content_format, source_url, confluence_page_id, parent_page_id, tree_root, version, is_active, fetched_at, updated_at, notes")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true);
        const { data, error: qErr } = await q;
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
        if (!cancelled) { setError(e?.message || `Failed to load ${emptyLabel}.`); setRows([]); }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Auto-default selection: once rows are loaded and selectedId is still
  // null (i.e. URL was bare /playbook), pick the root page and
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

  // When a page is selected (URL deep-link, search jump, initial default),
  // auto-expand its ancestor chain so the selection is visible in the tree.
  useEffect(() => {
    if (!selectedId || !rows.length) return;
    const byId = new Map(rows.map(r => [r.confluence_page_id, r]));
    const ancestors = [];
    let cur = byId.get(selectedId);
    while (cur && cur.parent_page_id) {
      ancestors.push(cur.parent_page_id);
      cur = byId.get(cur.parent_page_id);
    }
    if (!ancestors.length) return;
    setExpandedIds((prev) => {
      let changed = false;
      const next = new Set(prev);
      for (const id of ancestors) {
        if (!next.has(id)) { next.add(id); changed = true; }
      }
      return changed ? next : prev;
    });
  }, [selectedId, rows]);

  // Nodes visible right now: depth-0 always; deeper only if every ancestor
  // is in expandedIds. Pre-computed via a DFS that skips branches whose
  // parent isn't expanded. Flag hasChildren so the row renders a chevron.
  const visibleFlat = useMemo(() => {
    const out = [];
    const walk = (n, d) => {
      const kids = Array.isArray(n?.children) ? n.children : [];
      out.push({ node: n, depth: d, hasChildren: kids.length > 0 });
      if (expandedIds.has(n?.confluence_page_id)) {
        for (const c of kids) walk(c, d + 1);
      }
    };
    for (const r of (tree || [])) walk(r, 0);
    return out;
  }, [tree, expandedIds]);

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
        Loading {moduleTitle.toLowerCase()}…
      </div>
    );
  }
  if (error) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.redLt, color: T.red, padding: 16, borderRadius: 10, fontSize: 13, border: `1px solid ${T.red}33` }}>
          <strong>Could not load the {emptyLabel}.</strong><br />
          {error}
        </div>
      </div>
    );
  }
  if (!rows.length) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.slate50, padding: 24, borderRadius: 12, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>No {emptyLabel} pages yet</div>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            The {emptyLabel} tree is empty. The Confluence ingestion pipeline writes here.
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
            Team Operations
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            {moduleTitle}
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
            {moduleSubtitle}
          </div>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={searchPlaceholder}
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
          {(visibleIds ? flat : visibleFlat).map((entry) => {
            const node = entry.node;
            const depth = entry.depth;
            const isActive = node.confluence_page_id === selectedId;
            const hidden = visibleIds && !visibleIds.has(node.confluence_page_id);
            if (hidden) return null;
            const hasChildren = "hasChildren" in entry
              ? entry.hasChildren
              : (Array.isArray(node.children) && node.children.length > 0);
            const isExpanded = expandedIds.has(node.confluence_page_id);
            const icon = iconForTitle(node.title);
            return (
              <div
                key={node.confluence_page_id}
                style={{
                  display: "flex",
                  alignItems: "stretch",
                  background: isActive ? T.blueLt : "transparent",
                  borderLeft: isActive ? `3px solid ${T.blue}` : "3px solid transparent",
                  transition: "background 0.12s",
                }}
                onMouseOver={(e) => { if (!isActive) e.currentTarget.style.background = T.slate50; }}
                onMouseOut={(e) => { if (!isActive) e.currentTarget.style.background = "transparent"; }}
              >
                <button
                  type="button"
                  onClick={(ev) => { ev.stopPropagation(); if (hasChildren) toggleExpand(node.confluence_page_id); }}
                  aria-label={hasChildren ? (isExpanded ? "Collapse" : "Expand") : ""}
                  tabIndex={hasChildren ? 0 : -1}
                  onMouseOver={(e) => {
                    if (hasChildren) {
                      e.currentTarget.style.background = T.blueLt;
                      e.currentTarget.style.color = T.blue;
                      e.currentTarget.style.borderColor = T.blue;
                    }
                  }}
                  onMouseOut={(e) => {
                    if (hasChildren) {
                      e.currentTarget.style.background = T.slate100;
                      e.currentTarget.style.color = T.slate700;
                      e.currentTarget.style.borderColor = T.slate300;
                    }
                  }}
                  style={{
                    width: 24,
                    minWidth: 24,
                    height: 24,
                    alignSelf: "center",
                    marginLeft: 6 + depth * 16,
                    marginRight: 4,
                    padding: 0,
                    background: hasChildren ? T.slate100 : "transparent",
                    border: hasChildren ? `1px solid ${T.slate300}` : "1px solid transparent",
                    borderRadius: 6,
                    cursor: hasChildren ? "pointer" : "default",
                    color: hasChildren ? T.slate700 : "transparent",
                    fontSize: 13,
                    fontWeight: 700,
                    lineHeight: 1,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    userSelect: "none",
                    transition: "background 0.12s, color 0.12s, border-color 0.12s",
                  }}
                >
                  {hasChildren ? (isExpanded ? "▾" : "▸") : ""}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    selectPage(node.confluence_page_id);
                    if (hasChildren && !isExpanded) toggleExpand(node.confluence_page_id);
                    if (_vp.isPhone) setDrawerOpen(false);
                  }}
                  style={{
                    flex: 1,
                    minWidth: 0,
                    textAlign: "left",
                    background: "transparent",
                    border: "none",
                    padding: "10px 16px 10px 4px",
                    cursor: "pointer",
                    display: "flex",
                    gap: 10,
                    alignItems: "flex-start",
                  }}
                >
                  <div style={{ fontSize: 16, lineHeight: 1.2, marginTop: 1 }}>{icon}</div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{
                      fontSize: 13, fontWeight: depth === 0 ? 700 : 600,
                      color: T.slate900,
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
              </div>
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
        {selected ? <PlaybookPage page={selected} allRows={rows} /> : (
          <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
            {_vp.isPhone ? 'Tap "Sections" to choose a page.' : 'Select a page from the sidebar.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Page detail view ─────────────────────────────────────────
function PlaybookPage({ page, allRows }) {
  const resolveInclude = useMemo(
    () => makeIncludeResolver(buildIncludeLookup(allRows || [])),
    [allRows]
  );
  const html = useMemo(
    () => mdToHtml(page?.content || "", { resolveInclude }),
    [page?.content, resolveInclude]
  );
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
          padding: 2px 0 2px 22px;
          user-select: none;
          list-style: none;
          position: relative;
        }
        .bcc-handbook-body summary::-webkit-details-marker { display: none; }
        .bcc-handbook-body summary::before {
          content: "▸";
          position: absolute;
          left: 0;
          top: 2px;
          color: ${T.blue};
          font-size: 14px;
          font-weight: 700;
          display: inline-block;
        }
        .bcc-handbook-body details[open] > summary::before { content: "▾"; }
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
