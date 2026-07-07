import { useState, useEffect, useMemo, useCallback, Fragment } from "react";
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
// Icons are stored on the row itself (public.handbook.icon column) so a title
// rename or a new section doesn't require a code change. Only rendered at
// depth 0 in the sidebar for consistency with Processes + Admin.
function iconForNode(n) {
  return String(n?.icon || "").trim();
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
  buildGlossaryLookup,
  makeGlossaryResolver,
} from "../lib/markdown.js";

// ─── Build tree from flat rows ────────────────────────────────
// Ordering: sort_order ASC (NULLS LAST), then title alpha. Display numbers
// are computed as siblings' rank within their parent (see annotateDisplayNumbers).
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
  const cmp = (a, b) => {
    const ao = a?.sort_order;
    const bo = b?.sort_order;
    const aNull = ao == null;
    const bNull = bo == null;
    if (aNull && !bNull) return 1;
    if (!aNull && bNull) return -1;
    if (!aNull && !bNull && ao !== bo) return ao - bo;
    return (a?.title || "").localeCompare(b?.title || "");
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

// Attach a two-digit rank prefix ("01", "02", …) to each node based on its
// position among siblings. Also builds a Map keyed by confluence_page_id so
// non-tree consumers (selected header, page detail) can look up the same number.
function annotateDisplayNumbers(roots) {
  const byPid = new Map();
  const walk = (nodes) => {
    (nodes || []).forEach((n, i) => {
      const num = String(i + 1).padStart(2, "0");
      n._displayNumber = num;
      byPid.set(n.confluence_page_id, n);
      if (Array.isArray(n.children) && n.children.length) walk(n.children);
    });
  };
  walk(roots);
  return byPid;
}

// Render a node's title with its computed display number prefix.
function withNumber(n) {
  if (!n) return "";
  const t = n.title || "Untitled";
  return n._displayNumber ? `${n._displayNumber}  ${t}` : t;
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


// ─── Dynamic (live) handbook pages ────────────────────────────
// Pages whose body is generated at render time from another table rather than
// from the stored handbook.content. Keyed by confluence_page_id.
const DYNAMIC_HANDBOOK_PAGES = {
  "345407825": "team_roster", // Team List — renders live from public.team
  "newtworks-native-handbook-glossary": "glossary_all", // Glossary — renders live from public.glossary_terms
};

// Live roster component for the Team List page.
// Pulls active, non-admin-backoffice, non-test team members and groups by function.
function TeamRoster() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: e } = await supabase
          .from("team")
          .select("first_name, last_name, nickname, role, role_category, primary_function, account_alpha, sf_alias, phone_extension, phone_personal, email_personal, work_location, four_day_off_day, license_states, license_pc, license_lh")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .eq("is_admin_backoffice", false)
          .eq("is_test_user", false)
          .is("archived_at", null)
          .order("last_name", { ascending: true });
        if (cancelled) return;
        if (e) { setError(e.message); setLoading(false); return; }
        setRows(data || []);
        setLoading(false);
      } catch (err) {
        if (!cancelled) { setError(err?.message || String(err)); setLoading(false); }
      }
    })();
    return () => { cancelled = true; };
  }, []);

  if (loading) {
    return <p style={{ color: T.slate500, fontStyle: "italic" }}>Loading team roster…</p>;
  }
  if (error) {
    return <p style={{ color: "#b91c1c" }}>Couldn't load team roster: {error}</p>;
  }
  if (!rows.length) {
    return <p style={{ color: T.slate500, fontStyle: "italic" }}>No active team members found.</p>;
  }

  // Group by role_category, with Ownership pulled out for primary_function=owner.
  const groupOf = (m) => {
    if (m.primary_function === "owner") return "Ownership";
    if (m.role_category === "Sales") return "Sales";
    if (m.role_category === "Retention") return "Retention";
    return "Other";
  };
  const groupOrder = ["Sales", "Retention", "Other", "Ownership"];
  const groups = {};
  for (const m of rows) {
    const g = groupOf(m);
    (groups[g] = groups[g] || []).push(m);
  }

  const displayName = (m) => {
    return `${m.first_name} ${m.last_name}`;
  };

  return (
    <div>
      {groupOrder.filter((g) => groups[g]?.length).map((g) => (
        <section key={g} style={{ marginBottom: 8 }}>
          <h2>{g}</h2>
          {groups[g].map((m) => (
            <div key={`${m.first_name}-${m.last_name}-${m.sf_alias || ""}`} style={{ marginBottom: 18 }}>
              <h4 style={{ margin: "0 0 2px 0" }}>{displayName(m)}</h4>
              <ul style={{ margin: "4px 0 0 0" }}>
                {m.sf_alias && <li>Alias: {String(m.sf_alias).toUpperCase()}</li>}
                {m.account_alpha && <li>Accounts: {m.account_alpha}</li>}
                {m.phone_extension && <li>Ext: {m.phone_extension}</li>}
                {m.phone_personal && <li>Cell: {m.phone_personal}</li>}
                {m.email_personal && (
                  <li>Email: <a href={`mailto:${m.email_personal}`}>{m.email_personal}</a></li>
                )}
              </ul>
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}


// Live glossary component for the Glossary page. Renders active terms from
// public.glossary_terms grouped alphabetically by first letter. Terms are
// authored in-DB (no admin UI yet); an empty table renders a friendly stub.
function GlossaryList() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: e } = await supabase
          .from("glossary_terms")
          .select("term, definition, sort_order")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .order("sort_order", { ascending: true, nullsFirst: false })
          .order("term", { ascending: true });
        if (cancelled) return;
        if (e) { setError(e.message); setLoading(false); return; }
        setRows(data || []);
        setLoading(false);
      } catch (err) {
        if (!cancelled) { setError(err?.message || String(err)); setLoading(false); }
      }
    })();
    return () => { cancelled = true; };
  }, []);

  if (loading) {
    return <p style={{ color: T.slate500, fontStyle: "italic" }}>Loading glossary…</p>;
  }
  if (error) {
    return <p style={{ color: "#b91c1c" }}>Couldn't load glossary: {error}</p>;
  }
  if (!rows.length) {
    return (
      <p style={{ color: T.slate500, fontStyle: "italic" }}>
        No glossary terms yet. Add rows to <code>public.glossary_terms</code> and they'll appear here.
      </p>
    );
  }

  // Group by first character of the term (uppercased) for A/B/C headers.
  const firstChar = (t) => {
    const s = String(t || "").trim();
    if (!s) return "";
    const ch = s.charAt(0).toUpperCase();
    return /[A-Z]/.test(ch) ? ch : "#";
  };
  const groups = new Map();
  for (const r of rows) {
    const g = firstChar(r.term);
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(r);
  }
  const groupKeys = Array.from(groups.keys()).sort((a, b) => {
    // "#" (non-letter) sorts last
    if (a === "#" && b !== "#") return 1;
    if (b === "#" && a !== "#") return -1;
    return a.localeCompare(b);
  });

  return (
    <div>
      {groupKeys.map((g) => (
        <section key={g} style={{ marginBottom: 8 }}>
          <h2>{g}</h2>
          {groups.get(g).map((r, i) => (
            <div key={`${r.term}-${i}`} style={{ marginBottom: 18 }}>
              <div style={{ fontWeight: 800, color: T.slate900, letterSpacing: "0.02em" }}>{r.term}</div>
              <div
                style={{ marginTop: 4 }}
                dangerouslySetInnerHTML={{ __html: mdToHtml(r.definition || "") }}
              />
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}


// ─── Module ───────────────────────────────────────────────────
export default function Handbook() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  // ── URL ↔ selectedId sync ─────────────────────────────────────────
  // Page id is carried in the URL as /handbook/<confluence_page_id>.
  // Refresh keeps you on the same page; back/forward navigates between visits.
  const _initialSelectedId = (typeof window !== "undefined")
    ? (/^\/handbook\/([^/]+)\/?$/.exec(window.location.pathname || "")?.[1] || null)
    : null;
  const [selectedId, setSelectedId] = useState(_initialSelectedId);
  const selectPage = useCallback((id, replace = false) => {
    setSelectedId(id);
    if (typeof window === "undefined" || !id) return;
    const desired = `/handbook/${encodeURIComponent(id)}`;
    if (window.location.pathname === desired) return;
    if (replace) window.history.replaceState({}, "", desired);
    else window.history.pushState({}, "", desired);
  }, []);
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const onPop = () => {
      const m = /^\/handbook\/([^/]+)\/?$/.exec(window.location.pathname || "");
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
        const { data, error: qErr } = await supabase
          .from("handbook")
          .select("id, title, content, content_format, source_url, confluence_page_id, parent_page_id, sort_order, version, is_active, icon, fetched_at, updated_at, notes")
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
  // null (i.e. URL was bare /handbook), pick the root page and
  // replaceState so the address bar reflects what is being shown without
  // adding a spurious history entry.
  useEffect(() => {
    if (!rows.length || selectedId) return;
    const root = rows.find(r => !r.parent_page_id);
    const defaultId = root?.confluence_page_id || rows[0]?.confluence_page_id;
    if (defaultId) selectPage(defaultId, true);
  }, [rows, selectedId, selectPage]);

  const { tree, nodeById } = useMemo(() => {
    const roots = buildTree(rows);
    const byPid = annotateDisplayNumbers(roots);
    return { tree: roots, nodeById: byPid };
  }, [rows]);
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
    () => nodeById.get(selectedId) || (rows || []).find(r => r.confluence_page_id === selectedId) || null,
    [nodeById, rows, selectedId]
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
            The handbook table is empty.
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
            Team Reference
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            Handbook
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
          {(visibleIds ? flat : visibleFlat).map((entry) => {
            const node = entry.node;
            const depth = entry.depth;
            const isActive = node.confluence_page_id === selectedId;
            const hidden = visibleIds && !visibleIds.has(node.confluence_page_id);
            if (hidden) return null;
            // In search mode we synthesize hasChildren from tree; otherwise it's on entry.
            const hasChildren = "hasChildren" in entry
              ? entry.hasChildren
              : (Array.isArray(node.children) && node.children.length > 0);
            const isExpanded = expandedIds.has(node.confluence_page_id);
            const icon = depth === 0 ? iconForNode(node) : "";
            return (
              <Fragment key={node.confluence_page_id}>
              {!visibleIds && depth === 0 && node.title === "Glossary" && (
                <div style={{ height: 1, background: T.slate200, margin: "8px 16px" }} aria-hidden="true" />
              )}
              <div
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
                {/* Chevron column — reserved width so titles align regardless of children */}
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
                  {icon && <div style={{ fontSize: 16, lineHeight: 1.2, marginTop: 1 }}>{icon}</div>}
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{
                      fontSize: 13, fontWeight: depth === 0 ? 700 : 600,
                      color: T.slate900,
                      letterSpacing: "-0.01em",
                      lineHeight: 1.3,
                    }}>
                      {withNumber(node)}
                    </div>
                    {depth === 0 && (
                      <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.4, marginTop: 2 }}>
                        {previewText(node.content, 70) || "—"}
                      </div>
                    )}
                  </div>
                </button>
              </div>
              </Fragment>
            );
          })}
        </div>

        {/* Footer */}
        <div style={{ padding: "12px 18px", borderTop: `1px solid ${T.slate200}`, background: T.slate50 }}>
          <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.5 }}>
            <strong style={{ color: T.slate700 }}>{rows.length} pages.</strong>
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
              {selected ? withNumber(selected) : "Pick a section"}
            </div>
          </div>
        )}
        {selected ? <HandbookPage page={selected} allRows={rows} /> : (
          <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
            {_vp.isPhone ? 'Tap "Sections" to choose a page.' : 'Select a page from the sidebar.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Page detail view ─────────────────────────────────────────
function HandbookPage({ page, allRows }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "20px 16px 48px" : _vp.isTablet ? "26px 24px 60px" : "32px 40px 80px 40px";

  // Load glossary terms so pages can reference them inline via {{glossary:tag}}.
  const [glossaryRows, setGlossaryRows] = useState([]);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: e } = await supabase
          .from("glossary_terms")
          .select("tag, term, definition, sort_order, is_active")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true);
        if (cancelled) return;
        if (!e) setGlossaryRows(Array.isArray(data) ? data : []);
      } catch (_err) { /* silent — inline glossary is optional */ }
    })();
    return () => { cancelled = true; };
  }, []);

  const resolveInclude = useMemo(
    () => makeIncludeResolver(buildIncludeLookup(allRows || [])),
    [allRows]
  );
  const resolveGlossary = useMemo(
    () => makeGlossaryResolver(buildGlossaryLookup(glossaryRows || [])),
    [glossaryRows]
  );
  const html = useMemo(
    () => mdToHtml(page?.content || "", { resolveInclude, resolveGlossary }),
    [page?.content, resolveInclude, resolveGlossary]
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

  const icon = iconForNode(page);

  return (
    <div style={{ maxWidth: 880, margin: "0 auto", padding: _pad }}>
      {/* Inline style block for HTML-rendered handbook content.
          Scoped via a wrapper class so it can't bleed into other modules. */}
      <style>{`
        .bcc-handbook-body { font-size: 14px; line-height: 1.75; color: ${T.slate700}; }
        .bcc-handbook-body h1 { font-size: 24px; font-weight: 800; color: ${T.slate900}; margin: 28px 0 12px 0; letter-spacing: -0.02em; }
        .bcc-handbook-body h2 { font-size: 19px; font-weight: 700; color: ${T.slate900}; margin: 36px 0 14px 0; padding: 8px 12px; letter-spacing: -0.015em; background: linear-gradient(to right, ${T.blue}22, transparent 65%); border-left: 3px solid ${T.blue}; border-radius: 0 4px 4px 0; }
        .bcc-handbook-body .bcc-info-btn { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; padding: 0; margin: 0 2px; border: 1px solid ${T.blue}55; background: ${T.blue}11; color: ${T.blue}; font-size: 12px; line-height: 1; font-family: inherit; vertical-align: baseline; cursor: pointer; border-radius: 50%; }
        .bcc-handbook-body .bcc-info-btn:hover, .bcc-handbook-body .bcc-info-btn:focus-visible { background: ${T.blue}33; border-color: ${T.blue}; outline: none; }
        .bcc-info-popover { padding: 12px 14px; max-width: min(360px, calc(100vw - 32px)); border: 1px solid ${T.blue}; border-radius: 6px; background: white; color: ${T.slate900}; font-size: 14px; line-height: 1.5; box-shadow: 0 8px 24px rgba(0,0,0,0.12); }
        .bcc-info-popover a { color: ${T.blue}; text-decoration: underline; }
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
        {icon && <div style={{ fontSize: 40, lineHeight: 1 }}>{icon}</div>}
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
            {page ? withNumber(page) : "Untitled page"}
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
        {DYNAMIC_HANDBOOK_PAGES[page?.confluence_page_id] === "team_roster" ? (
          <div className="bcc-handbook-body">
            <TeamRoster />
          </div>
        ) : DYNAMIC_HANDBOOK_PAGES[page?.confluence_page_id] === "glossary_all" ? (
          <div className="bcc-handbook-body">
            <GlossaryList />
          </div>
        ) : (page?.content || "").trim() ? (
          <div className="bcc-handbook-body" dangerouslySetInnerHTML={{ __html: html }} />
        ) : (
          <div style={{ color: T.slate500, fontStyle: "italic", fontSize: 13 }}>
            This page has no text content.{page?.notes ? ` (${page.notes})` : ""}
          </div>
        )}
      </div>
    </div>
  );
}
