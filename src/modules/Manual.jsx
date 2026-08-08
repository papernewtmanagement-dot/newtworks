import { useState, useEffect, useMemo, useCallback, useRef, Fragment } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";

// ============================================================
// NEWTWORKS MANUAL MODULE v1.0
// Unified renderer for handbook, processes, admin, and future manuals.
//
// PURPOSE:
// Reads public.manuals filtered by manual_type (handbook | processes
// | admin | roleplaying | financial_literacy | investments) and renders
// the same tree UI + page detail view for all of them. Each caller
// mounts <Manual manualType="..."/> from NewtworksApp.jsx and the
// per-manual settings (base URL, chip label, dynamic pages, glossary
// enable) come from MANUAL_CONFIG below.
//
// DATA SHAPE (public.manuals):
//   - one row per page, scoped by (agency_id, manual_type)
//   - tree via parent_page_id (NULL = root)
//   - content stored as Markdown with embedded HTML for
//     <details>/<summary> expand sections, <blockquote>
//     callouts, and tables that contain expands
//   - versioned: is_active=true for the current version,
//     prior versions kept with archived_at set
// ============================================================

// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

// ─── Per-manual configuration ─────────────────────────────────
// Every manual_type has one entry. To add a new manual:
//   1. Add its value to the manuals_manual_type_check DB constraint.
//   2. Add a config entry here.
//   3. Add a NAV_ITEMS entry in NewtworksApp.jsx pointing at
//      <Manual manualType="..." />.
// basePath must match the NAV_ITEMS id and the parseUrl slug.
const MANUAL_CONFIG = {
  handbook: {
    basePath: "/handbook",
    moduleTitle: "Handbook",
    moduleSubtitle: "Team Reference",
    searchPlaceholder: "Search handbook…",
    emptyLabel: "handbook",
    chipLabel: "Handbook",
    askContextLabel: "our team handbook",
    hasGlossary: true,
    glossaryParentId: "newtworks-native-handbook-glossary",
    dynamicPages: {
      "345407825": "team_roster",
      "newtworks-native-handbook-glossary": "glossary_all",
    },
  },
  processes: {
    basePath: "/processes",
    moduleTitle: "Processes",
    moduleSubtitle: "Operational Reference",
    searchPlaceholder: "Search processes…",
    emptyLabel: "processes",
    chipLabel: "Processes",
    askContextLabel: "our operational processes reference",
    hasGlossary: false,
    glossaryParentId: null,
    dynamicPages: {},
  },
  admin: {
    basePath: "/admin",
    moduleTitle: "Admin",
    moduleSubtitle: "Back-office Reference",
    searchPlaceholder: "Search admin…",
    emptyLabel: "admin pages",
    chipLabel: "Admin",
    askContextLabel: "our admin reference",
    hasGlossary: false,
    glossaryParentId: null,
    dynamicPages: {},
  },
};

// ─── Section icon picker ──────────────────────────────────────
// Icons are stored on the row itself (public.manuals.icon column) so a title
// rename or a new section doesn't require a code change. Only rendered at
// depth 0 in the sidebar.
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
  buildExcerptLookup,
  makeExcerptResolver,
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
          .from("team_directory")
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


// Live glossary component. Renders active glossary terms (manuals rows
// whose parent_page_id matches the given glossaryParentId) grouped
// alphabetically by first letter. Terms authored as child pages of the
// Glossary row; empty state renders a friendly stub.
function GlossaryList({ manualType, parentId }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: e } = await supabase
          .from("manuals")
          .select("title, content, confluence_page_id, sort_order")
          .eq("agency_id", AGENCY_ID)
          .eq("manual_type", manualType)
          .eq("is_active", true)
          .eq("parent_page_id", parentId)
          .order("sort_order", { ascending: true, nullsFirst: false })
          .order("title", { ascending: true });
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
        No glossary terms yet. Add child pages under the Glossary row (parent_page_id=<code>{parentId}</code>) and they&apos;ll appear here.
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
    const g = firstChar(r.title);
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
            <div key={`${r.confluence_page_id || r.title}-${i}`} style={{ marginBottom: 18 }}>
              <div style={{ fontWeight: 800, color: T.slate900, letterSpacing: "0.02em" }}>{r.title}</div>
              <div
                style={{ marginTop: 4 }}
                dangerouslySetInnerHTML={{ __html: mdToHtml(r.content || "") }}
              />
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}


// ─── Team-visibility gate ─────────────────────────────────────
// Admin users see every row; non-admin users see rows only up to and
// including the first root with divider_after=true. Everything after
// that root (in the sorted root list) plus all their descendants is
// filtered out. Root ordering matches buildTree's comparator so this
// aligns with what the sidebar would render.
const ADMIN_ROLES = ["owner", "manager"];

