// =========================================================================
// FitScorecards.jsx
// =========================================================================
// Simple Conversation FIT Scorecards — team self-assessment on customer
// conversations, per handbook 04 Win the Week + processes 04 Daily Checklist.
//   - Every active agency team member can create/edit their own entries
//   - Whole-team read (open training loop)
//   - Tenure-tier is stamped at entry time via public.fit_scorecard_tenure_tier()
// Data lives in public.fit_scorecards. Sunday-anchored week navigator
// (agency calendar convention). All dates in America/Chicago.
// =========================================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// ─── constants ───────────────────────────────────────────

const DIMENSIONS = [
  { key: "demeanor_score",         label: "Demeanor" },
  { key: "frogs_score",            label: "FROGS" },
  { key: "intro_score",            label: "Intro" },
  { key: "eligibility_score",      label: "Determine Eligibility" },
  { key: "setup_gnc_score",        label: "Setup GNC" },
  { key: "uncover_gap_score",      label: "Uncover the Gap" },
  { key: "bridge_gap_score",       label: "Bridge the Gap" },
  { key: "customize_close_score",  label: "Customize & Close" },
  { key: "set_followup_score",     label: "Set FU" },
  { key: "review_referral_score",  label: "Review & Referral" },
];

const ENTRY_TYPES = [
  { value: "conversation", label: "Conversation" },
  { value: "quote_review", label: "Quote / Review" },
  { value: "end_of_day",   label: "End of Day" },
];

const TIER_LABELS = {
  weeks_1_8:     "Weeks 1–8",
  weeks_9_13:    "Weeks 9–13",
  weeks_14_plus: "Weeks 14+",
};

// Cadence per handbook "Your Path" §Scorecarding Cadence. Not user-editable.
// Also enforced server-side by tg_fit_scorecards_enforce_entry_type trigger.
const ENTRY_TYPE_BY_TIER = {
  weeks_1_8:     "conversation",
  weeks_9_13:    "quote_review",
  weeks_14_plus: "end_of_day",
};

// ─── date helpers (America/Chicago, Sunday-anchored week) ─────────

function todayInCT() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Chicago",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date());
  const y = parts.find((p) => p.type === "year").value;
  const m = parts.find((p) => p.type === "month").value;
  const d = parts.find((p) => p.type === "day").value;
  return `${y}-${m}-${d}`;
}

function ymdToDate(ymd) {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}

function dateToYMD(d) {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function weekBoundsSundayToSaturday(ymd) {
  const d = ymdToDate(ymd);
  const dow = d.getUTCDay(); // 0=Sun
  const sun = new Date(d);
  sun.setUTCDate(d.getUTCDate() - dow);
  const sat = new Date(sun);
  sat.setUTCDate(sun.getUTCDate() + 6);
  return { start: dateToYMD(sun), end: dateToYMD(sat) };
}

function shiftWeek(ymd, deltaWeeks) {
  const d = ymdToDate(ymd);
  d.setUTCDate(d.getUTCDate() + 7 * deltaWeeks);
  return dateToYMD(d);
}

function prettyRange(startYMD, endYMD) {
  const opts = { timeZone: "UTC", month: "short", day: "numeric" };
  const s = ymdToDate(startYMD).toLocaleDateString("en-US", opts);
  const e = ymdToDate(endYMD).toLocaleDateString("en-US", opts);
  return `${s} – ${e}`;
}

// ─── tiny UI primitives (match Renewals.jsx style) ────────────

function Button({ children, variant = "primary", onClick, disabled, size = "md", type = "button" }) {
  const sizes = {
    sm: { padding: "6px 10px", fontSize: "0.85rem" },
    md: { padding: "8px 14px", fontSize: "0.95rem" },
  };
  const variants = {
    primary: { background: T.blue, color: "#fff", border: `1px solid ${T.blue}` },
    ghost:   { background: "transparent", color: T.slate900, border: `1px solid ${T.slate200}` },
    danger:  { background: "#c0392b", color: "#fff", border: "1px solid #c0392b" },
  };
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled}
      style={{
        ...sizes[size], ...variants[variant],
        borderRadius: 6, cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.55 : 1, fontWeight: 500,
      }}
    >
      {children}
    </button>
  );
}

function Card({ children, style }) {
  return (
    <div style={{
      background: T.white, border: `1px solid ${T.slate200}`,
      borderRadius: 8, padding: 16, ...(style || {}),
    }}>
      {children}
    </div>
  );
}

