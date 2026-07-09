import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// ============================================================
// Newtworks BOOK MODULE
// Newtworks — State Farm Agent Edition
//
// Alphabet split of household assignments across the team.
// Snapshot-per-date: each row is (snapshot_date, letter_bucket,
// team_member_id, account_count). The most recent snapshot is
// the current active split; prior snapshots preserve history.
//
// Data: book_alpha_split, team (active + non-backoffice only)
// ============================================================

// ─── Local Design Tokens & Helpers ────────────────────────────
const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);

const CANONICAL_BUCKETS = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X-Z"];

// ─── Book Assignments Section ────────────────────────────────
// Snapshot-based alphabet split for service-book assignment.
// One row per (snapshot_date, letter_bucket) in book_alpha_split.
const producerLabel = (m) => {
  if (!m) return "Unassigned";
  const nick = m.nickname || m.first_name || "";
  return (nick + " " + (m.last_name || "")).trim();
};

// Shared styles for editor + buttons (defined once near component)
const bookInputStyle = { padding:"5px 8px", fontSize:12, border:`1px solid ${T.slate200}`, borderRadius:6, background:T.white, color:T.slate800 };
const bookBtnPrimary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" };
const bookBtnSecondary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.slate700, background:T.white, border:`1px solid ${T.slate200}`, borderRadius:7, cursor:"pointer" };
const bookBtnDanger = { padding:"6px 12px", fontSize:11, fontWeight:600, color:T.red, background:T.white, border:`1px solid ${T.redLt}`, borderRadius:7, cursor:"pointer" };

const BucketEditor = ({ buckets, draft, setDraft, teamList }) => {
  const update = (bucket, field, value) => {
    setDraft(prev => ({ ...prev, [bucket]: { ...(prev[bucket] || {}), [field]: value } }));
  };
  return (
    <Card>
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(240px, 1fr))", gap:8 }}>
        {(buckets || []).map(b => {
          const v = draft?.[b] || { team_member_id: null, account_count: 0 };
          return (
            <div key={b} style={{ border:`1px solid ${T.slate200}`, borderRadius:8, padding:"8px 10px" }}>
              <div style={{ fontSize:12, fontWeight:700, color:T.slate900, marginBottom:6 }}>{b}</div>
              <select
                value={v.team_member_id || ""}
                onChange={e => update(b, "team_member_id", e.target.value || null)}
                style={{ ...bookInputStyle, width:"100%", marginBottom:6 }}
              >
                <option value="">— Unassigned —</option>
                {(teamList || []).map(t => (
                  <option key={t.id} value={t.id}>{producerLabel(t)}</option>
                ))}
              </select>
              <input
                type="number"
                min="0"
                value={v.account_count ?? 0}
                onChange={e => update(b, "account_count", e.target.value)}
                style={{ ...bookInputStyle, width:"100%" }}
              />
            </div>
          );
        })}
      </div>
    </Card>
  );
};