function filterBelowDivider(rows, userRole) {
  if (!Array.isArray(rows) || rows.length === 0) return rows || [];
  if (ADMIN_ROLES.includes(userRole)) return rows;

  const byId = new Map(rows.map((r) => [r.confluence_page_id, r]));
  const roots = rows.filter(
    (r) => !r.parent_page_id || !byId.has(r.parent_page_id),
  );

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
  const sortedRoots = [...roots].sort(cmp);

  const dividerIdx = sortedRoots.findIndex((r) => r?.divider_after);
  if (dividerIdx === -1) return rows;

  const belowLineRootIds = new Set(
    sortedRoots.slice(dividerIdx + 1).map((r) => r.confluence_page_id),
  );
  if (belowLineRootIds.size === 0) return rows;

  const childrenByParent = new Map();
  for (const r of rows) {
    if (!r.parent_page_id) continue;
    if (!childrenByParent.has(r.parent_page_id)) {
      childrenByParent.set(r.parent_page_id, []);
    }
    childrenByParent.get(r.parent_page_id).push(r.confluence_page_id);
  }
  const hiddenIds = new Set(belowLineRootIds);
  const queue = [...belowLineRootIds];
  while (queue.length) {
    const pid = queue.shift();
    const kids = childrenByParent.get(pid) || [];
    for (const kid of kids) {
      if (!hiddenIds.has(kid)) {
        hiddenIds.add(kid);
        queue.push(kid);
      }
    }
  }

  return rows.filter((r) => !hiddenIds.has(r.confluence_page_id));
}

