// =========================================================================
// CourseGradebook.jsx
// =========================================================================
// Owner-only module for Peter's Thursday consumer math / financial literacy
// course gradebook. Grade model (LOCKED): 40% participation, 45% projects
// (22 of them), 15% capstone. Renormalized weighting — v_course_grades does
// the math server-side; this component just displays it.
//
// Minors' data constraint: only first-name + last-initial display_name,
// grade_level, is_active, notes are stored anywhere. No last names, no DOB,
// no contact info, no photos persisted. Student names are never written to
// persistent_memory / session_notes / open_questions — reference by row id.
//
// Data: course_students, course_sessions, course_grade_items,
// course_participation, v_course_grades (read-only aggregate view).
// RLS restricts all four tables to the owner role only.
// =========================================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useTabParam } from "../lib/routing.jsx";
import { useViewport } from "../lib/hooks.js";

const SCHOOL_YEAR = "2026-27";

const CHECKS = [
  { key: "on_time",           label: "On time" },
  { key: "brought_bible",     label: "Brought Bible" },
  { key: "took_notes",        label: "Took notes" },
  { key: "contributed",       label: "Contributed" },
  { key: "homework_complete", label: "Homework complete" },
];

// ─── shared UI primitives ─────────────────────────────────────────────────
const Card = ({ children, style = {} }) => (
  <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: "16px 18px", boxSizing: "border-box", ...style }}>
    {children}
  </div>
);

const Btn = ({ children, onClick, variant = "primary", disabled, style = {} }) => {
  const variants = {
    primary:   { background: T.blue, color: T.white, border: `1px solid ${T.blue}` },
    secondary: { background: T.white, color: T.slate700, border: `1px solid ${T.slate300}` },
    danger:    { background: T.white, color: T.red, border: `1px solid ${T.red}` },
  };
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        padding: "8px 14px", borderRadius: 8, fontSize: 13, fontWeight: 600,
        cursor: disabled ? "not-allowed" : "pointer", opacity: disabled ? 0.5 : 1,
        boxSizing: "border-box", ...variants[variant], ...style,
      }}
    >
      {children}
    </button>
  );
};

const Toast = ({ text, kind = "success", onDone }) => {
  useEffect(() => {
    const t = setTimeout(onDone, 2600);
    return () => clearTimeout(t);
  }, [onDone]);
  const bg = kind === "error" ? T.redLt : T.greenLt;
  const fg = kind === "error" ? T.red : T.green;
  return (
    <div style={{ position: "fixed", bottom: 20, left: "50%", transform: "translateX(-50%)", background: bg, color: fg, border: `1px solid ${fg}`, borderRadius: 10, padding: "10px 18px", fontSize: 13, fontWeight: 600, zIndex: 200, boxShadow: "0 4px 16px rgba(0,0,0,0.12)" }}>
      {text}
    </div>
  );
};

function nearestSessionCode(sessions) {
  if (!Array.isArray(sessions) || sessions.length === 0) return null;
  const today = new Date().toISOString().slice(0, 10);
  let best = sessions[0];
  let bestDiff = Infinity;
  for (const s of sessions) {
    const diff = Math.abs(new Date(s.session_date) - new Date(today));
    if (diff < bestDiff) { bestDiff = diff; best = s; }
  }
  return best.session_code;
}

