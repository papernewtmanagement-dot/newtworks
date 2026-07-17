import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { useTabParam } from "../lib/routing.jsx";
import {
  mdToHtml,
  buildIncludeLookup,
  makeIncludeResolver,
  buildExcerptLookup,
  makeExcerptResolver,
} from "../lib/markdown.js";

// ============================================================
// Newtworks CONTENT EDITOR MODULE v1.0
//
// PURPOSE:
// A single admin surface for editing every row in public.manuals
// regardless of manual_type. This includes:
//   - handbook / processes / admin (visible in tree UI)
//   - roleplaying / financial_literacy / investments (future manuals)
//   - excerpt (hidden fragments, referenced by
//     [Embedded excerpt from: X] markers on other pages)
//
// WHY THIS EXISTS:
// Manual.jsx is a READ view scoped to one manual_type at a time.
// Excerpts don't appear in its tree by design (they're referenced,
// not browsed). Prior to this module there was no path to edit
// an excerpt after cutting the Confluence umbilical — nor to
// move a page between manual_types, edit metadata fields like
// sort_order or icon, or archive a page.
//
// UX MODEL:
// Left pane: filterable + searchable list of rows. Right pane:
// form-driven editor with a live preview. On mobile the list
// becomes a slide-out drawer, matching CorePrinciples.jsx.
//
// SAVE SEMANTICS:
// UPDATE-in-place. Bumps version + updated_at. Archive sets
// is_active=false and archived_at=NOW(). Hard-delete is NOT
// exposed here — archived rows can be restored from any admin
// with SQL access if needed.
// ============================================================

// ─── Manual type registry (label + tint) ────────────────────
const MANUAL_TYPES = [
  { id: "handbook",           label: "Handbook",           tint: T.blue },
  { id: "processes",          label: "Processes",          tint: T.green },
  { id: "admin",              label: "Admin",              tint: T.purple },
  { id: "roleplaying",        label: "Roleplaying",        tint: T.gold },
  { id: "financial_literacy", label: "Financial Literacy", tint: T.red },
  { id: "investments",        label: "Investments",        tint: T.slate600 },
  { id: "excerpt",            label: "Excerpt",            tint: T.slate500 },
];
const typeById = Object.fromEntries(MANUAL_TYPES.map(t => [t.id, t]));

const BLANK_ROW = () => ({
  id: null,                // populated after INSERT
  title: "",
  manual_type: "handbook",
  content: "",
  content_format: "markdown",
  notes: null,
  icon: null,
  sort_order: 0,
  parent_page_id: null,
  tree_root: null,
  source_url: null,
  confluence_page_id: null,
  is_active: true,
  version: 1,
  archived_at: null,
});

