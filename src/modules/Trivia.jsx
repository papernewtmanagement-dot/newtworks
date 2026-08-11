import { useState, useEffect, useMemo, useCallback, useRef } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { useTabParam } from "../lib/routing.jsx";

// ============================================================
// Newtworks TRIVIA MODULE — Wave 2 Block B (play tab shipped,
// admin-only flag removed)
//
// SCOPE: Block A — review/approve/retire quiz items, browse
// approved items, work the bad-question report queue, switch a
// manual-page read to the resolved FAQ view. Block B — a Play tab
// (Daily Five + Duel) open to every team-visible role, plus a
// weekly trivia standings strip. Review/Approved/Reports stay
// admin-gated in-module. The planning thread authors items
// separately; no question-writing UI lives here.
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
  // ── Play-tab styles ──
  playGrid: {
    display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))",
    gap: 12, marginBottom: 16,
  },
  playCard: {
    background: "#fff", border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 16,
  },
  playCardTitle: { fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 4 },
  playCardDesc: { fontSize: 12, color: T.slate500, marginBottom: 12 },
  bigStat: { fontSize: 22, fontWeight: 700, color: T.slate900 },
  smallLabel: { fontSize: 11, color: T.slate500, marginTop: 2 },
  timerPill: (urgent) => ({
    fontSize: 12, fontWeight: 700, padding: "3px 10px", borderRadius: 12,
    background: urgent ? T.redLt : T.slate100, color: urgent ? T.red : T.slate700,
  }),
  qStem: { fontSize: 15, fontWeight: 600, color: T.slate900, lineHeight: 1.4, marginBottom: 12 },
  qOptionBtn: (state) => {
    // state: "default" | "selectedCorrect" | "selectedWrong" | "revealCorrect" | "revealDim"
    const map = {
      default: { background: "#fff", border: `1px solid ${T.slate300}`, color: T.slate800 },
      selectedCorrect: { background: T.greenLt, border: `1px solid ${T.green}`, color: T.green },
      selectedWrong: { background: T.redLt, border: `1px solid ${T.red}`, color: T.red },
      revealCorrect: { background: T.greenLt, border: `1px solid ${T.green}`, color: T.green },
      revealDim: { background: T.slate50, border: `1px solid ${T.slate200}`, color: T.slate400 },
    };
    const chosen = map[state] || map.default;
    return {
      display: "block", width: "100%", textAlign: "left", padding: "10px 12px",
      fontSize: 13, borderRadius: 8, marginBottom: 8, cursor: "pointer", ...chosen,
    };
  },
  explanationBox: {
    marginTop: 8, padding: 10, background: T.slate50, borderRadius: 6,
    fontSize: 12, color: T.slate700, lineHeight: 1.5,
  },
  standingsRow: {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    padding: "8px 10px", borderRadius: 6, marginBottom: 6, background: T.slate50, fontSize: 13,
  },
  standingsTier: (tier) => ({
    width: 22, height: 22, borderRadius: 11, display: "flex", alignItems: "center",
    justifyContent: "center", fontSize: 11, fontWeight: 700, color: "#fff",
    background: tier === 1 ? T.gold : tier === 2 ? T.slate500 : T.amber,
  }),
  opponentPickRow: {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    padding: "8px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, marginBottom: 6, fontSize: 13,
  },
  duelListRow: {
    padding: "8px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, marginBottom: 6, fontSize: 13,
  },
};

const DIFFICULTY_TINT = { basic: T.green, intermediate: T.amber, advanced: T.red };