function Badge({ children, tone = "neutral" }) {
  const tones = {
    neutral:  { bg: "#eef1f5", fg: "#404b5a" },
    positive: { bg: "#e6f4ea", fg: "#1e6b3a" },
    warn:     { bg: "#fff4d6", fg: "#8a6100" },
    info:     { bg: "#e3edf9", fg: "#1e4a86" },
  };
  const c = tones[tone] || tones.neutral;
  return (
    <span style={{
      background: c.bg, color: c.fg, padding: "2px 8px",
      borderRadius: 999, fontSize: "0.78rem", fontWeight: 600,
      whiteSpace: "nowrap",
    }}>
      {children}
    </span>
  );
}

// ─── the module ────────────────────────────────────────────

export default function FitScorecards({ userRole, userId }) {
  const isAdmin = ["owner", "manager"].includes(userRole);

  const [team, setTeam]         = useState([]);
  const [selfTeamId, setSelf]   = useState(null);
  const [filterMember, setFM]   = useState("all"); // "all" | team.id
  const [weekAnchor, setWA]     = useState(todayInCT());
  const [entries, setEntries]   = useState([]);
  const [loading, setLoading]   = useState(true);
  const [err, setErr]           = useState(null);
  const [modal, setModal]       = useState(null); // null | {mode:"create"|"edit", row?}

  const { start: weekStart, end: weekEnd } = useMemo(
    () => weekBoundsSundayToSaturday(weekAnchor),
    [weekAnchor]
  );

  // ─── load team roster (agency, non-admin-backoffice, active) ───
  useEffect(() => {
    (async () => {
      const { data, error } = await supabase
        .from("team")
        .select("id, first_name, last_name, nickname, user_id, hire_date, start_date, category, is_admin_backoffice, is_active, archived_at, role, role_category")
        .eq("agency_id", AGENCY_ID)
        .eq("category", "agency")
        .eq("is_active", true)
        .eq("is_admin_backoffice", false)
        .is("archived_at", null)
        .order("first_name");
      if (error) { setErr(error.message); return; }
      setTeam(data || []);
      const me = (data || []).find((r) => r.user_id === userId);
      if (me) {
        setSelf(me.id);
        setFM(me.id);
      }
    })();
  }, [userId]);

  // ─── load entries for the visible week ───
  const loadEntries = useCallback(async () => {
    setLoading(true); setErr(null);
    let q = supabase
      .from("fit_scorecards")
      .select("*")
      .eq("agency_id", AGENCY_ID)
      .gte("scorecard_date", weekStart)
      .lte("scorecard_date", weekEnd)
      .order("scorecard_date", { ascending: false })
      .order("created_at",     { ascending: false });
    if (filterMember !== "all") q = q.eq("team_member_id", filterMember);
    const { data, error } = await q;
    if (error) { setErr(error.message); setLoading(false); return; }
    setEntries(data || []);
    setLoading(false);
  }, [weekStart, weekEnd, filterMember]);

  useEffect(() => { loadEntries(); }, [loadEntries]);

  // ─── per-dimension weekly averages (rollup grid) ───
  const rollup = useMemo(() => {
    const bucket = {};
    for (const dim of DIMENSIONS) bucket[dim.key] = { sum: 0, count: 0 };
    for (const row of entries) {
      for (const dim of DIMENSIONS) {
        const v = row[dim.key];
        if (v !== null && v !== undefined) {
          bucket[dim.key].sum += v;
          bucket[dim.key].count += 1;
        }
      }
    }
    return bucket;
  }, [entries]);

  const teamById = useMemo(() => {
    const m = {};
    for (const p of team) m[p.id] = p;
    return m;
  }, [team]);

  function displayName(p) {
    if (!p) return "—";
    if (p.nickname) return p.nickname;
    return `${p.first_name || ""} ${p.last_name || ""}`.trim() || "—";
  }

  function toneForScore(v) {
    if (v == null) return "neutral";
    if (v >= 2.5) return "positive";
    if (v >= 1.75) return "info";
    return "warn";
  }

  async function handleDelete(row) {
    if (!confirm("Delete this entry?")) return;
    const { error } = await supabase.from("fit_scorecards").delete().eq("id", row.id);
    if (error) { alert(error.message); return; }
    loadEntries();
  }

  return (
    <div style={{ padding: 16, color: T.slate900 }}>
      <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 12, marginBottom: 12 }}>
        <h2 style={{ margin: 0, fontSize: "1.3rem" }}>Simple Conversation FIT Scorecards</h2>
        <div style={{ marginLeft: "auto", display: "flex", gap: 8, flexWrap: "wrap" }}>
          <Button variant="ghost" size="sm" onClick={() => setWA(shiftWeek(weekAnchor, -1))}>← Prev</Button>
          <Badge tone="info">{prettyRange(weekStart, weekEnd)}</Badge>
          <Button variant="ghost" size="sm" onClick={() => setWA(shiftWeek(weekAnchor,  1))}>Next →</Button>
          <Button variant="ghost" size="sm" onClick={() => setWA(todayInCT())}>This Week</Button>
        </div>
      </div>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 12 }}>
        <label style={{ fontSize: "0.9rem" }}>
          View:{" "}
          <select
            value={filterMember}
            onChange={(e) => setFM(e.target.value)}
            style={{ padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 }}
          >
            <option value="all">Whole team</option>
            {team.map((p) => (
              <option key={p.id} value={p.id}>{displayName(p)}{p.id === selfTeamId ? " (me)" : ""}</option>
            ))}
          </select>
        </label>
        {selfTeamId && (
          <Button onClick={() => setModal({ mode: "create" })}>+ New scorecard</Button>
        )}
      </div>

      {err && (
        <Card style={{ borderColor: "#c0392b", background: "#fdecea", color: "#8a1c1c", marginBottom: 12 }}>
          {err}
        </Card>
      )}

      {/* per-dimension weekly rollup */}
      <Card style={{ marginBottom: 16 }}>
        <div style={{ fontWeight: 600, marginBottom: 8 }}>
          Weekly averages {filterMember === "all" ? "(whole team)" : `— ${displayName(teamById[filterMember])}`}
        </div>
        <div style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))",
          gap: 8,
        }}>
          {DIMENSIONS.map((dim) => {
            const b = rollup[dim.key];
            const avg = b.count ? b.sum / b.count : null;
            return (
              <div key={dim.key} style={{
                border: `1px solid ${T.slate200}`, borderRadius: 6, padding: "8px 10px",
              }}>
                <div style={{ fontSize: "0.78rem", color: T.slate500 }}>{dim.label}</div>
                <div style={{ display: "flex", alignItems: "baseline", gap: 6 }}>
                  <span style={{ fontSize: "1.15rem", fontWeight: 700 }}>
                    {avg === null ? "—" : avg.toFixed(2)}
                  </span>
                  <span style={{ fontSize: "0.75rem", color: T.slate500 }}>
                    n={b.count}
                  </span>
                </div>
                {avg !== null && (
                  <div style={{ marginTop: 4 }}><Badge tone={toneForScore(avg)}>{avg.toFixed(2)}</Badge></div>
                )}
              </div>
            );
          })}
        </div>
      </Card>

      {/* entry list */}
      <Card>
        <div style={{ fontWeight: 600, marginBottom: 8 }}>
          Entries this week {loading ? "…" : `(${entries.length})`}
        </div>
        {!loading && entries.length === 0 && (
          <div style={{ color: T.slate500, fontSize: "0.9rem" }}>
            No entries yet for this week.
          </div>
        )}
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {entries.map((row) => {
            const p = teamById[row.team_member_id];
            const canEdit = isAdmin || row.team_member_id === selfTeamId;
            return (
              <div key={row.id} style={{
                border: `1px solid ${T.slate200}`, borderRadius: 6, padding: 10,
                display: "flex", flexDirection: "column", gap: 6,
              }}>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
                  <strong>{displayName(p)}</strong>
                  <Badge tone="neutral">{row.scorecard_date}</Badge>
                  <Badge tone="info">
                    {ENTRY_TYPES.find((e) => e.value === row.entry_type)?.label || row.entry_type}
                  </Badge>
                  <Badge tone="neutral">{TIER_LABELS[row.tenure_tier_at_entry] || row.tenure_tier_at_entry}</Badge>
                  {row.customer_first_name && <Badge tone="neutral">Cust: {row.customer_first_name}</Badge>}
                  {row.recording_turned_in && <Badge tone="positive">🎙 recording</Badge>}
                  {row.average_score != null && (
                    <Badge tone={toneForScore(Number(row.average_score))}>
                      avg {Number(row.average_score).toFixed(2)}
                    </Badge>
                  )}
                  {canEdit && (
                    <span style={{ marginLeft: "auto", display: "flex", gap: 6 }}>
                      <Button variant="ghost" size="sm" onClick={() => setModal({ mode: "edit", row })}>Edit</Button>
                      <Button variant="danger" size="sm" onClick={() => handleDelete(row)}>Delete</Button>
                    </span>
                  )}
                </div>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
                  {DIMENSIONS.map((dim) => {
                    const v = row[dim.key];
                    return (
                      <span key={dim.key} style={{
                        fontSize: "0.78rem", padding: "2px 6px",
                        border: `1px solid ${T.slate200}`, borderRadius: 4,
                        color: v == null ? (T.slate500) : T.slate900,
                      }}>
                        {dim.label}: {v == null ? "—" : v}
                      </span>
                    );
                  })}
                </div>
                {row.notes && (
                  <div style={{ fontSize: "0.85rem", color: T.slate500 }}>
                    {row.notes}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </Card>

      {modal && (
        <EntryModal
          mode={modal.mode}
          row={modal.row}
          team={team}
          selfTeamId={selfTeamId}
          isAdmin={isAdmin}
          userId={userId}
          onClose={() => setModal(null)}
          onSaved={() => { setModal(null); loadEntries(); }}
        />
      )}
    </div>
  );
}

// ─── ScorePicker ────────────────────────────────────────

function ScorePicker({ value, onChange }) {
  return (
    <div style={{ display: "flex", gap: 4 }}>
      {[null, 1, 2, 3].map((v) => {
        const active = value === v;
        const label = v === null ? "N/A" : String(v);
        return (
          <button
            key={label}
            type="button"
            onClick={() => onChange(v)}
            style={{
              padding: "4px 10px",
              borderRadius: 4,
              border: `1px solid ${active ? T.blue : T.slate200}`,
              background: active ? T.blue : "transparent",
              color: active ? "#fff" : T.slate900,
              fontWeight: active ? 600 : 400,
              cursor: "pointer",
              fontSize: "0.85rem",
            }}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}

// ─── Modal form ─────────────────────────────────────────

function EntryModal({ mode, row, team, selfTeamId, isAdmin, userId, onClose, onSaved }) {
  const isEdit = mode === "edit";
  const initialMember = isEdit ? row.team_member_id : selfTeamId;

  const [teamMemberId, setTMI]   = useState(initialMember || "");
  const [date,       setDate]    = useState(isEdit ? row.scorecard_date : todayInCT());
  const [tenureTier, setTenureTier] = useState(isEdit ? row.tenure_tier_at_entry : null);
  const entryType = tenureTier ? ENTRY_TYPE_BY_TIER[tenureTier] : null;
  const [custName,   setCust]    = useState(isEdit ? (row.customer_first_name || "") : "");
  const [oppRef,     setOpp]     = useState(isEdit ? (row.opportunity_ref || "") : "");
  const [recTurned,  setRec]     = useState(isEdit ? row.recording_turned_in : false);
  const [recUrl,     setRecUrl]  = useState(isEdit ? (row.recording_url || "") : "");
  const [scores,     setScores]  = useState(() => {
    const s = {};
    for (const dim of DIMENSIONS) s[dim.key] = isEdit ? row[dim.key] : null;
    return s;
  });
  const [notes,      setNotes]   = useState(isEdit ? (row.notes || "") : "");
  const [saving,     setSaving]  = useState(false);
  const [err,        setErr]     = useState(null);

  // Auto-resolve tenure tier (and therefore entry_type) whenever team member or date changes.
  // Entry type is not user-selectable — cadence is dictated by tenure per handbook "Your Path".
  useEffect(() => {
    if (!teamMemberId || !date) { setTenureTier(null); return; }
    let cancelled = false;
    (async () => {
      const { data, error } = await supabase
        .rpc("fit_scorecard_tenure_tier", { p_team_id: teamMemberId, p_as_of: date });
      if (!cancelled && !error) setTenureTier(data || "weeks_14_plus");
    })();
    return () => { cancelled = true; };
  }, [teamMemberId, date]);

  async function handleSave() {
    if (!teamMemberId) { setErr("Pick a team member."); return; }
    if (!tenureTier)   { setErr("Tenure tier still resolving — try again."); return; }
    setSaving(true); setErr(null);

    const payload = {
      agency_id:            AGENCY_ID,
      team_member_id:       teamMemberId,
      created_by_user_id:   userId || null,
      scorecard_date:       date,
      entry_type:           entryType,
      tenure_tier_at_entry: tenureTier,
      customer_first_name:  custName || null,
      opportunity_ref:      oppRef  || null,
      recording_turned_in:  !!recTurned,
      recording_url:        recTurned ? (recUrl || null) : null,
      notes:                notes || null,
      ...scores,
    };

    let error;
    if (isEdit) {
      ({ error } = await supabase.from("fit_scorecards").update(payload).eq("id", row.id));
    } else {
      ({ error } = await supabase.from("fit_scorecards").insert(payload));
    }
    setSaving(false);
    if (error) { setErr(error.message); return; }
    onSaved();
  }

  const canPickMember = isAdmin || !isEdit; // creators can only pick self implicitly; admins can override
  const memberOptions = isAdmin
    ? team
    : team.filter((p) => p.id === selfTeamId);

  return (
    <div style={{
      position: "fixed", inset: 0, background: "rgba(0,0,0,0.5)",
      display: "flex", alignItems: "center", justifyContent: "center",
      zIndex: 1000, padding: 16,
    }}>
      <div style={{
        background: T.white, borderRadius: 8, padding: 16,
        maxWidth: 640, width: "100%", maxHeight: "90vh", overflowY: "auto",
        border: `1px solid ${T.slate200}`, color: T.slate900,
        boxShadow: "0 20px 60px rgba(0,0,0,0.3)",
      }}>
        <div style={{ display: "flex", alignItems: "center", marginBottom: 12 }}>
          <h3 style={{ margin: 0, fontSize: "1.1rem" }}>
            {isEdit ? "Edit scorecard entry" : "New scorecard entry"}
          </h3>
          <span style={{ marginLeft: "auto" }}>
            <Button variant="ghost" size="sm" onClick={onClose}>Close</Button>
          </span>
        </div>

        {err && (
          <div style={{
            background: "#fdecea", color: "#8a1c1c",
            border: "1px solid #c0392b", borderRadius: 6,
            padding: "6px 10px", marginBottom: 10, fontSize: "0.85rem",
          }}>{err}</div>
        )}

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 10, marginBottom: 12 }}>
          <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: "0.85rem" }}>
            Team member
            <select
              value={teamMemberId}
              onChange={(e) => setTMI(e.target.value)}
              disabled={!canPickMember && memberOptions.length <= 1}
              style={{ padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 }}
            >
              {memberOptions.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nickname || `${p.first_name || ""} ${p.last_name || ""}`.trim()}
                </option>
              ))}
            </select>
          </label>

          <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: "0.85rem" }}>
            Date
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
              style={{ padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 }} />
          </label>

          <div style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: "0.85rem" }}>
            <span>Entry type</span>
            <div style={{
              padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6,
              background: T.slate50 || "#f8fafc", color: T.slate900,
              display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8,
              minHeight: 32,
            }}>
              <span style={{ fontWeight: 500 }}>
                {entryType ? (ENTRY_TYPES.find((e) => e.value === entryType)?.label || entryType) : "—"}
              </span>
              <span style={{ fontSize: "0.72rem", color: T.slate500 || "#64748b" }}>
                {tenureTier ? `Auto · ${TIER_LABELS[tenureTier]}` : "resolving…"}
              </span>
            </div>
          </div>

          <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: "0.85rem" }}>
            Customer first name (optional)
            <input value={custName} onChange={(e) => setCust(e.target.value)}
              style={{ padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 }} />
          </label>
        </div>

        <div style={{ marginBottom: 12 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: "0.85rem" }}>
            <input type="checkbox" checked={recTurned} onChange={(e) => setRec(e.target.checked)} />
            Recording turned in
          </label>
          {recTurned && (
            <input value={recUrl} onChange={(e) => setRecUrl(e.target.value)}
              placeholder="Recording URL (optional)"
              style={{ marginTop: 6, width: "100%", padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 }} />
          )}
        </div>

        <div style={{ border: `1px solid ${T.slate200}`, borderRadius: 6, padding: 10, marginBottom: 12 }}>
          <div style={{ fontWeight: 600, marginBottom: 6, fontSize: "0.9rem" }}>Scores (1–3, or N/A)</div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 8 }}>
            {DIMENSIONS.map((dim) => (
              <div key={dim.key} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
                <span style={{ fontSize: "0.85rem" }}>{dim.label}</span>
                <ScorePicker value={scores[dim.key]} onChange={(v) => setScores((s) => ({ ...s, [dim.key]: v }))} />
              </div>
            ))}
          </div>
        </div>

        <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: "0.85rem", marginBottom: 12 }}>
          Notes (optional)
          <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={3}
            style={{ padding: "6px 10px", border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900, resize: "vertical" }} />
        </label>

        <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
          <Button variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving ? "Saving…" : (isEdit ? "Save changes" : "Save scorecard")}
          </Button>
        </div>
      </div>
    </div>
  );
}
