import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useState, useEffect, useMemo, useCallback } from "react";
import { T } from "../lib/theme.js";

// =====================================================================
// TimeClockEditRequests.jsx — request + approval flow for time-clock edits
//
// Two exports:
//   <StaffRequestSection /> — shown at the bottom of the Kiosk view for
//     hourly staff. Lets them submit missed-shift / missed-clock-out /
//     wrong-time requests, and view their own pending + resolved requests.
//   <AdminApprovalQueue />  — shown at the top of the Admin view for
//     owner/manager. Lists all pending requests and calls the approve /
//     deny RPCs.
//
// Backing schema:
//   public.time_clock_edit_requests (see migration time_clock_edit_requests_schema)
//   RPCs: approve_time_clock_edit, deny_time_clock_edit, cancel_time_clock_edit
//
// Current-week enforcement lives in a BEFORE INSERT trigger, so client
// need not duplicate the check — the DB will 400 if a stale date sneaks in.
// =====================================================================

const EDIT_TYPE_LABELS = {
  missed_clock_in:  "Missed clock-in",
  missed_clock_out: "Missed clock-out",
  wrong_time:       "Wrong time",
  missed_shift:     "Missed shift",
};

// ---------------------------------------------------------------------
// Small helpers (duplicated from TimeClock — keeps this file standalone)
// ---------------------------------------------------------------------
function fmtDate(d) {
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}
function fmtDateLong(d) {
  return d.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
}
function fmtTime(iso) {
  if (!iso) return "--";
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
function fmtHM(h) {
  if (!Number.isFinite(h)) return "0.00";
  return h.toFixed(2);
}
function hoursBetween(a, b) {
  if (!a || !b) return 0;
  return (new Date(b) - new Date(a)) / 3_600_000;
}
function toLocalInput(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fromLocalInput(v) {
  if (!v) return null;
  return new Date(v).toISOString();
}
function toDateInput(d) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
function startOfSundayWeek(date) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - d.getDay());
  return d;
}
function addDays(date, days) {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d;
}

// ---------------------------------------------------------------------
// Local primitives
// ---------------------------------------------------------------------
function Card({ children, style = {} }) {
  return (
    <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: "16px 18px", ...style }}>
      {children}
    </div>
  );
}
function Button({ children, onClick, variant = "secondary", disabled = false, type = "button", style = {} }) {
  const variants = {
    primary:   { bg: T.blue,     color: T.white,    border: T.blue },
    secondary: { bg: T.white,    color: T.slate700, border: T.slate200 },
    ghost:     { bg: "transparent", color: T.blue,  border: "transparent" },
    danger:    { bg: T.white,    color: T.red,      border: T.slate200 },
    dark:      { bg: T.slate900, color: T.white,    border: T.slate900 },
    success:   { bg: T.green,    color: T.white,    border: T.green },
  };
  const v = variants[variant] || variants.secondary;
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled}
      style={{
        padding: "7px 13px", borderRadius: 7,
        border: `1px solid ${v.border}`, background: v.bg, color: v.color,
        fontSize: 12, fontWeight: 600,
        cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.45 : 1, whiteSpace: "nowrap",
        ...style,
      }}
    >
      {children}
    </button>
  );
}
function Pill({ children, bg = T.slate100, color = T.slate700, style = {} }) {
  return (
    <span style={{
      display: "inline-flex", alignItems: "center",
      padding: "3px 8px", borderRadius: 20,
      fontSize: 10, fontWeight: 600,
      background: bg, color, whiteSpace: "nowrap", ...style,
    }}>{children}</span>
  );
}
function TextInput({ value, onChange, type = "text", placeholder, style = {} }) {
  return (
    <input
      type={type}
      value={value}
      onChange={onChange}
      placeholder={placeholder}
      style={{
        width: "100%", padding: "8px 10px",
        borderRadius: 7, border: `1px solid ${T.slate200}`,
        background: T.white, fontSize: 13, color: T.slate900,
        outline: "none", ...style,
      }}
    />
  );
}
function TextArea({ value, onChange, placeholder, rows = 3, style = {} }) {
  return (
    <textarea
      value={value}
      onChange={onChange}
      placeholder={placeholder}
      rows={rows}
      style={{
        width: "100%", padding: "8px 10px",
        borderRadius: 7, border: `1px solid ${T.slate200}`,
        background: T.white, fontSize: 13, color: T.slate900,
        outline: "none", resize: "vertical", fontFamily: "inherit",
        ...style,
      }}
    />
  );
}
function ModalShell({ children, onClose, width = 500 }) {
  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed", inset: 0, background: "rgba(15,23,42,0.45)",
        display: "flex", alignItems: "center", justifyContent: "center",
        zIndex: 9999, padding: 16,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: T.white, borderRadius: 12, width: "100%", maxWidth: width,
          maxHeight: "92vh", overflowY: "auto",
          boxShadow: "0 20px 50px rgba(15,23,42,0.25)",
        }}
      >
        {children}
      </div>
    </div>
  );
}

