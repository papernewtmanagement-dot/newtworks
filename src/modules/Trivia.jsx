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
//
// Spin & Solve wave step 3 — the seventh mode: a hidden coverage term guessed
// letter by letter, then the meaning question. It has its OWN runner
// (PhraseRunner) and its own server-drawn selection path
// (quiz_start_spin_attempt), once per Central-time day. The shared
// multiple-choice QuestionRunner is untouched by it.
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
  // When a game is actually being played it takes the whole width on its own
  // instead of sitting in one narrow column of the lobby grid. Everything a
  // player needs — the board, the phrase, the options — gets the full screen.
  stageWrap: { marginBottom: 16 },
  stageCard: {
    background: "#fff", border: `1px solid ${T.slate200}`, borderRadius: 10,
    padding: 18, maxWidth: 900, margin: "0 auto", boxSizing: "border-box",
  },
  stageHeader: {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    gap: 10, flexWrap: "wrap", marginBottom: 14,
    paddingBottom: 10, borderBottom: `1px solid ${T.slate200}`,
  },
  stageTitle: { fontSize: 16, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em" },
  stageSub: { fontSize: 12, color: T.slate500 },
  playCardTitle: { fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 4 },
  playCardDesc: { fontSize: 12, color: T.slate500, marginBottom: 12 },
  // Every mode card carries its own solo / multiplayer choice inside the card.
  modeRow: { display: "flex", gap: 6, marginBottom: 12, flexWrap: "wrap" },
  modeBtn: (on) => ({
    padding: "5px 12px", borderRadius: 14, fontSize: 12, fontWeight: 700,
    cursor: "pointer", fontFamily: "inherit",
    border: `1px solid ${on ? T.blue : T.slate300}`,
    background: on ? T.blueLt : "#fff", color: on ? T.blue : T.slate700,
  }),
  bigStat: { fontSize: 22, fontWeight: 700, color: T.slate900 },
  smallLabel: { fontSize: 11, color: T.slate500, marginTop: 2 },
  timerPill: (urgent) => ({
    fontSize: 12, fontWeight: 700, padding: "3px 10px", borderRadius: 12,
    background: urgent ? T.redLt : T.slate100, color: urgent ? T.red : T.slate700,
  }),
  qStem: { fontSize: 15, fontWeight: 600, color: T.slate900, lineHeight: 1.4, marginBottom: 12 },
  qOptionBtn: (state) => {
    // state: "default" | "static" | "selectedCorrect" | "selectedWrong" | "revealCorrect" | "revealDim"
    const map = {
      default: { background: "#fff", border: `1px solid ${T.slate300}`, color: T.slate800 },
      static: { background: "#fff", border: `1px solid ${T.slate300}`, color: T.slate800, cursor: "default" },
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
  phraseBoard: {
    display: "flex", flexWrap: "wrap", gap: 10, justifyContent: "center",
    padding: "14px 8px", marginBottom: 12, background: T.slate50,
    border: `1px solid ${T.slate200}`, borderRadius: 8, boxSizing: "border-box",
  },
  phraseWord: { display: "flex", gap: 4, flexWrap: "nowrap" },
  // Tile size is passed in rather than fixed. A fixed 24px tile made the longest
  // term in the bank ("PROFESSIONAL SERVICES EXCLUSION", a 14-letter word) 388px
  // wide inside a card only 280-400px wide, so the blanks ran off the edge and
  // looked like they were missing. Every unrevealed tile is now a visible white
  // blank rather than an almost-invisible underline.
  phraseTile: (shown, w, h) => ({
    width: w, height: h, display: "flex", alignItems: "center", justifyContent: "center",
    fontSize: Math.max(11, Math.round(w * 0.62)), fontWeight: 700,
    borderRadius: 3, boxSizing: "border-box", flexShrink: 0,
    color: shown ? T.slate900 : "transparent",
    background: T.white,
    border: `1px solid ${T.slate300}`,
    borderBottom: `3px solid ${shown ? T.blue : T.slate400}`,
  }),
  phrasePunct: (w, h) => ({
    width: Math.max(8, Math.round(w * 0.5)), height: h, display: "flex",
    alignItems: "flex-end", justifyContent: "center", flexShrink: 0,
    fontSize: Math.max(11, Math.round(w * 0.62)), fontWeight: 700,
    color: T.slate600, boxSizing: "border-box",
  }),
  phraseCategoryPill: {
    display: "inline-block", marginBottom: 12, padding: "4px 12px", borderRadius: 12,
    background: T.blueLt, color: T.blue, fontSize: 11, fontWeight: 700,
    textTransform: "uppercase", letterSpacing: "0.05em",
  },
  phraseStatusRow: {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    gap: 8, flexWrap: "wrap", marginBottom: 8, fontSize: 12, color: T.slate600,
  },
  solveRow: { display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 10 },
  letterGrid: {
    display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(38px, 1fr))",
    gap: 6, marginBottom: 10,
  },
  letterBtn: (state, isVowel) => {
    const base = {
      padding: "10px 0", fontSize: 14, fontWeight: 700, borderRadius: 6,
      cursor: "pointer", fontFamily: "inherit", boxSizing: "border-box",
      background: T.white, color: T.slate800, border: `1px solid ${T.slate300}`,
    };
    if (state === "hit") return { ...base, background: T.greenLt, borderColor: T.green, color: T.green, cursor: "default" };
    if (state === "miss") return { ...base, background: T.slate100, borderColor: T.slate200, color: T.slate400, cursor: "default" };
    if (isVowel) return { ...base, background: T.goldLt, borderColor: T.gold, color: T.slate800 };
    return base;
  },
  wheelRow: {
    display: "flex", alignItems: "center", gap: 14, flexWrap: "wrap",
    marginBottom: 10, justifyContent: "center",
  },
  wheelSideCol: {
    display: "flex", flexDirection: "column", gap: 8, minWidth: 160, flex: 1,
  },
  roundMoneyPill: {
    display: "inline-block", padding: "4px 10px", borderRadius: 10,
    background: T.slate100, color: T.slate800, fontSize: 12, fontWeight: 700,
    textAlign: "center",
  },
  spinResultBanner: (kind) => {
    const map = {
      bankrupt: { background: T.redLt, color: T.red, border: `1px solid ${T.red}` },
      lose_turn: { background: T.slate100, color: T.slate600, border: `1px solid ${T.slate300}` },
      free_spin: { background: T.purpleLt, color: T.purple, border: `1px solid ${T.purple}` },
      value: { background: T.greenLt, color: T.green, border: `1px solid ${T.green}` },
    };
    const chosen = map[kind] || map.value;
    return {
      padding: "8px 10px", borderRadius: 6, fontSize: 13, fontWeight: 700,
      marginBottom: 8, textAlign: "center", boxSizing: "border-box", ...chosen,
    };
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
  // Shared Grid is no longer a tab of its own — it is a mode inside Play, like
  // every other game. Non-admins only ever see Play.
  const tab = isAdmin ? tabRaw : "play";

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

// Play data no longer comes from the question tables. It used to: the screen
// read every column of every question and every option, which meant the answer
// key - which option is right, the written explanation, and the hidden term
// itself - sat in the browser before a single answer had been given. Every
// signed-in teammate could read it. That was tolerable while these games were
// solo and cosmetic and stopped being tolerable the moment all three carried a
// same-day team scoreboard.
//
// quiz_play_state serves one game's questions with the answers taken out, plus,
// for any question already answered, that question's reveal - which is what
// makes resuming a half-finished game work without handing anything over early.
async function loadPlayState(attemptId) {
  const { data, error } = await supabase.rpc("quiz_play_state", { p_attempt_id: attemptId });
  if (error) throw error;
  const items = Array.isArray(data?.items) ? data.items : [];
  const itemsById = {};
  const answeredIds = new Set();
  for (const it of items) {
    itemsById[it.item_id] = it;
    if (it.answered) answeredIds.add(it.item_id);
  }
  return {
    itemsById,
    orderedIds: items.map(it => it.item_id),
    answeredIds,
    remainingIds: items.filter(it => !it.answered).map(it => it.item_id),
  };
}

// The Grid column header rule: strip a leading "sf_" and prefix
// "State Farm ", replace underscores with spaces, capitalise each
// word. sf_auto -> "State Farm Auto", fire -> "Fire",
// commercial_auto -> "Commercial Auto".
//
// Two categories get a hand-written label because the automatic rule reads
// wrong. All 29 questions filed under sf_lending are general mortgage knowledge
// - discount points, debt-to-income, Texas cash-out rules - with nothing State
// Farm specific in them, so "State Farm Lending" on a board header was
// misleading. The stored category keys are untouched; only the words shown to a
// player change.
const CATEGORY_LABEL_OVERRIDES = {
  sf_lending: "Mortgages",
  // sf_flood was split 2026-08-19: the 7 questions specifically about the
  // Dover Bay product (a real State Farm subsidiary, confirmed by Peter)
  // moved to category "dover_bay"; the 4 generic flood-zone/map questions
  // with no Dover Bay-specific product detail moved to the existing "flood"
  // category. sf_flood is now empty. Neither dover_bay nor flood needs an
  // override — dover_bay has no "sf_" prefix so it auto-formats to
  // "Dover Bay", and flood already auto-formats to "Flood".
};

function formatGridCategoryLabel(category) {
  if (CATEGORY_LABEL_OVERRIDES[category]) return CATEGORY_LABEL_OVERRIDES[category];
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

// Recording one answer is identical for a solo game and for a game inside a
// room, because a room gives every player an ordinary game record. Lives at
// module level so both the solo card and the shared room shell call the same
// one rather than keeping two copies in step.
async function submitAnswer(attemptId, itemId, chosenOptionId, secondsTaken) {
  const { data, error } = await supabase.rpc("quiz_submit_answer", {
    p_attempt_id: attemptId,
    p_item_id: itemId,
    p_chosen_option_id: chosenOptionId || null,
    p_seconds_taken: Number.isFinite(secondsTaken) ? secondsTaken : 0,
  });
  if (error) throw error;
  return data;
}

// ============================================================
// TriviaRoom — the shared multiplayer shell.
//
// Step 3 of the Play-tab sequence. One of these renders inside a mode card
// whenever the player picks Multiplayer. It owns everything that is identical
// for every mode: finding the room you are already in, opening one, joining
// somebody else's, showing who is in it, the host's start button, your own
// questions once it begins, and the live scoreboard. A mode supplies only two
// things — the name of the server function that deals its questions, and how
// to draw its own gameplay.
//
// Every player in a room holds an ordinary game record, exactly like a solo
// game, which is why loading questions, recording answers and scoring all work
// here untouched. Multiplayer scoring is not reinvented anywhere.
//
// Nothing pushes from the database. That was tried and ruled out twice: a
// database broadcast fails silently because the realtime message table has no
// partitions, and row-change subscriptions deliver nothing because these
// tables have security switched on with no read rules. A short poll is the
// proven path and it is what Trivia Night already runs on.
// ============================================================
function TriviaRoom({ modeKey, startFnName, onStatusChange, renderPlay }) {
  const [room, setRoom] = useState(null);
  const [openRooms, setOpenRooms] = useState([]);
  const [play, setPlay] = useState(null);
  const [finishResult, setFinishResult] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);

  const roomId = room?.room_id || null;
  const status = room?.status || null;
  const myAttemptId = room?.my_attempt_id || null;
  const players = Array.isArray(room?.players) ? room.players : [];
  const me = players.find(p => p.is_me) || null;
  const iAmDone = !!me?.finished;

  // Tell the card whether a game is running so it can take the whole width,
  // the same handoff The Grid's multiplayer branch already uses.
  useEffect(() => { onStatusChange?.(status); }, [status, onStatusChange]);

  const refreshRoom = useCallback(async (id) => {
    if (!id) return null;
    const { data, error: err } = await supabase.rpc("quiz_room_state", { p_room_id: id });
    if (err) { setError(err.message); return null; }
    setRoom(data);
    return data;
  }, []);

  const refreshOpen = useCallback(async () => {
    const { data, error: err } = await supabase.rpc("quiz_room_list_open", { p_mode_key: modeKey });
    if (err) { setError(err.message); return; }
    setOpenRooms(Array.isArray(data) ? data : []);
  }, [modeKey]);

  // A player who closes the tab and comes back should land straight back in
  // their room, so the room id is never carried in the address bar — the
  // server is asked instead.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const { data: mine } = await supabase.rpc("quiz_room_my_active", { p_mode_key: modeKey });
      if (cancelled) return;
      if (mine) await refreshRoom(mine); else await refreshOpen();
      if (!cancelled) setLoading(false);
    })();
    return () => { cancelled = true; };
  }, [modeKey, refreshRoom, refreshOpen]);

  useEffect(() => {
    if (loading) return undefined;
    const watching = !roomId || status === "lobby" || status === "playing";
    if (!watching) return undefined;
    const t = setInterval(() => {
      if (roomId) refreshRoom(roomId); else refreshOpen();
    }, 5000);
    return () => clearInterval(t);
  }, [loading, status, roomId, refreshRoom, refreshOpen]);

  // My own questions for this room. Loaded once the game starts and left alone
  // afterwards, so the poll refreshing the scoreboard never disturbs play.
  useEffect(() => {
    let cancelled = false;
    if (status !== "playing" || !myAttemptId) { setPlay(null); return undefined; }
    (async () => {
      try {
        const st = await loadPlayState(myAttemptId);
        if (!cancelled) setPlay(st);
      } catch (ex) {
        if (!cancelled) setError(ex?.message || "Could not load the questions.");
      }
    })();
    return () => { cancelled = true; };
  }, [status, myAttemptId]);

  const act = async (fn) => {
    setError(null);
    setBusy(true);
    try { await fn(); }
    catch (ex) { setError(ex?.message || "That did not work."); }
    finally { setBusy(false); }
  };

  const openRoom = () => act(async () => {
    const { data, error: err } = await supabase.rpc("quiz_room_open", { p_mode_key: modeKey, p_config: {} });
    if (err) throw err;
    await refreshRoom(data);
  });

  const joinRoom = (id) => act(async () => {
    const { data, error: err } = await supabase.rpc("quiz_room_join", { p_room_id: id });
    if (err) throw err;
    setRoom(data);
  });

  const leaveRoom = () => act(async () => {
    const { error: err } = await supabase.rpc("quiz_room_leave", { p_room_id: roomId });
    if (err) throw err;
    setRoom(null);
    setPlay(null);
    setFinishResult(null);
    await refreshOpen();
  });

  const startGame = () => act(async () => {
    const { data, error: err } = await supabase.rpc(startFnName, { p_room_id: roomId });
    if (err) throw err;
    setRoom(data);
  });

  const clearRoom = () => act(async () => {
    setRoom(null);
    setPlay(null);
    setFinishResult(null);
    await refreshOpen();
  });

  const finishMine = async () => {
    setError(null);
    const { data, error: err } = await supabase.rpc("quiz_room_my_finish", { p_room_id: roomId });
    if (err) { setError(err.message || "Could not finish — try again."); return; }
    setFinishResult(data?.result || null);
    if (data?.room) setRoom(data.room);
  };

  const submitRoomAnswer = async (itemId, chosenOptionId, secondsTaken) =>
    submitAnswer(myAttemptId, itemId, chosenOptionId, secondsTaken);

  const scoreboard = players.length > 0 && (
    <div style={{ marginTop: 12 }}>
      <div style={s.groupTitle}>{status === "lobby" ? "In this room" : "Scores"}</div>
      {players.map(p => (
        <div key={p.team_member_id} style={s.duelListRow}>
          <div style={{ display: "flex", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
            <span style={{ fontWeight: p.is_me ? 700 : 500 }}>
              {p.name}{p.is_host ? " · host" : ""}{p.is_me ? " · you" : ""}
            </span>
            <span style={{ fontSize: 12, color: T.slate500 }}>
              {status === "lobby"
                ? "ready"
                : `${p.correct_count}/${p.answered_count} · ${p.points} pts${p.finished ? " ✓" : ""}`}
            </span>
          </div>
        </div>
      ))}
    </div>
  );

  if (loading) {
    return <div style={{ fontSize: 13, color: T.slate500 }}>Checking for a room…</div>;
  }

  return (
    <div>
      {error && <div style={s.errorBanner}>{error}</div>}

      {!roomId && (
        <div>
          <div style={s.playCardDesc}>
            Play the same questions as your teammates, at the same time.
          </div>
          <button type="button" style={s.primaryBtn} disabled={busy} onClick={openRoom}>
            Start a room
          </button>
          {openRooms.length > 0 && (
            <div style={{ marginTop: 14 }}>
              <div style={s.groupTitle}>Rooms open now</div>
              {openRooms.map(r => (
                <div key={r.room_id} style={s.duelListRow}>
                  <div style={{ marginBottom: 6 }}>
                    {r.host_name}&apos;s room — {r.player_count} in
                    {r.status === "playing" ? " · already started" : ""}
                  </div>
                  {r.status === "lobby" ? (
                    <button type="button" style={s.ghostBtn} disabled={busy} onClick={() => joinRoom(r.room_id)}>
                      Join
                    </button>
                  ) : (
                    <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>too late to join</div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {roomId && status === "lobby" && (
        <div>
          <div style={s.playCardDesc}>
            {room.is_host
              ? "Your room is open. Start when everyone is in."
              : "You are in. Waiting for the host to start."}
          </div>
          {scoreboard}
          <div style={s.actionsRow}>
            {room.is_host && (
              <button type="button" style={s.primaryBtn} disabled={busy} onClick={startGame}>
                Start game
              </button>
            )}
            <button type="button" style={s.ghostBtn} disabled={busy} onClick={leaveRoom}>
              {room.is_host ? "Close room" : "Leave"}
            </button>
          </div>
        </div>
      )}

      {roomId && status === "playing" && !iAmDone && play && renderPlay
        && renderPlay({ play, submitRoomAnswer, finishMine, attemptId: myAttemptId })}

      {roomId && status === "playing" && !iAmDone && !play && (
        <div style={{ fontSize: 13, color: T.slate500 }}>Dealing the questions…</div>
      )}

      {roomId && status === "playing" && iAmDone && (
        <div>
          <div style={{ fontSize: 13, color: T.slate500 }}>
            You are done — waiting on the others to finish.
          </div>
          {scoreboard}
        </div>
      )}

      {roomId && (status === "finished" || status === "abandoned") && (
        <div>
          {finishResult && (
            <>
              <div style={s.bigStat}>{finishResult.correct_count}/{finishResult.question_count}</div>
              <div style={s.smallLabel}>{finishResult.points_earned} points earned</div>
            </>
          )}
          {status === "abandoned" && (
            <div style={{ fontSize: 13, color: T.slate500, marginTop: 6 }}>The host closed this room.</div>
          )}
          {scoreboard}
          <div style={s.actionsRow}>
            <button type="button" style={s.ghostBtn} disabled={busy} onClick={clearRoom}>Done</button>
          </div>
        </div>
      )}
    </div>
  );
}

function TriviaPlayTab({ userId, isAdmin }) {
  const [modes, setModes] = useState({});
  const [modesError, setModesError] = useState(null);
  const [poolCount, setPoolCount] = useState(0);
  const [poolError, setPoolError] = useState(null);

  // Shared Grid runs inside Play now. It owns its own state, so it tells us
  // when a game is actually running and we treat it like any other live game.
  const [sharedActive, setSharedActive] = useState(false);

  // The Grid is the first card wired to the in-card choice: "multi" is the
  // shared-screen game that used to sit on its own tab. Kept in the URL so a
  // refresh mid-game lands back on the right branch.
  const [gridMode, setGridMode] = useTabParam("gridmode", "solo", ["solo", "multi"]);

  // A host who closes the tab and comes back to a clean URL should still find
  // their room. One cheap check on mount flips the card to the multiplayer
  // branch, and the branch resumes itself from there.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error } = await supabase.rpc("quiz_shared_grid_my_active_session");
      if (cancelled || error || !data) return;
      setGridMode("multi");
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Daily Five carries the same in-card choice The Grid got in step 1. "multi"
  // is a room: same five questions dealt to everyone at once, each person
  // scored on their own record. Kept in the address bar so a refresh lands
  // back on the right branch. The room id itself is deliberately NOT in the
  // address bar - several cards can sit in multiplayer at the same time in the
  // lobby grid and would fight over one shared parameter. The room is found by
  // asking the server instead.
  const [dfMode, setDfMode] = useTabParam("dfmode", "solo", ["solo", "multi"]);
  const [dailyRoomStatus, setDailyRoomStatus] = useState(null);

  // Cold start: someone already in a Daily Five room lands on the right branch
  // without having to pick it again.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error } = await supabase.rpc("quiz_room_my_active", { p_mode_key: "daily_five" });
      if (cancelled || error || !data) return;
      setDfMode("multi");
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

  // Today's standings per solo mode — Daily Five, The Grid, Spin & Solve are all
  // once-a-day games, so everyone's score for the day is directly comparable.
  const [dayStandings, setDayStandings] = useState({});

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
  const [nightState, setNightState] = useState(null); // full quiz_night_state result
  const nightChannelRef = useRef(null);      // this session's live channel
  const nightLobbyChannelRef = useRef(null); // agency-wide "a night exists" channel
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

  // Spin & Solve (Spin and Solve wave, step 3)
  const [spinPhase, setSpinPhase] = useState("checking"); // checking | not_started | in_progress | playing | finishing | finished | error
  const [spinError, setSpinError] = useState(null);
  const [spinAttempt, setSpinAttempt] = useState(null);
  const [spinItemsById, setSpinItemsById] = useState({});
  const [spinRemainingIds, setSpinRemainingIds] = useState([]);
  const [spinResult, setSpinResult] = useState(null);
  const [spinTermCount, setSpinTermCount] = useState(null);

  // ── Loaders ──
  const loadModes = useCallback(async () => {
    try {
      const { data, error } = await supabase.from("quiz_modes").select("*")
        .eq("agency_id", AGENCY_ID)
        .in("mode_key", ["daily_five", "duel", "gauntlet", "phase_final", "the_grid", "spin_and_solve"]);
      if (error) throw error;
      const modeMap = {};
      for (const m of (data || [])) modeMap[m.mode_key] = m;
      setModes(modeMap);
    } catch (ex) {
      setModesError(ex?.message || "Could not load trivia settings.");
    }
  }, []);

  // How much material each mode has to work with, for the lobby cards. This was
  // three separate counts the browser read straight off the question table. That
  // read is gone, and it was wrong for an agency admin anyway - an admin's row
  // rules are unfiltered, so their counts quietly included draft and retired
  // questions. One server call now, filtered the same way the start functions
  // filter, so the card and the start function agree.
  const loadAvailability = useCallback(async () => {
    try {
      const { data, error } = await supabase.rpc("quiz_play_availability");
      if (error) throw error;
      setPoolCount(Number(data?.pool_count) || 0);
      setSpinTermCount(Number(data?.phrase_count) || 0);
      setGridCatCounts(data?.grid_category_counts || {});
    } catch (ex) {
      // non-fatal - each card reads "not enough questions yet" on its own
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

  // Pulled after a mode finishes, and again when the lobby loads, so a player who
  // has already had their turn can see where they landed without replaying.
  const loadDayStandings = useCallback(async (modeKey) => {
    try {
      const { data, error } = await supabase.rpc("quiz_mode_day_standings", { p_mode_key: modeKey });
      if (error) throw error;
      setDayStandings(prev => ({ ...prev, [modeKey]: Array.isArray(data) ? data : [] }));
    } catch (ex) {
      // A missing readout is not worth an error banner over a finished game.
      setDayStandings(prev => ({ ...prev, [modeKey]: [] }));
    }
  }, []);

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

  // Telling the other screens something changed.
  //
  // This is deliberately a message with nothing in it. It does not say WHAT
  // changed and it carries no game content - the other screens hear "refresh"
  // and go re-read quiz_night_state, which stays the one thing that decides what
  // each person is allowed to see. That matters: quiz_night_state hides which
  // option is correct until the host flips to reveal, and a message carrying the
  // actual change would have handed that over early.
  //
  // Losing a nudge is not an error worth showing anybody. The slow re-read below
  // is the safety net.
  const nightNudge = useCallback(() => {
    const ch = nightChannelRef.current;
    if (!ch) return;
    try {
      ch.send({ type: "broadcast", event: "refresh", payload: {} });
    } catch (ex) {
      /* the periodic re-read covers it */
    }
  }, []);

  // Same thing, but for "a night has started" / "a night is over" - which the
  // session channel cannot carry, because a teammate who has not joined yet is
  // not listening to that session at all.
  const nightLobbyNudge = useCallback(() => {
    const ch = nightLobbyChannelRef.current;
    if (!ch) return;
    try {
      ch.send({ type: "broadcast", event: "refresh", payload: {} });
    } catch (ex) {
      /* the periodic re-read covers it */
    }
  }, []);

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

  const loadSpinStatus = useCallback(async () => {
    if (!userId) return;
    setSpinPhase("checking");
    setSpinError(null);
    try {
      const today = ctToday();
      const { data: row, error } = await supabase.from("quiz_attempts").select("*")
        .eq("team_member_id", userId).eq("mode_key", "spin_and_solve").eq("attempt_day", today)
        .maybeSingle();
      if (error) throw error;
      if (!row) {
        setSpinAttempt(null);
        setSpinPhase("not_started");
      } else if (row.finished_at) {
        setSpinAttempt(row);
        setSpinResult({ correct_count: row.correct_count, question_count: row.question_count, points_earned: row.points_earned });
        setSpinPhase("finished");
      } else {
        setSpinAttempt(row);
        setSpinPhase("in_progress");
      }
    } catch (ex) {
      setSpinError(ex?.message || "Could not check today's game.");
      setSpinPhase("error");
    }
  }, [userId]);

  useEffect(() => { loadModes(); }, [loadModes]);
  useEffect(() => { loadAvailability(); }, [loadAvailability]);
  useEffect(() => { loadDailyStatus(); }, [loadDailyStatus]);
  useEffect(() => { loadDuelLists(); }, [loadDuelLists]);
  useEffect(() => { loadStandings(); }, [loadStandings]);
  useEffect(() => {
    loadDayStandings("daily_five");
    loadDayStandings("the_grid");
    loadDayStandings("spin_and_solve");
  }, [loadDayStandings]);
  useEffect(() => { loadGates(); }, [loadGates]);
  useEffect(() => { loadGridStatus(); }, [loadGridStatus]);
  useEffect(() => { loadNightActive(); }, [loadNightActive]);
  useEffect(() => { loadSpinStatus(); }, [loadSpinStatus]);

  // Live updates for everyone watching this session.
  //
  // This asked the server for the whole state every 2 seconds, from every open
  // screen, for the entire night. Now each screen is told when to look.
  //
  // The telling is done by the browsers, not by the database. The database
  // cannot do it on this project: broadcasting from the database means writing a
  // row to Supabase's realtime.messages, that table is split by day and has no
  // day partitions at all, so every write there fails - and fails quietly,
  // reporting success. So whoever just did something sends the nudge themselves,
  // right after their own write comes back clean.
  //
  // Not a private channel, on purpose. A private channel checks whether you are
  // allowed to send by attempting a write against that same broken table. And
  // there is nothing here to protect - the message is the word "refresh" and an
  // empty payload. Knowing that something changed is not knowing an answer.
  //
  // The periodic re-read stays, at 10 seconds instead of 2. It covers the one
  // gap the nudges cannot: if the browser that just wrote something dies before
  // it sends its nudge, nobody else would ever hear.
  useEffect(() => {
    if (!nightShouldPoll) return undefined;
    let cancelled = false;
    const pull = async () => {
      try {
        const { data, error } = await supabase.rpc("quiz_night_state", { p_session_id: nightSessionId });
        if (error) throw error;
        if (!cancelled) setNightState(data);
      } catch (ex) {
        if (!cancelled) setNightError(ex?.message || "Could not refresh trivia night.");
      }
    };
    pull();

    const channel = supabase.channel(`quiz_night:${nightSessionId}`);
    channel.on("broadcast", { event: "refresh" }, () => { pull(); }).subscribe();
    nightChannelRef.current = channel;

    const id = setInterval(pull, 10000);
    return () => {
      cancelled = true;
      clearInterval(id);
      nightChannelRef.current = null;
      supabase.removeChannel(channel);
    };
  }, [nightShouldPoll, nightSessionId]);

  // A teammate who has not joined anything is listening to no session, so they
  // would never find out a night had started - their own check ran once when the
  // page opened and never again. This is the one channel every screen holds, all
  // night, whether or not its owner is playing.
  useEffect(() => {
    const ch = supabase.channel(`quiz_night_lobby:${AGENCY_ID}`);
    ch.on("broadcast", { event: "refresh" }, () => { loadNightActive(); }).subscribe();
    nightLobbyChannelRef.current = ch;
    return () => {
      nightLobbyChannelRef.current = null;
      supabase.removeChannel(ch);
    };
  }, [loadNightActive]);

  // Local smoothing tick between re-reads — each one overwrites this.
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

  // Every mode records an answer the same way, and the reveal for that one
  // question comes back as the return value of the write. That is the whole
  // trick: the screen learns which option was right at the moment it can no
  // longer change its mind, and the one-answer-per-question rule in the
  // database means it only gets one moment.

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
      const state = await loadPlayState(attemptId);
      setGateAttempt(attemptRow);
      setGateItemsById(state.itemsById);
      setGateRemainingIds(state.remainingIds);
      setGateResult(null);
      setGatePhase("playing");
    } catch (ex) {
      setGateError(ex?.message || "Could not start.");
      setGatePhase("idle");
    }
  };

  const submitGateAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    return submitAnswer(gateAttempt.id, itemId, chosenOptionId, secondsTaken);
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
    const state = await loadPlayState(attempt.id);

    // Which cells are already spent, and what they were worth. The server
    // reports right-or-wrong per answered question, so the running total no
    // longer needs the answer key sitting in the browser to be worked out.
    const answeredMap = {};
    let pts = 0;
    for (const id of state.answeredIds) {
      const it = state.itemsById[id];
      answeredMap[id] = { chosen_option_id: it?.chosen_option_id || null, is_correct: !!it?.was_correct };
    }
    for (const col of board) {
      for (const clue of (col.clues || [])) {
        const ans = answeredMap[clue.item_id];
        if (ans && ans.is_correct) pts += clue.points;
      }
    }

    setGridAttempt(attempt);
    setGridBoard(board);
    setGridItemsById(state.itemsById);
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
    const reveal = await submitAnswer(gridAttempt.id, itemId, chosenOptionId, secondsTaken);
    const isCorrect = !!reveal?.was_correct;
    setGridAnsweredByItem(prev => ({ ...prev, [itemId]: { chosen_option_id: chosenOptionId, is_correct: isCorrect } }));
    if (isCorrect && gridActiveCell && gridActiveCell.item_id === itemId) {
      setGridPointsSoFar(prev => prev + gridActiveCell.points);
    }
    return reveal;
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
    await loadDayStandings("the_grid");
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

  // ── Spin & Solve actions ──
  const beginPlayingSpin = async (attempt) => {
    const state = await loadPlayState(attempt.id);
    const remaining = state.remainingIds;

    setSpinAttempt(attempt);
    setSpinItemsById(state.itemsById);
    setSpinRemainingIds(remaining);

    if (remaining.length === 0) {
      await finishSpin(attempt.id);
    } else {
      setSpinPhase("playing");
    }
  };

  const startSpin = async () => {
    setSpinError(null);
    setSpinPhase("checking");
    try {
      const { data: attemptId, error } = await supabase.rpc("quiz_start_spin_attempt");
      if (error) {
        setSpinError(error.message);
        setSpinPhase("not_started");
        return;
      }
      const { data: row, error: fetchErr } = await supabase
        .from("quiz_attempts").select("*").eq("id", attemptId).maybeSingle();
      if (fetchErr) throw fetchErr;
      await beginPlayingSpin(row);
    } catch (ex) {
      setSpinError(ex?.message || "Could not start the game.");
      setSpinPhase("error");
    }
  };

  const resumeSpin = async () => {
    if (!spinAttempt) return;
    setSpinError(null);
    setSpinPhase("checking");
    try {
      await beginPlayingSpin(spinAttempt);
    } catch (ex) {
      setSpinError(ex?.message || "Could not resume the game.");
      setSpinPhase("error");
    }
  };

  // The browser no longer reports anything about the hidden-term half. It used
  // to send up solved-or-not and the miss count as facts, and those two numbers
  // are exactly what the solve bonus is calculated from. The server keeps its
  // own record of the guessing and reads the bonus off that instead.
  const submitSpinAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    return submitAnswer(spinAttempt.id, itemId, chosenOptionId, secondsTaken);
  };

  const guessSpinLetter = async (itemId, letter) => {
    const { data, error } = await supabase.rpc("quiz_phrase_guess", {
      p_attempt_id: spinAttempt.id, p_item_id: itemId, p_letter: letter,
    });
    if (error) throw error;
    return data;
  };

  // Full casino wheel: spin lands on a value / Bankrupt / Lose a Turn / Free
  // Spin. A landed value must be spent on a consonant guess before the wheel
  // can spin again (guessSpinLetter now enforces that server-side).
  const spinSpinWheel = async (itemId) => {
    const { data, error } = await supabase.rpc("quiz_wheel_spin", {
      p_attempt_id: spinAttempt.id, p_item_id: itemId,
    });
    if (error) throw error;
    return data;
  };

  // Vowels bypass the wheel entirely — fixed cost out of the term's banked
  // money, no spin required, no value earned or lost either way.
  const buySpinVowel = async (itemId, letter) => {
    const { data, error } = await supabase.rpc("quiz_wheel_buy_vowel", {
      p_attempt_id: spinAttempt.id, p_item_id: itemId, p_letter: letter,
    });
    if (error) throw error;
    return data;
  };

  const solveSpinTerm = async (itemId, text) => {
    const { data, error } = await supabase.rpc("quiz_phrase_solve", {
      p_attempt_id: spinAttempt.id, p_item_id: itemId, p_text: text,
    });
    if (error) throw error;
    return data;
  };

  // The letter half has its own clock. When it runs out the term is shown and
  // the solve bonus is gone. The screen used to reveal a term it was holding;
  // it holds nothing now, so ending the half is a request.
  const giveUpSpinTerm = async (itemId) => {
    const { data, error } = await supabase.rpc("quiz_phrase_give_up", {
      p_attempt_id: spinAttempt.id, p_item_id: itemId,
    });
    if (error) throw error;
    return data;
  };

  const finishSpin = async (attemptId) => {
    setSpinPhase("finishing");
    const { data, error } = await supabase.rpc("quiz_finish_attempt", { p_attempt_id: attemptId });
    if (error) {
      setSpinError(error.message || "Could not finish — try again.");
      setSpinPhase("playing");
      return;
    }
    setSpinResult(data);
    setSpinPhase("finished");
    await loadDayStandings("spin_and_solve");
    await loadStandings();
  };

  // ── Trivia Night actions ──
  const nightStartSession = async () => {
    setNightError(null);
    try {
      const { error } = await supabase.rpc("quiz_night_create_session");
      if (error) { setNightError(error.message); return; }
      await loadNightActive();
      // the session channel does not exist yet on this screen, so this one goes
      // out on the agency-wide channel to put the night on everybody's page
      nightLobbyNudge();
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
      nightNudge(); // the host's player list
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
      nightNudge(); // everybody off the lobby and onto question one
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
      nightNudge(); // reveal, or the next question
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
      nightNudge();      // the players still on the question screen
      nightLobbyNudge(); // and anybody who was only ever watching the lobby
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
      else nightNudge(); // the host's "3 of 5 answered" counter
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
  // The screen used to insert the attempt row itself, passing the signed-in
  // person's id from the users table. The security rule on that table checks
  // against the person's id from the team table, and those two ids differ for
  // every person here, so every start was refused with "new row violates row
  // level security policy". Starting now goes through a server-side function
  // that resolves the person and draws the questions itself, the same way The
  // Grid and Spin & Solve already did. A double-tap resumes rather than erroring
  // because the function returns the unfinished attempt it already found.
  const startFreshDaily = async () => {
    setDfError(null);
    setDfPhase("checking");
    try {
      const { data: attemptId, error } = await supabase.rpc("quiz_start_daily_attempt");
      if (error) {
        setDfError(error.message);
        setDfPhase("not_started");
        return;
      }
      const { data: row, error: fetchErr } = await supabase
        .from("quiz_attempts").select("*").eq("id", attemptId).maybeSingle();
      if (fetchErr) throw fetchErr;
      if (!row) throw new Error("Started, but could not read today's five back.");
      await beginPlayingDaily(row);
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
    const state = await loadPlayState(attempt.id);
    const remaining = state.remainingIds;
    const answeredIds = state.answeredIds;

    setDfAttempt(attempt);
    setDfItemsById(state.itemsById);
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
    return submitAnswer(dfAttempt.id, itemId, chosenOptionId, secondsTaken);
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
    await loadDayStandings("daily_five");
    await loadDailyStatus();
  };

  // ── Duel actions ──
  const startDuelChallenge = async (opponent) => {
    setDuelError(null);
    setDuelMode("starting");
    try {
      // Same fix as Daily Five: the id the screen holds is the users-table id,
      // and the security rule wants the team-table id. The server resolves the
      // challenger itself, checks the opponent is a live teammate, and draws the
      // questions, so no id crosses the wire.
      const { data: attemptId, error } = await supabase.rpc("quiz_start_duel_challenge", {
        p_opponent_team_member_id: opponent.team_member_id,
      });
      if (error) {
        setDuelError(error.message);
        setDuelMode("idle");
        return;
      }
      const { data: inserted, error: fetchErr } = await supabase
        .from("quiz_attempts").select("*").eq("id", attemptId).maybeSingle();
      if (fetchErr) throw fetchErr;
      if (!inserted) throw new Error("Started, but could not read the duel back.");
      const state = await loadPlayState(attemptId);
      setDuelActiveAttempt(inserted);
      setDuelActiveItemsById(state.itemsById);
      setDuelActiveRemainingIds(state.remainingIds);
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
      const state = await loadPlayState(newAttemptId);
      setDuelActiveAttempt(newRow);
      setDuelActiveItemsById(state.itemsById);
      setDuelActiveRemainingIds(state.remainingIds);
      setDuelActiveOpponentName(pending.challenger_name);
      setDuelResult(null);
      setDuelMode("playing");
    } catch (ex) {
      setDuelError(ex?.message || "Could not accept the duel.");
      setDuelMode("idle");
    }
  };

  const submitDuelAnswer = async (itemId, chosenOptionId, secondsTaken) => {
    return submitAnswer(duelActiveAttempt.id, itemId, chosenOptionId, secondsTaken);
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
  const spinCfg = modes.spin_and_solve;
  const spinAvailable = Number.isFinite(spinTermCount)
    && spinTermCount >= (spinCfg?.question_count || 6);
  const gridQualifyingCats = useMemo(() => {
    return Object.entries(gridCatCounts)
      .filter(([, n]) => n >= 5)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .map(([cat]) => cat);
  }, [gridCatCounts]);
  const gridAvailable = gridQualifyingCats.length >= 3;
  const nightJoined = nightState?.players?.some(p => p.is_me) ?? nightActive?.joined ?? false;
  const nightIsHost = nightState?.is_host ?? nightActive?.is_host ?? false;

  // Whichever game is mid-play takes the whole width to itself and everything
  // else on the page steps out of the way. Before this, a live board or a hidden
  // phrase had to squeeze into one narrow column of the lobby grid alongside
  // five idle cards, which is what made the formatting fall apart. Only one game
  // can be in play at a time, so the first match wins; a live trivia night
  // outranks everything because the whole room is waiting on it.
  const nightInPlay = !!nightActive && (nightIsHost || nightJoined)
    && ["lobby", "question", "reveal", "finished", "abandoned"].includes(nightLiveStatus);
  const activeGame =
      nightInPlay ? "night"
    : (!gatesError && activeGate && gatePhase !== "idle") ? "gate"
    : (gridPhase === "board" || gridPhase === "finishing" || sharedActive) ? "grid"
    : (spinPhase === "playing" || spinPhase === "finishing") ? "spin"
    : (duelMode === "playing" || duelMode === "starting") ? "duel"
    : (dfPhase === "playing" || dfPhase === "finishing"
       || dailyRoomStatus === "playing" || dailyRoomStatus === "finished") ? "daily"
    : null;
  const stageTitles = {
    night: "Trivia Night", gate: "Training", grid: "The Grid",
    spin: "Spin & Solve", duel: "Duel", daily: "Daily Five",
  };
  const shows = (key) => !activeGame || activeGame === key;
  const boxStyle = (key) => (activeGame === key ? s.stageCard : s.playCard);

  return (
    <div>
      {(modesError || poolError) && <div style={s.errorBanner}>{modesError || poolError}</div>}

      {activeGame && (
        <div style={s.stageHeader}>
          <div>
            <div style={s.stageTitle}>{stageTitles[activeGame]}</div>
            <div style={s.stageSub}>
              {activeGame === "daily" && dailyRoomStatus === "finished" ? "game over" : "in play"}
            </div>
          </div>
        </div>
      )}

      {!gatesLoading && shows("gate") && (gatesError || gates.length > 0) && (
        <div style={boxStyle("gate")}>
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

      <div style={activeGame ? s.stageWrap : s.playGrid}>
        {/* ── Daily Five card ── */}
        {shows("daily") && (
        <div style={boxStyle("daily")}>
          <div style={s.playCardTitle}>Daily Five</div>

          {activeGame !== "daily" && (
            <div style={s.modeRow}>
              <button type="button" style={s.modeBtn(dfMode === "solo")} onClick={() => setDfMode("solo")}>
                Solo
              </button>
              <button type="button" style={s.modeBtn(dfMode === "multi")} onClick={() => setDfMode("multi")}>
                Multiplayer
              </button>
            </div>
          )}

          {dfMode === "multi" && (
            <TriviaRoom
              modeKey="daily_five"
              startFnName="quiz_room_start_daily_five"
              onStatusChange={setDailyRoomStatus}
              renderPlay={({ play, submitRoomAnswer, finishMine, attemptId }) => (
                <QuestionRunner
                  itemIds={play.remainingIds}
                  itemsById={play.itemsById}
                  attemptId={attemptId}
                  secondsPerQuestion={dailyCfg?.seconds_per_question || 30}
                  onSubmitAnswer={submitRoomAnswer}
                  onAllDone={finishMine}
                />
              )}
            />
          )}

          {dfMode === "solo" && (
          <>
          <div style={s.playCardDesc}>{dailyCfg?.description || "Five questions a day. Keep your streak going."}</div>

          {dfError && <div style={s.errorBanner}>{dfError}</div>}

          {dfPhase === "checking" && <div style={{ fontSize: 13, color: T.slate500 }}>Checking today's status…</div>}

          {dfPhase === "not_started" && (
            poolCount < (dailyCfg?.question_count || 5) ? (
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
              <DayStandings rows={dayStandings.daily_five} label="Today's five — the team" />
            </div>
          )}

          {dfPhase !== "finished" && dfPhase !== "playing" && (
            <DayStandings rows={dayStandings.daily_five} label="Today's five — the team" />
          )}
          </>
          )}
        </div>
        )}

        {/* ── Duel card ── */}
        {shows("duel") && (
        <div style={boxStyle("duel")}>
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
              <div style={s.actionsRow}>
                <button
                  type="button"
                  style={s.ghostBtn}
                  onClick={() => { setDuelMode("idle"); setDuelResult(null); setDuelActiveAttempt(null); }}
                >
                  Done
                </button>
              </div>
            </div>
          )}

          {(duelMode === "idle" || duelMode === "picking") && (
            <>
              {poolCount < (duelCfg?.question_count || 7) ? (
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
        )}

        {/* ── The Grid card ── */}
        {shows("grid") && (
        <div style={boxStyle("grid")}>
          <div style={s.playCardTitle}>The Grid</div>

          {activeGame !== "grid" && (
            <div style={s.modeRow}>
              <button type="button" style={s.modeBtn(gridMode === "solo")} onClick={() => setGridMode("solo")}>
                Solo
              </button>
              <button type="button" style={s.modeBtn(gridMode === "multi")} onClick={() => setGridMode("multi")}>
                Multiplayer
              </button>
            </div>
          )}

          {gridMode === "multi" && (
            <TriviaSharedGridTab userId={userId} onActiveChange={setSharedActive} />
          )}

          {gridMode === "solo" && (
          <>
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
              <DayStandings rows={dayStandings.the_grid} label="Today's board — the team" />
            </div>
          )}

          {gridPhase !== "finished" && gridPhase !== "board" && (
            <DayStandings rows={dayStandings.the_grid} label="Today's board — the team" />
          )}
          </>
          )}
        </div>
        )}

        {/* ── Spin & Solve card ── */}
        {shows("spin") && (
        <div style={boxStyle("spin")}>
          <div style={s.playCardTitle}>Spin &amp; Solve</div>
          <div style={s.playCardDesc}>Solve the hidden coverage term, then say what it means.</div>

          {spinError && <div style={s.errorBanner}>{spinError}</div>}

          {spinPhase === "checking" && <div style={{ fontSize: 13, color: T.slate500 }}>Checking today's game…</div>}

          {spinPhase === "not_started" && (
            !spinAvailable ? (
              <div style={{ fontSize: 13, color: T.slate500 }}>
                Not enough terms yet — this one needs {spinCfg?.question_count || 6} approved terms.
              </div>
            ) : (
              <button type="button" style={s.primaryBtn} onClick={startSpin}>Play Spin &amp; Solve</button>
            )
          )}

          {spinPhase === "in_progress" && (
            <button type="button" style={s.primaryBtn} onClick={resumeSpin}>Resume the game</button>
          )}

          {spinPhase === "finishing" && <div style={{ fontSize: 13, color: T.slate500 }}>Finishing up…</div>}

          {spinPhase === "playing" && spinAttempt && spinRemainingIds.length > 0 && (
            <PhraseRunner
              itemIds={spinRemainingIds}
              itemsById={spinItemsById}
              attemptId={spinAttempt.id}
              secondsPerPhase={spinCfg?.seconds_per_question || 60}
              secondsFirstPhase={spinCfg?.seconds_first_phase || 150}
              onSpinWheel={spinSpinWheel}
              onBuyVowel={buySpinVowel}
              onSubmitAnswer={submitSpinAnswer}
              onGuessLetter={guessSpinLetter}
              onSolveTerm={solveSpinTerm}
              onTermTimeout={giveUpSpinTerm}
              onAllDone={() => finishSpin(spinAttempt.id)}
            />
          )}

          {spinPhase === "finished" && spinResult && (
            <div>
              <div style={s.bigStat}>{spinResult.correct_count}/{spinResult.question_count}</div>
              <div style={s.smallLabel}>{spinResult.points_earned} points earned</div>
              <div style={s.smallLabel}>once a day — back tomorrow.</div>
              {spinResult.on_leaderboard && (
                <div style={{ ...s.smallLabel, color: T.gold, fontWeight: 700, marginTop: 4 }}>made the board! 🏆</div>
              )}
              <DayStandings rows={dayStandings.spin_and_solve} label="Today's terms — the team" />
            </div>
          )}

          {spinPhase !== "finished" && spinPhase !== "playing" && (
            <DayStandings rows={dayStandings.spin_and_solve} label="Today's terms — the team" />
          )}
        </div>
        )}

        {/* ── Trivia Night card ── */}
        {shows("night") && (
        <div style={boxStyle("night")}>
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
        )}

      </div>

      {/* ── Standings strip ── */}
      {!activeGame && (
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
      )}
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

// ============================================================
// SHARED GRID — one shared screen, named players (not signed-in
// team members — just labels for whoever's in the room), turns,
// per-player scoring. The host is the only one who needs to be
// signed in; everyone else calls out answers and the host judges.
// Points are server-authoritative (quiz_grid_sessions.board_points,
// same as the solo Grid) — the client never reports a value.
// ============================================================
const gridShared = {
  // Renders inside The Grid card now, so this is a plain container, not a card.
  wrap: {},
  setupRow: { display: "flex", alignItems: "center", gap: 8, marginBottom: 8 },
  nameInput: {
    flex: 1, padding: "8px 10px", fontSize: 13, borderRadius: 6,
    border: `1px solid ${T.slate300}`, fontFamily: "inherit",
  },
  playerStrip: {
    display: "flex", flexWrap: "wrap", gap: 8, marginBottom: 14,
  },
  playerChip: (isTurn) => ({
    display: "flex", alignItems: "center", gap: 6, padding: "6px 12px", borderRadius: 20,
    fontSize: 13, fontWeight: 700, border: `1px solid ${isTurn ? T.blue : T.slate200}`,
    background: isTurn ? T.blueLt : T.slate50, color: isTurn ? T.blue : T.slate800,
  }),
  boardCol: { display: "flex", flexDirection: "column", gap: 6 },
  clueBtn: (answered) => ({
    width: "100%", padding: "12px 6px", borderRadius: 6, fontSize: 14, fontWeight: 700,
    textAlign: "center", cursor: answered ? "default" : "pointer",
    background: answered ? T.slate100 : "#fff",
    border: `1px solid ${answered ? T.slate200 : T.slate300}`,
    color: answered ? T.slate300 : T.slate800,
  }),
  clueCard: {
    padding: 16, borderRadius: 8, background: T.slate50, border: `1px solid ${T.slate200}`, marginBottom: 12,
  },
  winnerBtn: (chosen) => ({
    padding: "8px 14px", borderRadius: 6, fontSize: 13, fontWeight: 700, cursor: "pointer",
    border: `1px solid ${chosen ? T.green : T.slate300}`,
    background: chosen ? T.greenLt : "#fff", color: chosen ? T.green : T.slate800,
  }),
};

function TriviaSharedGridTab({ userId, onActiveChange }) {
  const vp = useViewport();
  const [gsSessionId, setGsSessionId] = useTabParam("gsession", null);
  const [gsPhase, setGsPhase] = useState("checking"); // checking | setup | board | error

  // Play owns the stage. Tell it when a shared game is genuinely running so the
  // other mode cards step aside, exactly the way the built-in modes behave.
  useEffect(() => {
    if (typeof onActiveChange === "function") onActiveChange(gsPhase === "board");
  }, [gsPhase, onActiveChange]);
  const [gsError, setGsError] = useState(null);
  const [gsState, setGsState] = useState(null);
  const [gsNames, setGsNames] = useState(["", ""]);
  const [gsBusy, setGsBusy] = useState(false);
  const [gsWinnerPick, setGsWinnerPick] = useState(null); // index chosen before scoring, or "none"
  const [gsWagerInputs, setGsWagerInputs] = useState({}); // round 3: player index -> wager input string
  const [gsCorrectSet, setGsCorrectSet] = useState(new Set()); // round 3: indexes marked correct on the finale

  const loadState = useCallback(async (sid) => {
    if (!sid) return;
    const { data, error } = await supabase.rpc("quiz_shared_grid_state", { p_session_id: sid });
    if (error) {
      setGsError(error.message || "Could not load that game.");
      setGsPhase("error");
      return;
    }
    setGsState(data);
    setGsWinnerPick(null);
    setGsPhase("board");
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (gsSessionId) {
        await loadState(gsSessionId);
        return;
      }
      setGsPhase("checking");
      const { data, error } = await supabase.rpc("quiz_shared_grid_my_active_session");
      if (cancelled) return;
      if (!error && data) {
        setGsSessionId(data);
        await loadState(data);
      } else {
        setGsPhase("setup");
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [gsSessionId]);

  const addNameField = () => {
    if (gsNames.length >= 8) return;
    setGsNames(prev => [...prev, ""]);
  };
  const updateName = (i, val) => {
    setGsNames(prev => prev.map((n, idx) => (idx === i ? val : n)));
  };
  const removeNameField = (i) => {
    setGsNames(prev => prev.filter((_, idx) => idx !== i));
  };

  const startGame = async () => {
    const cleaned = gsNames.map(n => n.trim()).filter(Boolean);
    if (cleaned.length === 0) {
      setGsError("Name at least one player.");
      return;
    }
    setGsBusy(true);
    setGsError(null);
    const { data, error } = await supabase.rpc("quiz_shared_grid_start", { p_player_names: cleaned });
    setGsBusy(false);
    if (error) {
      setGsError(error.message || "Could not start the board.");
      return;
    }
    setGsSessionId(data);
    await loadState(data);
  };

  const pickSquare = async (itemId) => {
    if (!gsState?.is_host || gsBusy) return;
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_pick", { p_session_id: gsSessionId, p_item_id: itemId });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not open that square."); return; }
    await loadState(gsSessionId);
  };

  const revealAnswer = async () => {
    if (!gsState?.is_host || gsBusy) return;
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_reveal", { p_session_id: gsSessionId });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not reveal the answer."); return; }
    await loadState(gsSessionId);
  };

  const scoreSquare = async () => {
    if (!gsState?.is_host || gsBusy || gsWinnerPick === null) return;
    setGsBusy(true);
    setGsError(null);
    const winner = gsWinnerPick === "none" ? null : gsWinnerPick;
    const { error } = await supabase.rpc("quiz_shared_grid_score", { p_session_id: gsSessionId, p_winner_index: winner });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not score that square."); return; }
    await loadState(gsSessionId);
  };

  const endGame = async () => {
    if (!gsState?.is_host) return;
    if (!window.confirm("End this game? The board and scores will be closed out.")) return;
    setGsBusy(true);
    const { error } = await supabase.rpc("quiz_shared_grid_end", { p_session_id: gsSessionId });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not end the game."); return; }
    setGsSessionId(null);
    setGsState(null);
    setGsNames(["", ""]);
    setGsWagerInputs({});
    setGsCorrectSet(new Set());
    setGsPhase("setup");
  };

  const startNewAfterFinish = () => {
    setGsSessionId(null);
    setGsState(null);
    setGsNames(["", ""]);
    setGsWagerInputs({});
    setGsCorrectSet(new Set());
    setGsPhase("setup");
  };

  // ── Round two (doubled board) / round three (wager finale) ──
  const startRound2 = async () => {
    if (!gsState?.is_host || gsBusy) return;
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_start_round2", { p_session_id: gsSessionId });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not start round two."); return; }
    await loadState(gsSessionId);
  };

  const startRound3 = async () => {
    if (!gsState?.is_host || gsBusy) return;
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_start_round3", { p_session_id: gsSessionId });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not start the wager finale."); return; }
    setGsWagerInputs({});
    setGsCorrectSet(new Set());
    await loadState(gsSessionId);
  };

  const submitWager = async (playerIndex) => {
    if (!gsState?.is_host || gsBusy) return;
    const raw = gsWagerInputs[playerIndex];
    const amount = Math.max(0, Math.round(Number(raw)));
    if (!Number.isFinite(amount)) { setGsError("Enter a whole-number wager."); return; }
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_set_wager", {
      p_session_id: gsSessionId, p_player_index: playerIndex, p_amount: amount,
    });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not save that wager."); return; }
    await loadState(gsSessionId);
  };

  const lockWagers = async () => {
    if (!gsState?.is_host || gsBusy) return;
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_lock_wagers", { p_session_id: gsSessionId });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not lock wagers — has everyone wagered?"); return; }
    await loadState(gsSessionId);
  };

  const toggleCorrect = (i) => {
    setGsCorrectSet(prev => {
      const next = new Set(prev);
      if (next.has(i)) next.delete(i); else next.add(i);
      return next;
    });
  };

  const scoreFinal = async () => {
    if (!gsState?.is_host || gsBusy) return;
    setGsBusy(true);
    setGsError(null);
    const { error } = await supabase.rpc("quiz_shared_grid_score_final", {
      p_session_id: gsSessionId, p_correct_indexes: Array.from(gsCorrectSet),
    });
    setGsBusy(false);
    if (error) { setGsError(error.message || "Could not score the finale."); return; }
    setGsCorrectSet(new Set());
    await loadState(gsSessionId);
  };

  if (gsPhase === "checking") {
    return <div style={{ fontSize: 13, color: T.slate500 }}>Checking for a game in progress…</div>;
  }

  if (gsPhase === "setup") {
    return (
      <div style={gridShared.wrap}>
        <div style={s.playCardDesc}>
          One shared screen, everyone in the room. Type in who's playing, then the host
          picks squares, reveals the answer, and taps who got it right.
        </div>
        {gsError && <div style={s.errorBanner}>{gsError}</div>}
        {gsNames.map((n, i) => (
          <div key={i} style={gridShared.setupRow}>
            <input
              type="text" style={gridShared.nameInput} placeholder={`Player ${i + 1} name`}
              value={n} onChange={(e) => updateName(i, e.target.value)}
            />
            {gsNames.length > 1 && (
              <button type="button" style={s.ghostBtn} onClick={() => removeNameField(i)}>Remove</button>
            )}
          </div>
        ))}
        <div style={s.actionsRow}>
          {gsNames.length < 8 && (
            <button type="button" style={s.ghostBtn} onClick={addNameField}>+ Add player</button>
          )}
          <button type="button" style={s.primaryBtn} disabled={gsBusy} onClick={startGame}>
            {gsBusy ? "Building the board…" : "Start game"}
          </button>
        </div>
      </div>
    );
  }

  if (gsPhase === "error") {
    return (
      <div style={gridShared.wrap}>
        <div style={s.errorBanner}>{gsError}</div>
        <div style={s.actionsRow}>
          <button type="button" style={s.ghostBtn} onClick={startNewAfterFinish}>Start a new game</button>
        </div>
      </div>
    );
  }

  if (!gsState) return null;

  const players = gsState.players || [];
  const board = gsState.board || [];
  const q = gsState.question;

  return (
    <div style={gridShared.wrap}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, flexWrap: "wrap", marginBottom: 12 }}>
        <div style={s.stageSub}>
          {gsState.status === "finished" ? "multiplayer — game over" : "multiplayer — in play"}
        </div>
        {gsState.is_host && gsState.status !== "finished" && (
          <button type="button" style={s.ghostBtn} onClick={endGame} disabled={gsBusy}>End game</button>
        )}
      </div>

      {gsError && <div style={s.errorBanner}>{gsError}</div>}

      <div style={gridShared.playerStrip}>
        {players.map((p, i) => (
          <div key={i} style={gridShared.playerChip(i === gsState.current_player_index && gsState.status !== "finished")}>
            {p.name} — {p.score}
          </div>
        ))}
      </div>

      {gsState.status === "finished" && (
        <div>
          <div style={{ fontSize: 13, fontWeight: 700, color: T.slate800, marginBottom: 10 }}>
            {gsState.round === 3 ? "Final: " : `Round ${gsState.round} standings: `}
            {[...players].sort((a, b) => b.score - a.score).map(p => `${p.name} (${p.score})`).join(" · ")}
          </div>
          <div style={s.actionsRow}>
            {gsState.is_host && gsState.round === 1 && (
              <button type="button" style={s.primaryBtn} disabled={gsBusy} onClick={startRound2}>Start round two</button>
            )}
            {gsState.is_host && gsState.round === 2 && (
              <button type="button" style={s.primaryBtn} disabled={gsBusy} onClick={startRound3}>Start the wager finale</button>
            )}
            <button type="button" style={s.ghostBtn} onClick={startNewAfterFinish}>New game</button>
          </div>
        </div>
      )}

      {gsState.status === "active" && !q && (
        <div style={{ ...gridShared.boardCol, display: "grid", gridTemplateColumns: `repeat(${board.length}, 1fr)`, gap: 8 }}>
          {board.map((col, ci) => (
            <div key={ci}>
              <div style={s.gridColumnHeader}>{formatGridCategoryLabel(col.category)}</div>
              {col.clues.map((clue) => (
                <button
                  key={clue.item_id}
                  type="button"
                  disabled={clue.answered || !gsState.is_host || gsBusy}
                  style={gridShared.clueBtn(clue.answered)}
                  onClick={() => pickSquare(clue.item_id)}
                >
                  {clue.answered ? "—" : clue.points}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}

      {gsState.status === "wagering" && (
        <div>
          <div style={s.smallLabel}>Final category: {formatGridCategoryLabel(gsState.final_category)}</div>
          <div style={{ fontSize: 12, color: T.slate500, marginBottom: 10 }}>
            Everyone locks in a wager before the question shows.
          </div>
          {gsState.is_host && players.map((p, i) => {
            const locked = gsState.final_wagers && Object.prototype.hasOwnProperty.call(gsState.final_wagers, String(i));
            return (
              <div key={i} style={gridShared.setupRow}>
                <div style={{ width: 120, fontSize: 13, fontWeight: 700, color: T.slate800 }}>{p.name}</div>
                <input
                  type="number" min={0} max={Math.max(p.score, 0)} style={gridShared.nameInput}
                  placeholder="wager"
                  value={gsWagerInputs[i] ?? ""}
                  onChange={(e) => setGsWagerInputs(prev => ({ ...prev, [i]: e.target.value }))}
                />
                <button type="button" style={s.ghostBtn} disabled={gsBusy} onClick={() => submitWager(i)}>
                  {locked ? "Update" : "Lock in"}
                </button>
                {locked && <span style={{ fontSize: 12, color: T.green, marginLeft: 4 }}>✓ {gsState.final_wagers[String(i)]}</span>}
              </div>
            );
          })}
          {gsState.is_host && (
            <div style={s.actionsRow}>
              <button type="button" style={s.primaryBtn} disabled={gsBusy} onClick={lockWagers}>Reveal the question</button>
            </div>
          )}
          {!gsState.is_host && (
            <div style={{ fontSize: 12, color: T.slate500 }}>Waiting on the host to collect wagers…</div>
          )}
        </div>
      )}

      {q && (
        <div>
          <div style={s.smallLabel}>
            {formatGridCategoryLabel(q.category)}{gsState.round !== 3 && q.points != null ? ` — ${q.points} points` : ""}
          </div>
          <div style={gridShared.clueCard}>
            <div style={s.qStem}>{q.stem}</div>
            {(q.options || []).map((o) => (
              <div
                key={o.id}
                style={s.qOptionBtn(gsState.active_revealed ? (o.is_correct ? "revealCorrect" : "revealDim") : "static")}
              >
                {o.option_text}
              </div>
            ))}
            {gsState.active_revealed && q.explanation && (
              <div style={s.explanationBox}>{q.explanation}</div>
            )}
          </div>

          {gsState.is_host && !gsState.active_revealed && (
            <div style={s.actionsRow}>
              <button type="button" style={s.primaryBtn} disabled={gsBusy} onClick={revealAnswer}>Reveal answer</button>
            </div>
          )}

          {gsState.is_host && gsState.active_revealed && gsState.round === 3 && (
            <div>
              <div style={s.smallLabel}>Who got the finale right? Tap everyone who did.</div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 8, margin: "8px 0" }}>
                {players.map((p, i) => (
                  <button
                    key={i} type="button"
                    style={gridShared.winnerBtn(gsCorrectSet.has(i))}
                    onClick={() => toggleCorrect(i)}
                  >
                    {p.name} (wagered {gsState.final_wagers?.[String(i)] ?? 0})
                  </button>
                ))}
              </div>
              <div style={s.actionsRow}>
                <button type="button" style={s.primaryBtn} disabled={gsBusy} onClick={scoreFinal}>
                  Score the finale
                </button>
              </div>
            </div>
          )}

          {gsState.is_host && gsState.active_revealed && gsState.round !== 3 && (
            <div>
              <div style={s.smallLabel}>Who got it right?</div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 8, margin: "8px 0" }}>
                {players.map((p, i) => (
                  <button
                    key={i} type="button"
                    style={gridShared.winnerBtn(gsWinnerPick === i)}
                    onClick={() => setGsWinnerPick(i)}
                  >
                    {p.name}
                  </button>
                ))}
                <button
                  type="button"
                  style={gridShared.winnerBtn(gsWinnerPick === "none")}
                  onClick={() => setGsWinnerPick("none")}
                >
                  Nobody
                </button>
              </div>
              <div style={s.actionsRow}>
                <button type="button" style={s.primaryBtn} disabled={gsBusy || gsWinnerPick === null} onClick={scoreSquare}>
                  Score it
                </button>
              </div>
            </div>
          )}

          {!gsState.is_host && (
            <div style={{ fontSize: 12, color: T.slate500 }}>Waiting on the host…</div>
          )}
        </div>
      )}
    </div>
  );
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
      // Topic sets feed the two gated exams, which are multiple-choice only,
      // so offer categories that actually have servable questions in them.
      const { data, error } = await supabase.from("quiz_items").select("category")
        .eq("agency_id", AGENCY_ID).eq("status", "approved")
        .eq("report_blocked", false).eq("shape", "choice");
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
        .eq("shape", "choice")
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
// Spin & Solve's own runner. The five multiple-choice modes share
// QuestionRunner below; this one deliberately does not, because a Spin & Solve
// item plays in two halves — guess the hidden coverage term, then answer what
// it means. Nothing here touches QuestionRunner or any of its four call sites.
//
// Four wrong guesses are allowed per term. A wrong letter and a wrong
// whole-term guess cost the same. The fourth miss ends the guessing, reveals
// the term and pays no solve bonus. The meaning question is asked either way,
// so every game records exactly one answer row per item and scores stay
// comparable across attempts.
//
// One clock per half, both the mode's own seconds_per_question. Full casino
// wheel mechanic as of 2026-08-18: spin for a consonant's value (or land on
// Bankrupt / Lose a Turn / Free Spin), buy a vowel for a flat cost out of the
// term's banked money, solve to bank whatever money is on the board. All
// wheel math and randomness happens server-side (quiz_wheel_spin,
// quiz_wheel_buy_vowel) — the visible wheel here is cosmetic only.
const PHRASE_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
const PHRASE_VOWELS = new Set(["A", "E", "I", "O", "U"]);
const PHRASE_MAX_MISSES = 4;
const VOWEL_COST = 25;

// The two halves of Spin & Solve are not the same job. Guessing a coverage term
// out of blanks with twenty-six letters to try through is far slower than picking
// one of four meanings, so each half carries its own clock: secondsFirstPhase for
// the letters, secondsPerPhase for the meaning.
// Today's scoreboard for a once-a-day mode. Every solo game gets one, so finishing
// tells you where you landed against the rest of the team instead of just handing
// back a number with no context.
function DayStandings({ rows, label }) {
  const list = Array.isArray(rows) ? rows : [];
  if (list.length === 0) return null;
  const mine = list.find(r => r.is_me);
  return (
    <div style={{ marginTop: 12 }}>
      <div style={{ ...s.groupTitle, marginBottom: 6 }}>{label}</div>
      {mine && (
        <div style={{ fontSize: 12, color: T.slate600, marginBottom: 6 }}>
          {list.length === 1
            ? "First one in today."
            : `You're ${mine.place} of ${list.length} so far today.`}
        </div>
      )}
      {list.map(r => (
        <div
          key={r.team_member_id}
          style={r.is_me ? { ...s.standingsRow, fontWeight: 700, background: T.blueLt } : s.standingsRow}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <span style={s.standingsTier(r.place > 3 ? 3 : r.place)}>{r.place}</span>
            <span>{r.name}{r.is_me ? " (you)" : ""}</span>
          </div>
          <div style={{ textAlign: "right" }}>
            <div style={{ fontWeight: 700 }}>{r.points} pts</div>
            <div style={{ fontSize: 10, color: T.slate500 }}>{r.correct_count}/{r.question_count} right</div>
          </div>
        </div>
      ))}
    </div>
  );
}

// Decorative spin wheel for Spin & Solve. Deliberately NOT wired to land
// precisely on the server's chosen wedge — rule 26 in the coding standards
// exists because pixel-exact wheel/pointer math has broken this codebase
// before (6 fix attempts chasing what turned out to be a box-sizing bug).
// The wheel spins for several full turns to a random cosmetic angle; the
// actual result is server-truth, shown in the banner underneath once the
// spin settles. This wheel never determines game state, only the mood.
function SpinWheel({ angle, spinning }) {
  const wheelColors = [T.blue, T.gold, T.green, T.pink, T.blue, T.amber, T.green, T.purple];
  const sliceDeg = 360 / wheelColors.length;
  const gradient = wheelColors
    .map((c, i) => `${c} ${i * sliceDeg}deg ${(i + 1) * sliceDeg}deg`)
    .join(", ");
  return (
    <div style={{ position: "relative", width: 96, height: 96, flexShrink: 0, boxSizing: "border-box" }}>
      <div
        style={{
          width: 96, height: 96, borderRadius: "50%", boxSizing: "border-box",
          border: `3px solid ${T.slate700}`,
          background: `conic-gradient(${gradient})`,
          transform: `rotate(${angle}deg)`,
          transition: spinning ? "transform 1.3s cubic-bezier(0.15, 0.65, 0.25, 1)" : "none",
        }}
      />
      <div
        style={{
          position: "absolute", top: -6, left: "50%", transform: "translateX(-50%)",
          width: 0, height: 0, boxSizing: "border-box",
          borderLeft: "7px solid transparent", borderRight: "7px solid transparent",
          borderTop: `12px solid ${T.slate900}`,
        }}
      />
    </div>
  );
}

// The letter guessing runs on the server now. It has to: the board cannot be
// drawn without the term, so as long as the browser did the guessing it needed
// the term, and the term is the answer. What comes back from each guess is the
// board as the player has earned it - letters found in place, everything else
// still a blank - plus the running miss count. The term itself only arrives once
// it is solved or the guesses have run out.
function PhraseRunner({ itemIds, itemsById, attemptId, secondsPerPhase, secondsFirstPhase, onSpinWheel, onBuyVowel, onSubmitAnswer, onGuessLetter, onSolveTerm, onTermTimeout, onAllDone }) {
  const _vp = useViewport();
  const [idx, setIdx] = useState(0);
  const [half, setHalf] = useState("term"); // term | meaning
  const [solveOpen, setSolveOpen] = useState(false);
  const [solveText, setSolveText] = useState("");
  const [solveWrong, setSolveWrong] = useState(false);
  const termSeconds = secondsFirstPhase || secondsPerPhase;
  const [timeLeft, setTimeLeft] = useState(termSeconds);
  const [revealed, setRevealed] = useState(false);
  const [selectedId, setSelectedId] = useState(null);
  const [reveal, setReveal] = useState(null);
  const [submitError, setSubmitError] = useState(null);
  const [guessError, setGuessError] = useState(null);
  const [busyLetter, setBusyLetter] = useState(null);
  const firingRef = useRef(false);
  const termFiringRef = useRef(false);

  // Wheel-specific UI state. spinning drives the cosmetic CSS spin — it is
  // purely decorative (rule 26's lesson: pixel-exact wedge/pointer math has
  // broken this codebase before), the actual outcome is whatever the server
  // returns and is shown in a separate result banner once the spin settles.
  const [spinning, setSpinning] = useState(false);
  const [spinAngle, setSpinAngle] = useState(0);
  const [spinResultBanner, setSpinResultBanner] = useState(null);
  const [spinError, setSpinError] = useState(null);
  const spinTimeoutRef = useRef(null);

  const currentId = itemIds[idx];
  const currentItem = itemsById[currentId];

  // Starting board for this term, as the server last left it. A resumed game
  // comes back with the letters already found still showing.
  const serverPhrase = currentItem?.phrase || null;
  const [progress, setProgress] = useState(null);
  useEffect(() => {
    setProgress(serverPhrase
      ? {
          display: serverPhrase.display || "",
          guessed: Array.isArray(serverPhrase.guessed) ? serverPhrase.guessed : [],
          misses: Number(serverPhrase.misses) || 0,
          solved: !!serverPhrase.solved,
          over: !!serverPhrase.over,
          answer: serverPhrase.answer || null,
          roundMoney: Number(serverPhrase.round_money) || 0,
          pendingSpin: serverPhrase.pending_spin || null,
        }
      : null);
    setSpinResultBanner(null);
  }, [currentId, serverPhrase]);

  const display = progress?.display || "";
  const guessed = progress?.guessed || [];
  const misses = progress?.misses || 0;
  const solved = !!progress?.solved;
  const termOver = !!progress?.over;
  const roundMoney = progress?.roundMoney || 0;
  const pendingSpin = progress?.pendingSpin || null;
  const hasPendingValue = !!pendingSpin && pendingSpin.type === "value";
  const displayOptions = useMemo(
    () => orderedOptions(currentItem?.options, attemptId, currentId),
    [currentItem, attemptId, currentId]
  );
  const guessedSet = useMemo(() => new Set(guessed), [guessed]);
  // Which tapped letters turned out to be in the term - taken from the board
  // itself, because a letter showing on the board is a letter that hit.
  const hitLetters = useMemo(
    () => new Set(display.split("").filter(ch => ch >= "A" && ch <= "Z")),
    [display]
  );

  // The board used to draw every letter at a fixed 24px with word wrapping off,
  // so a long word simply ran past the edge of the card and the blanks vanished.
  // Tiles are sized to the longest word in the term against the width actually
  // available, so the whole phrase always fits on screen.
  const { tileW, tileH } = useMemo(() => {
    const longestWord = display.split(" ").reduce((m, w) => Math.max(m, w.length), 0);
    const avail = Math.max(240, Math.min((_vp.width || 1024) - 96, 860));
    const raw = Math.floor((avail - 24 - Math.max(0, longestWord - 1) * 3) / Math.max(1, longestWord));
    const w = Math.max(13, Math.min(34, raw));
    return { tileW: w, tileH: Math.round(w * 1.35) };
  }, [display, _vp.width]);

  const resetForNext = useCallback(() => {
    termFiringRef.current = false;
    setHalf("term");
    setSolveOpen(false);
    setSolveText("");
    setSolveWrong(false);
    setRevealed(false);
    setSelectedId(null);
    setReveal(null);
    setGuessError(null);
    setTimeLeft(termSeconds);
    setSpinning(false);
    setSpinResultBanner(null);
    setSpinError(null);
    if (spinTimeoutRef.current) { clearTimeout(spinTimeoutRef.current); spinTimeoutRef.current = null; }
  }, [termSeconds]);

  const advanceOrFinish = useCallback(() => {
    firingRef.current = false;
    if (idx + 1 < itemIds.length) {
      setIdx(i => i + 1);
      resetForNext();
    } else {
      onAllDone();
    }
  }, [idx, itemIds.length, onAllDone, resetForNext]);

  const submitMeaning = useCallback(async (optionId, secondsTaken) => {
    try {
      const r = await onSubmitAnswer(currentId, optionId, secondsTaken);
      setReveal(r || null);
    } catch (ex) {
      setSubmitError(ex?.message || "Could not submit that answer.");
    }
  }, [currentId, onSubmitAnswer]);

  const handleMeaningTimeout = useCallback(async () => {
    if (firingRef.current || revealed) return;
    firingRef.current = true;
    setRevealed(true);
    await submitMeaning(null, secondsPerPhase);
    firingRef.current = false;
  }, [revealed, submitMeaning, secondsPerPhase]);

  const handleTermTimeout = useCallback(async () => {
    if (termFiringRef.current) return;
    termFiringRef.current = true;
    try {
      const p = await onTermTimeout(currentId);
      if (p) {
        setProgress({
          display: p.display || "",
          guessed: Array.isArray(p.guessed) ? p.guessed : [],
          misses: Number(p.misses) || 0,
          solved: !!p.solved,
          over: true,
          answer: p.answer || null,
          roundMoney: Number(p.round_money) || 0,
          pendingSpin: null,
        });
      }
    } catch (ex) {
      setGuessError(ex?.message || "The clock ran out — tap through to the meaning.");
    }
    termFiringRef.current = false;
  }, [currentId, onTermTimeout]);

  useEffect(() => {
    if (half === "term" && termOver) return undefined;
    if (half === "meaning" && revealed) return undefined;
    if (timeLeft <= 0) {
      if (half === "term") handleTermTimeout();
      else handleMeaningTimeout();
      return undefined;
    }
    const t = setTimeout(() => setTimeLeft(tl => tl - 1), 1000);
    return () => clearTimeout(t);
  }, [timeLeft, half, termOver, revealed, handleMeaningTimeout, handleTermTimeout]);

  if (!currentItem) {
    return <div style={{ fontSize: 13, color: T.slate500 }}>Loading question…</div>;
  }

  const applyProgress = (p) => {
    if (!p) return;
    setProgress(prev => ({
      display: p.display || "",
      guessed: Array.isArray(p.guessed) ? p.guessed : [],
      misses: Number(p.misses) || 0,
      solved: !!p.solved,
      over: !!p.over,
      answer: p.answer || null,
      roundMoney: p.round_money !== undefined ? (Number(p.round_money) || 0) : (prev?.roundMoney || 0),
      pendingSpin: p.pending_spin !== undefined ? p.pending_spin : (prev?.pendingSpin || null),
    }));
  };

  // Spin the wheel. Purely a data call — the visible wheel spin is cosmetic
  // (see the `spinning`/`spinAngle` state above) and settles independently.
  const doSpin = async () => {
    if (half !== "term" || termOver || hasPendingValue || spinning || busyLetter) return;
    setSpinError(null);
    setSpinResultBanner(null);
    setSpinning(true);
    setSpinAngle(a => a + 1440 + Math.floor(Math.random() * 360)); // several full turns, cosmetic only
    try {
      const r = await onSpinWheel(currentId);
      // Let the CSS spin transition play out before revealing the true result —
      // an instant reveal under a still-spinning wheel looks broken.
      spinTimeoutRef.current = setTimeout(() => {
        setSpinning(false);
        setProgress(prev => ({
          ...prev,
          misses: Number(r.misses) || 0,
          guessed: Array.isArray(r.guessed) ? r.guessed : (prev?.guessed || []),
          roundMoney: Number(r.round_money) || 0,
          pendingSpin: r.pending_spin || null,
        }));
        if (r.result_type === "bankrupt") {
          setSpinResultBanner({ kind: "bankrupt", text: "BANKRUPT — this term's board resets to 0. Spin again." });
        } else if (r.result_type === "lose_turn") {
          setSpinResultBanner({ kind: "lose_turn", text: "Lose a Turn — no change. Spin again." });
        } else if (r.free_spin_resolved) {
          setSpinResultBanner({ kind: "free_spin", text: `Free Spin! Landed on ${r.pending_spin?.amount ?? 0} — call a consonant.` });
        } else {
          setSpinResultBanner({ kind: "value", text: `Landed on ${r.pending_spin?.amount ?? 0} — call a consonant.` });
        }
      }, 1400);
    } catch (ex) {
      setSpinning(false);
      setSpinError(ex?.message || "The wheel did not spin — try again.");
    }
  };

  const tapLetter = async (letter) => {
    if (half !== "term" || termOver || guessedSet.has(letter) || busyLetter) return;
    if (!hasPendingValue) { setGuessError("Spin the wheel before calling a consonant."); return; }
    setBusyLetter(letter);
    setGuessError(null);
    setSpinResultBanner(null);
    try {
      applyProgress(await onGuessLetter(currentId, letter));
    } catch (ex) {
      setGuessError(ex?.message || "That guess did not register — try again.");
    }
    setBusyLetter(null);
  };

  const tapVowel = async (letter) => {
    if (half !== "term" || termOver || guessedSet.has(letter) || busyLetter) return;
    if (roundMoney < VOWEL_COST) { setGuessError(`Not enough on the board yet — a vowel costs ${VOWEL_COST}.`); return; }
    setBusyLetter(letter);
    setGuessError(null);
    try {
      applyProgress(await onBuyVowel(currentId, letter));
    } catch (ex) {
      setGuessError(ex?.message || "That purchase did not register — try again.");
    }
    setBusyLetter(null);
  };

  const submitSolve = async () => {
    if (half !== "term" || termOver || busyLetter) return;
    setBusyLetter("SOLVE");
    setGuessError(null);
    try {
      const p = await onSolveTerm(currentId, solveText);
      applyProgress(p);
      if (p?.correct) {
        setSolveOpen(false);
        setSolveWrong(false);
      } else {
        setSolveText("");
        setSolveWrong(true);
      }
    } catch (ex) {
      setGuessError(ex?.message || "That guess did not register — try again.");
    }
    setBusyLetter(null);
  };

  const goToMeaning = () => {
    setHalf("meaning");
    setSolveOpen(false);
    setTimeLeft(secondsPerPhase);
  };

  const chooseMeaning = async (optionId) => {
    if (revealed || firingRef.current) return;
    firingRef.current = true;
    const secondsTaken = Math.max(0, secondsPerPhase - timeLeft);
    setSelectedId(optionId);
    setRevealed(true);
    await submitMeaning(optionId, secondsTaken);
    firingRef.current = false;
  };

  const solveBonus = solved ? roundMoney : 0;
  const guessesLeft = Math.max(0, PHRASE_MAX_MISSES - misses);
  const clockRunning = half === "term" ? !termOver : !revealed;
  const urgent = timeLeft <= 5;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10 }}>
        <span style={{ fontSize: 11, color: T.slate500 }}>{idx + 1} of {itemIds.length}</span>
        {clockRunning && <span style={s.timerPill(urgent)}>{timeLeft}s</span>}
      </div>
      {submitError && <div style={s.errorBanner}>{submitError}</div>}

      {/* The stem is not a clue, it is the definition — and the correct meaning
          option is a paraphrase of it. Showing it during the letter half handed
          over both halves at once. While the term is still hidden the player
          gets the category and nothing else; the definition appears only after
          the meaning has been answered. */}
      {half === "term" ? (
        <div style={s.phraseCategoryPill}>{formatGridCategoryLabel(currentItem.category)}</div>
      ) : (
        <div style={{ ...s.phraseCategoryPill, marginBottom: 8 }}>
          {formatGridCategoryLabel(currentItem.category)}
        </div>
      )}

      {/* The board is exactly what the server sent: letters found in place,
          everything still hidden as a blank tile. */}
      <div style={s.phraseBoard}>
        {display.split(" ").map((word, wi) => (
          <div key={wi} style={s.phraseWord}>
            {word.split("").map((ch, ci) => {
              const isBlank = (ch === "_");
              const isLetter = ch >= "A" && ch <= "Z";
              if (!isBlank && !isLetter) return <span key={ci} style={s.phrasePunct(tileW, tileH)}>{ch}</span>;
              return <span key={ci} style={s.phraseTile(!isBlank, tileW, tileH)}>{isBlank ? "" : ch}</span>;
            })}
          </div>
        ))}
      </div>

      {half === "term" && !termOver && (
        <>
          <div style={s.wheelRow}>
            <SpinWheel angle={spinAngle} spinning={spinning} />
            <div style={s.wheelSideCol}>
              <div style={s.roundMoneyPill}>{roundMoney} on the board</div>
              <button
                type="button"
                style={s.primaryBtn}
                onClick={doSpin}
                disabled={spinning || hasPendingValue || !!busyLetter}
              >
                {spinning ? "Spinning…" : hasPendingValue ? `Spun ${pendingSpin.amount} — call a consonant` : "Spin the wheel"}
              </button>
              <button
                type="button"
                style={s.ghostBtn}
                onClick={() => setSolveOpen(o => !o)}
              >
                {solveOpen ? "Back to letters" : "Solve it"}
              </button>
            </div>
          </div>
          {spinResultBanner && (
            <div style={s.spinResultBanner(spinResultBanner.kind)}>{spinResultBanner.text}</div>
          )}
          {spinError && <div style={s.errorBanner}>{spinError}</div>}
          <div style={s.phraseStatusRow}>
            <span>{guessesLeft} wrong {guessesLeft === 1 ? "guess" : "guesses"} left</span>
            <span>Buy a vowel — {VOWEL_COST} pts</span>
          </div>
          {guessError && <div style={s.errorBanner}>{guessError}</div>}
          {solveOpen ? (
            <div style={s.solveRow}>
              <input
                type="text"
                value={solveText}
                onChange={(e) => setSolveText(e.target.value)}
                placeholder="Type the whole term"
                style={{ ...s.editInput, flex: 1, minWidth: 150 }}
              />
              <button type="button" style={s.primaryBtn} onClick={submitSolve} disabled={!solveText.trim() || !!busyLetter}>
                Submit
              </button>
            </div>
          ) : (
            <div style={s.letterGrid}>
              {PHRASE_LETTERS.map(letter => {
                let state = "default";
                if (guessedSet.has(letter)) state = hitLetters.has(letter) ? "hit" : "miss";
                const isVowel = PHRASE_VOWELS.has(letter);
                const disabled = guessedSet.has(letter) || !!busyLetter
                  || (isVowel ? roundMoney < VOWEL_COST : !hasPendingValue);
                return (
                  <button
                    key={letter}
                    type="button"
                    style={isVowel ? s.letterBtn(state, true) : s.letterBtn(state)}
                    onClick={() => (isVowel ? tapVowel(letter) : tapLetter(letter))}
                    disabled={disabled}
                    title={isVowel ? `Buy for ${VOWEL_COST} pts` : "Spin first"}
                  >
                    {letter}
                  </button>
                );
              })}
            </div>
          )}
        </>
      )}

      {half === "term" && termOver && (
        <div>
          <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8, color: solved ? T.green : T.slate600 }}>
            {solved
              ? `Solved — ${solveBonus} points for the term.`
              : solveWrong
                ? "Not it — one guess to solve, and that was it. No bonus this time."
                : "Out of guesses — that is the term. No bonus this time."}
          </div>
          {guessError && <div style={s.errorBanner}>{guessError}</div>}
          <div style={s.actionsRow}>
            <button type="button" style={s.primaryBtn} onClick={goToMeaning}>Now, what does it mean?</button>
          </div>
        </div>
      )}

      {half === "meaning" && (
        <>
          <div style={s.qStem}>What does it mean?</div>
          {(displayOptions || []).map(o => {
            let state = "default";
            // Wait for the actual server response before coloring anything —
            // setRevealed(true) fires synchronously on click, before the
            // await resolves, so gating on `revealed` alone briefly renders
            // every option (including the correct one) as reveal ? in the
            // one frame where reveal is still null. That is the red-then-
            // green flash: gate on reveal being present instead.
            if (revealed && reveal) {
              const right = o.id === reveal.correct_option_id;
              if (o.id === selectedId && right) state = "selectedCorrect";
              else if (o.id === selectedId && !right) state = "selectedWrong";
              else if (right) state = "revealCorrect";
              else state = "revealDim";
            }
            return (
              <button
                key={o.id}
                type="button"
                style={s.qOptionBtn(state)}
                onClick={() => chooseMeaning(o.id)}
                disabled={revealed}
              >
                {o.option_text}
              </button>
            );
          })}
          {revealed && (
            <>
              {reveal?.stem && (
                <div style={{ ...s.explanationBox, background: T.blueLt, color: T.slate800 }}>
                  <strong>{reveal.phrase_answer || progress?.answer || ""}</strong> — {reveal.stem}
                </div>
              )}
              {reveal?.explanation && <div style={s.explanationBox}>{reveal.explanation}</div>}
              <div style={s.actionsRow}>
                <button type="button" style={s.primaryBtn} onClick={advanceOrFinish}>
                  {idx + 1 < itemIds.length ? "Next term" : "Finish"}
                </button>
              </div>
            </>
          )}
        </>
      )}
    </div>
  );
}

// The colouring used to read is_correct off each option, which meant the answer
// key had to be in the browser before the question was answered. It is not any
// more. onSubmitAnswer hands back which option was right, and that arrives at
// the only moment it is safe to know: after the answer has been recorded.
function QuestionRunner({ itemIds, itemsById, attemptId, secondsPerQuestion, onSubmitAnswer, onAllDone }) {
  const [idx, setIdx] = useState(0);
  const [timeLeft, setTimeLeft] = useState(secondsPerQuestion);
  const [revealed, setRevealed] = useState(false);
  const [selectedId, setSelectedId] = useState(null);
  const [reveal, setReveal] = useState(null);
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
      setReveal(null);
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
      const r = await onSubmitAnswer(currentId, optionId, secondsTaken);
      setReveal(r || null);
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
        // Same fix as PhraseRunner's meaning phase: gate on reveal being
        // present, not just revealed, so a correct answer never renders red
        // for the one frame before the server response lands.
        if (revealed && reveal) {
          const right = o.id === reveal.correct_option_id;
          if (o.id === selectedId && right) state = "selectedCorrect";
          else if (o.id === selectedId && !right) state = "selectedWrong";
          else if (right) state = "revealCorrect";
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
          {reveal?.explanation && <div style={s.explanationBox}>{reveal.explanation}</div>}
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