// ── Central Time helpers (no library dependency) ──
function ctToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago" }).format(new Date());
}
function shiftDateStr(dateStr, deltaDays) {
  const parts = (dateStr || "").split("-").map(Number);
  if (parts.length !== 3 || parts.some(n => !Number.isFinite(n))) return dateStr;
  const [y, m, d] = parts;
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + deltaDays);
  return dt.toISOString().slice(0, 10);
}
function computeStreak(attemptDays) {
  const set = new Set(Array.isArray(attemptDays) ? attemptDays : []);
  let streak = 0;
  let cursor = ctToday();
  while (set.has(cursor)) {
    streak += 1;
    cursor = shiftDateStr(cursor, -1);
  }
  return streak;
}
function sampleN(pool, n) {
  const arr = Array.isArray(pool) ? [...pool] : [];
  const count = Math.min(n || 0, arr.length);
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr.slice(0, count);
}

export default function Trivia({ userRole, userId }) {
  const vp = useViewport();
  const isAdmin = userRole === "owner" || userRole === "manager";
  const [tabRaw, setTabRaw] = useTabParam("tab", isAdmin ? "review" : "play", ["play", "review", "approved", "reports"]);
  const tab = isAdmin ? tabRaw : "play"; // non-admins always land on Play regardless of URL param

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

  useEffect(() => {
    if (isAdmin) reload();
    else setLoading(false); // non-admins never touch the review/approved/reports data
  }, [reload, isAdmin]);

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
        <button type="button" style={s.tabBtn(tab === "play")} onClick={() => setTabRaw("play")}>Play</button>
        {isAdmin && (
          <>
            <button type="button" style={s.tabBtn(tab === "review")} onClick={() => setTabRaw("review")}>Review</button>
            <button type="button" style={s.tabBtn(tab === "approved")} onClick={() => setTabRaw("approved")}>Approved</button>
            <button type="button" style={s.tabBtn(tab === "reports")} onClick={() => setTabRaw("reports")}>
              Reports{reports.length > 0 && <span style={s.badge}>{reports.length}</span>}
            </button>
          </>
        )}
      </div>
      <div style={s.body}>
        {error && <div style={s.errorBanner}>{error}</div>}
        {banner && (
          <div style={banner.kind === "success" ? s.successBanner : s.errorBanner}>
            {banner.text.split("\n").map((line, idx) => <div key={idx}>{line}</div>)}
          </div>
        )}
        {tab === "play" && <TriviaPlayTab userId={userId} />}
        {isAdmin && loading && <div style={{ padding: 16, fontSize: 13, color: T.slate500 }}>Loading…</div>}
        {isAdmin && !loading && tab === "review" && reviewTab}
        {isAdmin && !loading && tab === "approved" && approvedTab}
        {isAdmin && !loading && tab === "reports" && reportsTab}
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

// ============================================================
// BLOCK B — PLAY TAB
// Daily Five + Duel + weekly trivia standings. Open to every
// team-visible role. No wager/speed-clock (both off on these two
// modes per the seeded quiz_modes rows) — flat 10-per-correct
// scoring, computed server-side by quiz_finish_attempt. This tab
// never calls quiz_record_serve; finish handles item stats once.
// ============================================================

async function loadItemsWithOptions(ids) {
  const cleanIds = Array.isArray(ids) ? ids.filter(Boolean) : [];
  if (cleanIds.length === 0) return {};
  const [itemsRes, optsRes] = await Promise.all([
    supabase.from("quiz_items").select("*").in("id", cleanIds),
    supabase.from("quiz_item_options").select("*").in("item_id", cleanIds).order("sort_order", { ascending: true }),
  ]);
  if (itemsRes.error) throw itemsRes.error;
  if (optsRes.error) throw optsRes.error;
  const optsByItem = {};
  for (const o of (optsRes.data || [])) {
    if (!optsByItem[o.item_id]) optsByItem[o.item_id] = [];
    optsByItem[o.item_id].push(o);
  }
  const map = {};
  for (const it of (itemsRes.data || [])) {
    map[it.id] = { ...it, options: optsByItem[it.id] || [] };
  }
  return map;
}

function TriviaPlayTab({ userId }) {
  const [modes, setModes] = useState({});
  const [modesError, setModesError] = useState(null);
  const [itemPool, setItemPool] = useState([]);
  const [poolError, setPoolError] = useState(null);

  // Daily Five
  const [dfPhase, setDfPhase] = useState("checking"); // checking | not_started | in_progress | playing | finishing | finished | error
  const [dfError, setDfError] = useState(null);
  const [dfAttempt, setDfAttempt] = useState(null);
  const [dfItemsById, setDfItemsById] = useState({});
  const [dfRemainingIds, setDfRemainingIds] = useState([]);
  const [dfResult, setDfResult] = useState(null);
  const [dfStreak, setDfStreak] = useState(0);

  // Duel
  const [duelOpponents, setDuelOpponents] = useState([]);
  const [pendingDuels, setPendingDuels] = useState([]);
  const [ownDuels, setOwnDuels] = useState([]);
  const [ownDuelResults, setOwnDuelResults] = useState({});
  const [duelListError, setDuelListError] = useState(null);
  const [duelMode, setDuelMode] = useState("idle"); // idle | picking | starting | playing | finished
  const [duelError, setDuelError] = useState(null);
  const [duelActiveAttempt, setDuelActiveAttempt] = useState(null);
  const [duelActiveItemsById, setDuelActiveItemsById] = useState({});
  const [duelActiveRemainingIds, setDuelActiveRemainingIds] = useState([]);
  const [duelActiveOpponentName, setDuelActiveOpponentName] = useState(null);
  const [duelResult, setDuelResult] = useState(null);

  // Standings
  const [standings, setStandings] = useState([]);
  const [standingsNameById, setStandingsNameById] = useState({});
  const [standingsError, setStandingsError] = useState(null);

  // ── Loaders ──
  const loadModesAndPool = useCallback(async () => {
    try {
      const [modesRes, poolRes] = await Promise.all([
        supabase.from("quiz_modes").select("*").eq("agency_id", AGENCY_ID).in("mode_key", ["daily_five", "duel"]),
        supabase.from("quiz_items").select("id"),
      ]);
      if (modesRes.error) throw modesRes.error;
      const modeMap = {};
      for (const m of (modesRes.data || [])) modeMap[m.mode_key] = m;
      setModes(modeMap);

      if (poolRes.error) throw poolRes.error;
      setItemPool((poolRes.data || []).map(r => r.id));
    } catch (ex) {
      setModesError(ex?.message || "Could not load trivia settings.");
    }
  }, []);

  const loadDailyStatus = useCallback(async () => {
    if (!userId) return;
    setDfPhase("checking");
    setDfError(null);
    try {
      const today = ctToday();
      const [existingRes, historyRes] = await Promise.all([
        supabase.from("quiz_attempts").select("*")
          .eq("team_member_id", userId).eq("mode_key", "daily_five").eq("attempt_day", today)
          .maybeSingle(),
        supabase.from("quiz_attempts").select("attempt_day")
          .eq("team_member_id", userId).eq("mode_key", "daily_five").not("finished_at", "is", null)
          .order("attempt_day", { ascending: false }).limit(400),
      ]);
      if (existingRes.error) throw existingRes.error;
      if (historyRes.error) throw historyRes.error;

      setDfStreak(computeStreak((historyRes.data || []).map(r => r.attempt_day)));

      const row = existingRes.data;
      if (!row) {
        setDfAttempt(null);
        setDfPhase("not_started");
      } else if (row.finished_at) {
        setDfAttempt(row);
        setDfResult({ correct_count: row.correct_count, question_count: row.question_count, points_earned: row.points_earned });
        setDfPhase("finished");
      } else {
        setDfAttempt(row);
        setDfPhase("in_progress");
      }
    } catch (ex) {
      setDfError(ex?.message || "Could not check today's status.");
      setDfPhase("error");
    }
  }, [userId]);

  const loadDuelLists = useCallback(async () => {
    if (!userId) return;
    setDuelListError(null);
    try {
      const [oppRes, pendRes, ownRes] = await Promise.all([
        supabase.rpc("quiz_duel_opponents"),
        supabase.rpc("quiz_pending_duels"),
        supabase.from("quiz_attempts").select("*")
          .eq("team_member_id", userId).eq("mode_key", "duel")
          .not("finished_at", "is", null).not("opponent_attempt_id", "is", null)
          .order("finished_at", { ascending: false }).limit(10),
      ]);
      if (oppRes.error) throw oppRes.error;
      if (pendRes.error) throw pendRes.error;
      if (ownRes.error) throw ownRes.error;

      setDuelOpponents(Array.isArray(oppRes.data) ? oppRes.data : []);
      setPendingDuels(Array.isArray(pendRes.data) ? pendRes.data : []);
      const ownRows = Array.isArray(ownRes.data) ? ownRes.data : [];
      setOwnDuels(ownRows);

      const results = {};
      await Promise.all(ownRows.map(async (row) => {
        const { data, error } = await supabase.rpc("quiz_duel_result", { p_attempt_id: row.id });
        if (!error) results[row.id] = data;
      }));
      setOwnDuelResults(results);
    } catch (ex) {
      setDuelListError(ex?.message || "Could not load duels.");
    }
  }, [userId]);

  const loadStandings = useCallback(async () => {
    try {
      const [lbRes, oppRes] = await Promise.all([
        supabase.from("leaderboards").select("*")
          .eq("agency_id", AGENCY_ID).eq("category", "trivia_week_points")
          .order("tier", { ascending: true }),
        supabase.rpc("quiz_duel_opponents"),
      ]);
      if (lbRes.error) throw lbRes.error;
      setStandings(Array.isArray(lbRes.data) ? lbRes.data : []);

      const nameMap = {};
      if (!oppRes.error) {
        for (const o of (oppRes.data || [])) nameMap[o.team_member_id] = o.first_name;
      }
      if (userId) {
        const { data: ownRow } = await supabase.from("team").select("id, first_name").eq("id", userId).maybeSingle();
        if (ownRow?.id) nameMap[ownRow.id] = ownRow.first_name;
      }
      setStandingsNameById(nameMap);
    } catch (ex) {
      setStandingsError(ex?.message || "Could not load standings.");
    }
  }, [userId]);

  useEffect(() => { loadModesAndPool(); }, [loadModesAndPool]);
  useEffect(() => { loadDailyStatus(); }, [loadDailyStatus]);
  useEffect(() => { loadDuelLists(); }, [loadDuelLists]);
  useEffect(() => { loadStandings(); }, [loadStandings]);

  // ── Daily Five actions ──
  const startFreshDaily = async () => {
    setDfError(null);
    setDfPhase("checking");
    try {
      const dailyCfg = modes.daily_five;
      const ids = sampleN(itemPool, dailyCfg?.question_count || 5);
      let attempt = null;
      const { data: inserted, error: insErr } = await supabase
        .from("quiz_attempts")
        .insert({ agency_id: AGENCY_ID, team_member_id: userId, mode_key: "daily_five", context: { item_ids: ids } })
        .select("*")
        .maybeSingle();
      if (insErr) {
        // Unique-index hit (double-tap) — re-query and resume instead of erroring.
        const today = ctToday();
        const { data: retryRow, error: retryErr } = await supabase
          .from("quiz_attempts").select("*")
          .eq("team_member_id", userId).eq("mode_key", "daily_five").eq("attempt_day", today)
          .maybeSingle();
        if (retryErr || !retryRow) throw (retryErr || insErr);
        attempt = retryRow;
      } else {
        attempt = inserted;
      }
      await beginPlayingDaily(attempt);
    } catch (ex) {
      setDfError(ex?.message || "Could not start today's five.");
      setDfPhase("error");
    }
  };

  const resumeDaily = async () => {
    if (!dfAttempt) return;
    setDfError(null);
    setDfPhase("checking");
    try {
      await beginPlayingDaily(dfAttempt);
    } catch (ex) {
      setDfError(ex?.message || "Could not resume today's five.");
      setDfPhase("error");
    }
  };

  const beginPlayingDaily = async (attempt) => {
    const allIds = (attempt?.context?.item_ids) || [];
    const { data: answeredRows, error: ansErr } = await supabase
      .from("quiz_answers").select("item_id").eq("attempt_id", attempt.id);
    if (ansErr) throw ansErr;
    const answeredIds = new Set((answeredRows || []).map(r => r.item_id));
    const remaining = allIds.filter(id => !answeredIds.has(id));
    const itemsMap = await loadItemsWithOptions(allIds);

    setDfAttempt(attempt);
    setDfItemsById(itemsMap);
    setDfRemainingIds(remaining);

    if (remaining.length === 0) {
      setDfPhase("finishing");
      await finishDaily(attempt.id);
    } else {
      setDfPhase("playing");
    }
  };

  const submitDailyAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    const { error } = await supabase.from("quiz_answers").insert({
      attempt_id: dfAttempt.id, item_id: itemId, chosen_option_id: chosenOptionId, seconds_taken: secondsTaken,
    });
    if (error) throw error;
  };

  const finishDaily = async (attemptId) => {
    setDfPhase("finishing");
    const { data, error } = await supabase.rpc("quiz_finish_attempt", { p_attempt_id: attemptId });
    if (error) {
      setDfError(error.message || "Could not finish — try again.");
      setDfPhase("error");
      return;
    }
    setDfResult(data);
    setDfPhase("finished");
    await loadDailyStatus();
  };

  // ── Duel actions ──
  const startDuelChallenge = async (opponent) => {
    setDuelError(null);
    setDuelMode("starting");
    try {
      const duelCfg = modes.duel;
      const ids = sampleN(itemPool, duelCfg?.question_count || 7);
      const { data: inserted, error } = await supabase
        .from("quiz_attempts")
        .insert({
          agency_id: AGENCY_ID, team_member_id: userId, mode_key: "duel",
          context: { item_ids: ids, duel_opponent_team_member_id: opponent.team_member_id },
        })
        .select("*")
        .maybeSingle();
      if (error) throw error;
      const itemsMap = await loadItemsWithOptions(ids);
      setDuelActiveAttempt(inserted);
      setDuelActiveItemsById(itemsMap);
      setDuelActiveRemainingIds(ids);
      setDuelActiveOpponentName(opponent.first_name);
      setDuelResult(null);
      setDuelMode("playing");
    } catch (ex) {
      setDuelError(ex?.message || "Could not start the duel.");
      setDuelMode("idle");
    }
  };

  const acceptDuel = async (pending) => {
    setDuelError(null);
    setDuelMode("starting");
    try {
      const { data: newAttemptId, error } = await supabase.rpc("quiz_accept_duel", { p_challenge_attempt_id: pending.challenge_attempt_id });
      if (error) throw error;
      const { data: newRow, error: fetchErr } = await supabase
        .from("quiz_attempts").select("*").eq("id", newAttemptId).maybeSingle();
      if (fetchErr) throw fetchErr;
      const ids = (newRow?.context?.item_ids) || [];
      const itemsMap = await loadItemsWithOptions(ids);
      setDuelActiveAttempt(newRow);
      setDuelActiveItemsById(itemsMap);
      setDuelActiveRemainingIds(ids);
      setDuelActiveOpponentName(pending.challenger_name);
      setDuelResult(null);
      setDuelMode("playing");
    } catch (ex) {
      setDuelError(ex?.message || "Could not accept the duel.");
      setDuelMode("idle");
    }
  };

  const submitDuelAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    const { error } = await supabase.from("quiz_answers").insert({
      attempt_id: duelActiveAttempt.id, item_id: itemId, chosen_option_id: chosenOptionId, seconds_taken: secondsTaken,
    });
    if (error) throw error;
  };

  const finishDuel = async () => {
    if (!duelActiveAttempt) return;
    const attemptId = duelActiveAttempt.id;
    const { data, error } = await supabase.rpc("quiz_finish_attempt", { p_attempt_id: attemptId });
    if (error) {
      setDuelError(error.message || "Could not finish — try again.");
      return;
    }
    const { data: resultData, error: resErr } = await supabase.rpc("quiz_duel_result", { p_attempt_id: attemptId });
    if (resErr) {
      setDuelError(resErr.message || "Finished, but could not load the result.");
    } else {
      setDuelResult(resultData);
    }
    setDuelMode("finished");
    await loadDuelLists();
    await loadStandings();
  };

  // ── Render ──
  const dailyCfg = modes.daily_five;
  const duelCfg = modes.duel;

  return (
    <div>
      {(modesError || poolError) && <div style={s.errorBanner}>{modesError || poolError}</div>}

      <div style={s.playGrid}>
        {/* ── Daily Five card ── */}
        <div style={s.playCard}>
          <div style={s.playCardTitle}>Daily Five</div>
          <div style={s.playCardDesc}>{dailyCfg?.description || "Five questions a day. Keep your streak going."}</div>

          {dfError && <div style={s.errorBanner}>{dfError}</div>}

          {dfPhase === "checking" && <div style={{ fontSize: 13, color: T.slate500 }}>Checking today's status…</div>}

          {dfPhase === "not_started" && (
            <button type="button" style={s.primaryBtn} onClick={startFreshDaily}>Play today's five</button>
          )}

          {dfPhase === "in_progress" && (
            <button type="button" style={s.primaryBtn} onClick={resumeDaily}>Resume</button>
          )}

          {dfPhase === "finishing" && <div style={{ fontSize: 13, color: T.slate500 }}>Finishing up…</div>}

          {dfPhase === "playing" && dfAttempt && (
            <QuestionRunner
              itemIds={dfRemainingIds}
              itemsById={dfItemsById}
              secondsPerQuestion={dailyCfg?.seconds_per_question || 30}
              onSubmitAnswer={submitDailyAnswer}
              onAllDone={() => finishDaily(dfAttempt.id)}
            />
          )}

          {dfPhase === "finished" && dfResult && (
            <div>
              <div style={s.bigStat}>{dfResult.correct_count}/{dfResult.question_count}</div>
              <div style={s.smallLabel}>{dfResult.points_earned} points earned today</div>
              <div style={s.smallLabel}>Streak: {dfStreak} day{dfStreak === 1 ? "" : "s"}</div>
              {dfResult.on_leaderboard && (
                <div style={{ ...s.smallLabel, color: T.gold, fontWeight: 700, marginTop: 4 }}>made the board! 🏆</div>
              )}
            </div>
          )}
        </div>

        {/* ── Duel card ── */}
        <div style={s.playCard}>
          <div style={s.playCardTitle}>Duel</div>
          <div style={s.playCardDesc}>{duelCfg?.description || "Challenge a teammate. Same questions, play when you have a minute."}</div>

          {duelError && <div style={s.errorBanner}>{duelError}</div>}
          {duelListError && <div style={s.errorBanner}>{duelListError}</div>}

          {duelMode === "playing" && duelActiveAttempt && (
            <div>
              <div style={{ fontSize: 12, color: T.slate500, marginBottom: 8 }}>vs {duelActiveOpponentName || "teammate"}</div>
              <QuestionRunner
                itemIds={duelActiveRemainingIds}
                itemsById={duelActiveItemsById}
                secondsPerQuestion={duelCfg?.seconds_per_question || 20}
                onSubmitAnswer={submitDuelAnswer}
                onAllDone={finishDuel}
              />
            </div>
          )}

          {duelMode === "starting" && <div style={{ fontSize: 13, color: T.slate500 }}>Setting up…</div>}

          {duelMode === "finished" && duelResult && (
            <div style={{ marginBottom: 12 }}>
              {duelResult.both_finished ? (
                <>
                  <div style={s.bigStat}>
                    {duelResult.my_points} – {duelResult.opponent_points}
                  </div>
                  <div style={s.smallLabel}>
                    {duelResult.my_points > duelResult.opponent_points
                      ? "You win!"
                      : duelResult.my_points < duelResult.opponent_points
                      ? `${duelResult.opponent_name || "Opponent"} wins`
                      : "Tie"}
                  </div>
                </>
              ) : (
                <div style={s.smallLabel}>Waiting on {duelActiveOpponentName || "your opponent"}</div>
              )}
            </div>
          )}

          {(duelMode === "idle" || duelMode === "picking") && (
            <>
              <button type="button" style={s.ghostBtn} onClick={() => setDuelMode(duelMode === "picking" ? "idle" : "picking")}>
                Challenge a teammate
              </button>
              {duelMode === "picking" && (
                <div style={{ marginTop: 10 }}>
                  {duelOpponents.length === 0 && <div style={{ fontSize: 12, color: T.slate500 }}>No teammates available to challenge.</div>}
                  {duelOpponents.map(o => (
                    <div key={o.team_member_id} style={s.opponentPickRow}>
                      <span>{o.first_name}</span>
                      <button type="button" style={s.ghostBtn} onClick={() => startDuelChallenge(o)}>Challenge</button>
                    </div>
                  ))}
                </div>
              )}

              {pendingDuels.length > 0 && (
                <div style={{ marginTop: 14 }}>
                  <div style={s.groupTitle}>Duels against you</div>
                  {pendingDuels.map(p => (
                    <div key={p.challenge_attempt_id} style={s.duelListRow}>
                      <div style={{ marginBottom: 6 }}>{p.challenger_name} challenged you</div>
                      <button type="button" style={s.primaryBtn} onClick={() => acceptDuel(p)}>Accept</button>
                    </div>
                  ))}
                </div>
              )}

              {ownDuels.length > 0 && (
                <div style={{ marginTop: 14 }}>
                  <div style={s.groupTitle}>Your recent duels</div>
                  {ownDuels.map(row => {
                    const res = ownDuelResults[row.id];
                    if (!res) return null;
                    let line;
                    if (!res.both_finished) {
                      line = `Waiting on ${res.opponent_name || "opponent"}`;
                    } else if (res.my_points > res.opponent_points) {
                      line = `Won ${res.my_points} – ${res.opponent_points} vs ${res.opponent_name || "opponent"}`;
                    } else if (res.my_points < res.opponent_points) {
                      line = `Lost ${res.my_points} – ${res.opponent_points} vs ${res.opponent_name || "opponent"}`;
                    } else {
                      line = `Tied ${res.my_points} – ${res.opponent_points} vs ${res.opponent_name || "opponent"}`;
                    }
                    return <div key={row.id} style={s.duelListRow}>{line}</div>;
                  })}
                </div>
              )}
            </>
          )}
        </div>
      </div>

      {/* ── Standings strip ── */}
      <div style={s.playCard}>
        <div style={s.playCardTitle}>This week's trivia standings</div>
        {standingsError && <div style={s.errorBanner}>{standingsError}</div>}
        {standings.length === 0 && !standingsError && (
          <div style={{ fontSize: 12, color: T.slate500 }}>No records yet this week.</div>
        )}
        {standings.map(row => (
          <div key={row.id} style={s.standingsRow}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={s.standingsTier(row.tier)}>{row.tier}</span>
              <span>{standingsNameById[row.team_member_id] || "—"}</span>
            </div>
            <div style={{ textAlign: "right" }}>
              <div style={{ fontWeight: 700 }}>{row.record_value} pts</div>
              <div style={{ fontSize: 10, color: T.slate500 }}>{row.record_period_label}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─── Shared question-loop runner for Daily Five + Duel ───
function QuestionRunner({ itemIds, itemsById, secondsPerQuestion, onSubmitAnswer, onAllDone }) {
  const [idx, setIdx] = useState(0);
  const [timeLeft, setTimeLeft] = useState(secondsPerQuestion);
  const [revealed, setRevealed] = useState(false);
  const [selectedId, setSelectedId] = useState(null);
  const [submitError, setSubmitError] = useState(null);
  const firingRef = useRef(false);

  const currentId = itemIds[idx];
  const currentItem = itemsById[currentId];

  const advanceOrFinish = useCallback(() => {
    firingRef.current = false;
    if (idx + 1 < itemIds.length) {
      setIdx(i => i + 1);
      setTimeLeft(secondsPerQuestion);
      setRevealed(false);
      setSelectedId(null);
    } else {
      onAllDone();
    }
  }, [idx, itemIds.length, secondsPerQuestion, onAllDone]);

  const handleTimeout = useCallback(async () => {
    if (firingRef.current || revealed) return;
    firingRef.current = true;
    try {
      await onSubmitAnswer(currentId, null, secondsPerQuestion);
    } catch (ex) {
      setSubmitError(ex?.message || "Could not submit — moving on.");
    }
    advanceOrFinish();
  }, [currentId, secondsPerQuestion, onSubmitAnswer, advanceOrFinish, revealed]);

  useEffect(() => {
    if (revealed) return undefined;
    if (timeLeft <= 0) {
      handleTimeout();
      return undefined;
    }
    const t = setTimeout(() => setTimeLeft(tl => tl - 1), 1000);
    return () => clearTimeout(t);
  }, [timeLeft, revealed, handleTimeout]);

  if (!currentItem) {
    return <div style={{ fontSize: 13, color: T.slate500 }}>Loading question…</div>;
  }

  const handleSelect = async (optionId) => {
    if (revealed || firingRef.current) return;
    firingRef.current = true;
    const secondsTaken = Math.max(0, secondsPerQuestion - timeLeft);
    setSelectedId(optionId);
    setRevealed(true);
    try {
      await onSubmitAnswer(currentId, optionId, secondsTaken);
    } catch (ex) {
      setSubmitError(ex?.message || "Could not submit that answer.");
    }
    firingRef.current = false;
  };

  const handleNext = () => advanceOrFinish();

  const urgent = timeLeft <= 5;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10 }}>
        <span style={{ fontSize: 11, color: T.slate500 }}>{idx + 1} of {itemIds.length}</span>
        {!revealed && <span style={s.timerPill(urgent)}>{timeLeft}s</span>}
      </div>
      {submitError && <div style={s.errorBanner}>{submitError}</div>}
      <div style={s.qStem}>{currentItem.stem}</div>
      {(currentItem.options || []).map(o => {
        let state = "default";
        if (revealed) {
          if (o.id === selectedId && o.is_correct) state = "selectedCorrect";
          else if (o.id === selectedId && !o.is_correct) state = "selectedWrong";
          else if (o.is_correct) state = "revealCorrect";
          else state = "revealDim";
        }
        return (
          <button
            key={o.id}
            type="button"
            style={s.qOptionBtn(state)}
            onClick={() => handleSelect(o.id)}
            disabled={revealed}
          >
            {o.option_text}
          </button>
        );
      })}
      {revealed && (
        <>
          {currentItem.explanation && <div style={s.explanationBox}>{currentItem.explanation}</div>}
          <div style={s.actionsRow}>
            <button type="button" style={s.primaryBtn} onClick={handleNext}>
              {idx + 1 < itemIds.length ? "Next" : "Finish"}
            </button>
          </div>
        </>
      )}
    </div>
  );
}