// =====================================================================
// STAFF SECTION
// =====================================================================
export function StaffRequestSection({ user, entries, weekStart, onChange }) {
  const [pending, setPending]   = useState([]);
  const [resolved, setResolved] = useState([]);
  const [showForm, setShowForm] = useState(null); // null | {entry} | {missed:true}
  const [loaded, setLoaded]     = useState(false);

  const memberId = user?.team_member_id || null;

  const reload = useCallback(async () => {
    if (!memberId) { setLoaded(true); return; }
    const { data: p } = await supabase
      .from("time_clock_edit_requests")
      .select("id, punch_date, edit_type, target_entry_id, requested_clock_in_at, requested_clock_out_at, reason, status, submitted_at, reviewed_at, review_note")
      .eq("team_member_id", memberId)
      .eq("status", "pending")
      .order("submitted_at", { ascending: false });
    setPending(p || []);
    const { data: r } = await supabase
      .from("time_clock_edit_requests")
      .select("id, punch_date, edit_type, requested_clock_in_at, requested_clock_out_at, reason, status, reviewed_at, review_note")
      .eq("team_member_id", memberId)
      .neq("status", "pending")
      .order("reviewed_at", { ascending: false })
      .limit(5);
    setResolved(r || []);
    setLoaded(true);
  }, [memberId]);

  useEffect(() => { reload(); }, [reload]);

  // My entries this week only (defensive)
  const myEntries = useMemo(() => {
    return (entries || []).filter((e) => e?.team_member_id === memberId);
  }, [entries, memberId]);

  async function cancelReq(id) {
    if (!window.confirm("Cancel this edit request?")) return;
    const { error } = await supabase.rpc("cancel_time_clock_edit", { p_request_id: id });
    if (error) {
      window.alert("Could not cancel: " + error.message);
      return;
    }
    reload();
  }

  // Staff members without a linked team_member_id can't request edits
  if (!memberId) return null;

  return (
    <div style={{ marginTop: 20 }}>
      <Card>
        <div style={{
          display: "flex", justifyContent: "space-between", alignItems: "center",
          flexWrap: "wrap", gap: 10, marginBottom: 12
        }}>
          <div>
            <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
              Missed a punch? Request a fix.
            </div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
              Current week only. Peter reviews and approves.
            </div>
          </div>
          <Button variant="dark" onClick={() => setShowForm({ missed: true })}>
            + Missed shift
          </Button>
        </div>

        {loaded && myEntries.length === 0 && pending.length === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, padding: "10px 0" }}>
            No punches this week yet. If you worked a shift that's not showing, use "+ Missed shift".
          </div>
        )}

        {myEntries.length > 0 && (
          <div>
            <div style={{ fontSize: 10, fontWeight: 700, color: T.slate500, marginBottom: 8, textTransform: "uppercase", letterSpacing: 0.5 }}>
              This week's punches
            </div>
            {myEntries.map((e) => {
              const hasPending = pending.some((p) => p.target_entry_id === e.id);
              const hrs = e.clock_out_at ? hoursBetween(e.clock_in_at, e.clock_out_at) : null;
              return (
                <div key={e.id} style={{
                  display: "flex", justifyContent: "space-between", alignItems: "center",
                  flexWrap: "wrap", gap: 8,
                  padding: "10px 0", borderTop: `1px solid ${T.slate100}`
                }}>
                  <div style={{ fontSize: 12, color: T.slate700, minWidth: 180 }}>
                    <div style={{ fontWeight: 600 }}>
                      {fmtDateLong(new Date(e.clock_in_at))}
                    </div>
                    <div style={{ color: T.slate500, marginTop: 2 }}>
                      {fmtTime(e.clock_in_at)} &ndash; {e.clock_out_at ? fmtTime(e.clock_out_at) : <span style={{ color: T.green, fontWeight: 600 }}>still open</span>}
                      {hrs !== null && ` · ${fmtHM(hrs)} hrs`}
                    </div>
                  </div>
                  {hasPending ? (
                    <Pill bg={T.amberLt} color={T.amber}>Edit pending</Pill>
                  ) : (
                    <Button onClick={() => setShowForm({ entry: e })}>Request edit</Button>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {pending.length > 0 && (
          <div style={{ marginTop: 16, paddingTop: 12, borderTop: `1px solid ${T.slate200}` }}>
            <div style={{ fontSize: 10, fontWeight: 700, color: T.amber, marginBottom: 8, textTransform: "uppercase", letterSpacing: 0.5 }}>
              Your pending requests ({pending.length})
            </div>
            {pending.map((r) => (
              <PendingRow key={r.id} req={r} onCancel={() => cancelReq(r.id)} />
            ))}
          </div>
        )}

        {resolved.length > 0 && (
          <div style={{ marginTop: 12 }}>
            <details>
              <summary style={{ fontSize: 11, color: T.slate500, cursor: "pointer" }}>
                Recent resolved ({resolved.length})
              </summary>
              <div style={{ marginTop: 8 }}>
                {resolved.map((r) => (
                  <ResolvedRow key={r.id} req={r} />
                ))}
              </div>
            </details>
          </div>
        )}
      </Card>

      {showForm && (
        <RequestFormModal
          user={user}
          initial={showForm}
          weekStart={weekStart || startOfSundayWeek(new Date())}
          onClose={() => setShowForm(null)}
          onSubmitted={() => { setShowForm(null); reload(); onChange?.(); }}
        />
      )}
    </div>
  );
}

function PendingRow({ req, onCancel }) {
  return (
    <div style={{
      display: "flex", justifyContent: "space-between", alignItems: "center",
      flexWrap: "wrap", gap: 8, padding: "8px 0", borderTop: `1px solid ${T.slate100}`
    }}>
      <div style={{ fontSize: 12, color: T.slate700, minWidth: 200 }}>
        <div style={{ fontWeight: 600 }}>
          {EDIT_TYPE_LABELS[req.edit_type] || req.edit_type} · {fmtDate(new Date(req.punch_date + "T00:00:00"))}
        </div>
        <div style={{ color: T.slate500, marginTop: 2 }}>
          {req.requested_clock_in_at && <>In: {fmtTime(req.requested_clock_in_at)} </>}
          {req.requested_clock_out_at && <>· Out: {fmtTime(req.requested_clock_out_at)}</>}
        </div>
        {req.reason && (
          <div style={{ color: T.slate500, marginTop: 2, fontStyle: "italic" }}>
            "{req.reason}"
          </div>
        )}
      </div>
      <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
        <Pill bg={T.amberLt} color={T.amber}>Pending</Pill>
        <Button variant="ghost" onClick={onCancel}>Cancel</Button>
      </div>
    </div>
  );
}

function ResolvedRow({ req }) {
  const isApproved  = req.status === "approved";
  const isDenied    = req.status === "denied";
  const isCancelled = req.status === "cancelled";
  const pillBg    = isApproved ? T.greenLt : isDenied ? T.redLt : T.slate100;
  const pillColor = isApproved ? T.green   : isDenied ? T.red   : T.slate600;
  const label     = isApproved ? "Approved" : isDenied ? "Denied" : "Cancelled";
  return (
    <div style={{
      display: "flex", justifyContent: "space-between", alignItems: "center",
      flexWrap: "wrap", gap: 8, padding: "6px 0", borderTop: `1px solid ${T.slate100}`
    }}>
      <div style={{ fontSize: 11, color: T.slate600 }}>
        <div style={{ fontWeight: 600 }}>
          {EDIT_TYPE_LABELS[req.edit_type] || req.edit_type} · {fmtDate(new Date(req.punch_date + "T00:00:00"))}
        </div>
        {req.review_note && (
          <div style={{ color: T.slate500, marginTop: 2, fontStyle: "italic" }}>
            Peter: "{req.review_note}"
          </div>
        )}
      </div>
      <Pill bg={pillBg} color={pillColor}>{label}</Pill>
    </div>
  );
}

// =====================================================================
// REQUEST FORM MODAL
// =====================================================================
function RequestFormModal({ user, initial, weekStart, onClose, onSubmitted }) {
  // initial = { entry } for editing an existing punch, or { missed: true } for missed shift
  const isMissedShift = !!initial?.missed;
  const existingEntry = initial?.entry || null;
  const openEntry     = existingEntry && !existingEntry.clock_out_at;

  // Determine default edit_type
  const defaultType = isMissedShift
    ? "missed_shift"
    : openEntry
      ? "missed_clock_out"
      : "wrong_time";

  const [editType, setEditType] = useState(defaultType);

  // Date defaults
  const initialDate = existingEntry
    ? new Date(existingEntry.clock_in_at)
    : new Date();
  const [punchDate, setPunchDate] = useState(toDateInput(initialDate));

  // Time defaults (datetime-local strings)
  const [clockIn, setClockIn]   = useState(existingEntry ? toLocalInput(existingEntry.clock_in_at) : "");
  const [clockOut, setClockOut] = useState(existingEntry?.clock_out_at ? toLocalInput(existingEntry.clock_out_at) : "");
  const [reason, setReason]     = useState("");
  const [busy, setBusy]         = useState(false);
  const [error, setError]       = useState("");

  // For a missed shift, if user changes the date, seed times to that date at typical work hours
  useEffect(() => {
    if (!isMissedShift) return;
    if (clockIn) return;
    // No-op — leave blank; user fills in
  }, [punchDate, isMissedShift, clockIn]);

  // Current week bounds — for the punch_date <input> constraint
  const weekBounds = useMemo(() => {
    const ws = weekStart || startOfSundayWeek(new Date());
    const we = addDays(ws, 6);
    return { min: toDateInput(ws), max: toDateInput(we) };
  }, [weekStart]);

  async function submit() {
    setError("");
    if (!user?.team_member_id) { setError("Your account isn't linked to a team row."); return; }
    if (!reason || reason.trim().length < 3) { setError("Please add a short reason (3+ characters)."); return; }

    // Validate times per edit type
    const inIso  = fromLocalInput(clockIn);
    const outIso = fromLocalInput(clockOut);

    if (editType === "missed_shift") {
      if (!inIso) { setError("Clock-in time required."); return; }
      if (outIso && new Date(outIso) <= new Date(inIso)) {
        setError("Clock-out must be after clock-in."); return;
      }
    } else if (editType === "missed_clock_out") {
      if (!outIso) { setError("Clock-out time required."); return; }
      if (existingEntry && new Date(outIso) <= new Date(existingEntry.clock_in_at)) {
        setError("Clock-out must be after the original clock-in."); return;
      }
    } else if (editType === "wrong_time") {
      if (!inIso && !outIso) { setError("Enter at least one corrected time."); return; }
      if (inIso && outIso && new Date(outIso) <= new Date(inIso)) {
        setError("Clock-out must be after clock-in."); return;
      }
    }

    setBusy(true);
    const payload = {
      agency_id: AGENCY_ID,
      team_member_id: user.team_member_id,
      punch_date: punchDate,
      edit_type: editType,
      target_entry_id: existingEntry?.id || null,
      requested_clock_in_at: inIso,
      requested_clock_out_at: outIso,
      reason: reason.trim(),
      status: "pending",
    };
    const { error: insErr } = await supabase.from("time_clock_edit_requests").insert(payload);
    setBusy(false);
    if (insErr) {
      // Surface the DB message — includes the current-week-window error text if that's the cause
      setError(insErr.message || "Could not submit request.");
      return;
    }
    onSubmitted();
  }

  const title = isMissedShift
    ? "Request: missed shift"
    : "Request: edit this punch";

  return (
    <ModalShell onClose={busy ? () => {} : onClose}>
      <div style={{ padding: "16px 20px", borderBottom: `1px solid ${T.slate200}` }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{title}</div>
        <div style={{ fontSize: 11, color: T.slate500, marginTop: 3 }}>
          This week only ({weekBounds.min} through {weekBounds.max}). Peter reviews.
        </div>
      </div>

      <div style={{ padding: "16px 20px", display: "flex", flexDirection: "column", gap: 12 }}>
        {/* Type picker — shown for any edit of an existing entry (open or closed) */}
        {!isMissedShift && (
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 6 }}>What's wrong?</div>
            <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
              <Button
                variant={editType === "wrong_time" ? "dark" : "secondary"}
                onClick={() => setEditType("wrong_time")}
              >{openEntry ? "Wrong clock-in time" : "Wrong time(s)"}</Button>
              {!openEntry && (
                <Button
                  variant={editType === "missed_clock_out" ? "dark" : "secondary"}
                  onClick={() => setEditType("missed_clock_out")}
                >Missed clock-out</Button>
              )}
              {openEntry && (
                <Button
                  variant={editType === "missed_clock_out" ? "dark" : "secondary"}
                  onClick={() => setEditType("missed_clock_out")}
                >Add clock-out</Button>
              )}
            </div>
          </div>
        )}

        {/* Date */}
        <div>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>Date</div>
          <TextInput
            type="date"
            value={punchDate}
            onChange={(e) => setPunchDate(e.target.value)}
            style={{ maxWidth: 200 }}
          />
        </div>

        {/* Clock in — needed for missed_shift and wrong_time */}
        {(editType === "missed_shift" || editType === "wrong_time") && (
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>
              Clock in {editType === "wrong_time" && <span style={{ color: T.slate400, fontWeight: 400 }}>(leave blank to keep original)</span>}
            </div>
            <TextInput type="datetime-local" value={clockIn} onChange={(e) => setClockIn(e.target.value)} />
            {editType === "wrong_time" && existingEntry?.clock_in_at && (
              <div style={{ fontSize: 10, color: T.slate500, marginTop: 3 }}>
                Original: {fmtTime(existingEntry.clock_in_at)}
              </div>
            )}
          </div>
        )}

        {/* Clock out — needed for all three; optional for missed_shift/wrong_time */}
        {(editType === "missed_shift" || editType === "missed_clock_out" || editType === "wrong_time") && (
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>
              Clock out{" "}
              {editType === "missed_shift" && <span style={{ color: T.slate400, fontWeight: 400 }}>(optional if still working)</span>}
              {editType === "wrong_time" && existingEntry?.clock_out_at && <span style={{ color: T.slate400, fontWeight: 400 }}>(leave blank to keep original)</span>}
              {editType === "wrong_time" && !existingEntry?.clock_out_at && <span style={{ color: T.slate400, fontWeight: 400 }}>(leave blank if still working)</span>}
            </div>
            <TextInput type="datetime-local" value={clockOut} onChange={(e) => setClockOut(e.target.value)} />
            {editType === "wrong_time" && existingEntry?.clock_out_at && (
              <div style={{ fontSize: 10, color: T.slate500, marginTop: 3 }}>
                Original: {fmtTime(existingEntry.clock_out_at)}
              </div>
            )}
          </div>
        )}

        {/* Reason */}
        <div>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>Reason</div>
          <TextArea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="e.g. forgot to clock in after lunch, was on a call"
            rows={2}
          />
        </div>

        {error && (
          <div style={{ padding: "8px 10px", background: T.redLt, color: T.red, borderRadius: 6, fontSize: 12 }}>
            {error}
          </div>
        )}
      </div>

      <div style={{ padding: "12px 20px", borderTop: `1px solid ${T.slate200}`, display: "flex", justifyContent: "flex-end", gap: 8 }}>
        <Button onClick={onClose} disabled={busy}>Cancel</Button>
        <Button variant="dark" onClick={submit} disabled={busy}>
          {busy ? "Submitting..." : "Submit request"}
        </Button>
      </div>
    </ModalShell>
  );
}

// =====================================================================
// ADMIN APPROVAL QUEUE
// =====================================================================
export function AdminApprovalQueue({ user, onResolved }) {
  const [pending, setPending] = useState([]);
  const [loading, setLoading] = useState(true);
  const [reviewing, setReviewing] = useState(null);
  const [collapsed, setCollapsed] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    // Two-step: fetch requests, then hydrate team names + target entry data client-side.
    // Avoids brittle PostgREST FK-alias syntax if relationships aren't cached.
    const { data: reqs, error } = await supabase
      .from("time_clock_edit_requests")
      .select("id, team_member_id, punch_date, edit_type, target_entry_id, requested_clock_in_at, requested_clock_out_at, reason, submitted_at")
      .eq("agency_id", AGENCY_ID)
      .eq("status", "pending")
      .order("submitted_at", { ascending: true });
    if (error) { setPending([]); setLoading(false); return; }

    const rows = reqs || [];
    const memberIds = [...new Set(rows.map((r) => r.team_member_id).filter(Boolean))];
    const entryIds  = [...new Set(rows.map((r) => r.target_entry_id).filter(Boolean))];

    const memberMap = new Map();
    if (memberIds.length) {
      const { data: members } = await supabase
        .from("team")
        .select("id, first_name, last_name")
        .in("id", memberIds);
      (members || []).forEach((m) => memberMap.set(m.id, m));
    }
    const entryMap = new Map();
    if (entryIds.length) {
      const { data: ents } = await supabase
        .from("time_clock_entries")
        .select("id, clock_in_at, clock_out_at")
        .in("id", entryIds);
      (ents || []).forEach((e) => entryMap.set(e.id, e));
    }

    const hydrated = rows.map((r) => ({
      ...r,
      _member: memberMap.get(r.team_member_id) || null,
      _entry:  r.target_entry_id ? (entryMap.get(r.target_entry_id) || null) : null,
    }));
    setPending(hydrated);
    setLoading(false);
  }, []);

  useEffect(() => { reload(); }, [reload]);

  const count = pending.length;
  const hasCount = count > 0;

  return (
    <Card style={{ marginBottom: 14, borderTop: hasCount ? `3px solid ${T.amber}` : undefined }}>
      <div
        style={{ display: "flex", justifyContent: "space-between", alignItems: "center", cursor: "pointer" }}
        onClick={() => setCollapsed((c) => !c)}
      >
        <div>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
            Pending edit requests {hasCount && <span style={{ color: T.amber }}>({count})</span>}
          </div>
          {!hasCount && !loading && (
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>None waiting.</div>
          )}
          {loading && (
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>Loading...</div>
          )}
        </div>
        <div style={{ fontSize: 11, color: T.slate500 }}>{collapsed ? "Show" : "Hide"}</div>
      </div>

      {!collapsed && hasCount && (
        <div style={{ marginTop: 12, display: "flex", flexDirection: "column", gap: 10 }}>
          {pending.map((r) => (
            <PendingApprovalRow key={r.id} req={r} onReview={() => setReviewing(r)} />
          ))}
        </div>
      )}

      {reviewing && (
        <ReviewModal
          req={reviewing}
          user={user}
          onClose={() => setReviewing(null)}
          onDone={() => { setReviewing(null); reload(); onResolved?.(); }}
        />
      )}
    </Card>
  );
}

function PendingApprovalRow({ req, onReview }) {
  const memberName = req._member
    ? `${req._member.first_name} ${req._member.last_name}`
    : "Unknown";
  return (
    <div style={{
      padding: "10px 12px", borderRadius: 8, border: `1px solid ${T.slate200}`, background: T.slate50,
      display: "flex", justifyContent: "space-between", alignItems: "center",
      flexWrap: "wrap", gap: 10,
    }}>
      <div style={{ minWidth: 240 }}>
        <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>
          {memberName} · {EDIT_TYPE_LABELS[req.edit_type] || req.edit_type}
        </div>
        <div style={{ fontSize: 11, color: T.slate600, marginTop: 3 }}>
          {fmtDateLong(new Date(req.punch_date + "T00:00:00"))}
        </div>
        <ChangeSummary req={req} />
        {req.reason && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 4, fontStyle: "italic" }}>
            "{req.reason}"
          </div>
        )}
      </div>
      <div style={{ display: "flex", gap: 6 }}>
        <Button variant="dark" onClick={onReview}>Review</Button>
      </div>
    </div>
  );
}

