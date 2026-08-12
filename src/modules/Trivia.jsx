import { useState, useEffect, useMemo, useCallback, useRef } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { useTabParam } from "../lib/routing.jsx";

// ============================================================
// Newtworks TRIVIA MODULE — Wave 5 (Trivia Night) shipped
//
// SCOPE: Block A — review/approve/retire quiz items, browse
// approved items, work the bad-question report queue, switch a
// manual-page read to the resolved FAQ view. Block B — a Play tab
// (Daily Five + Duel) open to every team-visible role, plus a
// weekly trivia standings strip. Wave 3 — a database-enforced
// onboarding training gate: a Training card on Play (server-drawn
// gauntlet/phase_final attempts against named topic sets) and an
// admin-only Gates tab (topic sets, rules, pool preview, step
// attachments, per-teammate status + owner override). Wave 4 part
// 1 — The Grid: a server-drawn, content-adaptive 3-5 column board
// on Play, once per Central-time day like Daily Five, with
// server-authoritative per-cell point values. Wave 5 — Trivia
// Night: a host-run live session on Play, every phone on the same
// question and the same server-side clock, polling quiz_night_state
// every two seconds rather than a realtime subscription. Per-attempt
// option shuffling is live across every play runner (Daily Five,
// Duel, Training, The Grid, Trivia Night). Review/Approved/Reports/
// Gates stay admin-gated in-module. The planning thread authors
// items separately; no question-writing UI lives here.
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
  gridBoardGrid: {
    display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))",
    gap: 8, marginTop: 10,
  },
  gridColumnHeader: {
    fontSize: 11, fontWeight: 700, color: T.slate600, textAlign: "center",
    marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.03em",
  },
  gridCellBtn: (state) => {
    // state: "open" | "correct" | "wrong"
    const map = {
      open: { background: "#fff", border: `1px solid ${T.slate300}`, color: T.slate800, cursor: "pointer" },
      correct: { background: T.greenLt, border: `1px solid ${T.green}`, color: T.green, cursor: "default" },
      wrong: { background: T.redLt, border: `1px solid ${T.red}`, color: T.red, cursor: "default" },
    };
    const chosen = map[state] || map.open;
    return {
      width: "100%", padding: "10px 6px", marginBottom: 6, fontSize: 13, fontWeight: 700,
      textAlign: "center", borderRadius: 6, ...chosen,
    };
  },
  gridRunningTotal: { fontSize: 13, fontWeight: 700, color: T.slate800, marginTop: 10, textAlign: "right" },
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

