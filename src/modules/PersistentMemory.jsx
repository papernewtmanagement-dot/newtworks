import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// ============================================================
// BCC PERSISTENT MEMORY MODULE v1.0
// Business Command Center — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// PURPOSE:
// The agency brain. Everything Claude needs to know about
// this business lives here. Editable by owner or Claude.
// Categories mirror persistent_memory table in Supabase.
//
// CATEGORIES (rendered dynamically from data):
// The sidebar populates from whatever categories the persistent_memory table contains.


// ─── Design Tokens ────────────────────────────────────────────
const T = {
  navy:    "#1B2B4B",
  blue:    "#2D7DD2",
  blueLt:  "#EFF6FF",
  green:   "#10B981",
  greenLt: "#D1FAE5",
  amber:   "#F59E0B",
  amberLt: "#FEF3C7",
  red:     "#EF4444",
  redLt:   "#FEE2E2",
  purple:  "#7C3AED",
  purpleLt:"#EDE9FE",
  teal:    "#0D9488",
  tealLt:  "#CCFBF1",
  slate50: "#F8FAFC",
  slate100:"#F1F5F9",
  slate200:"#E2E8F0",
  slate300:"#CBD5E1",
  slate400:"#94A3B8",
  slate500:"#64748B",
  slate600:"#475569",
  slate700:"#334155",
  slate800:"#1E293B",
  slate900:"#0F172A",
  white:   "#FFFFFF",
};

// ─── Category Metadata ────────────────────────────────────────
// Visual config per known category. The sidebar is built dynamically from
// whatever categories actually exist in the persistent_memory table — any
// category not in this map gets DEFAULT_CATEGORY_META styling.
const CATEGORY_META = {
  agency_profile:    { label: "Agency Profile",    icon: "ð¢", color: "#3B82F6", colorLt: "#DBEAFE", description: "Entity details, licensing, contact information",          order: 1 },
  business_context:  { label: "Business Context",  icon: "ð§­", color: "#0EA5E9", colorLt: "#E0F2FE", description: "Who the agent is and how the business operates",          order: 2 },
  accounting_rules:  { label: "Accounting Rules",  icon: "ð", color: "#10B981", colorLt: "#D1FAE5", description: "Cash-basis rules, two-entity convention, GL conventions",  order: 3 },
  financial_context: { label: "Financial Context", icon: "ð°", color: "#10B981", colorLt: "#D1FAE5", description: "Accounting setup, CPA details, compensation structure",   order: 4 },
  business_rules:    { label: "Business Rules",    icon: "⚙️", color: "#1E3A8A", colorLt: "#F1F5F9", description: "Rules Claude must always follow in every conversation",   order: 5 },
  staff:             { label: "Staff & Team",      icon: "ð¥", color: "#A855F7", colorLt: "#FAF5FF", description: "Team members, roles, employment details",                 order: 6 },
  goals:             { label: "Goals & Priorities",icon: "ð¯", color: "#F59E0B", colorLt: "#FEF3C7", description: "Current targets, priorities, milestones",                 order: 7 },
  relationships:     { label: "Key Relationships", icon: "ð¤", color: "#14B8A6", colorLt: "#CCFBF1", description: "CPA, vendors, SF contacts, key business relationships",   order: 8 },
  compliance_notes:  { label: "Compliance Notes",  icon: "ð¡️", color: "#EF4444", colorLt: "#FEE2E2", description: "Agency-specific compliance reminders and notes",          order: 9 },
  session_note:      { label: "Session Notes",     icon: "ð", color: "#64748B", colorLt: "#F1F5F9", description: "Working notes Claude wrote at the end of past sessions",  order: 99 },
};
const DEFAULT_CATEGORY_META = { label: null, icon: "ð", color: "#64748B", colorLt: "#F1F5F9", description: "", order: 50 };
const metaFor = (id) => {
  const m = CATEGORY_META[id] || DEFAULT_CATEGORY_META;
  return { ...m, label: m.label || (id || "").replace(/_/g," ").replace(/\b\w/g, c => c.toUpperCase()) };
};
const ALL_CATEGORIES = Object.entries(CATEGORY_META)
  .map(([id, m]) => ({ id, ...m }))
  .sort((a, b) => (a.order || 50) - (b.order || 50));

// ─── Shared Components ────────────────────────────────────────
const AskBtn = ({ context, size = "normal" }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context); window.open("https://claude.ai","_blank"); }}
    style={{
      display: "flex", alignItems: "center", gap: 5,
      background: T.blue, color: T.white,
      border: "none", borderRadius: 7,
      padding: size === "small" ? "5px 10px" : "7px 13px",
      fontSize: size === "small" ? 10 : 11,
      fontWeight: 600, cursor: "pointer", whiteSpace: "nowrap",
    }}
  >⚡ Ask Claude</button>
);