function ChangeSummary({ req }) {
  const orig = req._entry;
  const line = (label, from, to) => (
    <div style={{ fontSize: 11, color: T.slate600, marginTop: 2 }}>
      <span style={{ fontWeight: 600, color: T.slate500 }}>{label}: </span>
      {from
        ? <><span style={{ textDecoration: "line-through", color: T.slate400 }}>{fmtTime(from)}</span> → </>
        : null}
      <span style={{ fontWeight: 600, color: T.slate800 }}>{fmtTime(to)}</span>
    </div>
  );
  if (req.edit_type === "missed_shift") {
    return (
      <>
        {req.requested_clock_in_at && line("In", null, req.requested_clock_in_at)}
        {req.requested_clock_out_at && line("Out", null, req.requested_clock_out_at)}
      </>
    );
  }
  if (req.edit_type === "missed_clock_out") {
    return (
      <>
        {orig && <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>In: {fmtTime(orig.clock_in_at)} (unchanged)</div>}
        {req.requested_clock_out_at && line("Out", orig?.clock_out_at, req.requested_clock_out_at)}
      </>
    );
  }
  // wrong_time
  return (
    <>
      {req.requested_clock_in_at  && line("In",  orig?.clock_in_at,  req.requested_clock_in_at)}
      {req.requested_clock_out_at && line("Out", orig?.clock_out_at, req.requested_clock_out_at)}
    </>
  );
}