// Deterministic per-attempt option order. The same attempt and item
// always produce the same order, so a resumed attempt looks identical
// while the correct answer no longer sits in a fixed slot.
function orderedOptions(options, attemptId, itemId) {
  const arr = Array.isArray(options) ? [...options] : [];
  let h = 2166136261;
  const seed = `${attemptId || ""}:${itemId || ""}`;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  for (let i = arr.length - 1; i > 0; i--) {
    h = (Math.imul(h, 1664525) + 1013904223) >>> 0;
    const j = h % (i + 1);
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

export default function Trivia({ userRole, userId }) {
  const vp = useViewport();
  const isAdmin = userRole === "owner" || userRole === "manager";
  const [tabRaw, setTabRaw] = useTabParam("tab", isAdmin ? "review" : "play", ["play", "review", "approved", "reports", "gates"]);
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
            .insert({ item_id: itemId, option_text: opt.option_text, is_correct: opt.is_correct, sort_order: i + 1 });
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
            .insert({ item_id: itemId, option_text: opt.option_text, is_correct: opt.is_correct, sort_order: i + 1 });
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
            <button type="button" style={s.tabBtn(tab === "gates")} onClick={() => setTabRaw("gates")}>Gates</button>
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
        {tab === "play" && <TriviaPlayTab userId={userId} isAdmin={isAdmin} />}
        {isAdmin && loading && <div style={{ padding: 16, fontSize: 13, color: T.slate500 }}>Loading…</div>}
        {isAdmin && !loading && tab === "review" && reviewTab}
        {isAdmin && !loading && tab === "approved" && approvedTab}
        {isAdmin && !loading && tab === "reports" && reportsTab}
        {isAdmin && !loading && tab === "gates" && <TriviaGatesTab userId={userId} />}
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

// The Grid column header rule: strip a leading "sf_" and prefix
// "State Farm ", replace underscores with spaces, capitalise each
// word. sf_auto -> "State Farm Auto", fire -> "Fire",
// commercial_auto -> "Commercial Auto".
function formatGridCategoryLabel(category) {
  let label = category || "";
  let prefix = "";
  if (label.startsWith("sf_")) {
    label = label.slice(3);
    prefix = "State Farm ";
  }
  label = label.replace(/_/g, " ");
  label = label.replace(/\b\w/g, (c) => c.toUpperCase());
  return prefix + label;
}

function TriviaPlayTab({ userId, isAdmin }) {
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

  // Training gates (Wave 3)
  const [gates, setGates] = useState([]);
  const [gatesLoading, setGatesLoading] = useState(true);
  const [gatesError, setGatesError] = useState(null);
  const [activeGate, setActiveGate] = useState(null);
  const [gateAttempt, setGateAttempt] = useState(null);
  const [gateItemsById, setGateItemsById] = useState({});
  const [gateRemainingIds, setGateRemainingIds] = useState([]);
  const [gatePhase, setGatePhase] = useState("idle"); // idle | starting | playing | finishing | result
  const [gateResult, setGateResult] = useState(null);
  const [gateError, setGateError] = useState(null);

  // The Grid (Wave 4 part 1)
  const [gridCatCounts, setGridCatCounts] = useState({});
  const [gridPhase, setGridPhase] = useState("checking"); // checking | not_started | in_progress | board | finishing | finished | error
  const [gridError, setGridError] = useState(null);
  const [gridAttempt, setGridAttempt] = useState(null);
  const [gridBoard, setGridBoard] = useState([]);
  const [gridItemsById, setGridItemsById] = useState({});
  const [gridAnsweredByItem, setGridAnsweredByItem] = useState({});
  const [gridPointsSoFar, setGridPointsSoFar] = useState(0);
  const [gridActiveCell, setGridActiveCell] = useState(null); // { category, item_id, points } when in clue view
  const [gridResult, setGridResult] = useState(null);

  // Trivia Night (Wave 5)
  const [nightActive, setNightActive] = useState(undefined); // undefined = not yet checked; null = nothing running
  const [nightState, setNightState] = useState(null); // full quiz_night_state poll result
  const [nightError, setNightError] = useState(null);
  const [nightSecondsLeft, setNightSecondsLeft] = useState(0);
  const [nightAnswered, setNightAnswered] = useState(false);
  const [nightTimedOut, setNightTimedOut] = useState(false);
  const [nightStandings, setNightStandings] = useState([]);
  const [nightStandingsError, setNightStandingsError] = useState(null);
  const [nightFinishResult, setNightFinishResult] = useState(null);
  const [nightFinishError, setNightFinishError] = useState(null);
  const nightFinishFiredRef = useRef(false);
  const nightAnswerFiredRef = useRef(false);
  const nightQuestionIndexRef = useRef(null);

  // ── Loaders ──
  const loadModesAndPool = useCallback(async () => {
    try {
      const [modesRes, poolRes] = await Promise.all([
        supabase.from("quiz_modes").select("*").eq("agency_id", AGENCY_ID).in("mode_key", ["daily_five", "duel", "gauntlet", "phase_final", "the_grid"]),
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

  const loadGates = useCallback(async () => {
    setGatesLoading(true);
    setGatesError(null);
    try {
      const { data, error } = await supabase.rpc("quiz_my_gates");
      if (error) throw error;
      setGates(Array.isArray(data) ? data : []);
    } catch (ex) {
      setGatesError(ex?.message || "Could not load training requirements.");
    } finally {
      setGatesLoading(false);
    }
  }, []);

  // Category counts for The Grid's client-side availability check — same
  // approved/unblocked scope the rest of Play relies on via RLS.
  const loadGridAvailability = useCallback(async () => {
    try {
      const { data, error } = await supabase.from("quiz_items").select("category");
      if (error) throw error;
      const counts = {};
      for (const row of (data || [])) {
        if (!row.category) continue;
        counts[row.category] = (counts[row.category] || 0) + 1;
      }
      setGridCatCounts(counts);
    } catch (ex) {
      // non-fatal — the card will read "not enough questions yet" if this stays empty
    }
  }, []);

  const loadGridStatus = useCallback(async () => {
    if (!userId) return;
    setGridPhase("checking");
    setGridError(null);
    try {
      const today = ctToday();
      const { data: row, error } = await supabase.from("quiz_attempts").select("*")
        .eq("team_member_id", userId).eq("mode_key", "the_grid").eq("attempt_day", today)
        .maybeSingle();
      if (error) throw error;
      if (!row) {
        setGridAttempt(null);
        setGridPhase("not_started");
      } else if (row.finished_at) {
        setGridAttempt(row);
        setGridResult({ correct_count: row.correct_count, question_count: row.question_count, points_earned: row.points_earned });
        setGridPhase("finished");
      } else {
        setGridAttempt(row);
        setGridPhase("in_progress");
      }
    } catch (ex) {
      setGridError(ex?.message || "Could not check today's board.");
      setGridPhase("error");
    }
  }, [userId]);

  // Is a night running, and where do I stand with it.
  const loadNightActive = useCallback(async () => {
    setNightError(null);
    try {
      const { data, error } = await supabase.rpc("quiz_night_active");
      if (error) throw error;
      setNightActive(data || null);
      if (!data) setNightState(null);
    } catch (ex) {
      setNightError(ex?.message || "Could not check trivia night.");
      setNightActive(null);
    }
  }, []);

  const nightSessionId = nightActive?.session_id || null;
  const nightLiveStatus = nightState?.status || nightActive?.status || null;
  const nightShouldPoll = !!nightSessionId && ["lobby", "question", "reveal"].includes(nightLiveStatus);

  const refreshNightState = useCallback(async () => {
    if (!nightSessionId) return;
    try {
      const { data, error } = await supabase.rpc("quiz_night_state", { p_session_id: nightSessionId });
      if (error) throw error;
      setNightState(data);
    } catch (ex) {
      setNightError(ex?.message || "Could not refresh trivia night.");
    }
  }, [nightSessionId]);

  const loadNightStandings = useCallback(async (sid) => {
    setNightStandingsError(null);
    try {
      const { data, error } = await supabase.rpc("quiz_night_standings", { p_session_id: sid });
      if (error) throw error;
      setNightStandings(Array.isArray(data) ? data : []);
    } catch (ex) {
      setNightStandingsError(ex?.message || "Could not load standings.");
    }
  }, []);

  useEffect(() => { loadModesAndPool(); }, [loadModesAndPool]);
  useEffect(() => { loadDailyStatus(); }, [loadDailyStatus]);
  useEffect(() => { loadDuelLists(); }, [loadDuelLists]);
  useEffect(() => { loadStandings(); }, [loadStandings]);
  useEffect(() => { loadGates(); }, [loadGates]);
  useEffect(() => { loadGridAvailability(); }, [loadGridAvailability]);
  useEffect(() => { loadGridStatus(); }, [loadGridStatus]);
  useEffect(() => { loadNightActive(); }, [loadNightActive]);

  // Poll quiz_night_state every 2s while a session is known and live.
  // Cleared on unmount, and stopped the moment status is finished/abandoned
  // because nightShouldPoll then evaluates false and this effect re-runs.
  useEffect(() => {
    if (!nightShouldPoll) return undefined;
    let cancelled = false;
    const poll = async () => {
      try {
        const { data, error } = await supabase.rpc("quiz_night_state", { p_session_id: nightSessionId });
        if (error) throw error;
        if (!cancelled) setNightState(data);
      } catch (ex) {
        if (!cancelled) setNightError(ex?.message || "Could not refresh trivia night.");
      }
    };
    poll();
    const id = setInterval(poll, 2000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [nightShouldPoll, nightSessionId]);

  // Local smoothing tick between polls — each poll overwrites this.
  useEffect(() => {
    if (nightState?.seconds_left != null) setNightSecondsLeft(nightState.seconds_left);
  }, [nightState?.seconds_left]);
  useEffect(() => {
    if (nightLiveStatus !== "question") return undefined;
    const t = setInterval(() => setNightSecondsLeft(s => Math.max(0, s - 1)), 1000);
    return () => clearInterval(t);
  }, [nightLiveStatus]);

  // Reset the per-question answer lock when the question index advances.
  useEffect(() => {
    const idx = nightState?.current_index;
    if (idx == null) return;
    if (nightQuestionIndexRef.current !== idx) {
      nightQuestionIndexRef.current = idx;
      setNightAnswered(false);
      setNightTimedOut(false);
      nightAnswerFiredRef.current = false;
    }
  }, [nightState?.current_index]);

  // Standings load once on entering reveal, and once on entering finished.
  const nightPrevStatusRef = useRef(null);
  useEffect(() => {
    if (!nightSessionId) return;
    if ((nightLiveStatus === "reveal" || nightLiveStatus === "finished")
        && nightPrevStatusRef.current !== nightLiveStatus) {
      loadNightStandings(nightSessionId);
    }
    nightPrevStatusRef.current = nightLiveStatus;
  }, [nightSessionId, nightLiveStatus, loadNightStandings]);

  // Finish my own attempt exactly once when the night ends.
  useEffect(() => {
    if (nightLiveStatus !== "finished") return;
    if (!nightState?.my_attempt_id) return;
    if (nightFinishFiredRef.current) return;
    nightFinishFiredRef.current = true;
    (async () => {
      try {
        const { data, error } = await supabase.rpc("quiz_finish_attempt", { p_attempt_id: nightState.my_attempt_id });
        if (error) {
          if (!/already finished/i.test(error.message || "")) setNightFinishError(error.message);
          return;
        }
        setNightFinishResult(data);
      } catch (ex) {
        if (!/already finished/i.test(ex?.message || "")) {
          setNightFinishError(ex?.message || "Could not finish.");
        }
      }
    })();
  }, [nightLiveStatus, nightState?.my_attempt_id]);

  // ── Training gate actions ──
  const startGate = async (gate) => {
    setGateError(null);
    setActiveGate(gate);
    setGatePhase("starting");
    try {
      const { data: attemptId, error } = await supabase.rpc("quiz_start_gated_attempt", {
        p_mode_key: gate.mode_key, p_topic_set_id: gate.topic_set_id,
      });
      if (error) {
        setGateError(error.message);
        setGatePhase("idle");
        return;
      }
      const { data: attemptRow, error: fetchErr } = await supabase
        .from("quiz_attempts").select("*").eq("id", attemptId).maybeSingle();
      if (fetchErr) throw fetchErr;
      const ids = (attemptRow?.context?.item_ids) || [];
      const itemsMap = await loadItemsWithOptions(ids);
      setGateAttempt(attemptRow);
      setGateItemsById(itemsMap);
      setGateRemainingIds(ids);
      setGateResult(null);
      setGatePhase("playing");
    } catch (ex) {
      setGateError(ex?.message || "Could not start.");
      setGatePhase("idle");
    }
  };

  const submitGateAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    const { error } = await supabase.from("quiz_answers").insert({
      attempt_id: gateAttempt.id, item_id: itemId, chosen_option_id: chosenOptionId, seconds_taken: secondsTaken,
    });
    if (error) throw error;
  };

  const finishGate = async () => {
    if (!gateAttempt) return;
    setGatePhase("finishing");
    const { data, error } = await supabase.rpc("quiz_finish_attempt", { p_attempt_id: gateAttempt.id });
    if (error) {
      setGateError(error.message || "Could not finish — try again.");
      setGatePhase("playing");
      return;
    }
    setGateResult(data);
    setGatePhase("result");
    await loadGates();
  };

  const retakeGate = () => {
    if (activeGate) startGate(activeGate);
  };

  const closeGate = () => {
    setActiveGate(null);
    setGateAttempt(null);
    setGatePhase("idle");
    setGateResult(null);
    setGateError(null);
  };

  // ── The Grid actions ──
  const beginPlayingGrid = async (attempt) => {
    const board = attempt?.context?.board || [];
    const allIds = (attempt?.context?.item_ids) || [];
    const [ansRes, itemsMap] = await Promise.all([
      supabase.from("quiz_answers").select("item_id, chosen_option_id").eq("attempt_id", attempt.id),
      loadItemsWithOptions(allIds),
    ]);
    if (ansRes.error) throw ansRes.error;

    const answeredMap = {};
    let pts = 0;
    for (const r of (ansRes.data || [])) {
      const item = itemsMap[r.item_id];
      const opt = (item?.options || []).find(o => o.id === r.chosen_option_id);
      answeredMap[r.item_id] = { chosen_option_id: r.chosen_option_id, is_correct: !!opt?.is_correct };
    }
    for (const col of board) {
      for (const clue of (col.clues || [])) {
        const ans = answeredMap[clue.item_id];
        if (ans && ans.is_correct) pts += clue.points;
      }
    }

    setGridAttempt(attempt);
    setGridBoard(board);
    setGridItemsById(itemsMap);
    setGridAnsweredByItem(answeredMap);
    setGridPointsSoFar(pts);
    setGridActiveCell(null);

    const totalCells = board.reduce((n, col) => n + (col.clues || []).length, 0);
    const answeredCount = Object.keys(answeredMap).length;
    if (totalCells > 0 && answeredCount >= totalCells) {
      setGridPhase("finishing");
      await finishGrid(attempt.id);
    } else {
      setGridPhase("board");
    }
  };

  const startGrid = async () => {
    setGridError(null);
    setGridPhase("checking");
    try {
      const { data: attemptId, error } = await supabase.rpc("quiz_start_grid_attempt");
      if (error) {
        setGridError(error.message);
        setGridPhase("not_started");
        return;
      }
      const { data: row, error: fetchErr } = await supabase
        .from("quiz_attempts").select("*").eq("id", attemptId).maybeSingle();
      if (fetchErr) throw fetchErr;
      await beginPlayingGrid(row);
    } catch (ex) {
      setGridError(ex?.message || "Could not start the board.");
      setGridPhase("error");
    }
  };

  const resumeGrid = async () => {
    if (!gridAttempt) return;
    setGridError(null);
    setGridPhase("checking");
    try {
      await beginPlayingGrid(gridAttempt);
    } catch (ex) {
      setGridError(ex?.message || "Could not resume the board.");
      setGridPhase("error");
    }
  };

  const openGridCell = (category, clue) => {
    if (gridAnsweredByItem[clue.item_id]) return;
    setGridActiveCell({ category, item_id: clue.item_id, points: clue.points });
  };

  const submitGridAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    const { error } = await supabase.from("quiz_answers").insert({
      attempt_id: gridAttempt.id, item_id: itemId, chosen_option_id: chosenOptionId, seconds_taken: secondsTaken,
    });
    if (error) throw error;
    const item = gridItemsById[itemId];
    const opt = (item?.options || []).find(o => o.id === chosenOptionId);
    const isCorrect = !!opt?.is_correct;
    setGridAnsweredByItem(prev => ({ ...prev, [itemId]: { chosen_option_id: chosenOptionId, is_correct: isCorrect } }));
    if (isCorrect && gridActiveCell && gridActiveCell.item_id === itemId) {
      setGridPointsSoFar(prev => prev + gridActiveCell.points);
    }
  };

  const finishGrid = async (attemptId) => {
    setGridPhase("finishing");
    const { data, error } = await supabase.rpc("quiz_finish_attempt", { p_attempt_id: attemptId });
    if (error) {
      setGridError(error.message || "Could not finish — try again.");
      setGridPhase("board");
      return;
    }
    setGridResult(data);
    setGridPhase("finished");
    await loadStandings();
  };

  // Every cell spent → finish automatically, same moment the board goes empty.
  useEffect(() => {
    if (gridPhase !== "board" || !gridAttempt) return;
    const totalCells = gridBoard.reduce((n, col) => n + (col.clues || []).length, 0);
    const answeredCount = Object.keys(gridAnsweredByItem).length;
    if (totalCells > 0 && answeredCount >= totalCells) {
      finishGrid(gridAttempt.id);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [gridAnsweredByItem, gridBoard, gridPhase, gridAttempt]);

  // ── Trivia Night actions ──
  const nightStartSession = async () => {
    setNightError(null);
    try {
      const { error } = await supabase.rpc("quiz_night_create_session");
      if (error) { setNightError(error.message); return; }
      await loadNightActive();
    } catch (ex) {
      setNightError(ex?.message || "Could not start trivia night.");
    }
  };

  const nightJoinSession = async () => {
    if (!nightSessionId) return;
    setNightError(null);
    try {
      const { error } = await supabase.rpc("quiz_night_join", { p_session_id: nightSessionId });
      if (error) { setNightError(error.message); return; }
      await loadNightActive();
    } catch (ex) {
      setNightError(ex?.message || "Could not join.");
    }
  };

  const nightStartTheNight = async () => {
    if (!nightSessionId) return;
    setNightError(null);
    try {
      const { error } = await supabase.rpc("quiz_night_start", { p_session_id: nightSessionId });
      if (error) { setNightError(error.message); return; }
      await refreshNightState();
    } catch (ex) {
      setNightError(ex?.message || "Could not start the night.");
    }
  };

  const nightAdvance = async () => {
    if (!nightSessionId) return;
    setNightError(null);
    try {
      const { error } = await supabase.rpc("quiz_night_advance", { p_session_id: nightSessionId });
      if (error) { setNightError(error.message); return; }
      await refreshNightState();
    } catch (ex) {
      setNightError(ex?.message || "Could not advance.");
    }
  };

  const nightAbandonSession = async () => {
    if (!nightSessionId) return;
    setNightError(null);
    try {
      const { error } = await supabase.rpc("quiz_night_abandon", { p_session_id: nightSessionId });
      if (error) { setNightError(error.message); return; }
      await refreshNightState();
    } catch (ex) {
      setNightError(ex?.message || "Could not call it off.");
    }
  };

  const submitNightAnswer = async (optionId) => {
    if (!nightSessionId || nightAnswerFiredRef.current) return;
    nightAnswerFiredRef.current = true;
    setNightAnswered(true);
    if (optionId == null) setNightTimedOut(true);
    try {
      const { error } = await supabase.rpc("quiz_night_answer", {
        p_session_id: nightSessionId, p_option_id: optionId,
      });
      if (error) setNightError(error.message);
    } catch (ex) {
      setNightError(ex?.message || "Could not submit your answer.");
    }
  };

  // Timer hits zero with no answer → send once, automatically.
  useEffect(() => {
    if (nightLiveStatus !== "question") return;
    if (nightSecondsLeft > 0) return;
    if (!nightState?.my_attempt_id) return;
    if (nightAnswerFiredRef.current) return;
    submitNightAnswer(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nightSecondsLeft, nightLiveStatus, nightState?.my_attempt_id]);

  const nightDone = () => {
    setNightActive(null);
    setNightState(null);
    setNightStandings([]);
    setNightFinishResult(null);
    setNightFinishError(null);
    nightFinishFiredRef.current = false;
    nightAnswerFiredRef.current = false;
    nightQuestionIndexRef.current = null;
  };

  // ── Daily Five actions ──
  const startFreshDaily = async () => {
    setDfError(null);
    setDfPhase("checking");
    try {
      const dailyCfg = modes.daily_five;
      const ids = sampleN(itemPool, dailyCfg?.question_count || 5);
      if (ids.length < (dailyCfg?.question_count || 5)) {
        setDfError("Not enough questions available yet.");
        setDfPhase("not_started");
        return;
      }
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

    if (remaining.length === 0 && answeredIds.size > 0) {
      setDfPhase("finishing");
      await finishDaily(attempt.id);
    } else if (remaining.length === 0 && answeredIds.size === 0) {
      setDfError("Today's round is empty — it will reset tomorrow.");
      setDfPhase("not_started");
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
      if (ids.length < (duelCfg?.question_count || 7)) {
        setDuelError("Not enough questions available yet.");
        setDuelMode("idle");
        return;
      }
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
  const gridCfg = modes.the_grid;
  const gridQualifyingCats = useMemo(() => {
    return Object.entries(gridCatCounts)
      .filter(([, n]) => n >= 5)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .map(([cat]) => cat);
  }, [gridCatCounts]);
  const gridAvailable = gridQualifyingCats.length >= 3;
  const nightJoined = nightState?.players?.some(p => p.is_me) ?? nightActive?.joined ?? false;
  const nightIsHost = nightState?.is_host ?? nightActive?.is_host ?? false;

  return (
    <div>
      {(modesError || poolError) && <div style={s.errorBanner}>{modesError || poolError}</div>}

      {!gatesLoading && (gatesError || gates.length > 0) && (
        <div style={s.playCard}>
          <div style={s.playCardTitle}>Training</div>
          {gatesError && <div style={s.errorBanner}>{gatesError}</div>}

          {!gatesError && activeGate && gatePhase !== "idle" && (
            <div>
              <div style={{ fontSize: 12, color: T.slate500, marginBottom: 8 }}>
                {activeGate.step_title} — {activeGate.set_title}
              </div>
              {gateError && <div style={s.errorBanner}>{gateError}</div>}

              {gatePhase === "starting" && <div style={{ fontSize: 13, color: T.slate500 }}>Starting…</div>}

              {gatePhase === "playing" && gateAttempt && (
                <QuestionRunner
                  itemIds={gateRemainingIds}
                  itemsById={gateItemsById}
                  attemptId={gateAttempt?.id}
                  secondsPerQuestion={(activeGate.mode_key === "gauntlet" ? modes.gauntlet : modes.phase_final)?.seconds_per_question || 30}
                  onSubmitAnswer={submitGateAnswer}
                  onAllDone={finishGate}
                />
              )}

              {gatePhase === "finishing" && <div style={{ fontSize: 13, color: T.slate500 }}>Finishing up…</div>}

              {gatePhase === "result" && gateResult && (
                <div>
                  <div style={s.bigStat}>
                    {gateResult.question_count > 0 ? Math.round((gateResult.correct_count * 100) / gateResult.question_count) : 0}%
                  </div>
                  {gateResult.passed === true && (
                    <>
                      <div style={{ ...s.smallLabel, color: T.green, fontWeight: 700 }}>
                        PASSED — {gateResult.correct_count}/{gateResult.question_count}
                      </div>
                      <div style={s.actionsRow}>
                        <button type="button" style={s.ghostBtn} onClick={closeGate}>Close</button>
                      </div>
                    </>
                  )}
                  {gateResult.passed === false && (
                    <>
                      <div style={{ ...s.smallLabel, color: T.red, fontWeight: 700 }}>
                        Not yet — {gateResult.passing_score}% needed
                      </div>
                      <div style={s.actionsRow}>
                        <button type="button" style={s.primaryBtn} onClick={retakeGate}>Retake</button>
                        <button type="button" style={s.ghostBtn} onClick={closeGate}>Close</button>
                      </div>
                    </>
                  )}
                </div>
              )}
            </div>
          )}

          {!gatesError && (!activeGate || gatePhase === "idle") && gates.map(g => (
            <div key={g.step_id} style={s.duelListRow}>
              <div style={{ fontWeight: 600, marginBottom: 2 }}>{g.step_title}</div>
              <div style={{ fontSize: 12, color: T.slate500, marginBottom: 4 }}>
                {g.set_title} — {(g.mode_key === "gauntlet" ? modes.gauntlet?.title : modes.phase_final?.title) || g.mode_key} — pass at {g.passing_score}%
                {g.best_pct != null && <> — best: {g.best_pct}%</>}
              </div>
              {g.overridden ? (
                <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>cleared by owner</div>
              ) : (
                <button type="button" style={s.primaryBtn} onClick={() => startGate(g)}>
                  {g.best_pct != null ? "Retake" : "Take it"}
                </button>
              )}
            </div>
          ))}
        </div>
      )}

      <div style={s.playGrid}>
        {/* ── Daily Five card ── */}
        <div style={s.playCard}>
          <div style={s.playCardTitle}>Daily Five</div>
          <div style={s.playCardDesc}>{dailyCfg?.description || "Five questions a day. Keep your streak going."}</div>

          {dfError && <div style={s.errorBanner}>{dfError}</div>}

          {dfPhase === "checking" && <div style={{ fontSize: 13, color: T.slate500 }}>Checking today's status…</div>}

          {dfPhase === "not_started" && (
            itemPool.length < (dailyCfg?.question_count || 5) ? (
              <div style={{ fontSize: 13, color: T.slate500 }}>Questions are coming soon — check back after review.</div>
            ) : (
              <button type="button" style={s.primaryBtn} onClick={startFreshDaily}>Play today's five</button>
            )
          )}

          {dfPhase === "in_progress" && (
            <button type="button" style={s.primaryBtn} onClick={resumeDaily}>Resume</button>
          )}

          {dfPhase === "finishing" && <div style={{ fontSize: 13, color: T.slate500 }}>Finishing up…</div>}

          {dfPhase === "playing" && dfAttempt && (
            <QuestionRunner
              itemIds={dfRemainingIds}
              itemsById={dfItemsById}
              attemptId={dfAttempt?.id}
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
                attemptId={duelActiveAttempt?.id}
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
              {itemPool.length < (duelCfg?.question_count || 7) ? (
                <div style={{ fontSize: 13, color: T.slate500 }}>Questions are coming soon — check back after review.</div>
              ) : (
                <button type="button" style={s.ghostBtn} onClick={() => setDuelMode(duelMode === "picking" ? "idle" : "picking")}>
                  Challenge a teammate
                </button>
              )}
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

        {/* ── The Grid card ── */}
        <div style={s.playCard}>
          <div style={s.playCardTitle}>The Grid</div>
          <div style={s.playCardDesc}>Pick a square, answer the question — higher rows are worth more.</div>

          {gridError && <div style={s.errorBanner}>{gridError}</div>}

          {gridPhase === "checking" && <div style={{ fontSize: 13, color: T.slate500 }}>Checking today's board…</div>}

          {gridPhase === "not_started" && (
            !gridAvailable ? (
              <div style={{ fontSize: 13, color: T.slate500 }}>
                Not enough questions yet — the board needs three categories with five questions each.
              </div>
            ) : (
              <button type="button" style={s.primaryBtn} onClick={startGrid}>Play The Grid</button>
            )
          )}

          {gridPhase === "in_progress" && (
            <button type="button" style={s.primaryBtn} onClick={resumeGrid}>Resume the board</button>
          )}

          {gridPhase === "finishing" && <div style={{ fontSize: 13, color: T.slate500 }}>Finishing up…</div>}

          {gridPhase === "board" && gridAttempt && !gridActiveCell && (
            <div>
              <div style={s.gridBoardGrid}>
                {gridBoard.map(col => (
                  <div key={col.category}>
                    <div style={s.gridColumnHeader}>{formatGridCategoryLabel(col.category)}</div>
                    {(col.clues || []).map(clue => {
                      const ans = gridAnsweredByItem[clue.item_id];
                      const cellState = ans ? (ans.is_correct ? "correct" : "wrong") : "open";
                      return (
                        <button
                          key={clue.item_id}
                          type="button"
                          style={s.gridCellBtn(cellState)}
                          disabled={!!ans}
                          onClick={() => openGridCell(col.category, clue)}
                        >
                          {clue.points}
                        </button>
                      );
                    })}
                  </div>
                ))}
              </div>
              <div style={s.gridRunningTotal}>{gridPointsSoFar} points so far</div>
            </div>
          )}

          {gridPhase === "board" && gridAttempt && gridActiveCell && (
            <QuestionRunner
              itemIds={[gridActiveCell.item_id]}
              itemsById={gridItemsById}
              attemptId={gridAttempt.id}
              secondsPerQuestion={gridCfg?.seconds_per_question || 30}
              onSubmitAnswer={submitGridAnswer}
              onAllDone={() => setGridActiveCell(null)}
            />
          )}

          {gridPhase === "finished" && gridResult && (
            <div>
              <div style={s.bigStat}>{gridResult.correct_count}/{gridResult.question_count}</div>
              <div style={s.smallLabel}>{gridResult.points_earned} points earned</div>
              <div style={s.smallLabel}>once a day — back tomorrow.</div>
              {gridResult.on_leaderboard && (
                <div style={{ ...s.smallLabel, color: T.gold, fontWeight: 700, marginTop: 4 }}>made the board! 🏆</div>
              )}
            </div>
          )}
        </div>

        {/* ── Trivia Night card ── */}
        <div style={s.playCard}>
          <div style={s.playCardTitle}>Trivia Night</div>
          <div style={s.playCardDesc}>Everyone plays the same questions at the same time, live.</div>

          {nightError && <div style={s.errorBanner}>{nightError}</div>}

          {nightActive === undefined && (
            <div style={{ fontSize: 13, color: T.slate500 }}>Checking…</div>
          )}

          {nightActive === null && (
            isAdmin ? (
              <button type="button" style={s.primaryBtn} onClick={nightStartSession}>Start trivia night</button>
            ) : (
              <div style={{ fontSize: 13, color: T.slate500 }}>
                No trivia night running right now. An owner starts these live.
              </div>
            )
          )}

          {nightActive && !(nightIsHost || nightJoined) && nightLiveStatus === "lobby" && (
            <button type="button" style={s.primaryBtn} onClick={nightJoinSession}>Join</button>
          )}

          {nightActive && !(nightIsHost || nightJoined)
            && (nightLiveStatus === "question" || nightLiveStatus === "reveal") && (
            <div style={{ fontSize: 13, color: T.slate500 }}>This one already started — catch the next.</div>
          )}

          {nightActive && (nightIsHost || nightJoined) && nightLiveStatus === "lobby" && (
            <div>
              <div style={{ fontSize: 12, color: T.slate500, marginBottom: 8 }}>Players in the lobby:</div>
              {(nightState?.players || []).length === 0 && (
                <div style={{ fontSize: 13, color: T.slate500 }}>Nobody has joined yet.</div>
              )}
              {(nightState?.players || []).map(p => (
                <div key={p.team_member_id} style={s.duelListRow}>{p.name || "—"}</div>
              ))}

              {!nightJoined && (
                <div style={{ marginTop: 10 }}>
                  <button type="button" style={s.primaryBtn} onClick={nightJoinSession}>Join</button>
                </div>
              )}

              {nightIsHost && (
                <>
                  <div style={s.actionsRow}>
                    <button
                      type="button"
                      style={s.primaryBtn}
                      onClick={nightStartTheNight}
                      disabled={(nightState?.players || []).length === 0}
                    >
                      Start the night
                    </button>
                    <button type="button" style={s.ghostBtn} onClick={nightAbandonSession}>Call it off</button>
                  </div>
                  {(nightState?.players || []).length === 0 && (
                    <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
                      Waiting for players to join before you can start.
                    </div>
                  )}
                </>
              )}
              {!nightIsHost && nightJoined && (
                <div style={{ fontSize: 13, color: T.slate500, marginTop: 8 }}>You're in — waiting on the host.</div>
              )}
            </div>
          )}

          {nightActive && (nightIsHost || nightJoined) && nightLiveStatus === "question" && (
            <div>
              <div style={{ fontSize: 11, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.03em", marginBottom: 4 }}>
                {formatGridCategoryLabel(nightState?.question?.category)}
              </div>
              <div style={s.qStem}>{nightState?.question?.stem}</div>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10 }}>
                <span style={s.timerPill(nightSecondsLeft <= 5)}>{nightSecondsLeft}s</span>
                <span style={{ fontSize: 11, color: T.slate500 }}>
                  {(nightState?.players || []).filter(p => p.answered_current).length} of {(nightState?.players || []).length} answered
                </span>
              </div>

              {nightState?.my_attempt_id ? (
                nightAnswered ? (
                  <div style={{ fontSize: 13, color: T.slate500 }}>
                    {nightTimedOut ? "Time — no answer." : "Locked in — waiting on the room."}
                  </div>
                ) : (
                  orderedOptions(nightState?.question?.options, nightState?.my_attempt_id, nightState?.question?.item_id).map(o => (
                    <button
                      key={o.id}
                      type="button"
                      style={s.qOptionBtn("default")}
                      onClick={() => submitNightAnswer(o.id)}
                    >
                      {o.option_text}
                    </button>
                  ))
                )
              ) : (
                <div style={{ fontSize: 13, color: T.slate500 }}>Watching — you're not in this one.</div>
              )}

              {nightIsHost && (
                <div style={s.actionsRow}>
                  <button type="button" style={s.primaryBtn} onClick={nightAdvance}>Reveal the answer</button>
                </div>
              )}
            </div>
          )}

          {nightActive && (nightIsHost || nightJoined) && nightLiveStatus === "reveal" && (
            <div>
              <div style={{ fontSize: 11, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.03em", marginBottom: 4 }}>
                {formatGridCategoryLabel(nightState?.question?.category)}
              </div>
              <div style={s.qStem}>{nightState?.question?.stem}</div>
              {orderedOptions(nightState?.question?.options, nightState?.my_attempt_id, nightState?.question?.item_id).map(o => (
                <div key={o.id} style={s.qOptionBtn(o.is_correct ? "revealCorrect" : "revealDim")}>
                  {o.option_text}
                </div>
              ))}
              {nightState?.question?.explanation && <div style={s.explanationBox}>{nightState.question.explanation}</div>}

              <div style={{ marginTop: 12, fontSize: 12, color: T.slate500 }}>Standings so far:</div>
              {nightStandingsError && <div style={s.errorBanner}>{nightStandingsError}</div>}
              {nightStandings.map(row => (
                <div key={row.team_member_id} style={s.standingsRow}>
                  <span>{row.name || "—"}{row.is_me ? " (you)" : ""}</span>
                  <span>{row.correct_count} correct — {row.points == null ? "—" : row.points} pts</span>
                </div>
              ))}

              {nightIsHost && (
                <div style={s.actionsRow}>
                  <button type="button" style={s.primaryBtn} onClick={nightAdvance}>
                    {(nightState?.current_index ?? 0) + 1 < (nightState?.question_total ?? 0) ? "Next question" : "Finish"}
                  </button>
                </div>
              )}
            </div>
          )}

          {nightActive && (nightIsHost || nightJoined) && nightLiveStatus === "finished" && (
            <div>
              {nightFinishError && <div style={s.errorBanner}>{nightFinishError}</div>}
              {nightState?.my_attempt_id ? (
                nightFinishResult ? (
                  <div>
                    <div style={s.bigStat}>{nightFinishResult.correct_count}/{nightFinishResult.question_count}</div>
                    <div style={s.smallLabel}>{nightFinishResult.points_earned} points earned</div>
                    {nightFinishResult.week_points != null && (
                      <div style={s.smallLabel}>{nightFinishResult.week_points} points this week</div>
                    )}
                    {nightFinishResult.on_leaderboard && (
                      <div style={{ ...s.smallLabel, color: T.gold, fontWeight: 700, marginTop: 4 }}>made the board! 🏆</div>
                    )}
                  </div>
                ) : (
                  <div style={{ fontSize: 13, color: T.slate500 }}>Finishing up…</div>
                )
              ) : (
                <div style={{ fontSize: 13, color: T.slate500 }}>The night is over.</div>
              )}

              <div style={{ marginTop: 12, fontSize: 12, color: T.slate500 }}>Final standings:</div>
              {nightStandingsError && <div style={s.errorBanner}>{nightStandingsError}</div>}
              {nightStandings.map(row => (
                <div
                  key={row.team_member_id}
                  style={row.is_me ? { ...s.standingsRow, fontWeight: 700 } : s.standingsRow}
                >
                  <span>{row.name || "—"}{row.is_me ? " (you)" : ""}</span>
                  <span>{row.correct_count} correct — {row.points == null ? "—" : row.points} pts</span>
                </div>
              ))}

              <div style={s.actionsRow}>
                <button type="button" style={s.ghostBtn} onClick={nightDone}>Done</button>
              </div>
            </div>
          )}

          {nightActive && (nightIsHost || nightJoined) && nightLiveStatus === "abandoned" && (
            <div>
              <div style={{ fontSize: 13, color: T.slate500 }}>That trivia night was called off.</div>
              <div style={s.actionsRow}>
                <button type="button" style={s.ghostBtn} onClick={nightDone}>Done</button>
              </div>
            </div>
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

// ============================================================
// WAVE 3 — GATES TAB (admin only)
// Topic sets, rules, pool preview, step attachments, and
// per-teammate gate status + owner override.
// ============================================================

function slugifySetKey(title) {
  return (title || "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9\s_]/g, "")
    .replace(/\s+/g, "_");
}

function renderRuleLabel(rule, pinnedItemsById) {
  const parts = [];
  if (rule.item_id) {
    const stem = pinnedItemsById[rule.item_id]?.stem || "(item)";
    parts.push(`pinned: ${stem.slice(0, 60)}`);
  }
  if (rule.category) parts.push(`category: ${rule.category}`);
  if (rule.difficulty) parts.push(`difficulty: ${rule.difficulty}`);
  if (parts.length === 0) return "whole bank";
  return parts.join(" + ");
}

function TriviaGatesTab({ userId }) {
  const [topicSets, setTopicSets] = useState([]);
  const [setsError, setSetsError] = useState(null);
  const [setsLoading, setSetsLoading] = useState(true);
  const [selectedSetId, setSelectedSetId] = useState(null);

  const [newSetTitle, setNewSetTitle] = useState("");
  const [newSetDesc, setNewSetDesc] = useState("");
  const [editingSetId, setEditingSetId] = useState(null);
  const [editSetTitle, setEditSetTitle] = useState("");
  const [editSetDesc, setEditSetDesc] = useState("");

  const [rules, setRules] = useState([]);
  const [rulesError, setRulesError] = useState(null);
  const [pinnedItemsById, setPinnedItemsById] = useState({});
  const [categories, setCategories] = useState([]);
  const [newRuleCategory, setNewRuleCategory] = useState("");
  const [newRuleDifficulty, setNewRuleDifficulty] = useState("");
  const [pinnedSearch, setPinnedSearch] = useState("");
  const [pinnedResults, setPinnedResults] = useState([]);

  const [poolPreview, setPoolPreview] = useState(null);
  const [poolPreviewError, setPoolPreviewError] = useState(null);
  const [modesForPreview, setModesForPreview] = useState({});

  const [stepTemplates, setStepTemplates] = useState([]);
  const [templatesError, setTemplatesError] = useState(null);
  const [attachSetId, setAttachSetId] = useState({});
  const [attachMode, setAttachMode] = useState({});

  const [teamList, setTeamList] = useState([]);
  const [teamGateRows, setTeamGateRows] = useState([]);
  const [overridesList, setOverridesList] = useState([]);
  const [teamAttempts, setTeamAttempts] = useState([]);
  const [plansCount, setPlansCount] = useState(null);
  const [teamStatusError, setTeamStatusError] = useState(null);
  const [overrideOpenFor, setOverrideOpenFor] = useState(null);
  const [overrideReason, setOverrideReason] = useState("");

  const [gatesBanner, setGatesBanner] = useState(null);

  // ── Loaders ──
  const loadSets = useCallback(async () => {
    setSetsLoading(true);
    setSetsError(null);
    try {
      const { data, error } = await supabase.from("quiz_topic_sets").select("*").eq("agency_id", AGENCY_ID);
      if (error) throw error;
      const list = Array.isArray(data) ? [...data] : [];
      list.sort((a, b) => {
        if (!!a.is_active !== !!b.is_active) return a.is_active ? -1 : 1;
        return (a.title || "").localeCompare(b.title || "");
      });
      setTopicSets(list);
      setSelectedSetId(prev => prev || (list[0]?.id ?? null));
    } catch (ex) {
      setSetsError(ex?.message || "Could not load topic sets.");
    } finally {
      setSetsLoading(false);
    }
  }, []);

  const loadCategories = useCallback(async () => {
    try {
      const { data, error } = await supabase.from("quiz_items").select("category").eq("agency_id", AGENCY_ID);
      if (error) throw error;
      const set = new Set((data || []).map(r => r.category).filter(Boolean));
      setCategories([...set].sort());
    } catch (ex) {
      // non-fatal — category dropdown just stays empty
    }
  }, []);

  const loadRules = useCallback(async (setId) => {
    if (!setId) { setRules([]); setPinnedItemsById({}); return; }
    setRulesError(null);
    try {
      const { data, error } = await supabase.from("quiz_topic_set_rules").select("*").eq("set_id", setId);
      if (error) throw error;
      const list = Array.isArray(data) ? data : [];
      setRules(list);
      const pinnedIds = list.map(r => r.item_id).filter(Boolean);
      if (pinnedIds.length > 0) {
        const { data: pinnedData } = await supabase.from("quiz_items").select("id, stem").in("id", pinnedIds);
        const map = {};
        for (const it of (pinnedData || [])) map[it.id] = it;
        setPinnedItemsById(map);
      } else {
        setPinnedItemsById({});
      }
    } catch (ex) {
      setRulesError(ex?.message || "Could not load rules.");
    }
  }, []);

  const loadPoolPreview = useCallback(async (setId) => {
    if (!setId) { setPoolPreview(null); return; }
    setPoolPreviewError(null);
    try {
      const [poolRes, modesRes] = await Promise.all([
        supabase.rpc("quiz_topic_set_pool", { p_set_id: setId }),
        supabase.from("quiz_modes").select("*").eq("agency_id", AGENCY_ID).in("mode_key", ["gauntlet", "phase_final"]),
      ]);
      if (poolRes.error) throw poolRes.error;
      if (modesRes.error) throw modesRes.error;
      const modeMap = {};
      for (const m of (modesRes.data || [])) modeMap[m.mode_key] = m;
      setModesForPreview(modeMap);
      setPoolPreview({ count: Array.isArray(poolRes.data) ? poolRes.data.length : 0 });
    } catch (ex) {
      setPoolPreviewError(ex?.message || "Could not load pool preview.");
    }
  }, []);

  const loadTemplates = useCallback(async () => {
    setTemplatesError(null);
    try {
      const { data, error } = await supabase.from("onboarding_step_templates").select("*").eq("agency_id", AGENCY_ID);
      if (error) throw error;
      const list = Array.isArray(data) ? [...data] : [];
      list.sort((a, b) => (a.phase - b.phase) || (a.title || "").localeCompare(b.title || ""));
      setStepTemplates(list);
    } catch (ex) {
      setTemplatesError(ex?.message || "Could not load step templates.");
    }
  }, []);

  const loadTeamStatus = useCallback(async () => {
    setTeamStatusError(null);
    try {
      const teamRes = await supabase.from("team").select("id, first_name, last_name, role, is_active")
        .eq("agency_id", AGENCY_ID).eq("is_active", true);
      if (teamRes.error) throw teamRes.error;
      const filteredTeam = (teamRes.data || []).filter(t => t.role !== "backoffice");
      setTeamList(filteredTeam);

      const plansRes = await supabase.from("team_onboarding_plans").select("id, team_member_id").eq("agency_id", AGENCY_ID);
      if (plansRes.error) throw plansRes.error;
      const plans = plansRes.data || [];
      setPlansCount(plans.length);
      const planIds = plans.map(p => p.id);
      const planMemberById = {};
      for (const p of plans) planMemberById[p.id] = p.team_member_id;

      let gateSteps = [];
      if (planIds.length > 0) {
        const stepsRes = await supabase.from("team_onboarding_steps")
          .select("*")
          .in("plan_id", planIds)
          .is("completed_at", null)
          .not("required_topic_set_id", "is", null);
        if (stepsRes.error) throw stepsRes.error;
        gateSteps = (stepsRes.data || []).map(row => ({ ...row, team_member_id: planMemberById[row.plan_id] }));
      }
      setTeamGateRows(gateSteps);

      const overridesRes = await supabase.from("quiz_gate_overrides").select("*").eq("agency_id", AGENCY_ID);
      if (overridesRes.error) throw overridesRes.error;
      setOverridesList(Array.isArray(overridesRes.data) ? overridesRes.data : []);

      const memberIds = [...new Set(gateSteps.map(r => r.team_member_id).filter(Boolean))];
      if (memberIds.length > 0) {
        const attemptsRes = await supabase.from("quiz_attempts")
          .select("team_member_id, topic_set_id, mode_key, passed, finished_at")
          .eq("agency_id", AGENCY_ID)
          .in("team_member_id", memberIds)
          .not("finished_at", "is", null);
        if (attemptsRes.error) throw attemptsRes.error;
        setTeamAttempts(Array.isArray(attemptsRes.data) ? attemptsRes.data : []);
      } else {
        setTeamAttempts([]);
      }
    } catch (ex) {
      setTeamStatusError(ex?.message || "Could not load team status.");
    }
  }, []);

  useEffect(() => { loadSets(); }, [loadSets]);
  useEffect(() => { loadCategories(); }, [loadCategories]);
  useEffect(() => { loadTemplates(); }, [loadTemplates]);
  useEffect(() => { loadTeamStatus(); }, [loadTeamStatus]);
  useEffect(() => {
    if (selectedSetId) {
      loadRules(selectedSetId);
      loadPoolPreview(selectedSetId);
    } else {
      setRules([]);
      setPoolPreview(null);
    }
  }, [selectedSetId, loadRules, loadPoolPreview]);

  const memberHasPassed = (memberId, setId, modeKey) => teamAttempts.some(a =>
    a.team_member_id === memberId && a.topic_set_id === setId && a.mode_key === modeKey && a.passed === true
  );
  const memberOverrideRow = (memberId, setId, modeKey) => overridesList.find(o =>
    o.team_member_id === memberId && o.topic_set_id === setId && o.mode_key === modeKey
  );

  // ── Actions ──
  const doCreateSet = async () => {
    const title = newSetTitle.trim();
    if (!title) return;
    setGatesBanner(null);
    try {
      const set_key = slugifySetKey(title);
      const { error } = await supabase.from("quiz_topic_sets").insert({
        agency_id: AGENCY_ID, title, description: newSetDesc || null, set_key, is_active: true,
      });
      if (error) throw error;
      setNewSetTitle(""); setNewSetDesc("");
      await loadSets();
      setGatesBanner({ kind: "success", text: "Topic set created." });
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not create topic set." });
    }
  };

  const doSaveSetEdit = async (setId) => {
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("quiz_topic_sets")
        .update({ title: editSetTitle, description: editSetDesc || null })
        .eq("id", setId);
      if (error) throw error;
      setEditingSetId(null);
      await loadSets();
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not save." });
    }
  };

  const doToggleSetActive = async (set) => {
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("quiz_topic_sets").update({ is_active: !set.is_active }).eq("id", set.id);
      if (error) throw error;
      await loadSets();
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not update." });
    }
  };

  const doAddCategoryRule = async () => {
    if (!selectedSetId) return;
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("quiz_topic_set_rules").insert({
        set_id: selectedSetId,
        category: newRuleCategory || null, difficulty: newRuleDifficulty || null,
      });
      if (error) throw error;
      setNewRuleCategory(""); setNewRuleDifficulty("");
      await loadRules(selectedSetId);
      await loadPoolPreview(selectedSetId);
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not add rule." });
    }
  };

  const searchPinnedItems = async (q) => {
    setPinnedSearch(q);
    if (!q || q.trim().length < 2) { setPinnedResults([]); return; }
    try {
      const { data, error } = await supabase.from("quiz_items")
        .select("id, stem, category").eq("agency_id", AGENCY_ID).eq("status", "approved")
        .ilike("stem", `%${q.trim()}%`).limit(10);
      if (error) throw error;
      setPinnedResults(Array.isArray(data) ? data : []);
    } catch (ex) {
      setPinnedResults([]);
    }
  };

  const doAddPinnedRule = async (itemId) => {
    if (!selectedSetId) return;
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("quiz_topic_set_rules").insert({
        set_id: selectedSetId, item_id: itemId,
      });
      if (error) throw error;
      setPinnedSearch(""); setPinnedResults([]);
      await loadRules(selectedSetId);
      await loadPoolPreview(selectedSetId);
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not pin item." });
    }
  };

  const doDeleteRule = async (ruleId) => {
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("quiz_topic_set_rules").delete().eq("id", ruleId);
      if (error) throw error;
      await loadRules(selectedSetId);
      await loadPoolPreview(selectedSetId);
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not delete rule." });
    }
  };

  const doAttachStep = async (templateId) => {
    const setId = attachSetId[templateId];
    const modeKey = attachMode[templateId];
    if (!setId || !modeKey) return;
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("onboarding_step_templates")
        .update({ required_topic_set_id: setId, required_mode_key: modeKey })
        .eq("id", templateId);
      if (error) throw error;
      await loadTemplates();
      setGatesBanner({ kind: "success", text: "Attached." });
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not attach." });
    }
  };

  const doDetachStep = async (templateId) => {
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("onboarding_step_templates")
        .update({ required_topic_set_id: null, required_mode_key: null })
        .eq("id", templateId);
      if (error) throw error;
      await loadTemplates();
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not detach." });
    }
  };

  const doSubmitOverride = async () => {
    if (!overrideOpenFor) return;
    const reason = overrideReason.trim();
    if (reason.length < 5) {
      setGatesBanner({ kind: "error", text: "Reason must be at least 5 characters." });
      return;
    }
    setGatesBanner(null);
    try {
      const { error } = await supabase.from("quiz_gate_overrides").insert({
        agency_id: AGENCY_ID,
        team_member_id: overrideOpenFor.team_member_id,
        topic_set_id: overrideOpenFor.topic_set_id,
        mode_key: overrideOpenFor.mode_key,
        reason,
        granted_by: userId,
      });
      if (error) throw error;
      setOverrideOpenFor(null);
      setOverrideReason("");
      await loadTeamStatus();
      setGatesBanner({ kind: "success", text: "Override granted." });
    } catch (ex) {
      setGatesBanner({ kind: "error", text: ex?.message || "Could not grant override." });
    }
  };

  const selectedSet = topicSets.find(s2 => s2.id === selectedSetId);

  return (
    <div>
      {gatesBanner && (
        <div style={gatesBanner.kind === "success" ? s.successBanner : s.errorBanner}>
          {gatesBanner.text}
        </div>
      )}

      {/* ── TOPIC SETS ── */}
      <div style={s.card}>
        <div style={s.groupTitle}>Topic sets</div>
        {setsError && <div style={s.errorBanner}>{setsError}</div>}
        {!setsLoading && topicSets.length === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, margin: "8px 0" }}>No topic sets yet — create the first one above.</div>
        )}
        {topicSets.map(set => (
          <div
            key={set.id}
            style={{ ...s.duelListRow, cursor: "pointer", background: selectedSetId === set.id ? T.blueLt : "#fff" }}
            onClick={() => setSelectedSetId(set.id)}
          >
            {editingSetId === set.id ? (
              <div onClick={(e) => e.stopPropagation()}>
                <input style={s.editInput} value={editSetTitle} onChange={(e) => setEditSetTitle(e.target.value)} />
                <textarea style={{ ...s.editTextarea, marginTop: 6 }} value={editSetDesc} onChange={(e) => setEditSetDesc(e.target.value)} />
                <div style={s.actionsRow}>
                  <button type="button" style={s.primaryBtn} onClick={() => doSaveSetEdit(set.id)}>Save</button>
                  <button type="button" style={s.ghostBtn} onClick={() => setEditingSetId(null)}>Cancel</button>
                </div>
              </div>
            ) : (
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
                <div>
                  <div style={{ fontWeight: 600 }}>
                    {set.title} {!set.is_active && <span style={s.pill(T.slate500)}>inactive</span>}
                  </div>
                  {set.description && <div style={{ fontSize: 12, color: T.slate500 }}>{set.description}</div>}
                </div>
                <div style={{ display: "flex", gap: 6 }} onClick={(e) => e.stopPropagation()}>
                  <button type="button" style={s.ghostBtn} onClick={() => { setEditingSetId(set.id); setEditSetTitle(set.title || ""); setEditSetDesc(set.description || ""); }}>Edit</button>
                  <button type="button" style={s.ghostBtn} onClick={() => doToggleSetActive(set)}>{set.is_active ? "Deactivate" : "Activate"}</button>
                </div>
              </div>
            )}
          </div>
        ))}
        <div style={{ marginTop: 12 }}>
          <div style={s.editField}>
            <label style={s.editLabel}>New set title</label>
            <input style={s.editInput} value={newSetTitle} onChange={(e) => setNewSetTitle(e.target.value)} />
          </div>
          <div style={s.editField}>
            <label style={s.editLabel}>Description</label>
            <textarea style={s.editTextarea} value={newSetDesc} onChange={(e) => setNewSetDesc(e.target.value)} />
          </div>
          <button type="button" style={s.primaryBtn} onClick={doCreateSet}>Create topic set</button>
        </div>
      </div>

      {/* ── RULES ── */}
      {selectedSetId && (
        <div style={s.card}>
          <div style={s.groupTitle}>Rules for "{selectedSet?.title || ""}"</div>
          {rulesError && <div style={s.errorBanner}>{rulesError}</div>}
          {rules.length === 0 && <div style={{ fontSize: 12, color: T.slate500, margin: "8px 0" }}>whole bank (no rules yet)</div>}
          {rules.map(rule => (
            <div key={rule.id} style={s.duelListRow}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
                <span>{renderRuleLabel(rule, pinnedItemsById)}</span>
                <button type="button" style={s.dangerBtn} onClick={() => doDeleteRule(rule.id)}>Delete</button>
              </div>
            </div>
          ))}
          <div style={{ marginTop: 12, display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
            <div style={s.editField}>
              <label style={s.editLabel}>Category</label>
              <select style={s.editInput} value={newRuleCategory} onChange={(e) => setNewRuleCategory(e.target.value)}>
                <option value="">(any)</option>
                {categories.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>
            <div style={s.editField}>
              <label style={s.editLabel}>Difficulty</label>
              <select style={s.editInput} value={newRuleDifficulty} onChange={(e) => setNewRuleDifficulty(e.target.value)}>
                <option value="">(any)</option>
                <option value="basic">basic</option>
                <option value="intermediate">intermediate</option>
                <option value="advanced">advanced</option>
              </select>
            </div>
            <button type="button" style={s.primaryBtn} onClick={doAddCategoryRule}>Add rule</button>
          </div>
          <div style={{ marginTop: 12 }}>
            <div style={s.editField}>
              <label style={s.editLabel}>Or pin a specific approved item — search by stem</label>
              <input style={s.editInput} value={pinnedSearch} onChange={(e) => searchPinnedItems(e.target.value)} placeholder="Search approved items…" />
            </div>
            {pinnedResults.map(it => (
              <div key={it.id} style={s.duelListRow}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
                  <span style={{ fontSize: 12 }}>{it.stem}</span>
                  <button type="button" style={s.ghostBtn} onClick={() => doAddPinnedRule(it.id)}>Pin</button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── POOL PREVIEW ── */}
      {selectedSetId && (
        <div style={s.card}>
          <div style={s.groupTitle}>Pool preview</div>
          {poolPreviewError && <div style={s.errorBanner}>{poolPreviewError}</div>}
          {poolPreview && (
            <div>
              <div style={s.bigStat}>{poolPreview.count} playable questions right now</div>
              <div style={{ marginTop: 8, display: "flex", gap: 16, flexWrap: "wrap" }}>
                {["gauntlet", "phase_final"].map(mk => {
                  const need = modesForPreview[mk]?.question_count;
                  const ok = need != null && poolPreview.count >= need;
                  return (
                    <div key={mk} style={{ fontSize: 12 }}>
                      {modesForPreview[mk]?.title || mk}:{" "}
                      {need != null ? (
                        ok ? <span style={{ color: T.green }}>✓ ({need} needed)</span> : <span style={{ color: T.red }}>short by {need - poolPreview.count}</span>
                      ) : "—"}
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── STEP ATTACHMENTS ── */}
      <div style={s.card}>
        <div style={s.groupTitle}>Step attachments</div>
        <div style={{ fontSize: 12, color: T.slate500, marginBottom: 10 }}>
          New hires get a copy of these steps — attaching here gates future plans. Existing plan steps are edited on the person.
        </div>
        {templatesError && <div style={s.errorBanner}>{templatesError}</div>}
        {[0, 1, 2, 3, 4, 5].map(phase => {
          const phaseSteps = stepTemplates.filter(t => t.phase === phase);
          if (phaseSteps.length === 0) return null;
          return (
            <div key={phase}>
              <div style={s.groupHeader}><div style={s.groupTitle}>Phase {phase}</div></div>
              {phaseSteps.map(t => (
                <div key={t.id} style={s.duelListRow}>
                  <div style={{ marginBottom: 6 }}>
                    <strong>{t.title}</strong> <span style={{ fontSize: 11, color: T.slate500 }}>{t.category}</span>
                  </div>
                  <div style={{ fontSize: 12, color: T.slate600, marginBottom: 6 }}>
                    {t.required_topic_set_id
                      ? `Attached: ${topicSets.find(s2 => s2.id === t.required_topic_set_id)?.title || "(set)"} — ${t.required_mode_key || "gauntlet"}`
                      : "Not attached"}
                  </div>
                  <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
                    <select style={s.editInput} value={attachSetId[t.id] || ""} onChange={(e) => setAttachSetId(m => ({ ...m, [t.id]: e.target.value }))}>
                      <option value="">Choose set…</option>
                      {topicSets.filter(s2 => s2.is_active).map(s2 => <option key={s2.id} value={s2.id}>{s2.title}</option>)}
                    </select>
                    <select style={s.editInput} value={attachMode[t.id] || ""} onChange={(e) => setAttachMode(m => ({ ...m, [t.id]: e.target.value }))}>
                      <option value="">Choose mode…</option>
                      <option value="gauntlet">gauntlet</option>
                      <option value="phase_final">phase_final</option>
                    </select>
                    <button type="button" style={s.primaryBtn} onClick={() => doAttachStep(t.id)}>Attach</button>
                    {t.required_topic_set_id && (
                      <button type="button" style={s.dangerBtn} onClick={() => doDetachStep(t.id)}>Detach</button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          );
        })}
      </div>

      {/* ── TEAM STATUS + OVERRIDE ── */}
      <div style={s.card}>
        <div style={s.groupTitle}>Team status</div>
        {teamStatusError && <div style={s.errorBanner}>{teamStatusError}</div>}
        {plansCount === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, margin: "8px 0" }}>
            No onboarding plans exist yet. The gate activates automatically when plans are created.
          </div>
        )}
        {plansCount > 0 && teamGateRows.length === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, margin: "8px 0" }}>No open gated steps right now.</div>
        )}
        {plansCount > 0 && teamList.map(member => {
          const rows = teamGateRows.filter(r => r.team_member_id === member.id);
          if (rows.length === 0) return null;
          return (
            <div key={member.id} style={{ marginBottom: 14 }}>
              <div style={{ fontWeight: 700, fontSize: 13, marginBottom: 6 }}>{member.first_name}</div>
              {rows.map(row => {
                const modeKey = row.required_mode_key || "gauntlet";
                const passed = memberHasPassed(member.id, row.required_topic_set_id, modeKey);
                const existingOverride = memberOverrideRow(member.id, row.required_topic_set_id, modeKey);
                const overridden = !!existingOverride;
                const setTitle = topicSets.find(s2 => s2.id === row.required_topic_set_id)?.title || "(set)";
                const openForThis = overrideOpenFor
                  && overrideOpenFor.team_member_id === member.id
                  && overrideOpenFor.topic_set_id === row.required_topic_set_id
                  && overrideOpenFor.mode_key === modeKey;
                return (
                  <div key={row.id} style={s.duelListRow}>
                    <div style={{ fontSize: 12, marginBottom: 4 }}>
                      {row.title} — {setTitle} ({modeKey}) —{" "}
                      {passed
                        ? <span style={{ color: T.green }}>passed</span>
                        : overridden
                        ? <span style={{ color: T.amber }}>overridden</span>
                        : <span style={{ color: T.red }}>locked</span>}
                    </div>
                    {existingOverride && (
                      <div style={{ fontSize: 11, color: T.slate500 }}>
                        Override: "{existingOverride.reason}" — {existingOverride.created_at ? new Date(existingOverride.created_at).toLocaleDateString() : ""}
                      </div>
                    )}
                    {!passed && !overridden && (
                      openForThis ? (
                        <div style={{ marginTop: 6 }}>
                          <input
                            style={s.editInput}
                            placeholder="Reason (min 5 characters)"
                            value={overrideReason}
                            onChange={(e) => setOverrideReason(e.target.value)}
                          />
                          <div style={s.actionsRow}>
                            <button type="button" style={s.primaryBtn} disabled={overrideReason.trim().length < 5} onClick={doSubmitOverride}>Submit override</button>
                            <button type="button" style={s.ghostBtn} onClick={() => { setOverrideOpenFor(null); setOverrideReason(""); }}>Cancel</button>
                          </div>
                        </div>
                      ) : (
                        <button
                          type="button"
                          style={s.ghostBtn}
                          onClick={() => setOverrideOpenFor({ team_member_id: member.id, topic_set_id: row.required_topic_set_id, mode_key: modeKey })}
                        >
                          Override
                        </button>
                      )
                    )}
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─── Shared question-loop runner for Daily Five + Duel ───
function QuestionRunner({ itemIds, itemsById, attemptId, secondsPerQuestion, onSubmitAnswer, onAllDone }) {
  const [idx, setIdx] = useState(0);
  const [timeLeft, setTimeLeft] = useState(secondsPerQuestion);
  const [revealed, setRevealed] = useState(false);
  const [selectedId, setSelectedId] = useState(null);
  const [submitError, setSubmitError] = useState(null);
  const firingRef = useRef(false);

  const currentId = itemIds[idx];
  const currentItem = itemsById[currentId];
  const displayOptions = useMemo(
    () => orderedOptions(currentItem?.options, attemptId, currentId),
    [currentItem, attemptId, currentId]
  );

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
      {(displayOptions || []).map(o => {
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