// ─── Memory Card ──────────────────────────────────────────────
const MemoryCard = ({ item, categoryConfig, onEdit }) => {
  const [expanded, setExpanded] = useState(false);
  const lines = item.content.split("\n").filter(Boolean);
  const preview = lines.slice(0, 3).join("\n");
  const hasMore = lines.length > 3;

  return (
    <div style={{
      background: T.white,
      border: `1px solid ${T.slate200}`,
      borderRadius: 12,
      overflow: "hidden",
      borderLeft: `4px solid ${categoryConfig.color}`,
    }}>
      {/* Card Header */}
      <div style={{
        padding: "12px 14px",
        display: "flex", alignItems: "flex-start",
        justifyContent: "space-between", gap: 8,
      }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800, marginBottom: 2 }}>
            {item.title}
          </div>
          <div style={{ fontSize: 10, color: T.slate400 }}>
            Added by {item.added_by} · {item.source.replace(/_/g," ")}
          </div>
        </div>
        <div style={{ display: "flex", gap: 6, flexShrink: 0 }}>
          <AskBtn size="small" context={`Memory context — ${item.title}:\n\n${item.content}\n\nHelp me review and update this information if needed.`} />
          <button
            onClick={() => onEdit(item)}
            style={{
              padding: "5px 10px", fontSize: 10, fontWeight: 600,
              color: T.slate600, background: T.slate100,
              border: `1px solid ${T.slate200}`,
              borderRadius: 6, cursor: "pointer",
            }}
          >Edit</button>
        </div>
      </div>

      {/* Content */}
      <div style={{
        padding: "0 14px 12px",
        fontSize: 12, color: T.slate700,
        lineHeight: 1.7,
        whiteSpace: "pre-line",
      }}>
        {expanded ? item.content : preview}
        {hasMore && (
          <button
            onClick={() => setExpanded(e => !e)}
            style={{
              display: "block", marginTop: 6,
              fontSize: 11, color: T.blue,
              background: "none", border: "none",
              cursor: "pointer", padding: 0, fontWeight: 500,
            }}
          >
            {expanded ? "Show less ↑" : `Show more (${lines.length - 3} more lines) ↓`}
          </button>
        )}
      </div>
    </div>
  );
};

