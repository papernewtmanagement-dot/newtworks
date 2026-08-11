import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { useTabParam } from "../lib/routing.jsx";

// ============================================================
// Newtworks TRIVIA MODULE — Wave 2 Block A (admin only)
//
// SCOPE: review/approve/retire quiz items, browse approved items,
// work the bad-question report queue, and switch a manual-page read
// to the resolved FAQ view. No play screens, no gate, no question
// writing here — the planning thread authors items separately.
//
// Three tabs: Review (draft items), Approved (live items), Reports
// (open bad-question reports). Card-based layout throughout.
// ============================================================

const s = {
  page: { display: "flex", flexDirection: "column", height: "100%", background: T.slate50 },
  headerBar: {
    display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap",
    padding: "12px 16px", background: T.chromeBg,
    borderBottom: `1px solid ${T.chromeBorder}`,
  },
  headerTitle: { fontSize: 15, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em" },
  tabBar: {
    display: "flex", gap: 4, overflowX: "auto", whiteSpace: "nowrap",
    padding: "8px 16px", background: T.white, borderBottom: `1px solid ${T.slate200}`,
  },
  tabBtn: (active) => ({
    flexShrink: 0, padding: "6px 14px", fontSize: 13, fontWeight: 600, cursor: "pointer",
    background: active ? T.blueLt : "transparent", color: active ? T.blue : T.slate600,
    border: "none", borderRadius: 6,
  }),
  badge: {
    marginLeft: 6, fontSize: 10, fontWeight: 700, padding: "1px 6px", borderRadius: 10,
    background: T.red, color: "#fff",
  },
  body: { flex: 1, overflowY: "auto", padding: 16 },
  searchInput: {
    padding: "6px 10px", fontSize: 13, minWidth: 220, flex: 1, maxWidth: 360,
    background: "#fff", border: `1px solid ${T.slate300}`,
    borderRadius: 6, color: T.slate800, fontFamily: "inherit",
  },
  groupHeader: {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    gap: 8, flexWrap: "wrap", padding: "12px 4px 6px",
  },
  groupTitle: {
    fontSize: 12, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.05em",
    color: T.slate600,
  },
  card: {
    background: "#fff", border: `1px solid ${T.slate200}`, borderRadius: 8,
    padding: 14, marginBottom: 10,
  },
  stem: { fontSize: 14, fontWeight: 600, color: T.slate900, marginBottom: 8, lineHeight: 1.4 },
  optionRow: (correct) => ({
    display: "flex", alignItems: "center", gap: 8, padding: "5px 8px", borderRadius: 5,
    background: correct ? T.greenLt : T.slate50, marginBottom: 4, fontSize: 13,
    color: correct ? T.green : T.slate700,
  }),
  metaRow: { display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center", marginTop: 8, fontSize: 11, color: T.slate500 },
  pill: (tint) => ({
    fontSize: 10, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.03em",
    padding: "2px 6px", borderRadius: 4, color: tint, background: `${tint}18`,
  }),
  actionsRow: { display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 },
  primaryBtn: {
    padding: "5px 12px", fontSize: 12, fontWeight: 600, cursor: "pointer",
    background: T.slate900, color: "#fff", border: "none", borderRadius: 6,
  },
  ghostBtn: {
    padding: "5px 12px", fontSize: 12, cursor: "pointer",
    background: "#fff", color: T.slate700, border: `1px solid ${T.slate300}`, borderRadius: 6,
  },
  dangerBtn: {
    padding: "5px 12px", fontSize: 12, cursor: "pointer",
    background: "#fff", color: T.red, border: `1px solid ${T.red}`, borderRadius: 6,
  },
  sourceToggle: { fontSize: 11, color: T.blue, cursor: "pointer", marginTop: 4, display: "inline-block" },
  sourceBox: {
    marginTop: 6, padding: 10, background: T.slate50, borderRadius: 6,
    fontSize: 12, color: T.slate700, lineHeight: 1.5,
  },
  emptyState: {
    padding: 40, textAlign: "center", color: T.slate500, fontSize: 13,
  },
  errorBanner: {
    margin: "0 0 12px", padding: "10px 12px", background: `${T.red}12`,
    borderLeft: `4px solid ${T.red}`, color: T.red, fontSize: 13, borderRadius: 4,
  },
  successBanner: {
    margin: "0 0 12px", padding: "10px 12px", background: `${T.green}12`,
    borderLeft: `4px solid ${T.green}`, color: T.green, fontSize: 13, borderRadius: 4,
  },
  editField: { display: "flex", flexDirection: "column", gap: 4, marginBottom: 10 },
  editLabel: { fontSize: 11, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.05em", color: T.slate500 },
  editInput: {
    padding: "7px 9px", fontSize: 13, background: "#fff",
    border: `1px solid ${T.slate300}`, borderRadius: 6, color: T.slate900, fontFamily: "inherit",
  },
  editTextarea: {
    padding: "8px 10px", fontSize: 13, lineHeight: 1.5, minHeight: 60,
    background: "#fff", border: `1px solid ${T.slate300}`, borderRadius: 6,
    color: T.slate900, fontFamily: "inherit", resize: "vertical",
  },
  optionEditRow: { display: "flex", alignItems: "center", gap: 8, marginBottom: 6 },
};

const DIFFICULTY_TINT = { basic: T.green, intermediate: T.amber, advanced: T.red };

export default function Trivia({ userRole, userId }) {
  const vp = useViewport();
  const [tab, setTab] = useTabParam("tab", "review", ["review", "approved", "reports"]);

  const [items, setItems] = useState([]);
  const [optionsByItem, setOptionsByItem] = useState({});
  const [faqById, setFaqById] = useState({});
  const [reports, setReports] = useState([]);
  const [teamById, setTeamById] = useState({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const [editingItemId, setEditingItemId] = useState(null);
  const [editingReportId, setEditingReportId] = useState(null); // "Fix" flow — item edit + report resolve together
  const [expandedSource, setExpandedSource] = useState({});
  const [approvedFilter, setApprovedFilter] = useState("");
  const [banner, setBanner] = useState(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [itemsRes, optsRes, faqRes, reportsRes, teamRes] = await Promise.all([
        supabase.from("quiz_items").select("*").eq("agency_id", AGENCY_ID),
        supabase.from("quiz_item_options").select("*").order("sort_order", { ascending: true }),
        supabase.from("v_knowledge_faqs_resolved").select("id, question_resolved, answer_resolved").eq("agency_id", AGENCY_ID),
        supabase.from("quiz_item_reports").select("*").eq("agency_id", AGENCY_ID).eq("status", "open").order("created_at", { ascending: false }),
        supabase.from("team").select("id, first_name").eq("agency_id", AGENCY_ID),
      ]);
      if (itemsRes.error) throw itemsRes.error;
      if (optsRes.error) throw optsRes.error;
      if (faqRes.error) throw faqRes.error;
      if (reportsRes.error) throw reportsRes.error;
      if (teamRes.error) throw teamRes.error;

      setItems(Array.isArray(itemsRes.data) ? itemsRes.data : []);

      const optsMap = {};
      for (const o of (optsRes.data || [])) {
        if (!optsMap[o.item_id]) optsMap[o.item_id] = [];
        optsMap[o.item_id].push(o);
      }
      setOptionsByItem(optsMap);

      const faqMap = {};
      for (const f of (faqRes.data || [])) faqMap[f.id] = f;
      setFaqById(faqMap);

      setReports(Array.isArray(reportsRes.data) ? reportsRes.data : []);

      const teamMap = {};
      for (const t of (teamRes.data || [])) teamMap[t.id] = t;
      setTeamById(teamMap);
    } catch (ex) {
      setError(ex?.message || "Failed to load trivia data.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { reload(); }, [reload]);

  const draftItems = useMemo(() => (items || []).filter(i => i.status === "draft"), [items]);
  const approvedItems = useMemo(() => (items || []).filter(i => i.status === "approved"), [items]);

  const draftGroups = useMemo(() => {
    const groups = new Map();
    for (const it of draftItems) {
      const cat = it.category || "(uncategorized)";
      if (!groups.has(cat)) groups.set(cat, []);
      groups.get(cat).push(it);
    }
    for (const list of groups.values()) {
      list.sort((a, b) => (a.stem || "").localeCompare(b.stem || ""));
    }
    return [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  }, [draftItems]);

  const approvedFiltered = useMemo(() => {
    const q = approvedFilter.trim().toLowerCase();
    let list = [...approvedItems].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    if (!q) return list;
    return list.filter(i =>
      (i.stem || "").toLowerCase().includes(q) || (i.category || "").toLowerCase().includes(q)
    );
  }, [approvedItems, approvedFilter]);

  const toggleSource = (itemId) => setExpandedSource(s2 => ({ ...s2, [itemId]: !s2[itemId] }));

  // ── Actions ──────────────────────────────────────────────
  const doApprove = async (itemId) => {
    setBanner(null);
    try {
      const { error: e } = await supabase
        .from("quiz_items")
        .update({ status: "approved", approved_at: new Date().toISOString(), approved_by: userId })
        .eq("id", itemId);
      if (e) throw e;
      await reload();
      setBanner({ kind: "success", text: "Approved." });
    } catch (ex) {
      setBanner({ kind: "error", text: ex?.message || "Approve failed." });
    }
  };

  const doRetire = async (itemId) => {
    setBanner(null);
    try {
      const { error: e } = await supabase.from("quiz_items").update({ status: "retired" }).eq("id", itemId);
      if (e) throw e;
      await reload();
      setBanner({ kind: "success", text: "Retired." });
    } catch (ex) {
      setBanner({ kind: "error", text: ex?.message || "Retire failed." });
    }
  };

  const doApproveAllInGroup = async (category, groupItems) => {
    if (!confirm(`Approve all ${groupItems.length} draft item(s) in "${category}"?`)) return;
    setBanner(null);
    const failures = [];
    for (const it of groupItems) {
      const { error: e } = await supabase
        .from("quiz_items")
        .update({ status: "approved", approved_at: new Date().toISOString(), approved_by: userId })
        .eq("id", it.id);
      if (e) failures.push(`${it.stem.slice(0, 40)}…: ${e.message}`);
    }
    await reload();
    if (failures.length) {
      setBanner({ kind: "error", text: `${failures.length} item(s) failed to approve:\n${failures.join("\n")}` });
    } else {
      setBanner({ kind: "success", text: `Approved all ${groupItems.length} item(s) in "${category}".` });
    }
  };

  const doSaveEdit = async (itemId, form) => {
    setBanner(null);
    try {
      const { error: e1 } = await supabase
        .from("quiz_items")
        .update({ stem: form.stem, explanation: form.explanation, difficulty: form.difficulty })
        .eq("id", itemId);
      if (e1) throw e1;
      for (let i = 0; i < form.options.length; i++) {
        const opt = form.options[i];
        if (opt.id) {
          const { error: e2 } = await supabase
            .from("quiz_item_options")
            .update({ option_text: opt.option_text, is_correct: opt.is_correct })
            .eq("id", opt.id);
          if (e2) throw e2;
        } else {
          const trimmed = (opt.option_text || "").trim();
          if (!trimmed) continue;
          const { error: e2 } = await supabase
            .from("quiz_item_options")
            .insert({ item_id: itemId, option_text: opt.option_text, is_correct: opt.is_correct, sort_order: i });
          if (e2) throw e2;
        }
      }
      setEditingItemId(null);
      await reload();
      setBanner({ kind: "success", text: "Saved." });
    } catch (ex) {
      setBanner({ kind: "error", text: ex?.message || "Save failed." });
    }
  };

  // Reports tab actions
  const doFixSave = async (report, itemId, form) => {
    setBanner(null);
    try {
      const { error: e1 } = await supabase
        .from("quiz_items")
        .update({ stem: form.stem, explanation: form.explanation, difficulty: form.difficulty, report_blocked: false })
        .eq("id", itemId);
      if (e1) throw e1;
      for (let i = 0; i < form.options.length; i++) {
        const opt = form.options[i];
        if (opt.id) {
          const { error: e2 } = await supabase
            .from("quiz_item_options")
            .update({ option_text: opt.option_text, is_correct: opt.is_correct })
            .eq("id", opt.id);
          if (e2) throw e2;
        } else {
          const trimmed = (opt.option_text || "").trim();
          if (!trimmed) continue;
          const { error: e2 } = await supabase
            .from("quiz_item_options")
            .insert({ item_id: itemId, option_text: opt.option_text, is_correct: opt.is_correct, sort_order: i });
          if (e2) throw e2;
        }
      }
      const { error: e3 } = await supabase
        .from("quiz_item_reports")
        .update({ status: "fixed", resolved_at: new Date().toISOString() })
        .eq("id", report.id);
      if (e3) throw e3;
      setEditingReportId(null);
      await reload();
      setBanner({ kind: "success", text: "Report fixed." });
    } catch (ex) {
      setBanner({ kind: "error", text: ex?.message || "Fix failed." });
    }
  };

  const doDismiss = async (report) => {
    setBanner(null);
    try {
      const { error: e1 } = await supabase
        .from("quiz_item_reports")
        .update({ status: "dismissed", resolved_at: new Date().toISOString() })
        .eq("id", report.id);
      if (e1) throw e1;
      const { error: e2 } = await supabase
        .from("quiz_items")
        .update({ report_blocked: false })
        .eq("id", report.item_id);
      if (e2) throw e2;
      await reload();
      setBanner({ kind: "success", text: "Dismissed." });
    } catch (ex) {
      setBanner({ kind: "error", text: ex?.message || "Dismiss failed." });
    }
  };

  const doRetireFromReport = async (report) => {
    if (!confirm("Retire this item? It will no longer be served in any mode.")) return;
    setBanner(null);
    try {
      const { error: e1 } = await supabase.from("quiz_items").update({ status: "retired" }).eq("id", report.item_id);
      if (e1) throw e1;
      const { error: e2 } = await supabase
        .from("quiz_item_reports")
        .update({ status: "fixed", resolved_at: new Date().toISOString() })
        .eq("id", report.id);
      if (e2) throw e2;
      await reload();
      setBanner({ kind: "success", text: "Item retired." });
    } catch (ex) {
      setBanner({ kind: "error", text: ex?.message || "Retire failed." });
    }
  };

  // ── Render helpers ───────────────────────────────────────
  const renderCard = (item, { showApprovalStats } = {}) => {
    const opts = optionsByItem[item.id] || [];
    const faq = item.source_faq_id ? faqById[item.source_faq_id] : null;
    const isEditing = editingItemId === item.id;

    if (isEditing) {
      return (
        <EditForm
          key={item.id}
          item={item}
          options={opts}
          onCancel={() => setEditingItemId(null)}
          onSave={(form) => doSaveEdit(item.id, form)}
        />
      );
    }

    return (
      <div key={item.id} style={s.card}>
        <div style={s.stem}>{item.stem}</div>
        {opts.map(o => (
          <div key={o.id} style={s.optionRow(o.is_correct)}>
            <span>{o.is_correct ? "✓" : "—"}</span>
            <span>{o.option_text}</span>
          </div>
        ))}
        <div style={s.metaRow}>
          <span style={s.pill(DIFFICULTY_TINT[item.difficulty] || T.slate500)}>{item.difficulty}</span>
          {item.category && <span>{item.category}</span>}
          {item.report_blocked && <span style={s.pill(T.red)}>reported</span>}
          {showApprovalStats && (
            <span>served {item.times_served || 0}, right {item.times_correct || 0}</span>
          )}
        </div>
        {item.source_faq_id && (
          <div>
            <span style={s.sourceToggle} onClick={() => toggleSource(item.id)}>
              {expandedSource[item.id] ? "hide source ▲" : "show source ▼"}
            </span>
            {expandedSource[item.id] && (
              <div style={s.sourceBox}>
                {faq ? (
                  <>
                    <div><strong>{faq.question_resolved}</strong></div>
                    <div style={{ marginTop: 4 }}>{faq.answer_resolved}</div>
                  </>
                ) : (
                  <div style={{ color: T.slate400 }}>(source row not found)</div>
                )}
              </div>
            )}
          </div>
        )}
        <div style={s.actionsRow}>
          {item.status === "draft" && (
            <button type="button" style={s.primaryBtn} onClick={() => doApprove(item.id)}>Approve</button>
          )}
          <button type="button" style={s.ghostBtn} onClick={() => setEditingItemId(item.id)}>Edit</button>
          <button type="button" style={s.dangerBtn} onClick={() => doRetire(item.id)}>Retire</button>
        </div>
      </div>
    );
  };

  // ── Tab content ──────────────────────────────────────────
  const reviewTab = (
    <div>
      {draftGroups.length === 0 && !loading && (
        <div style={s.emptyState}>No questions yet — the planning thread hasn't authored any drafts.</div>
      )}
      {draftGroups.map(([category, groupItems]) => (
        <div key={category}>
          <div style={s.groupHeader}>
            <div style={s.groupTitle}>{category} <span style={{ color: T.slate400, fontWeight: 500 }}>({groupItems.length})</span></div>
            <button type="button" style={s.ghostBtn} onClick={() => doApproveAllInGroup(category, groupItems)}>
              Approve all in this group
            </button>
          </div>
          {groupItems.map(it => renderCard(it))}
        </div>
      ))}
    </div>
  );

  const approvedTab = (
    <div>
      <div style={{ marginBottom: 12 }}>
        <input
          type="text"
          placeholder="Filter by stem or category…"
          style={s.searchInput}
          value={approvedFilter}
          onChange={(e) => setApprovedFilter(e.target.value)}
        />
      </div>
      {approvedFiltered.length === 0 && !loading && (
        <div style={s.emptyState}>No questions yet — nothing has been approved.</div>
      )}
      {approvedFiltered.map(it => renderCard(it, { showApprovalStats: true }))}
    </div>
  );

  const reportsTab = (
    <div>
      {reports.length === 0 && !loading && (
        <div style={s.emptyState}>No open reports.</div>
      )}
      {reports.map(r => {
        const item = items.find(i => i.id === r.item_id);
        const opts = optionsByItem[r.item_id] || [];
        const reporter = teamById[r.reported_by];
        const isFixing = editingReportId === r.id;

        if (isFixing && item) {
          return (
            <EditForm
              key={r.id}
              item={item}
              options={opts}
              onCancel={() => setEditingReportId(null)}
              onSave={(form) => doFixSave(r, item.id, form)}
            />
          );
        }

        return (
          <div key={r.id} style={s.card}>
            <div style={{ fontSize: 12, color: T.slate600, marginBottom: 6 }}>
              Reported by <strong>{reporter?.first_name || "(unknown)"}</strong>
              {r.reason && <> — {r.reason}</>}
            </div>
            <div style={s.stem}>{item?.stem || "(item not found)"}</div>
            {opts.map(o => (
              <div key={o.id} style={s.optionRow(o.is_correct)}>
                <span>{o.is_correct ? "✓" : "—"}</span>
                <span>{o.option_text}</span>
              </div>
            ))}
            <div style={s.actionsRow}>
              <button type="button" style={s.primaryBtn} onClick={() => setEditingReportId(r.id)}>Fix</button>
              <button type="button" style={s.ghostBtn} onClick={() => doDismiss(r)}>Dismiss</button>
              <button type="button" style={s.dangerBtn} onClick={() => doRetireFromReport(r)}>Retire item</button>
            </div>
          </div>
        );
      })}
    </div>
  );

  return (
    <div style={s.page}>
      <div style={s.headerBar}>
        <div style={s.headerTitle}>Trivia</div>
      </div>
      <div style={s.tabBar}>
        <button type="button" style={s.tabBtn(tab === "review")} onClick={() => setTab("review")}>Review</button>
        <button type="button" style={s.tabBtn(tab === "approved")} onClick={() => setTab("approved")}>Approved</button>
        <button type="button" style={s.tabBtn(tab === "reports")} onClick={() => setTab("reports")}>
          Reports{reports.length > 0 && <span style={s.badge}>{reports.length}</span>}
        </button>
      </div>
      <div style={s.body}>
        {error && <div style={s.errorBanner}>{error}</div>}
        {banner && (
          <div style={banner.kind === "success" ? s.successBanner : s.errorBanner}>
            {banner.text.split("\n").map((line, idx) => <div key={idx}>{line}</div>)}
          </div>
        )}
        {loading && <div style={{ padding: 16, fontSize: 13, color: T.slate500 }}>Loading…</div>}
        {!loading && tab === "review" && reviewTab}
        {!loading && tab === "approved" && approvedTab}
        {!loading && tab === "reports" && reportsTab}
      </div>
    </div>
  );
}

// ─── Inline edit form — stem, explanation, difficulty, 4 option texts + which is correct ───
function EditForm({ item, options, onCancel, onSave }) {
  const [stem, setStem] = useState(item.stem || "");
  const [explanation, setExplanation] = useState(item.explanation || "");
  const [difficulty, setDifficulty] = useState(item.difficulty || "basic");
  const [optDrafts, setOptDrafts] = useState(() => {
    const existing = (options || []).map(o => ({ id: o.id, option_text: o.option_text, is_correct: o.is_correct }));
    const padded = [...existing];
    while (padded.length < 4) {
      padded.push({ id: null, option_text: "", is_correct: false });
    }
    return padded.slice(0, 4);
  });

  const setOptText = (idx, text) => {
    setOptDrafts(list => list.map((o, i) => i === idx ? { ...o, option_text: text } : o));
  };
  const setCorrect = (idx) => {
    setOptDrafts(list => list.map((o, i) => ({ ...o, is_correct: i === idx })));
  };

  return (
    <div style={s.card}>
      <div style={s.editField}>
        <label style={s.editLabel}>Stem</label>
        <textarea style={s.editTextarea} value={stem} onChange={(e) => setStem(e.target.value)} />
      </div>
      <div style={s.editField}>
        <label style={s.editLabel}>Difficulty</label>
        <select style={s.editInput} value={difficulty} onChange={(e) => setDifficulty(e.target.value)}>
          <option value="basic">basic</option>
          <option value="intermediate">intermediate</option>
          <option value="advanced">advanced</option>
        </select>
      </div>
      <div style={s.editField}>
        <label style={s.editLabel}>Options (select the correct one)</label>
        {optDrafts.map((o, idx) => (
          <div key={idx} style={s.optionEditRow}>
            <input type="radio" checked={o.is_correct} onChange={() => setCorrect(idx)} />
            <input
              type="text"
              style={{ ...s.editInput, flex: 1 }}
              value={o.option_text}
              onChange={(e) => setOptText(idx, e.target.value)}
            />
          </div>
        ))}
      </div>
      <div style={s.editField}>
        <label style={s.editLabel}>Explanation</label>
        <textarea style={s.editTextarea} value={explanation} onChange={(e) => setExplanation(e.target.value)} />
      </div>
      <div style={s.actionsRow}>
        <button
          type="button"
          style={s.primaryBtn}
          onClick={() => onSave({ stem, explanation, difficulty, options: optDrafts })}
        >
          Save
        </button>
        <button type="button" style={s.ghostBtn} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}