// =========================================================================
// Tab 1 — This Week
// =========================================================================
function ThisWeekTab({ sessions, students, vp, notify }) {
  const nearest = useMemo(() => nearestSessionCode(sessions), [sessions]);
  const [sessionCode, setSessionCode] = useTabParam("session", nearest, sessions.map(s => s.session_code));
  const [grid, setGrid] = useState({}); // { studentId: { on_time: bool, ... } }
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);

  const session = sessions.find(s => s.session_code === sessionCode) || sessions.find(s => s.session_code === nearest);

  const loadWeek = useCallback(async () => {
    if (!session) return;
    setLoading(true);
    const { data, error } = await supabase
      .from("course_participation")
      .select("student_id, on_time, brought_bible, took_notes, contributed, homework_complete")
      .eq("agency_id", AGENCY_ID)
      .eq("session_id", session.id);
    if (error) {
      notify(`Couldn't load this week: ${error.message}`, "error");
      setLoading(false);
      return;
    }
    const byStudent = {};
    for (const row of data || []) byStudent[row.student_id] = row;
    // Default every active student to all-checked-true unless a saved row exists.
    const next = {};
    for (const st of students) {
      const existing = byStudent[st.id];
      next[st.id] = existing
        ? {
            on_time: existing.on_time !== false,
            brought_bible: existing.brought_bible !== false,
            took_notes: existing.took_notes !== false,
            contributed: existing.contributed !== false,
            homework_complete: existing.homework_complete !== false,
          }
        : { on_time: true, brought_bible: true, took_notes: true, contributed: true, homework_complete: true };
    }
    setGrid(next);
    setLoading(false);
  }, [session, students, notify]);

  useEffect(() => { loadWeek(); }, [loadWeek]);

  const toggle = (studentId, key) => {
    setGrid(g => ({ ...g, [studentId]: { ...g[studentId], [key]: !g[studentId]?.[key] } }));
  };

  const saveWeek = async () => {
    if (!session) return;
    setSaving(true);
    const rows = students.map(st => ({
      agency_id: AGENCY_ID,
      student_id: st.id,
      session_id: session.id,
      ...grid[st.id],
    }));
    const { data, error } = await supabase
      .from("course_participation")
      .upsert(rows, { onConflict: "agency_id,student_id,session_id" })
      .select("id");
    setSaving(false);
    if (error) {
      notify(`Save failed: ${error.message}. Nothing was saved — try again.`, "error");
      return;
    }
    if (!data || data.length !== rows.length) {
      notify("Save didn't affect all rows — check your connection and try again.", "error");
      return;
    }
    notify(`Saved ${session.session_code} for ${rows.length} students.`);
  };

  const toggleNotHeld = async () => {
    if (!session) return;
    const { data, error } = await supabase
      .from("course_sessions")
      .update({ was_held: !session.was_held })
      .eq("id", session.id)
      .eq("agency_id", AGENCY_ID)
      .select("id");
    if (error) { notify(`Couldn't update session: ${error.message}`, "error"); return; }
    if (!data || data.length === 0) { notify("Update didn't affect any rows.", "error"); return; }
    notify(session.was_held ? `${session.session_code} marked not held — dropped from grading.` : `${session.session_code} marked held again.`);
    session.was_held = !session.was_held; // optimistic local mirror; parent refetch also covers it
  };

  if (!session) return <Card>No sessions found for {SCHOOL_YEAR}.</Card>;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <Card>
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
          <select
            value={sessionCode || ""}
            onChange={(e) => setSessionCode(e.target.value)}
            style={{ padding: "8px 10px", borderRadius: 8, border: `1px solid ${T.slate300}`, fontSize: 14, fontWeight: 600, boxSizing: "border-box" }}
          >
            {sessions.map(s => (
              <option key={s.session_code} value={s.session_code}>
                {s.session_code} — {s.session_date}{s.was_held === false ? " (not held)" : ""}
              </option>
            ))}
          </select>
          <Btn variant={session.was_held === false ? "secondary" : "danger"} onClick={toggleNotHeld}>
            {session.was_held === false ? "Mark held" : "Session not held"}
          </Btn>
        </div>
        {session.was_held === false && (
          <div style={{ marginTop: 10, fontSize: 12.5, color: T.amber, fontWeight: 600 }}>
            This session is excluded from every student's participation grade.
          </div>
        )}
      </Card>

      {loading ? (
        <Card>Loading…</Card>
      ) : (
        <Card style={{ padding: 0, overflow: "hidden" }}>
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
            <table style={{ width: "100%", borderCollapse: "collapse", minWidth: vp.isPhone ? 520 : "auto" }}>
              <thead>
                <tr style={{ background: T.slate50 }}>
                  <th style={{ textAlign: "left", padding: "10px 12px", fontSize: 12, color: T.slate500, fontWeight: 700 }}>Student</th>
                  {CHECKS.map(c => (
                    <th key={c.key} style={{ textAlign: "center", padding: "10px 8px", fontSize: 11, color: T.slate500, fontWeight: 700 }}>{c.label}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {students.map(st => (
                  <tr key={st.id} style={{ borderTop: `1px solid ${T.slate200}` }}>
                    <td style={{ padding: "10px 12px", fontSize: 14, fontWeight: 600, color: T.slate900 }}>{st.display_name}</td>
                    {CHECKS.map(c => (
                      <td key={c.key} style={{ textAlign: "center", padding: "8px" }}>
                        <button
                          onClick={() => toggle(st.id, c.key)}
                          style={{
                            width: 32, height: 32, borderRadius: 8, boxSizing: "border-box",
                            border: `1.5px solid ${grid[st.id]?.[c.key] ? T.green : T.slate300}`,
                            background: grid[st.id]?.[c.key] ? T.greenLt : T.white,
                            color: grid[st.id]?.[c.key] ? T.green : T.slate400,
                            fontSize: 16, fontWeight: 700, cursor: "pointer",
                          }}
                        >
                          {grid[st.id]?.[c.key] ? "✓" : ""}
                        </button>
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      <Btn onClick={saveWeek} disabled={saving || loading} style={{ alignSelf: "flex-start", padding: "12px 22px", fontSize: 15 }}>
        {saving ? "Saving…" : "Save week"}
      </Btn>
    </div>
  );
}

// =========================================================================
// Tab 2 — Projects
// =========================================================================
function ProjectsTab({ students, vp, notify, reloadKey, bumpReload }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState(null); // { studentId, itemRef }
  const [scoreInput, setScoreInput] = useState("");
  const [feedbackInput, setFeedbackInput] = useState("");
  const [pasteStudent, setPasteStudent] = useState(students[0]?.id || "");
  const [pasteText, setPasteText] = useState("");
  const [pasteBusy, setPasteBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const { data, error } = await supabase
        .from("course_grade_items")
        .select("id, student_id, item_ref, item_title, weight_category, score, feedback")
        .eq("agency_id", AGENCY_ID)
        .eq("school_year", SCHOOL_YEAR)
        .order("item_ref", { ascending: true });
      if (cancelled) return;
      if (error) { notify(`Couldn't load projects: ${error.message}`, "error"); setLoading(false); return; }
      setItems(data || []);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, [notify, reloadKey]);

  const refs = useMemo(() => {
    const seen = new Map();
    for (const it of items) {
      if (!seen.has(it.item_ref)) seen.set(it.item_ref, it.weight_category);
    }
    // capstone last
    return [...seen.keys()].sort((a, b) => {
      if (a === "CAPSTONE") return 1;
      if (b === "CAPSTONE") return -1;
      return a.localeCompare(b, undefined, { numeric: true });
    });
  }, [items]);

  const cell = (studentId, ref) => items.find(it => it.student_id === studentId && it.item_ref === ref);

  const openEdit = (studentId, ref) => {
    const c = cell(studentId, ref);
    setEditing({ studentId, itemRef: ref });
    setScoreInput(c?.score != null ? String(c.score) : "");
    setFeedbackInput(c?.feedback || "");
  };

  const saveEdit = async () => {
    if (!editing) return;
    const scoreNum = scoreInput.trim() === "" ? null : Number(scoreInput);
    if (scoreInput.trim() !== "" && (Number.isNaN(scoreNum) || scoreNum < 0 || scoreNum > 100)) {
      notify("Score must be 0-100.", "error");
      return;
    }
    const { data, error } = await supabase
      .from("course_grade_items")
      .upsert([{
        agency_id: AGENCY_ID,
        school_year: SCHOOL_YEAR,
        student_id: editing.studentId,
        item_ref: editing.itemRef,
        weight_category: editing.itemRef === "CAPSTONE" ? "capstone" : "project",
        score: scoreNum,
        feedback: feedbackInput.trim() || null,
        graded_at: scoreNum != null ? new Date().toISOString() : null,
      }], { onConflict: "agency_id,school_year,student_id,item_ref" })
      .select("id");
    if (error) { notify(`Save failed: ${error.message}`, "error"); return; }
    if (!data || data.length === 0) { notify("Save didn't affect any rows.", "error"); return; }
    notify("Saved.");
    setEditing(null);
    bumpReload();
  };

  const runPaste = async () => {
    if (!pasteStudent || !pasteText.trim()) return;
    const lines = pasteText.split("\n").map(l => l.trim()).filter(Boolean);
    const rows = [];
    for (const line of lines) {
      const parts = line.split(",").map(p => p.trim());
      if (parts.length < 2) continue;
      const [ref, sc, ...rest] = parts;
      const scoreNum = Number(sc);
      if (Number.isNaN(scoreNum) || scoreNum < 0 || scoreNum > 100) continue;
      rows.push({
        agency_id: AGENCY_ID,
        school_year: SCHOOL_YEAR,
        student_id: pasteStudent,
        item_ref: ref,
        weight_category: ref === "CAPSTONE" ? "capstone" : "project",
        score: scoreNum,
        feedback: rest.join(",").trim() || null,
        graded_at: new Date().toISOString(),
      });
    }
    if (rows.length === 0) { notify("Nothing parseable — use one 'item_ref, score' per line.", "error"); return; }
    setPasteBusy(true);
    const { data, error } = await supabase
      .from("course_grade_items")
      .upsert(rows, { onConflict: "agency_id,school_year,student_id,item_ref" })
      .select("id");
    setPasteBusy(false);
    if (error) { notify(`Bulk save failed: ${error.message}`, "error"); return; }
    if (!data || data.length !== rows.length) { notify("Bulk save didn't affect all rows.", "error"); return; }
    notify(`Saved ${rows.length} scores.`);
    setPasteText("");
    bumpReload();
  };

  if (loading) return <Card>Loading…</Card>;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <Card>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 8 }}>Bulk entry (paste)</div>
        <div style={{ fontSize: 12.5, color: T.slate500, marginBottom: 10 }}>
          One line per score: <code>item_ref, score, optional feedback</code>. Creates the item if it doesn't exist yet.
        </div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 10 }}>
          <select
            value={pasteStudent}
            onChange={(e) => setPasteStudent(e.target.value)}
            style={{ padding: "8px 10px", borderRadius: 8, border: `1px solid ${T.slate300}`, fontSize: 14, boxSizing: "border-box" }}
          >
            {students.map(st => <option key={st.id} value={st.id}>{st.display_name}</option>)}
          </select>
        </div>
        <textarea
          value={pasteText}
          onChange={(e) => setPasteText(e.target.value)}
          placeholder={"1.5, 92, nice work\n2.6, 78"}
          rows={4}
          style={{ width: "100%", padding: 10, borderRadius: 8, border: `1px solid ${T.slate300}`, fontSize: 13, fontFamily: "monospace", boxSizing: "border-box" }}
        />
        <div style={{ marginTop: 10 }}>
          <Btn onClick={runPaste} disabled={pasteBusy}>{pasteBusy ? "Saving…" : "Save bulk scores"}</Btn>
        </div>
      </Card>

      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: vp.isPhone ? Math.max(520, refs.length * 70) : "auto" }}>
            <thead>
              <tr style={{ background: T.slate50 }}>
                <th style={{ textAlign: "left", padding: "10px 12px", fontSize: 12, color: T.slate500, fontWeight: 700, position: "sticky", left: 0, background: T.slate50 }}>Student</th>
                {refs.map(r => (
                  <th key={r} style={{ textAlign: "center", padding: "8px 6px", fontSize: 11, color: T.slate500, fontWeight: 700 }}>{r}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {students.map(st => (
                <tr key={st.id} style={{ borderTop: `1px solid ${T.slate200}` }}>
                  <td style={{ padding: "10px 12px", fontSize: 14, fontWeight: 600, color: T.slate900, position: "sticky", left: 0, background: T.white }}>{st.display_name}</td>
                  {refs.map(r => {
                    const c = cell(st.id, r);
                    const graded = c && c.score != null;
                    return (
                      <td key={r} style={{ textAlign: "center", padding: "6px" }}>
                        <button
                          onClick={() => openEdit(st.id, r)}
                          style={{
                            width: 44, height: 32, borderRadius: 8, boxSizing: "border-box",
                            border: `1px solid ${graded ? T.blue : T.slate300}`,
                            background: graded ? T.blueLt : T.white,
                            color: graded ? T.blue : T.slate400,
                            fontSize: 13, fontWeight: 700, cursor: "pointer",
                          }}
                        >
                          {graded ? c.score : "—"}
                        </button>
                      </td>
                    );
                  })}
                </tr>
              ))}
              {refs.length === 0 && (
                <tr><td style={{ padding: 16, fontSize: 13, color: T.slate500 }} colSpan={2}>
                  No project items yet. Use bulk entry above to add scores — it creates items on the fly.
                </td></tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>

      {editing && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.35)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 100, padding: 16, boxSizing: "border-box" }}>
          <Card style={{ width: "100%", maxWidth: 380 }}>
            <div style={{ fontSize: 15, fontWeight: 700, marginBottom: 12 }}>{editing.itemRef}</div>
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 4 }}>Score (0-100, blank = ungraded)</div>
            <input
              value={scoreInput}
              onChange={(e) => setScoreInput(e.target.value)}
              inputMode="numeric"
              style={{ width: "100%", padding: 10, borderRadius: 8, border: `1px solid ${T.slate300}`, fontSize: 14, marginBottom: 10, boxSizing: "border-box" }}
            />
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 4 }}>Feedback (optional)</div>
            <textarea
              value={feedbackInput}
              onChange={(e) => setFeedbackInput(e.target.value)}
              rows={3}
              style={{ width: "100%", padding: 10, borderRadius: 8, border: `1px solid ${T.slate300}`, fontSize: 13, marginBottom: 14, boxSizing: "border-box" }}
            />
            <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
              <Btn variant="secondary" onClick={() => setEditing(null)}>Cancel</Btn>
              <Btn onClick={saveEdit}>Save</Btn>
            </div>
          </Card>
        </div>
      )}
    </div>
  );
}