// ─── Edit Modal ───────────────────────────────────────────────
const EditModal = ({ item, categories, onSave, onCancel, onDelete }) => {
  const [title,    setTitle]    = useState(item?.title   || "");
  const [content,  setContent]  = useState(item?.content || "");
  const [category, setCategory] = useState(item?.category || "business_rules");
  const isNew = !item?.id;

  return (
    <div style={{
      position: "fixed", inset: 0,
      background: "rgba(15,23,42,0.5)",
      display: "flex", alignItems: "center",
      justifyContent: "center", zIndex: 1000,
      padding: 20,
    }}>
      <div style={{
        background: T.white, borderRadius: 16,
        width: "100%", maxWidth: 560,
        boxShadow: "0 20px 60px rgba(0,0,0,0.2)",
        overflow: "hidden",
      }}>
        {/* Modal Header */}
        <div style={{
          padding: "16px 20px",
          borderBottom: `1px solid ${T.slate200}`,
          display: "flex", justifyContent: "space-between", alignItems: "center",
        }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
            {isNew ? "Add Memory" : "Edit Memory"}
          </div>
          <button onClick={onCancel} style={{
            background: "none", border: "none",
            fontSize: 18, color: T.slate400,
            cursor: "pointer", lineHeight: 1,
          }}>×</button>
        </div>

        {/* Modal Body */}
        <div style={{ padding: "20px" }}>
          {/* Category */}
          <div style={{ marginBottom: 14 }}>
            <label style={{ fontSize: 11, fontWeight: 600, color: T.slate600, display: "block", marginBottom: 6 }}>
              CATEGORY
            </label>
            <select
              value={category}
              onChange={e => setCategory(e.target.value)}
              style={{
                width: "100%", padding: "8px 10px",
                fontSize: 12, color: T.slate800,
                background: T.white,
                border: `1px solid ${T.slate200}`,
                borderRadius: 8, outline: "none",
              }}
            >
              {categories.map(c => (
                <option key={c.id} value={c.id}>{c.icon} {c.label}</option>
              ))}
            </select>
          </div>

          {/* Title */}
          <div style={{ marginBottom: 14 }}>
            <label style={{ fontSize: 11, fontWeight: 600, color: T.slate600, display: "block", marginBottom: 6 }}>
              TITLE
            </label>
            <input
              value={title}
              onChange={e => setTitle(e.target.value)}
              placeholder="Short descriptive title..."
              style={{
                width: "100%", padding: "8px 10px",
                fontSize: 12, color: T.slate800,
                border: `1px solid ${T.slate200}`,
                borderRadius: 8, outline: "none",
                boxSizing: "border-box",
              }}
            />
          </div>

          {/* Content */}
          <div style={{ marginBottom: 6 }}>
            <label style={{ fontSize: 11, fontWeight: 600, color: T.slate600, display: "block", marginBottom: 6 }}>
              CONTENT
            </label>
            <textarea
              value={content}
              onChange={e => setContent(e.target.value)}
              placeholder="Enter the information Claude should remember..."
              rows={8}
              style={{
                width: "100%", padding: "10px",
                fontSize: 12, color: T.slate800,
                border: `1px solid ${T.slate200}`,
                borderRadius: 8, outline: "none",
                resize: "vertical", lineHeight: 1.6,
                fontFamily: "inherit",
                boxSizing: "border-box",
              }}
            />
          </div>
          <div style={{ fontSize: 10, color: T.slate400, marginBottom: 16 }}>
            Claude reads this in every conversation. Be specific and complete.
          </div>
        </div>

        {/* Modal Footer */}
        <div style={{
          padding: "12px 20px",
          borderTop: `1px solid ${T.slate200}`,
          display: "flex", justifyContent: "space-between", alignItems: "center",
        }}>
          <div>
            {!isNew && (
              <button
                onClick={() => onDelete(item.id)}
                style={{
                  padding: "7px 14px", fontSize: 11, fontWeight: 600,
                  color: T.red, background: T.redLt,
                  border: "none", borderRadius: 7, cursor: "pointer",
                }}
              >Delete</button>
            )}
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            <button
              onClick={onCancel}
              style={{
                padding: "7px 14px", fontSize: 11, fontWeight: 600,
                color: T.slate600, background: T.slate100,
                border: "none", borderRadius: 7, cursor: "pointer",
              }}
            >Cancel</button>
            <button
              onClick={() => onSave({ ...item, title, content, category })}
              disabled={!title.trim() || !content.trim()}
              style={{
                padding: "7px 16px", fontSize: 11, fontWeight: 600,
                color: T.white, background: T.navy,
                border: "none", borderRadius: 7, cursor: "pointer",
                opacity: (!title.trim() || !content.trim()) ? 0.5 : 1,
              }}
            >Save Memory</button>
          </div>
        </div>
      </div>
    </div>
  );
};

// ─── Category Sidebar ─────────────────────────────────────────
const CategorySidebar = ({ categories, activeCategory, counts, onChange }) => (
  <div style={{
    width: 200, flexShrink: 0,
    display: "flex", flexDirection: "column", gap: 4,
  }}>
    <button
      onClick={() => onChange("all")}
      style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        padding: "9px 12px", borderRadius: 8, cursor: "pointer",
        background: activeCategory === "all" ? T.navy : "transparent",
        border: `1px solid ${activeCategory === "all" ? T.navy : T.slate200}`,
        fontSize: 12, fontWeight: activeCategory === "all" ? 600 : 400,
        color: activeCategory === "all" ? T.white : T.slate600,
        textAlign: "left",
      }}
    >
      <span>All Memories</span>
      <span style={{
        fontSize: 10, fontWeight: 700,
        background: activeCategory === "all" ? "rgba(255,255,255,0.2)" : T.slate200,
        color: activeCategory === "all" ? T.white : T.slate600,
        borderRadius: 10, padding: "1px 7px",
      }}>{counts.all}</span>
    </button>

    {categories.map(cat => {
      const active = activeCategory === cat.id;
      return (
        <button
          key={cat.id}
          onClick={() => onChange(cat.id)}
          style={{
            display: "flex", alignItems: "center", justifyContent: "space-between",
            padding: "9px 12px", borderRadius: 8, cursor: "pointer",
            background: active ? cat.colorLt : "transparent",
            border: `1px solid ${active ? cat.color : T.slate200}`,
            fontSize: 12, fontWeight: active ? 600 : 400,
            color: active ? cat.color : T.slate600,
            textAlign: "left",
          }}
        >
          <span style={{ display: "flex", alignItems: "center", gap: 7 }}>
            <span style={{ fontSize: 14 }}>{cat.icon}</span>
            <span>{cat.label}</span>
          </span>
          <span style={{
            fontSize: 10, fontWeight: 600,
            background: active ? cat.color : T.slate100,
            color: active ? T.white : T.slate500,
            borderRadius: 10, padding: "1px 7px",
          }}>{counts[cat.id] || 0}</span>
        </button>
      );
    })}
  </div>
);