const s = {
  page: { display: "flex", flexDirection: "column", height: "100%", background: T.slate50 },
  headerBar: {
    display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap",
    padding: "12px 16px", background: T.chromeBg,
    borderBottom: `1px solid ${T.chromeBorder}`,
  },
  headerTitle: { fontSize: 15, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em" },
  filterSelect: {
    padding: "6px 10px", fontSize: 13, background: "#fff",
    border: `1px solid ${T.slate300}`, borderRadius: 6, color: T.slate800,
    fontFamily: "inherit",
  },
  searchInput: {
    padding: "6px 10px", fontSize: 13, minWidth: 180, flex: 1,
    background: "#fff", border: `1px solid ${T.slate300}`,
    borderRadius: 6, color: T.slate800, fontFamily: "inherit",
  },
  primaryBtn: {
    padding: "6px 12px", fontSize: 13, fontWeight: 600, cursor: "pointer",
    background: T.slate900, color: "#fff", border: "none", borderRadius: 6,
  },
  ghostBtn: {
    padding: "6px 10px", fontSize: 13, cursor: "pointer",
    background: "#fff", color: T.slate700,
    border: `1px solid ${T.slate300}`, borderRadius: 6,
  },
  dangerBtn: {
    padding: "6px 10px", fontSize: 13, cursor: "pointer",
    background: "#fff", color: T.red,
    border: `1px solid ${T.red}`, borderRadius: 6,
  },
  body: { display: "flex", flex: 1, minHeight: 0 },
  listCol: {
    width: 320, flexShrink: 0, borderRight: `1px solid ${T.chromeBorder}`,
    background: "#fff", overflowY: "auto",
  },
  listItem: (active) => ({
    padding: "10px 14px", borderBottom: `1px solid ${T.slate100}`, cursor: "pointer",
    background: active ? T.slate100 : "transparent",
    borderLeft: `3px solid ${active ? T.slate900 : "transparent"}`,
  }),
  listItemTitle: { fontSize: 13, fontWeight: 600, color: T.slate900, marginBottom: 2 },
  listItemMeta: { fontSize: 11, color: T.slate500, display: "flex", gap: 6, alignItems: "center" },
  pill: (tint) => ({
    fontSize: 10, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.03em",
    padding: "2px 6px", borderRadius: 4, color: tint, background: `${tint}18`,
  }),
  editorCol: { flex: 1, overflowY: "auto", padding: 20, background: T.slate50 },
  field: { display: "flex", flexDirection: "column", gap: 4, marginBottom: 14 },
  fieldLabel: { fontSize: 11, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.05em", color: T.slate500 },
  fieldRow: { display: "flex", gap: 12, flexWrap: "wrap" },
  input: {
    padding: "8px 10px", fontSize: 14, background: "#fff",
    border: `1px solid ${T.slate300}`, borderRadius: 6, color: T.slate900,
    fontFamily: "inherit",
  },
  textarea: {
    padding: "10px 12px", fontSize: 13, lineHeight: 1.5, minHeight: 320,
    background: "#fff", border: `1px solid ${T.slate300}`, borderRadius: 6,
    color: T.slate900, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    resize: "vertical",
  },
  emptyState: {
    display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center",
    height: "100%", padding: 40, color: T.slate500, textAlign: "center",
  },
  previewPane: {
    marginTop: 20, padding: 16, background: "#fff", borderRadius: 6,
    border: `1px solid ${T.slate200}`,
  },
  previewLabel: {
    fontSize: 11, fontWeight: 700, textTransform: "uppercase",
    letterSpacing: "0.05em", color: T.slate500, marginBottom: 10,
  },
  previewBody: {
    fontSize: 14, lineHeight: 1.6, color: T.slate800,
  },
  savingBadge: {
    fontSize: 11, fontWeight: 600, color: T.slate500, marginLeft: 8,
  },
  errorBanner: {
    margin: "0 0 12px", padding: "10px 12px", background: `${T.red}12`,
    borderLeft: `4px solid ${T.red}`, color: T.red, fontSize: 13, borderRadius: 4,
  },
  successBanner: {
    margin: "0 0 12px", padding: "10px 12px", background: `${T.green}12`,
    borderLeft: `4px solid ${T.green}`, color: T.green, fontSize: 13, borderRadius: 4,
  },
  drawerBackdrop: {
    position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", zIndex: 40,
  },
  drawerPanel: (open) => ({
    position: "fixed", top: 0, left: 0, bottom: 0, width: 300, maxWidth: "90vw",
    background: "#fff", zIndex: 50, transform: `translateX(${open ? "0" : "-100%"})`,
    transition: "transform 0.2s ease", overflowY: "auto",
    boxShadow: open ? "0 4px 20px rgba(0,0,0,0.15)" : "none",
  }),
};

// ─── Root component ─────────────────────────────────────────
export default function ContentEditor() {
  const vp = useViewport();
  const isPhone = vp.isPhone;

  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const [filterType, setFilterType] = useState("all");
  const [searchQ, setSearchQ] = useState("");
  const [showArchived, setShowArchived] = useState(false);

  // URL-persisted so refresh keeps the same content row open. Draft/dirty
  // remain local — unsaved edits still don't survive a refresh (would need
  // a beforeunload prompt), but the selection does.
  const [selectedId, setSelectedId] = useTabParam("row", null);
  const [draft, setDraft] = useState(null);   // working copy of the selected row
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState(null);

  const [drawerOpen, setDrawerOpen] = useState(false);

  // Initial load — every row, active + archived, all manual_types
  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const { data, error: e } = await supabase
        .from("manuals")
        .select("id, agency_id, manual_type, title, content, content_format, notes, icon, sort_order, parent_page_id, tree_root, source_url, confluence_page_id, is_active, version, archived_at, updated_at")
        .eq("agency_id", AGENCY_ID)
        .order("manual_type", { ascending: true })
        .order("sort_order", { ascending: true, nullsFirst: false })
        .order("title", { ascending: true });
      if (e) { setError(e.message); setRows([]); }
      else { setRows(Array.isArray(data) ? data : []); setError(null); }
    } catch (ex) {
      setError(ex?.message || "Failed to load manuals");
      setRows([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { reload(); }, [reload]);

  // Filtered list
  const filteredRows = useMemo(() => {
    const q = (searchQ || "").trim().toLowerCase();
    return rows.filter(r => {
      if (!showArchived && !r.is_active) return false;
      if (!showArchived && r.archived_at) return false;
      if (filterType !== "all" && r.manual_type !== filterType) return false;
      if (!q) return true;
      const hay = `${r.title || ""} ${r.content || ""} ${r.notes || ""}`.toLowerCase();
      return hay.includes(q);
    });
  }, [rows, filterType, searchQ, showArchived]);

  // Group rows by manual_type for section headers
  const groupedRows = useMemo(() => {
    const groups = new Map();
    for (const r of filteredRows) {
      if (!groups.has(r.manual_type)) groups.set(r.manual_type, []);
      groups.get(r.manual_type).push(r);
    }
    return groups;
  }, [filteredRows]);

  // Selected row → derive draft
  useEffect(() => {
    if (selectedId === "__new__") {
      setDraft(BLANK_ROW());
      setDirty(false);
      return;
    }
    const row = rows.find(r => r.id === selectedId);
    if (row) {
      setDraft({ ...row });
      setDirty(false);
    } else {
      setDraft(null);
    }
  }, [selectedId, rows]);

  const updateField = (field, value) => {
    setDraft(d => ({ ...d, [field]: value }));
    setDirty(true);
    setSaveMsg(null);
  };

  const handleSave = async () => {
    if (!draft) return;
    if (!draft.title?.trim()) { setSaveMsg({ kind: "error", text: "Title is required." }); return; }
    if (!draft.manual_type) { setSaveMsg({ kind: "error", text: "Manual type is required." }); return; }

    setSaving(true);
    setSaveMsg(null);
    try {
      const isNew = !draft.id;
      const payload = {
        agency_id: AGENCY_ID,
        manual_type: draft.manual_type,
        title: draft.title.trim(),
        content: draft.content ?? "",
        content_format: draft.content_format || "markdown",
        notes: draft.notes || null,
        icon: draft.icon || null,
        sort_order: Number.isFinite(Number(draft.sort_order)) ? Number(draft.sort_order) : 0,
        parent_page_id: draft.parent_page_id || null,
        tree_root: draft.tree_root || null,
        source_url: draft.source_url || null,
        confluence_page_id: draft.confluence_page_id || null,
        is_active: true,
        version: isNew ? 1 : (Number(draft.version) || 0) + 1,
        updated_at: new Date().toISOString(),
      };

      let result;
      if (isNew) {
        result = await supabase.from("manuals").insert(payload).select().single();
      } else {
        result = await supabase.from("manuals").update(payload).eq("id", draft.id).select().single();
      }
      if (result.error) throw result.error;
      const saved = result.data;

      // Update local rows list
      setRows(prev => {
        const without = prev.filter(r => r.id !== saved.id);
        return [...without, saved];
      });
      setSelectedId(saved.id);
      setDirty(false);
      setSaveMsg({ kind: "success", text: isNew ? "Created." : "Saved." });
    } catch (ex) {
      setSaveMsg({ kind: "error", text: ex?.message || "Save failed." });
    } finally {
      setSaving(false);
    }
  };

  const handleArchive = async () => {
    if (!draft?.id) return;
    if (!confirm(`Archive "${draft.title}"? It will hide from all readers. Restore later with SQL.`)) return;
    setSaving(true);
    setSaveMsg(null);
    try {
      const { data, error: e } = await supabase
        .from("manuals")
        .update({ is_active: false, archived_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("id", draft.id)
        .select()
        .single();
      if (e) throw e;
      setRows(prev => prev.map(r => r.id === data.id ? data : r));
      setDraft(data);
      setDirty(false);
      setSaveMsg({ kind: "success", text: "Archived." });
    } catch (ex) {
      setSaveMsg({ kind: "error", text: ex?.message || "Archive failed." });
    } finally {
      setSaving(false);
    }
  };

  const handleRestore = async () => {
    if (!draft?.id) return;
    setSaving(true);
    setSaveMsg(null);
    try {
      const { data, error: e } = await supabase
        .from("manuals")
        .update({ is_active: true, archived_at: null, updated_at: new Date().toISOString() })
        .eq("id", draft.id)
        .select()
        .single();
      if (e) throw e;
      setRows(prev => prev.map(r => r.id === data.id ? data : r));
      setDraft(data);
      setDirty(false);
      setSaveMsg({ kind: "success", text: "Restored." });
    } catch (ex) {
      setSaveMsg({ kind: "error", text: ex?.message || "Restore failed." });
    } finally {
      setSaving(false);
    }
  };

  const handleDiscard = () => {
    if (selectedId === "__new__") { setSelectedId(null); return; }
    const row = rows.find(r => r.id === selectedId);
    if (row) { setDraft({ ...row }); setDirty(false); setSaveMsg(null); }
  };

  const pickRow = (id) => {
    if (dirty && !confirm("You have unsaved changes. Discard and switch?")) return;
    setSelectedId(id);
    setSaveMsg(null);
    if (isPhone) setDrawerOpen(false);
  };

  // ── List panel ─────────────────────────────────────────────
  const listPanel = (
    <div style={s.listCol}>
      {loading && <div style={{ padding: 16, fontSize: 13, color: T.slate500 }}>Loading…</div>}
      {!loading && filteredRows.length === 0 && (
        <div style={{ padding: 16, fontSize: 13, color: T.slate500 }}>
          No pages match. Try a different filter or search.
        </div>
      )}
      {[...groupedRows.entries()].map(([type, list]) => {
        const meta = typeById[type] || { label: type, tint: T.slate600 };
        return (
          <div key={type}>
            <div style={{
              padding: "10px 14px 6px", fontSize: 10, fontWeight: 700,
              textTransform: "uppercase", letterSpacing: "0.05em", color: meta.tint,
              background: T.slate50, borderBottom: `1px solid ${T.slate100}`,
              position: "sticky", top: 0, zIndex: 1,
            }}>
              {meta.label} <span style={{ color: T.slate400, fontWeight: 500 }}>({list.length})</span>
            </div>
            {list.map(r => (
              <div key={r.id} style={s.listItem(r.id === selectedId)} onClick={() => pickRow(r.id)}>
                <div style={s.listItemTitle}>{r.title || "(untitled)"}</div>
                <div style={s.listItemMeta}>
                  <span>v{r.version || 1}</span>
                  {r.sort_order != null && <span>· #{r.sort_order}</span>}
                  {r.parent_page_id && <span>· nested</span>}
                  {!r.is_active && <span style={{ color: T.red }}>· archived</span>}
                </div>
              </div>
            ))}
          </div>
        );
      })}
    </div>
  );

  return (
    <div style={s.page}>
      {/* ── Header ── */}
      <div style={s.headerBar}>
        {isPhone && (
          <button type="button" style={s.ghostBtn} onClick={() => setDrawerOpen(true)}>☰ List</button>
        )}
        <div style={s.headerTitle}>Content Editor</div>

        <select
          style={s.filterSelect}
          value={filterType}
          onChange={(e) => setFilterType(e.target.value)}
        >
          <option value="all">All manuals</option>
          {MANUAL_TYPES.map(t => (
            <option key={t.id} value={t.id}>{t.label}</option>
          ))}
        </select>

        <input
          type="text"
          placeholder="Search title, content, notes…"
          style={s.searchInput}
          value={searchQ}
          onChange={(e) => setSearchQ(e.target.value)}
        />

        <label style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 12, color: T.slate600 }}>
          <input
            type="checkbox"
            checked={showArchived}
            onChange={(e) => setShowArchived(e.target.checked)}
          />
          Archived
        </label>

        <button type="button" style={s.primaryBtn} onClick={() => { setSelectedId("__new__"); setSaveMsg(null); }}>
          + New page
        </button>
      </div>

      {/* ── Body ── */}
      <div style={s.body}>
        {/* List — permanent on desktop, drawer on phone */}
        {!isPhone && listPanel}
        {isPhone && drawerOpen && (
          <>
            <div style={s.drawerBackdrop} onClick={() => setDrawerOpen(false)} />
            <div style={s.drawerPanel(drawerOpen)}>{listPanel}</div>
          </>
        )}

        {/* Editor */}
        <div style={s.editorCol}>
          {error && <div style={s.errorBanner}>{error}</div>}
          {!draft && (
            <div style={s.emptyState}>
              <div style={{ fontSize: 32, marginBottom: 12 }}>✏️</div>
              <div style={{ fontSize: 15, fontWeight: 600, color: T.slate700, marginBottom: 4 }}>
                Select a page or create a new one
              </div>
              <div style={{ fontSize: 13 }}>
                Filter by manual type on the left, search by title, or click New page above.
              </div>
            </div>
          )}
          {draft && <EditorPane
            draft={draft}
            rows={rows}
            saving={saving}
            dirty={dirty}
            saveMsg={saveMsg}
            onField={updateField}
            onSave={handleSave}
            onDiscard={handleDiscard}
            onArchive={handleArchive}
            onRestore={handleRestore}
            isPhone={isPhone}
          />}
        </div>
      </div>
    </div>
  );
}

// ─── Editor pane (form + preview) ──────────────────────────
function EditorPane({ draft, rows, saving, dirty, saveMsg, onField, onSave, onDiscard, onArchive, onRestore, isPhone }) {
  const [showPreview, setShowPreview] = useState(true);

  // Parent options: same manual_type, not the current row
  const parentOptions = useMemo(() => {
    return rows
      .filter(r => r.manual_type === draft.manual_type && r.id !== draft.id && r.is_active)
      .sort((a, b) => (a.title || "").localeCompare(b.title || ""));
  }, [rows, draft.manual_type, draft.id]);

  // Resolvers for preview — same-manual for include, all excerpts for excerpt
  const includeLookup = useMemo(
    () => buildIncludeLookup(rows.filter(r => r.manual_type === draft.manual_type && r.is_active)),
    [rows, draft.manual_type]
  );
  const excerptLookup = useMemo(
    () => buildExcerptLookup(rows.filter(r => r.manual_type === "excerpt" && r.is_active)),
    [rows]
  );
  const resolveInclude = useMemo(() => makeIncludeResolver(includeLookup), [includeLookup]);
  const resolveExcerpt = useMemo(() => makeExcerptResolver(excerptLookup), [excerptLookup]);

  const previewHtml = useMemo(
    () => mdToHtml(draft.content || "", { resolveInclude, resolveExcerpt }),
    [draft.content, resolveInclude, resolveExcerpt]
  );

  const isArchived = !draft.is_active || draft.archived_at;

  return (
    <div>
      {/* Save-status banner */}
      {saveMsg && (
        <div style={saveMsg.kind === "success" ? s.successBanner : s.errorBanner}>
          {saveMsg.text}
        </div>
      )}

      {/* Header row: id + version + action buttons */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: 8, marginBottom: 16 }}>
        <div style={{ fontSize: 12, color: T.slate500 }}>
          {draft.id ? (
            <>
              <span>id: <code style={{ fontFamily: "ui-monospace, monospace", fontSize: 11 }}>{draft.id.slice(0, 8)}</code></span>
              <span style={{ margin: "0 8px" }}>·</span>
              <span>v{draft.version || 1}</span>
              {isArchived && <span style={{ marginLeft: 8, color: T.red, fontWeight: 600 }}>ARCHIVED</span>}
            </>
          ) : <span>New page (unsaved)</span>}
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          {dirty && <button type="button" style={s.ghostBtn} onClick={onDiscard} disabled={saving}>Discard</button>}
          {draft.id && !isArchived && (
            <button type="button" style={s.dangerBtn} onClick={onArchive} disabled={saving}>Archive</button>
          )}
          {draft.id && isArchived && (
            <button type="button" style={s.ghostBtn} onClick={onRestore} disabled={saving}>Restore</button>
          )}
          <button type="button" style={s.primaryBtn} onClick={onSave} disabled={saving || !dirty}>
            {saving ? "Saving…" : draft.id ? "Save" : "Create"}
          </button>
        </div>
      </div>

      {/* Title */}
      <div style={s.field}>
        <label style={s.fieldLabel}>Title</label>
        <input
          type="text"
          style={s.input}
          value={draft.title || ""}
          onChange={(e) => onField("title", e.target.value)}
          placeholder="Page title"
        />
      </div>

      {/* Manual type + sort_order + icon in a row */}
      <div style={s.fieldRow}>
        <div style={{ ...s.field, flex: 1, minWidth: 160 }}>
          <label style={s.fieldLabel}>Manual type</label>
          <select
            style={s.input}
            value={draft.manual_type || "handbook"}
            onChange={(e) => onField("manual_type", e.target.value)}
          >
            {MANUAL_TYPES.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
          </select>
        </div>
        <div style={{ ...s.field, width: 120 }}>
          <label style={s.fieldLabel}>Sort order</label>
          <input
            type="number"
            style={s.input}
            value={draft.sort_order ?? 0}
            onChange={(e) => onField("sort_order", e.target.value)}
          />
        </div>
        <div style={{ ...s.field, width: 100 }}>
          <label style={s.fieldLabel}>Icon (emoji)</label>
          <input
            type="text"
            style={s.input}
            value={draft.icon || ""}
            onChange={(e) => onField("icon", e.target.value)}
            placeholder="e.g. 📘"
          />
        </div>
      </div>

      {/* Parent + tree root */}
      <div style={s.fieldRow}>
        <div style={{ ...s.field, flex: 1, minWidth: 200 }}>
          <label style={s.fieldLabel}>Parent page (same manual)</label>
          <select
            style={s.input}
            value={draft.parent_page_id || ""}
            onChange={(e) => onField("parent_page_id", e.target.value || null)}
          >
            <option value="">— top level —</option>
            {parentOptions.map(p => (
              <option key={p.id} value={p.confluence_page_id || p.id}>
                {p.title}
              </option>
            ))}
          </select>
        </div>
        <div style={{ ...s.field, flex: 1, minWidth: 160 }}>
          <label style={s.fieldLabel}>Tree root</label>
          <input
            type="text"
            style={s.input}
            value={draft.tree_root || ""}
            onChange={(e) => onField("tree_root", e.target.value || null)}
            placeholder="e.g. Checklists"
          />
        </div>
      </div>

      {/* Content */}
      <div style={s.field}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <label style={s.fieldLabel}>Content (markdown)</label>
          <label style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 12, color: T.slate600 }}>
            <input
              type="checkbox"
              checked={showPreview}
              onChange={(e) => setShowPreview(e.target.checked)}
            />
            Live preview
          </label>
        </div>
        <textarea
          style={s.textarea}
          value={draft.content || ""}
          onChange={(e) => onField("content", e.target.value)}
          placeholder="Markdown content. Use [Included from: X] to transclude another page, [Embedded excerpt from: X] to pull a named fragment."
        />
      </div>

      {/* Notes */}
      <div style={s.field}>
        <label style={s.fieldLabel}>Notes (internal, not shown to readers)</label>
        <textarea
          style={{ ...s.textarea, minHeight: 60, fontFamily: "inherit" }}
          value={draft.notes || ""}
          onChange={(e) => onField("notes", e.target.value)}
          placeholder="Internal notes about this page — history, deprecation reasons, TODOs."
        />
      </div>

      {/* Preview */}
      {showPreview && (
        <div style={s.previewPane}>
          <div style={s.previewLabel}>Preview (with includes + excerpts resolved)</div>
          <div style={s.previewBody} dangerouslySetInnerHTML={{ __html: previewHtml }} />
        </div>
      )}
    </div>
  );
}