function ReviewModal({ req, user, onClose, onDone }) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const memberName = req._member ? `${req._member.first_name} ${req._member.last_name}` : "Unknown";

  async function act(action) {
    setError("");
    if (!user?.id) { setError("No reviewer user id."); return; }
    setBusy(true);
    const fn = action === "approve" ? "approve_time_clock_edit" : "deny_time_clock_edit";
    const { error: rpcErr } = await supabase.rpc(fn, {
      p_request_id: req.id,
      p_reviewer_user_id: user.id,
      p_note: note.trim() || null,
    });
    setBusy(false);
    if (rpcErr) { setError(rpcErr.message); return; }
    onDone();
  }

  return (
    <ModalShell onClose={busy ? () => {} : onClose}>
      <div style={{ padding: "16px 20px", borderBottom: `1px solid ${T.slate200}` }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>
          Review edit request
        </div>
        <div style={{ fontSize: 11, color: T.slate500, marginTop: 3 }}>
          {memberName} · {EDIT_TYPE_LABELS[req.edit_type] || req.edit_type} · {fmtDateLong(new Date(req.punch_date + "T00:00:00"))}
        </div>
      </div>

      <div style={{ padding: "16px 20px", display: "flex", flexDirection: "column", gap: 12 }}>
        <div style={{ padding: 10, background: T.slate50, borderRadius: 8, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate500, marginBottom: 6, textTransform: "uppercase", letterSpacing: 0.5 }}>
            Requested change
          </div>
          <ChangeSummary req={req} />
        </div>

        {req.reason && (
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>Reason from {memberName.split(" ")[0]}</div>
            <div style={{ padding: 10, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, fontSize: 12, color: T.slate700, fontStyle: "italic" }}>
              "{req.reason}"
            </div>
          </div>
        )}

        <div>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>
            Note (optional — visible to the requester)
          </div>
          <TextArea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="e.g. approved. Please clock in on time going forward."
            rows={2}
          />
        </div>

        {error && (
          <div style={{ padding: "8px 10px", background: T.redLt, color: T.red, borderRadius: 6, fontSize: 12 }}>{error}</div>
        )}
      </div>

      <div style={{ padding: "12px 20px", borderTop: `1px solid ${T.slate200}`, display: "flex", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
        <Button onClick={onClose} disabled={busy}>Close</Button>
        <div style={{ display: "flex", gap: 8 }}>
          <Button variant="danger" onClick={() => act("deny")} disabled={busy}>
            {busy ? "..." : "Deny"}
          </Button>
          <Button variant="success" onClick={() => act("approve")} disabled={busy}>
            {busy ? "..." : "Approve"}
          </Button>
        </div>
      </div>
    </ModalShell>
  );
}