// ─── Main Module ──────────────────────────────────────────────
export default function PersistentMemory() {
  const [memories,        setMemories]        = useState([]);
  const [loading,         setLoading]          = useState(true);
  const [saveError,       setSaveError]        = useState(null);
  const [activeCategory,  setActiveCategory]  = useState("all");
  const [editingItem,     setEditingItem]      = useState(null);
  const [showNewModal,    setShowNewModal]     = useState(false);
  const [searchQuery,     setSearchQuery]      = useState("");

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!supabase || !AGENCY_ID) { setLoading(false); return; }
      try {
        const { data, error } = await supabase
          .from("persistent_memory")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .order("updated_at", { ascending: false });
        if (cancelled) return;
        if (error) console.error("[PersistentMemory] load error:", error);
        setMemories(data || []);
      } catch (e) {
        if (!cancelled) console.error("[PersistentMemory] load exception:", e);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, []);

  const activeMemories = useMemo(
    () => (memories || []).filter(m => m.is_active !== false),
    [memories]
  );

  const categories = useMemo(() => {
    const present = Array.from(new Set(activeMemories.map(m => m.category).filter(Boolean)));
    return present
      .map(id => ({ id, ...metaFor(id) }))
      .sort((a, b) => (a.order || 50) - (b.order || 50) || a.label.localeCompare(b.label));
  }, [activeMemories]);

  const counts = useMemo(() => ({
    all: activeMemories.length,
    ...Object.fromEntries(
      categories.map(c => [c.id, activeMemories.filter(m => m.category === c.id).length])
    ),
  }), [activeMemories, categories]);

  const filtered = useMemo(() => activeMemories.filter(m => {
    if (activeCategory !== "all" && m.category !== activeCategory) return false;
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      return (m.title || "").toLowerCase().includes(q) || (m.content || "").toLowerCase().includes(q);
    }
    return true;
  }), [activeMemories, activeCategory, searchQuery]);

  const grouped = useMemo(() => categories.reduce((acc, cat) => {
    const items = filtered.filter(m => m.category === cat.id);
    if (items.length) acc[cat.id] = items;
    return acc;
  }, {}), [filtered, categories]);

  const handleSave = async (item) => {
    setSaveError(null);
    if (!supabase || !AGENCY_ID) { setSaveError("Supabase not configured"); return; }
    if (item.id && !String(item.id).startsWith("pending-")) {
      const { data, error } = await supabase
        .from("persistent_memory")
        .update({
          category: item.category,
          title:    item.title,
          content:  item.content,
          updated_at: new Date().toISOString(),
        })
        .eq("id", item.id)
        .eq("agency_id", AGENCY_ID)
        .select()
        .maybeSingle();
      if (error) { setSaveError(error.message); return; }
      setMemories(prev => prev.map(m => m.id === item.id ? (data || { ...m, ...item }) : m));
    } else {
      const { data, error } = await supabase
        .from("persistent_memory")
        .insert([{
          agency_id: AGENCY_ID,
          category: item.category,
          title:    item.title,
          content:  item.content,
          added_by: "agent_ui",
          source:   "manual",
          is_active: true,
        }])
        .select()
        .maybeSingle();
      if (error) { setSaveError(error.message); return; }
      if (data) setMemories(prev => [data, ...prev]);
    }
    setEditingItem(null);
    setShowNewModal(false);
  };

  const handleDelete = async (id) => {
    setSaveError(null);
    if (!supabase || !AGENCY_ID || !id) return;
    const { error } = await supabase
      .from("persistent_memory")
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq("id", id)
      .eq("agency_id", AGENCY_ID);
    if (error) { setSaveError(error.message); return; }
    setMemories(prev => prev.map(m => m.id === id ? { ...m, is_active: false } : m));
    setEditingItem(null);
  };

  const allContext = memories
    .filter(m => m.is_active !== false)
    .map(m => `[${m.title}]\n${m.content}`)
    .join("\n\n---\n\n");

  return (
    <div>
      {/* Module Header */}
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 16 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>
            Persistent Memory
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 3 }}>
            {counts.all} memory entries · Claude reads all of these in every conversation
          </div>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <AskBtn
            context={`Here is my complete agency memory context — everything I want you to know about my business:\n\n${allContext}\n\nPlease review this and tell me: (1) Is anything missing? (2) Is anything outdated? (3) Are there any inconsistencies you notice?`}
          />
          <button
            onClick={() => setShowNewModal(true)}
            style={{
              display: "flex", alignItems: "center", gap: 6,
              background: T.navy, color: T.white,
              border: "none", borderRadius: 8,
              padding: "8px 16px", fontSize: 12, fontWeight: 600,
              cursor: "pointer",
            }}
          >+ Add Memory</button>
        </div>
      </div>

      {/* How Claude Uses This — Info Banner */}
      <div style={{
        background: T.blueLt,
        border: `1px solid ${T.blue}20`,
        borderLeft: `4px solid ${T.blue}`,
        borderRadius: 10, padding: "12px 16px",
        marginBottom: 20,
        display: "flex", alignItems: "flex-start", gap: 12,
      }}>
        <span style={{ fontSize: 20, flexShrink: 0 }}>ð¡</span>
        <div>
          <div style={{ fontSize: 12, fontWeight: 600, color: T.navy, marginBottom: 3 }}>
            How Claude uses this memory
          </div>
          <div style={{ fontSize: 11, color: T.slate600, lineHeight: 1.6 }}>
            Every entry here is passed to Claude as context at the start of each conversation. Claude uses it to give you answers that are specific to your agency — not generic advice. The more complete and accurate this memory is, the more useful your Claude becomes. You and Claude can both add, edit, and update these entries at any time.
          </div>
        </div>
      </div>

      {saveError && (
        <div style={{ marginBottom: 12, padding: "10px 14px", background: "#FEE2E2", border: "1px solid #FCA5A5", borderRadius: 8, fontSize: 12, color: "#991B1B" }}>
          Could not save: {saveError}
        </div>
      )}

      {loading && (
        <div style={{ padding: 40, textAlign: "center", fontSize: 13, color: T.slate500 }}>
          Loading memory entries…
        </div>
      )}

      {/* Search */}
      <div style={{ marginBottom: 16, display: loading ? "none" : "block" }}>
        <input
          value={searchQuery}
          onChange={e => setSearchQuery(e.target.value)}
          placeholder="Search memories..."
          style={{
            width: "100%", padding: "9px 14px",
            fontSize: 12, color: T.slate800,
            border: `1px solid ${T.slate200}`,
            borderRadius: 9, outline: "none",
            boxSizing: "border-box",
            background: T.white,
          }}
        />
      </div>

      {/* Body — Sidebar + Cards */}
      {!loading && (
      <div style={{ display: "flex", gap: 16, alignItems: "flex-start" }}>

        {/* Category Sidebar */}
        <CategorySidebar
          categories={categories}
          activeCategory={activeCategory}
          counts={counts}
          onChange={setActiveCategory}
        />

        {/* Memory Cards */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 20 }}>
          {filtered.length === 0 && (
            <div style={{
              textAlign: "center", padding: "40px 20px",
              color: T.slate400, fontSize: 13,
            }}>
              {searchQuery ? `No memories match "${searchQuery}"` : "No memories in this category yet."}
            </div>
          )}

          {activeCategory === "all"
            ? categories.map(cat => {
                const items = grouped[cat.id];
                if (!items?.length) return null;
                return (
                  <div key={cat.id}>
                    {/* Category Group Header */}
                    <div style={{
                      display: "flex", alignItems: "center", gap: 8,
                      marginBottom: 10,
                    }}>
                      <span style={{ fontSize: 16 }}>{cat.icon}</span>
                      <span style={{ fontSize: 13, fontWeight: 700, color: T.slate700 }}>{cat.label}</span>
                      <div style={{ flex: 1, height: 1, background: T.slate200, marginLeft: 4 }} />
                      <span style={{ fontSize: 11, color: T.slate400 }}>{items.length} {items.length === 1 ? "entry" : "entries"}</span>
                    </div>
                    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                      {items.map(item => (
                        <MemoryCard
                          key={item.id}
                          item={item}
                          categoryConfig={cat}
                          onEdit={setEditingItem}
                        />
                      ))}
                    </div>
                  </div>
                );
              })
            : (() => {
                const cat = categories.find(c => c.id === activeCategory);
                return (
                  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                    {filtered.map(item => (
                      <MemoryCard
                        key={item.id}
                        item={item}
                        categoryConfig={cat}
                        onEdit={setEditingItem}
                      />
                    ))}
                  </div>
                );
              })()
          }
        </div>
      </div>
      )}

      {/* Edit Modal */}
      {(editingItem || showNewModal) && (
        <EditModal
          item={editingItem}
          categories={ALL_CATEGORIES}
          onSave={handleSave}
          onCancel={() => { setEditingItem(null); setShowNewModal(false); }}
          onDelete={handleDelete}
        />
      )}
    </div>
  );
}