// =========================================================================
// Tab 3 — Grades
// =========================================================================
function GradesTab({ vp, notify }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const { data, error } = await supabase
        .from("v_course_grades")
        .select("*")
        .eq("agency_id", AGENCY_ID)
        .eq("school_year", SCHOOL_YEAR)
        .order("display_name", { ascending: true });
      if (cancelled) return;
      if (error) { notify(`Couldn't load grades: ${error.message}`, "error"); setLoading(false); return; }
      setRows(data || []);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, [notify]);

  const exportCsv = () => {
    const header = ["Student", "Participation %", "Projects %", "Projects graded", "Capstone %", "Current grade %"];
    const lines = [header.join(",")];
    for (const r of rows) {
      lines.push([
        r.display_name,
        r.participation_pct ?? "",
        r.projects_pct ?? "",
        `${r.projects_graded_count}/${r.projects_total_count}`,
        r.capstone_pct ?? "",
        r.current_grade_pct ?? "",
      ].join(","));
    }
    const blob = new Blob([lines.join("\n")], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `gradebook_${SCHOOL_YEAR}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (loading) return <Card>Loading…</Card>;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div style={{ display: "flex", justifyContent: "flex-end" }}>
        <Btn variant="secondary" onClick={exportCsv}>Export CSV</Btn>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))", gap: 12 }}>
        {rows.map(r => (
          <Card key={r.student_id}>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>{r.display_name}</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 13, color: T.slate700 }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span>Participation (40%)</span>
                <strong>{r.participation_pct != null ? `${r.participation_pct}%` : "—"}</strong>
              </div>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span>Projects (45%)</span>
                <strong>{r.projects_pct != null ? `${r.projects_pct}%` : "—"} <span style={{ color: T.slate400, fontWeight: 400 }}>({r.projects_graded_count}/{r.projects_total_count})</span></strong>
              </div>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span>Capstone (15%)</span>
                <strong>{r.capstone_pct != null ? `${r.capstone_pct}%` : "—"}</strong>
              </div>
              <div style={{ borderTop: `1px solid ${T.slate200}`, marginTop: 6, paddingTop: 8, display: "flex", justifyContent: "space-between", fontSize: 15 }}>
                <span style={{ fontWeight: 700 }}>Current grade</span>
                <strong style={{ color: T.blue }}>{r.current_grade_pct != null ? `${r.current_grade_pct}%` : "—"}</strong>
              </div>
            </div>
          </Card>
        ))}
        {rows.length === 0 && <Card>No students yet.</Card>}
      </div>
    </div>
  );
}

// =========================================================================
// Root
// =========================================================================
export default function CourseGradebook() {
  const vp = useViewport();
  const [tab, setTab] = useTabParam("tab", "week", ["week", "projects", "grades"]);
  const [students, setStudents] = useState([]);
  const [sessions, setSessions] = useState([]);
  const [loading, setLoading] = useState(true);
  const [toast, setToast] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);

  const notify = useCallback((text, kind = "success") => setToast({ text, kind }), []);
  const bumpReload = useCallback(() => setReloadKey(k => k + 1), []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const [stuRes, sesRes] = await Promise.all([
        supabase.from("course_students").select("id, display_name, grade_level, is_active")
          .eq("agency_id", AGENCY_ID).eq("school_year", SCHOOL_YEAR).eq("is_active", true)
          .order("display_name", { ascending: true }),
        supabase.from("course_sessions").select("id, session_code, session_date, semester, was_held")
          .eq("agency_id", AGENCY_ID).eq("school_year", SCHOOL_YEAR)
          .order("session_date", { ascending: true }),
      ]);
      if (cancelled) return;
      if (stuRes.error) notify(`Couldn't load students: ${stuRes.error.message}`, "error");
      if (sesRes.error) notify(`Couldn't load sessions: ${sesRes.error.message}`, "error");
      setStudents(stuRes.data || []);
      setSessions(sesRes.data || []);
      setLoading(false);
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const pad = vp.isPhone ? "12px" : "20px 24px";

  if (loading) {
    return <div style={{ padding: pad, boxSizing: "border-box" }}>Loading gradebook…</div>;
  }

  return (
    <div style={{ padding: pad, boxSizing: "border-box", display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: 10 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Course Gradebook</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>{SCHOOL_YEAR} · {students.length} students</div>
        </div>
      </div>

      <div style={{ display: "flex", gap: 8, overflowX: "auto", whiteSpace: "nowrap", borderBottom: `1px solid ${T.slate200}`, paddingBottom: 2 }}>
        {[["week", "This Week"], ["projects", "Projects"], ["grades", "Grades"]].map(([id, label]) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            style={{
              flexShrink: 0, padding: "10px 14px", borderRadius: "8px 8px 0 0", border: "none",
              borderBottom: tab === id ? `2px solid ${T.blue}` : "2px solid transparent",
              background: "transparent", color: tab === id ? T.blue : T.slate500,
              fontSize: 14, fontWeight: 700, cursor: "pointer",
            }}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === "week" && <ThisWeekTab sessions={sessions} students={students} vp={vp} notify={notify} />}
      {tab === "projects" && <ProjectsTab students={students} vp={vp} notify={notify} reloadKey={reloadKey} bumpReload={bumpReload} />}
      {tab === "grades" && <GradesTab vp={vp} notify={notify} />}

      {toast && <Toast text={toast.text} kind={toast.kind} onDone={() => setToast(null)} />}
    </div>
  );
}