const BookAssignmentsSection = () => {
  const [allRows, setAllRows] = useState([]);
  const [teamList, setTeamList] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedDate, setSelectedDate] = useState(null);
  const [editing, setEditing] = useState(false);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState({});
  const [newDate, setNewDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [saving, setSaving] = useState(false);

  const load = async () => {
    if (!supabase || !AGENCY_ID) { setLoading(false); return; }
    setLoading(true);
    setError(null);
    const [rowsRes, teamRes] = await Promise.all([
      supabase
        .from("book_alpha_split")
        .select("id, snapshot_date, letter_bucket, team_member_id, account_count, notes")
        .eq("agency_id", AGENCY_ID)
        .order("snapshot_date", { ascending: false }),
      supabase
        .from("team")
        .select("id, first_name, last_name, nickname")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true)
        .eq("is_admin_backoffice", false)
        .order("last_name"),
    ]);
    if (rowsRes?.error || teamRes?.error) {
      setError(rowsRes?.error?.message || teamRes?.error?.message);
      setLoading(false);
      return;
    }
    const rows = Array.isArray(rowsRes?.data) ? rowsRes.data : [];
    const team = Array.isArray(teamRes?.data) ? teamRes.data : [];
    setAllRows(rows);
    setTeamList(team);
    setSelectedDate(prev => prev || (rows.length ? rows[0].snapshot_date : null));
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const allDates = useMemo(() => {
    const set = new Set((allRows || []).map(r => r.snapshot_date));
    return Array.from(set).sort().reverse();
  }, [allRows]);

  const currentRows = useMemo(() => {
    if (!selectedDate) return [];
    return (allRows || []).filter(r => r.snapshot_date === selectedDate);
  }, [allRows, selectedDate]);

  const allBuckets = useMemo(() => {
    const extra = (currentRows || [])
      .map(r => r.letter_bucket)
      .filter(b => !CANONICAL_BUCKETS.includes(b));
    return [...CANONICAL_BUCKETS, ...Array.from(new Set(extra))];
  }, [currentRows]);

  const priorDate = useMemo(() => {
    const i = allDates.indexOf(selectedDate);
    return i >= 0 && i < allDates.length - 1 ? allDates[i + 1] : null;
  }, [allDates, selectedDate]);

  const priorRows = useMemo(() => {
    if (!priorDate) return [];
    return (allRows || []).filter(r => r.snapshot_date === priorDate);
  }, [allRows, priorDate]);

  const findRow = (rows, bucket) => (rows || []).find(r => r.letter_bucket === bucket);
  const memberById = (id) => (teamList || []).find(t => t.id === id);

  const rollup = useMemo(() => {
    const map = new Map();
    (currentRows || []).forEach(r => {
      const key = r.team_member_id || "_unassigned";
      const cur = map.get(key) || { team_member_id: r.team_member_id, total: 0, letters: [] };
      cur.total += Number(r.account_count) || 0;
      cur.letters.push(r.letter_bucket);
      map.set(key, cur);
    });
    return Array.from(map.values()).sort((a, b) => b.total - a.total);
  }, [currentRows]);

  const grandTotal = useMemo(() => rollup.reduce((s, r) => s + r.total, 0), [rollup]);

  const buildDraftFromRows = (rows) => {
    const d = {};
    allBuckets.forEach(b => {
      const r = findRow(rows, b);
      d[b] = { team_member_id: r?.team_member_id || null, account_count: r?.account_count ?? 0 };
    });
    return d;
  };

  const startEdit = () => { setDraft(buildDraftFromRows(currentRows)); setEditing(true); };
  const cancelEdit = () => { setEditing(false); setDraft({}); };

  const saveEdit = async () => {
    setSaving(true);
    const upserts = Object.entries(draft).map(([bucket, v]) => ({
      agency_id: AGENCY_ID,
      snapshot_date: selectedDate,
      letter_bucket: bucket,
      team_member_id: v.team_member_id || null,
      account_count: Number(v.account_count) || 0,
    }));
    const { error: upErr } = await supabase
      .from("book_alpha_split")
      .upsert(upserts, { onConflict: "agency_id,snapshot_date,letter_bucket" });
    setSaving(false);
    if (upErr) { setError(upErr.message); return; }
    setEditing(false);
    setDraft({});
    await load();
  };

  const startAdd = () => {
    setDraft(buildDraftFromRows(currentRows));
    setNewDate(new Date().toISOString().slice(0, 10));
    setAdding(true);
  };
  const cancelAdd = () => { setAdding(false); setDraft({}); };

  const saveAdd = async () => {
    if (!newDate) return;
    setSaving(true);
    const upserts = Object.entries(draft).map(([bucket, v]) => ({
      agency_id: AGENCY_ID,
      snapshot_date: newDate,
      letter_bucket: bucket,
      team_member_id: v.team_member_id || null,
      account_count: Number(v.account_count) || 0,
    }));
    const { error: upErr } = await supabase
      .from("book_alpha_split")
      .upsert(upserts, { onConflict: "agency_id,snapshot_date,letter_bucket" });
    setSaving(false);
    if (upErr) { setError(upErr.message); return; }
    setAdding(false);
    setDraft({});
    setSelectedDate(newDate);
    await load();
  };

  const deleteSnapshot = async () => {
    if (!selectedDate) return;
    if (!window.confirm(`Delete the ${selectedDate} snapshot entirely? This cannot be undone.`)) return;
    setSaving(true);
    const { error: delErr } = await supabase
      .from("book_alpha_split")
      .delete()
      .eq("agency_id", AGENCY_ID)
      .eq("snapshot_date", selectedDate);
    setSaving(false);
    if (delErr) { setError(delErr.message); return; }
    setSelectedDate(null);
    await load();
  };

  if (loading) return <Card><div style={{ color:T.slate500, fontSize:13 }}>Loading book assignments…</div></Card>;

  if ((allRows || []).length === 0 && !adding) {
    return (
      <Card>
        <div style={{ fontSize:14, fontWeight:600, color:T.slate800, marginBottom:8 }}>No book snapshots yet</div>
        <div style={{ fontSize:12, color:T.slate500, marginBottom:14 }}>
          Capture your first alphabet split — which producer services which letters of the alphabet.
        </div>
        <button onClick={startAdd} style={bookBtnPrimary}>Add first snapshot</button>
      </Card>
    );
  }

  if (adding) {
    return (
      <div>
        <Card style={{ marginBottom:12 }}>
          <div style={{ display:"flex", flexWrap:"wrap", gap:10, alignItems:"center", justifyContent:"space-between" }}>
            <div>
              <div style={{ fontSize:14, fontWeight:600, color:T.slate800 }}>New Book Snapshot</div>
              <div style={{ fontSize:11, color:T.slate500 }}>
                Pre-filled from {selectedDate || "blank"} · adjust producers or counts as needed
              </div>
            </div>
            <div style={{ display:"flex", gap:8, alignItems:"center" }}>
              <label style={{ fontSize:11, color:T.slate500 }}>Date</label>
              <input type="date" value={newDate} onChange={e => setNewDate(e.target.value)} style={bookInputStyle} />
              <button onClick={cancelAdd} style={bookBtnSecondary} disabled={saving}>Cancel</button>
              <button onClick={saveAdd} style={bookBtnPrimary} disabled={saving || !newDate}>
                {saving ? "Saving…" : "Save snapshot"}
              </button>
            </div>
          </div>
        </Card>
        <BucketEditor buckets={allBuckets} draft={draft} setDraft={setDraft} teamList={teamList} />
        {error && (
          <div style={{ marginTop:10, padding:"8px 12px", background:T.redLt, color:T.red, borderRadius:8, fontSize:12 }}>
            {error}
          </div>
        )}
      </div>
    );
  }

  return (
    <div>
      <Card style={{ marginBottom:12 }}>
        <div style={{ display:"flex", flexWrap:"wrap", gap:10, alignItems:"center", justifyContent:"space-between" }}>
          <div style={{ display:"flex", flexWrap:"wrap", alignItems:"center", gap:10 }}>
            <div style={{ fontSize:14, fontWeight:600, color:T.slate800 }}>Service Book Assignments</div>
            <select
              value={selectedDate || ""}
              onChange={e => setSelectedDate(e.target.value)}
              disabled={editing}
              style={bookInputStyle}
            >
              {allDates.map(d => <option key={d} value={d}>{d}</option>)}
            </select>
            <div style={{ fontSize:11, color:T.slate500 }}>
              {allDates.length} snapshot{allDates.length === 1 ? "" : "s"}{priorDate ? ` · prior: ${priorDate}` : " · no prior snapshot"}
            </div>
          </div>
          <div style={{ display:"flex", gap:8 }}>
            {!editing && <button onClick={startEdit} style={bookBtnSecondary}>Edit this snapshot</button>}
            {!editing && <button onClick={startAdd} style={bookBtnPrimary}>Add new snapshot</button>}
            {editing && <button onClick={cancelEdit} style={bookBtnSecondary} disabled={saving}>Cancel</button>}
            {editing && <button onClick={saveEdit} style={bookBtnPrimary} disabled={saving}>{saving ? "Saving…" : "Save"}</button>}
          </div>
        </div>
      </Card>

      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(200px, 1fr))", gap:10, marginBottom:12 }}>
        {rollup.map((r, i) => {
          const m = memberById(r.team_member_id);
          const priorTotal = (priorRows || [])
            .filter(p => p.team_member_id === r.team_member_id)
            .reduce((s, p) => s + (Number(p.account_count) || 0), 0);
          const delta = priorDate ? r.total - priorTotal : null;
          return (
            <Card key={r.team_member_id || `na-${i}`} style={{ padding:"12px 14px" }}>
              <div style={{ fontSize:11, color:T.slate500 }}>{producerLabel(m)}</div>
              <div style={{ fontSize:22, fontWeight:700, color:T.slate900, lineHeight:1.1, marginTop:2 }}>
                {Number(r.total || 0).toLocaleString()}
              </div>
              <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>
                {r.letters.length} letter{r.letters.length === 1 ? "" : "s"} · {r.letters.join(", ")}
              </div>
              {delta !== null && (
                <div style={{ fontSize:11, color: delta > 0 ? T.green : delta < 0 ? T.red : T.slate500, marginTop:4 }}>
                  {delta > 0 ? "▲" : delta < 0 ? "▼" : "·"} {Math.abs(delta).toLocaleString()} vs {priorDate}
                </div>
              )}
            </Card>
          );
        })}
        <Card style={{ padding:"12px 14px", background:T.slate50 }}>
          <div style={{ fontSize:11, color:T.slate500 }}>Total accounts</div>
          <div style={{ fontSize:22, fontWeight:700, color:T.slate900, lineHeight:1.1, marginTop:2 }}>
            {Number(grandTotal || 0).toLocaleString()}
          </div>
          <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>{currentRows.length} buckets</div>
        </Card>
      </div>

      {editing ? (
        <BucketEditor buckets={allBuckets} draft={draft} setDraft={setDraft} teamList={teamList} />
      ) : (
        <Card>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(140px, 1fr))", gap:8 }}>
            {allBuckets.map(b => {
              const r = findRow(currentRows, b);
              const m = memberById(r?.team_member_id);
              const p = findRow(priorRows, b);
              const delta = priorDate && p ? (Number(r?.account_count) || 0) - (Number(p.account_count) || 0) : null;
              return (
                <div key={b} style={{ border:`1px solid ${T.slate200}`, borderRadius:8, padding:"8px 10px", background:T.white }}>
                  <div style={{ display:"flex", justifyContent:"space-between", alignItems:"baseline" }}>
                    <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>{b}</div>
                    <div style={{ fontSize:15, fontWeight:600, color:T.slate800 }}>
                      {Number(r?.account_count || 0).toLocaleString()}
                    </div>
                  </div>
                  <div style={{ fontSize:10, color: m ? T.slate600 : T.slate400, marginTop:2 }}>
                    {m ? producerLabel(m) : "Unassigned"}
                  </div>
                  {delta !== null && delta !== 0 && (
                    <div style={{ fontSize:9, color: delta > 0 ? T.green : T.red, marginTop:1 }}>
                      {delta > 0 ? "+" : ""}{delta} vs {priorDate}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </Card>
      )}

      {!editing && allDates.length > 0 && (
        <div style={{ marginTop:16, textAlign:"right" }}>
          <button onClick={deleteSnapshot} style={bookBtnDanger} disabled={saving}>Delete this snapshot</button>
        </div>
      )}

      {error && (
        <div style={{ marginTop:10, padding:"8px 12px", background:T.redLt, color:T.red, borderRadius:8, fontSize:12 }}>
          {error}
        </div>
      )}
    </div>
  );
};

// ─── Section: Retention Budget ───────────────────────────────

// ─── Growth Budget Section ───────────────────────────────────
// Per-ramping-teammate breakdown + agency summary + forecasting UI.
// Reads: v_growth_budget_current, v_growth_budget_ytd,
//        get_growth_budget_ceiling RPC, get_growth_budget_forecast RPC.
// See op-rule "New team integration + Growth budget" for canonical mechanics.
// ─── Growth Budget Header ─────────────────────────────────────
// Compressed persistent strip: "Growth Budget · $YTD / $Ceiling · [bar] · % · [▾ Ramping (n)]"
// Ramping expands inline (one line per teammate). Always visible in the Growth tab.

export default function Book() {
  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Book</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            Household alphabet split across the team
          </div>
        </div>
      </div>
      <BookAssignmentsSection />
    </div>
  );
}