// ─── Module ───────────────────────────────────────────────────
export default function Manual({ manualType, userRole }) {
  const cfg = MANUAL_CONFIG[manualType];
  if (!cfg) {
    return (
      <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
        Unknown manual type: <code>{String(manualType)}</code>
      </div>
    );
  }
  const urlRe = useMemo(
    () => new RegExp("^" + cfg.basePath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/([^/]+)/?$"),
    [cfg.basePath]
  );
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  // Bumped by ManualPage edit/create/delete handlers to trigger a re-fetch.
  const [refreshTick, setRefreshTick] = useState(0);
  const onMutated = useCallback(() => setRefreshTick((t) => t + 1), []);
  // ── URL ↔ selectedId sync ─────────────────────────────────────────
  // Page id is carried in the URL as /handbook/<confluence_page_id>.
  // Refresh keeps you on the same page; back/forward navigates between visits.
  const _initialSelectedId = (typeof window !== "undefined")
    ? (urlRe.exec(window.location.pathname || "")?.[1] || null)
    : null;
  const [selectedId, setSelectedId] = useState(_initialSelectedId);
  const selectPage = useCallback((id, replace = false) => {
    setSelectedId(id);
    if (typeof window === "undefined" || !id) return;
    const desired = `${cfg.basePath}/${encodeURIComponent(id)}`;
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
        const { data, error: qErr } = await supabase
          .from("manuals")
          .select("id, title, content, content_format, source_url, confluence_page_id, parent_page_id, sort_order, version, is_active, icon, divider_after, fetched_at, updated_at")
          .eq("agency_id", AGENCY_ID)
          .eq("manual_type", manualType)
          .eq("is_active", true);
        if (cancelled) return;
        if (qErr) { setError(qErr.message); setRows([]); }
        else {
          const raw = Array.isArray(data) ? data : [];
          const list = filterBelowDivider(raw, userRole);
          setRows(list);
          // Default selection: root (no parent), or first row if no root
          // Default selection deferred to the auto-default useEffect below,
          // which fires once rows are loaded AND selectedId is still null.
          // This avoids stomping the URL-derived initial selectedId.
        }
      } catch (e) {
        if (!cancelled) { setError(e?.message || `Failed to load ${cfg.emptyLabel}.`); setRows([]); }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [manualType, userRole, refreshTick]);

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
      // Glossary terms are hidden from the sidebar (they render inside the Glossary
      // page via GlossaryList), so don't count them toward the parent's hasChildren —
      // otherwise the Glossary node draws a caret that expands to nothing.
      const kids = (cfg.hasGlossary && cfg.glossaryParentId && n?.confluence_page_id === cfg.glossaryParentId)
        ? []
        : (Array.isArray(n?.children) ? n.children : []);
      out.push({ node: n, depth: d, hasChildren: kids.length > 0 });
      if (expandedIds.has(n?.confluence_page_id)) {
        for (const c of kids) walk(c, d + 1);
      }
    };
    // Iterate roots. After each root's subtree, if the root has
    // divider_after=true, append a divider marker so the sidebar visually
    // separates this section from what follows. Divider lands after the
    // root's ENTIRE visible subtree (children if expanded, or just the row
    // if collapsed), not immediately after the row.
    for (const r of (tree || [])) {
      walk(r, 0);
      if (r?.divider_after) out.push({ divider: true });
    }
    return out;
  }, [tree, expandedIds, cfg]);

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
        Loading {cfg.emptyLabel}…
      </div>
    );
  }
  if (error) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.redLt, color: T.red, padding: 16, borderRadius: 10, fontSize: 13, border: `1px solid ${T.red}33` }}>
          <strong>Could not load the {cfg.emptyLabel}.</strong><br />
          {error}
        </div>
      </div>
    );
  }
  if (!rows.length) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.slate50, padding: 24, borderRadius: 12, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>No {cfg.emptyLabel} pages yet</div>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            The {cfg.emptyLabel} table is empty.
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
            {cfg.moduleSubtitle}
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            {cfg.moduleTitle}
          </div>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={cfg.searchPlaceholder}
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
          {(visibleIds ? flat : visibleFlat).map((entry, idx) => {
            // Divider marker inserted by visibleFlat after any root flagged
            // divider_after=true. Search mode uses `flat` which contains no
            // divider markers, so dividers are hidden while searching.
            if (entry.divider) {
              return (
                <div
                  key={`__divider-${idx}`}
                  style={{ height: 1, background: T.slate300, margin: "16px 16px" }}
                  aria-hidden="true"
                />
              );
            }
            const node = entry.node;
            const depth = entry.depth;
            const isActive = node.confluence_page_id === selectedId;
            const hidden = visibleIds && !visibleIds.has(node.confluence_page_id);
            // Hide glossary term children from the sidebar tree — they render inside the Glossary page via GlossaryList.
            if (cfg.hasGlossary && cfg.glossaryParentId && node.parent_page_id === cfg.glossaryParentId) return null;
            if (hidden) return null;
            // In search mode we synthesize hasChildren from tree; otherwise it's on entry.
            // Glossary terms are hidden from the sidebar, so the Glossary node itself
            // must not report hasChildren even though its tree row has kids.
            const hasChildren = "hasChildren" in entry
              ? entry.hasChildren
              : (!(cfg.hasGlossary && cfg.glossaryParentId && node.confluence_page_id === cfg.glossaryParentId)
                  && Array.isArray(node.children) && node.children.length > 0);
            const isExpanded = expandedIds.has(node.confluence_page_id);
            const icon = depth === 0 ? iconForNode(node) : "";
            return (
              <Fragment key={node.confluence_page_id}>
              {!visibleIds && cfg.hasGlossary && depth === 0 && node.title === "Glossary" && (
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
        {selected ? <ManualPage page={selected} allRows={rows} cfg={cfg} manualType={manualType} userRole={userRole} onMutated={onMutated} selectPage={selectPage} /> : (
          <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
            {_vp.isPhone ? 'Tap "Sections" to choose a page.' : 'Select a page from the sidebar.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Page detail view ─────────────────────────────────────────
// ─── Smooth <details> expand/collapse ──────────────────────────
// Native <details> snaps open/closed with no transition. This intercepts the
// summary click, measures start/end height, and animates it with the Web
// Animations API — standard reference pattern (web.dev "Building a smoothly
// animated details element"). Peter 2026-08-07: wanted the expanders in
// manuals to open smoothly instead of snapping.
//
// scrollHeight (not a manual sum of children) drives the expand target so
// margins/padding on the content are measured correctly automatically —
// summing child offsetHeights was tried first and undercounts spacing.
function nwEnableSmoothDetails(container) {
  if (!container) return;
  const nodes = container.querySelectorAll("details");
  nodes.forEach((el) => {
    if (el.dataset.nwAnimated) return; // idempotent — content swaps wholesale on nav
    el.dataset.nwAnimated = "1";
    const summary = el.querySelector(":scope > summary");
    if (!summary) return;

    let animation = null;
    let isClosing = false;
    let isExpanding = false;

    const onFinish = (isOpen) => {
      el.open = isOpen;
      animation = null;
      isClosing = false;
      isExpanding = false;
      el.style.height = "";
      el.style.overflow = "";
    };

    const shrink = () => {
      isClosing = true;
      const startHeight = `${el.offsetHeight}px`;
      const endHeight = `${summary.offsetHeight}px`;
      if (animation) animation.cancel();
      animation = el.animate(
        { height: [startHeight, endHeight] },
        { duration: 200, easing: "ease-out" }
      );
      animation.onfinish = () => onFinish(false);
      animation.oncancel = () => { isClosing = false; };
    };

    const expand = () => {
      isExpanding = true;
      const startHeight = `${el.offsetHeight}px`;
      const endHeight = `${el.scrollHeight}px`;
      if (animation) animation.cancel();
      animation = el.animate(
        { height: [startHeight, endHeight] },
        { duration: 200, easing: "ease-out" }
      );
      animation.onfinish = () => onFinish(true);
      animation.oncancel = () => { isExpanding = false; };
    };

    const openThenExpand = () => {
      el.style.height = `${el.offsetHeight}px`;
      el.open = true;
      requestAnimationFrame(() => requestAnimationFrame(expand));
    };

    summary.addEventListener("click", (e) => {
      e.preventDefault();
      el.style.overflow = "hidden";
      if (isClosing || !el.open) {
        openThenExpand();
      } else if (isExpanding || el.open) {
        shrink();
      }
    });
  });
}

function ManualPage({ page, allRows, cfg, manualType, userRole, onMutated, selectPage }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "20px 16px 48px" : _vp.isTablet ? "26px 24px 60px" : "32px 40px 80px 40px";
  const isAdmin = ADMIN_ROLES.includes(userRole);

  // ── Edit mode state ───────────────────────────────────────────
  // mode: 'view' | 'edit' | 'new-child'
  //   view       — read-only page render
  //   edit       — inline form editing THIS page
  //   new-child  — inline form authoring a new child page under THIS page
  const [mode, setMode] = useState("view");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  const [form, setForm] = useState(null);

  // Reset local edit state whenever the selected page changes.
  useEffect(() => { setMode("view"); setSaveError(null); setForm(null); }, [page?.id]);

  // Populate form from current page on entering edit mode.
  const enterEdit = useCallback(() => {
    if (!page) return;
    setForm({
      title: page.title || "",
      content: page.content || "",
      icon: page.icon || "",
      sort_order: page.sort_order ?? 0,
      parent_page_id: page.parent_page_id || "",
      divider_after: !!page.divider_after,
    });
    setSaveError(null);
    setMode("edit");
  }, [page]);

  // Populate form for a new child page.
  const enterNewChild = useCallback(() => {
    if (!page) return;
    // Next sort_order = max among existing siblings + 10 (10-step spacing).
    const siblings = (allRows || []).filter(
      (r) => (r.parent_page_id || null) === (page.confluence_page_id || null)
    );
    const maxSort = siblings.reduce((m, r) => (r.sort_order > m ? r.sort_order : m), 0);
    setForm({
      title: "",
      content: "",
      icon: "",
      sort_order: maxSort + 10,
      divider_after: false,
    });
    setSaveError(null);
    setMode("new-child");
  }, [page, allRows]);

  const cancelEdit = useCallback(() => { setMode("view"); setForm(null); setSaveError(null); }, []);

  // Save edits to THIS page. Bumps version and updated_at.
  const saveEdit = useCallback(async () => {
    if (!page || !form) return;
    setSaving(true); setSaveError(null);
    try {
      // Cycle guard: chosen parent must not be self or a descendant of self.
      const chosenParent = (form.parent_page_id || "").trim() || null;
      if (chosenParent) {
        if (chosenParent === page.confluence_page_id) {
          throw new Error("A page can't be its own parent.");
        }
        // Walk up from chosenParent — if we ever hit page.confluence_page_id,
        // the chosen parent is a descendant of this page (would create a cycle).
        const byId = {};
        for (const r of (allRows || [])) { if (r.confluence_page_id) byId[r.confluence_page_id] = r; }
        let cur = byId[chosenParent];
        let hops = 0;
        while (cur && hops < 500) {
          if (cur.confluence_page_id === page.confluence_page_id) {
            throw new Error("Can't move a page under one of its own descendants.");
          }
          cur = cur.parent_page_id ? byId[cur.parent_page_id] : null;
          hops += 1;
        }
      }
      const patch = {
        title: (form.title || "").trim() || "Untitled",
        content: form.content || "",
        icon: (form.icon || "").trim() || null,
        sort_order: Number.isFinite(Number(form.sort_order)) ? Number(form.sort_order) : 0,
        parent_page_id: chosenParent,
        divider_after: !!form.divider_after,
        version: (page.version || 0) + 1,
        updated_at: new Date().toISOString(),
      };
      // .select("id") makes silent-RLS-no-op visible: if the update is blocked,
      // Supabase returns [] rather than throwing.
      const { data, error: e } = await supabase
        .from("manuals")
        .update(patch)
        .eq("id", page.id)
        .select("id");
      if (e) throw new Error(e.message);
      if (!Array.isArray(data) || data.length === 0) {
        throw new Error("No row updated. Do you still have admin access?");
      }
      setMode("view");
      setForm(null);
      if (onMutated) onMutated();
    } catch (err) {
      setSaveError(err?.message || "Save failed.");
    } finally {
      setSaving(false);
    }
  }, [page, form, allRows, onMutated]);

  // Create a new child page under THIS page and navigate to it.
  const createChild = useCallback(async () => {
    if (!page || !form) return;
    setSaving(true); setSaveError(null);
    try {
      const rand = Math.random().toString(36).slice(2, 8);
      const newConfluenceId = `newtworks-native-${manualType}-${Date.now()}-${rand}`;
      const row = {
        agency_id: AGENCY_ID,
        manual_type: manualType,
        tree_root: page.tree_root || manualType,
        title: (form.title || "").trim() || "Untitled",
        content: form.content || "",
        content_format: "markdown",
        confluence_page_id: newConfluenceId,
        parent_page_id: page.confluence_page_id || null,
        icon: (form.icon || "").trim() || null,
        sort_order: Number.isFinite(Number(form.sort_order)) ? Number(form.sort_order) : 0,
        divider_after: !!form.divider_after,
        version: 1,
        is_active: true,
        fetched_at: new Date().toISOString(),
      };
      const { data, error: e } = await supabase
        .from("manuals")
        .insert(row)
        .select("id, confluence_page_id");
      if (e) throw new Error(e.message);
      if (!Array.isArray(data) || data.length === 0) {
        throw new Error("Insert blocked. Do you still have admin access?");
      }
      setMode("view");
      setForm(null);
      if (onMutated) onMutated();
      if (selectPage) selectPage(newConfluenceId);
    } catch (err) {
      setSaveError(err?.message || "Create failed.");
    } finally {
      setSaving(false);
    }
  }, [page, form, manualType, onMutated, selectPage]);

  // Hard delete THIS page. Warns about orphaned children (parent_page_id is
  // text, not FK — children do not cascade).
  const deletePage = useCallback(async () => {
    if (!page) return;
    const children = (allRows || []).filter(
      (r) => (r.parent_page_id || null) === (page.confluence_page_id || null)
    );
    const msg = children.length > 0
      ? `Delete "${page.title}"? This page has ${children.length} child page${children.length === 1 ? "" : "s"} which will become orphaned (they stay in the DB but drop off the tree). Type YES to confirm.`
      : `Delete "${page.title}"? This is a hard delete and cannot be undone. Type YES to confirm.`;
    const ans = window.prompt(msg);
    if ((ans || "").trim().toUpperCase() !== "YES") return;
    setSaving(true); setSaveError(null);
    try {
      const { data, error: e } = await supabase
        .from("manuals")
        .delete()
        .eq("id", page.id)
        .select("id");
      if (e) throw new Error(e.message);
      if (!Array.isArray(data) || data.length === 0) {
        throw new Error("Delete blocked. Do you still have admin access?");
      }
      // Navigate to parent (or root) after delete.
      const parentId = page.parent_page_id;
      if (onMutated) onMutated();
      if (selectPage) {
        if (parentId) selectPage(parentId, true);
        else {
          const nextRoot = (allRows || []).find(
            (r) => !r.parent_page_id && r.id !== page.id
          );
          if (nextRoot?.confluence_page_id) selectPage(nextRoot.confluence_page_id, true);
        }
      }
    } catch (err) {
      setSaveError(err?.message || "Delete failed.");
      setSaving(false);
    }
  }, [page, allRows, onMutated, selectPage]);

  // Load glossary terms so pages can reference them inline via {{glossary:tag}}.
  // Only fetched when this manual has a glossary (cfg.hasGlossary).
  const [glossaryRows, setGlossaryRows] = useState([]);
  useEffect(() => {
    if (!cfg.hasGlossary || !cfg.glossaryParentId) return undefined;
    let cancelled = false;
    (async () => {
      try {
        const { data, error: e } = await supabase
          .from("manuals")
          .select("title, content, confluence_page_id, sort_order, is_active")
          .eq("agency_id", AGENCY_ID)
          .eq("manual_type", manualType)
          .eq("is_active", true)
          .eq("parent_page_id", cfg.glossaryParentId);
        if (cancelled) return;
        if (!e) setGlossaryRows(Array.isArray(data) ? data : []);
      } catch (_err) { /* silent — inline glossary is optional */ }
    })();
    return () => { cancelled = true; };
  }, [cfg.hasGlossary, cfg.glossaryParentId, manualType]);

  // Load excerpt sources (manual_type='excerpt') — these are named-fragment
  // rows referenced by [Embedded excerpt from: X] markers. Recovered from
  // Confluence's original excerpt macro; hidden from tree UI.
  const [excerptRows, setExcerptRows] = useState([]);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: e } = await supabase
          .from("manuals")
          .select("title, content, is_active")
          .eq("agency_id", AGENCY_ID)
          .eq("manual_type", "excerpt")
          .eq("is_active", true);
        if (cancelled) return;
        if (!e) setExcerptRows(Array.isArray(data) ? data : []);
      } catch (_err) { /* silent — inline excerpts are optional */ }
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
  const resolveExcerpt = useMemo(
    () => makeExcerptResolver(buildExcerptLookup(excerptRows || [])),
    [excerptRows]
  );
  const html = useMemo(
    () => mdToHtml(page?.content || "", { resolveInclude, resolveGlossary, resolveExcerpt }),
    [page?.content, resolveInclude, resolveGlossary, resolveExcerpt]
  );
  const bodyRef = useRef(null);
  useEffect(() => {
    nwEnableSmoothDetails(bodyRef.current);
  }, [html]);
  const askContext = useMemo(() => {
    return `I\'m looking at this page from ${cfg.askContextLabel}:

TITLE: ${page?.title}
SOURCE: ${page?.source_url || "(no source url)"}
VERSION: ${page?.version ?? "—"}

CONTENT:
${page?.content || ""}

What I\'d like to discuss:
`;
  }, [page, cfg.askContextLabel]);

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
        .newtworks-handbook-body { font-size: 14px; line-height: 1.75; color: ${T.slate700}; }
        .newtworks-handbook-body h1 { font-size: 24px; font-weight: 800; color: ${T.slate900}; margin: 28px 0 12px 0; letter-spacing: -0.02em; }
        .newtworks-handbook-body h2 { font-size: 19px; font-weight: 700; color: ${T.slate900}; margin: 36px 0 14px 0; padding: 8px 12px; letter-spacing: -0.015em; background: linear-gradient(to right, ${T.blue}22, transparent 65%); border-left: 3px solid ${T.blue}; border-radius: 0 4px 4px 0; }
        .newtworks-handbook-body .newtworks-info-btn { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; padding: 0; margin: 0 2px; border: 1px solid ${T.blue}55; background: ${T.blue}11; color: ${T.blue}; font-size: 12px; line-height: 1; font-family: inherit; vertical-align: baseline; cursor: pointer; border-radius: 50%; }
        .newtworks-handbook-body .newtworks-info-btn:hover, .newtworks-handbook-body .newtworks-info-btn:focus-visible { background: ${T.blue}33; border-color: ${T.blue}; outline: none; }
        .newtworks-info-popover { padding: 12px 14px; max-width: min(360px, calc(100vw - 32px)); border: 1px solid ${T.blue}; border-radius: 6px; background: white; color: ${T.slate900}; font-size: 14px; line-height: 1.5; box-shadow: 0 8px 24px rgba(0,0,0,0.12); }
        .newtworks-info-popover a { color: ${T.blue}; text-decoration: underline; }
        .newtworks-handbook-body h3 { font-size: 16px; font-weight: 700; color: ${T.slate900}; margin: 22px 0 8px 0; }
        .newtworks-handbook-body h4 { font-size: 14px; font-weight: 700; color: ${T.slate800}; margin: 18px 0 6px 0; }
        /* Peter 2026-08-08: body content should sit slightly indented under its
           header, so it stands apart rather than starting flush at the same left
           edge as the heading above it. Direct-child selectors so this applies
           once at the top level and never double-indents nested content (a
           <p> inside a blockquote or details doesn't get hit again). */
        .newtworks-handbook-body > p,
        .newtworks-handbook-body > ul,
        .newtworks-handbook-body > ol,
        .newtworks-handbook-body > blockquote,
        .newtworks-handbook-body > pre,
        .newtworks-handbook-body > details,
        .newtworks-handbook-body > table {
          margin-left: 10px;
        }
        .newtworks-handbook-body > table { width: calc(100% - 10px); }
        .newtworks-handbook-body p { margin: 0 0 14px 0; }
        .newtworks-handbook-body ul, .newtworks-handbook-body ol { margin: 8px 0 16px 0; padding-left: 24px; }
        .newtworks-handbook-body li { margin-bottom: 6px; }
        .newtworks-handbook-body strong { font-weight: 700; color: ${T.slate900}; }
        .newtworks-handbook-body em { font-style: italic; }
        .newtworks-handbook-body code { background: ${T.slate100}; padding: 1px 6px; border-radius: 4px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; color: ${T.slate800}; }
        .newtworks-handbook-body pre { background: ${T.slate100}; padding: 14px 16px; border-radius: 8px; overflow-x: auto; margin: 14px 0; }
        .newtworks-handbook-body pre code { background: transparent; padding: 0; }
        .newtworks-handbook-body a { color: ${T.blue}; text-decoration: underline; text-decoration-color: ${T.blue}66; }
        .newtworks-handbook-body a:hover { text-decoration-color: ${T.blue}; }
        .newtworks-handbook-body hr { border: 0; border-top: 1px solid ${T.slate200}; margin: 24px 0; }
        .newtworks-handbook-body blockquote {
          background: ${T.blueLt};
          border-left: 4px solid ${T.blue};
          padding: 12px 16px;
          margin: 14px 0;
          border-radius: 6px;
          color: ${T.slate700};
        }
        .newtworks-handbook-body blockquote p { margin: 0 0 6px 0; }
        .newtworks-handbook-body blockquote p:last-child { margin-bottom: 0; }
        /* Info-box blockquotes (Knowledge & FAQ sections) carry their own left
           border + tint so they stand out on a plain page. Inside an OPEN
           expander that surface already exists - the blockquotes own border
           was showing as a second colored line nested inside the containers
           shading. Peter 2026-08-08. Neutralize only in that context; leave the
           standalone blockquote style untouched everywhere else. */
        .newtworks-handbook-body details[open] blockquote {
          background: transparent;
          border-left: none;
          border-radius: 0;
          padding: 4px 0;
          margin: 10px 0;
        }
        .newtworks-handbook-body table {
          border-collapse: collapse;
          margin: 16px 0;
          width: 100%;
          font-size: 13px;
        }
        .newtworks-handbook-body th, .newtworks-handbook-body td {
          border: 1px solid ${T.slate200};
          padding: 8px 12px;
          text-align: left;
          vertical-align: top;
        }
        .newtworks-handbook-body th { background: ${T.slate50}; font-weight: 700; color: ${T.slate900}; }
        /* Expanders — literal port of the approved preview file
           (expander_v4_preview.html), shipped 2026-08-08. Same hex values, same
           paddings, same plain-triangle caret — not translated through design
           tokens or redesigned. Do not "improve" this without a new preview
           approved first; that is exactly what went wrong last time. */
        .newtworks-handbook-body details { margin: 6px 0 6px 10px; }
        .newtworks-handbook-body details:not([open]) { background: #EFF1E8; border-radius: 7px; }
        .newtworks-handbook-body details:not([open]) > summary { padding: 8px 12px 8px 30px; }
        .newtworks-handbook-body details[open] {
          background: #DFE3D2;
          border-radius: 7px;
          overflow: hidden;
          margin-bottom: 14px;
        }
        .newtworks-handbook-body details[open] > summary {
          background: #EFF1E8;
          padding: 8px 12px 8px 30px;
          margin: 0;
        }
        .newtworks-handbook-body summary {
          cursor: pointer;
          font-weight: 600;
          color: ${T.slate700};
          position: relative;
          user-select: none;
          list-style: none;
        }
        .newtworks-handbook-body summary::-webkit-details-marker { display: none; }
        .newtworks-handbook-body summary::before {
          content: "▸";
          position: absolute;
          left: 10px;
          top: 9px;
          color: ${T.blue};
          font-size: 11px;
          font-weight: 700;
        }
        .newtworks-handbook-body details[open] > summary::before { content: "▾"; }
        .newtworks-handbook-body details[open] > *:not(summary) {
          margin: 0;
          padding: 4px 30px;
          background: transparent;
        }
        .newtworks-handbook-body details[open] > summary + * { padding-top: 10px; }
        .newtworks-handbook-body details[open] > *:last-child { padding-bottom: 12px; }
        .newtworks-handbook-body img { max-width: 100%; height: auto; border-radius: 6px; }
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
              {cfg.chipLabel}
            </div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500 }}>
              v{page?.version ?? "—"}
            </div>
            {updatedStr && (
              <div style={{ fontSize: 11, color: T.slate400 }}>
                • Mirrored {updatedStr}
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

      {/* Action row — admin-only edit controls */}
      {isAdmin && mode === "view" && (
        <div style={{ display: "flex", gap: 10, marginBottom: 22, flexWrap: "wrap" }}>
          <button
            type="button"
            onClick={enterEdit}
            style={{
              padding: "8px 14px", borderRadius: 8, border: `1px solid ${T.blue}`,
              background: T.white, color: T.blue, fontSize: 13, fontWeight: 700, cursor: "pointer",
            }}
          >
            ✎ Edit page
          </button>
          <button
            type="button"
            onClick={enterNewChild}
            style={{
              padding: "8px 14px", borderRadius: 8, border: `1px solid ${T.slate300}`,
              background: T.white, color: T.slate700, fontSize: 13, fontWeight: 600, cursor: "pointer",
            }}
          >
            + New page under this
          </button>
          <button
            type="button"
            onClick={deletePage}
            disabled={saving}
            style={{
              padding: "8px 14px", borderRadius: 8, border: `1px solid ${T.red}55`,
              background: T.white, color: T.red, fontSize: 13, fontWeight: 600, cursor: saving ? "not-allowed" : "pointer",
              marginLeft: "auto",
            }}
          >
            Delete
          </button>
        </div>
      )}
      {isAdmin && (mode === "edit" || mode === "new-child") && (
        <div style={{ display: "flex", gap: 10, marginBottom: 12, flexWrap: "wrap", alignItems: "center" }}>
          <button
            type="button"
            onClick={mode === "edit" ? saveEdit : createChild}
            disabled={saving}
            style={{
              padding: "8px 14px", borderRadius: 8, border: `1px solid ${T.blue}`,
              background: T.blue, color: T.white, fontSize: 13, fontWeight: 700,
              cursor: saving ? "not-allowed" : "pointer", opacity: saving ? 0.6 : 1,
            }}
          >
            {saving ? "Saving…" : (mode === "edit" ? "Save changes" : "Create page")}
          </button>
          <button
            type="button"
            onClick={cancelEdit}
            disabled={saving}
            style={{
              padding: "8px 14px", borderRadius: 8, border: `1px solid ${T.slate300}`,
              background: T.white, color: T.slate700, fontSize: 13, fontWeight: 600,
              cursor: saving ? "not-allowed" : "pointer",
            }}
          >
            Cancel
          </button>
          {saveError && (
            <div style={{ color: T.red, fontSize: 12, fontWeight: 600 }}>{saveError}</div>
          )}
          <div style={{ marginLeft: "auto", fontSize: 11, color: T.slate500 }}>
            {mode === "edit" ? `Editing v${page?.version ?? "—"} → v${(page?.version || 0) + 1}` : "New child page"}
          </div>
        </div>
      )}

      {/* Content */}
      <div style={{
        background: T.white,
        padding: "28px 32px",
        borderRadius: 14,
        border: `1px solid ${T.slate200}`,
        boxShadow: "0 1px 3px rgba(15, 23, 42, 0.04)",
      }}>
        {isAdmin && (mode === "edit" || mode === "new-child") && form ? (
          <ManualEditForm form={form} setForm={setForm} vp={_vp} allRows={allRows} currentPageId={page?.confluence_page_id} mode={mode} />
        ) : cfg.dynamicPages[page?.confluence_page_id] === "team_roster" ? (
          <div className="newtworks-handbook-body">
            <TeamRoster />
          </div>
        ) : cfg.dynamicPages[page?.confluence_page_id] === "glossary_all" ? (
          <div className="newtworks-handbook-body">
            <GlossaryList manualType={manualType} parentId={cfg.glossaryParentId} />
          </div>
        ) : (page?.content || "").trim() ? (
          <div className="newtworks-handbook-body" dangerouslySetInnerHTML={{ __html: html }} ref={bodyRef} />
        ) : (
          <div style={{ color: T.slate500, fontStyle: "italic", fontSize: 13 }}>
            This page has no text content.
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Inline edit form ─────────────────────────────────────────
// Rendered in place of the page content when ManualPage is in edit or
// new-child mode. Kept as a pure controlled form so parent owns the state
// and the save/create handlers can inspect `form` directly.
//
// Parent picker renders only in edit mode. In new-child mode, parent is
// implicit (the current page being viewed) — reparenting a brand-new page
// isn't useful until it has a title.
function ManualEditForm({ form, setForm, vp, allRows, currentPageId, mode }) {
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });
  const setBool = (k) => (e) => setForm({ ...form, [k]: !!e.target.checked });
  const rowStyle = { display: "flex", gap: 12, flexDirection: vp.isPhone ? "column" : "row", marginBottom: 14 };
  const labelStyle = { fontSize: 11, fontWeight: 700, color: T.slate600, textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: 4, display: "block" };
  const inputStyle = { width: "100%", padding: "8px 10px", borderRadius: 6, border: `1px solid ${T.slate300}`, fontSize: 14, fontFamily: "inherit", background: T.white, boxSizing: "border-box" };
  const taStyle = { ...inputStyle, minHeight: 340, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: 13, lineHeight: 1.55, resize: "vertical" };

  // Build the parent-picker options: every page in this manual except THIS
  // page and its descendants (which would create a cycle). Options render
  // in tree order with an indent prefix so hierarchy is visible.
  const parentOptions = useMemo(() => {
    if (mode !== "edit") return [];
    const rows = allRows || [];
    // Set of ids to exclude: self + all descendants.
    const excluded = new Set();
    if (currentPageId) {
      excluded.add(currentPageId);
      let added = true;
      while (added) {
        added = false;
        for (const r of rows) {
          if (r.parent_page_id && excluded.has(r.parent_page_id) && r.confluence_page_id && !excluded.has(r.confluence_page_id)) {
            excluded.add(r.confluence_page_id);
            added = true;
          }
        }
      }
    }
    // Build a tree walk for indent-ordered output.
    const byParent = new Map();
    for (const r of rows) {
      const p = r.parent_page_id || "";
      if (!byParent.has(p)) byParent.set(p, []);
      byParent.get(p).push(r);
    }
    for (const [, list] of byParent) {
      list.sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
    }
    const out = [];
    const walk = (parentKey, depth) => {
      const kids = byParent.get(parentKey) || [];
      for (const k of kids) {
        if (k.confluence_page_id && !excluded.has(k.confluence_page_id)) {
          out.push({ id: k.confluence_page_id, label: `${"— ".repeat(depth)}${k.icon ? k.icon + " " : ""}${k.title || "Untitled"}` });
        }
        // Descend even if this node was excluded; a descendant of an excluded
        // node is also excluded, so walking is safe — but for the target-in-
        // options case we still need to explore children of not-excluded nodes.
        if (k.confluence_page_id && !excluded.has(k.confluence_page_id)) {
          walk(k.confluence_page_id, depth + 1);
        }
      }
    };
    walk("", 0);
    return out;
  }, [allRows, currentPageId, mode]);

  return (
    <div>
      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Title</label>
        <input type="text" value={form.title} onChange={set("title")} style={inputStyle} />
      </div>
      <div style={rowStyle}>
        <div style={{ flex: "0 0 120px" }}>
          <label style={labelStyle}>Icon</label>
          <input type="text" value={form.icon} onChange={set("icon")} placeholder="📘" style={inputStyle} maxLength={4} />
        </div>
        <div style={{ flex: "0 0 140px" }}>
          <label style={labelStyle}>Sort order</label>
          <input type="number" value={form.sort_order} onChange={set("sort_order")} style={inputStyle} />
        </div>
        {mode === "edit" && (
          <div style={{ flex: 1 }}>
            <label style={labelStyle}>Parent (move under…)</label>
            <select
              value={form.parent_page_id || ""}
              onChange={set("parent_page_id")}
              style={inputStyle}
            >
              <option value="">— Top level (root) —</option>
              {parentOptions.map((o) => (
                <option key={o.id} value={o.id}>{o.label}</option>
              ))}
            </select>
          </div>
        )}
      </div>
      <div style={{ marginBottom: 14, display: "flex", alignItems: "center", gap: 8 }}>
        <input
          id="mp-divider"
          type="checkbox"
          checked={!!form.divider_after}
          onChange={setBool("divider_after")}
          style={{ width: 16, height: 16 }}
        />
        <label htmlFor="mp-divider" style={{ fontSize: 13, color: T.slate700, cursor: "pointer" }}>
          Show a section divider after this page in the sidebar (team-only pages below the divider are hidden from non-admin)
        </label>
      </div>
      <div>
        <label style={labelStyle}>Content (Markdown; HTML like &lt;details&gt; / &lt;blockquote&gt; passes through)</label>
        <textarea value={form.content} onChange={set("content")} style={taStyle} spellCheck={true} />
      </div>
    </div>
  );
}
