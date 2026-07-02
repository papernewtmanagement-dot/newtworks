import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useState, useEffect, useMemo, useCallback } from "react";

// =====================================================================
// TimeClock.jsx — Hourly team member timeclock (per-user, no PIN)
// Two views: Kiosk (name tile, tap to punch) and Admin (timesheet)
// Each user logs into BCC as themselves; auth.uid() identifies the puncher.
// Week boundary: Sunday 00:00 -> Saturday 23:59
// One time_clock_entries row = one continuous block of paid work.
// Lunches = gaps between blocks (clock out, clock back in).
//
// Weekly alerts:
//   < 39 hr      green   on track
//   39 - 40 hr   amber   approaching overtime
//   >= 40 hr     red     in overtime
//
// Schema:
//   v_time_clock_status: team_member_id, first_name, last_name, pay_rate,
//     open_entry_id, clock_in_at, is_clocked_in, hours_this_block, is_test_user
//   time_clock_entries:  id, team_member_id, clock_in_at, clock_out_at,
//     notes, source ('self'|'admin'|'admin_create'|'admin_edit'|'kiosk'),
//     edited_by_user_id, edited_at
//   RPC time_clock_punch_simple(p_team_member_id uuid DEFAULT NULL) -> jsonb
//     - NULL targets caller's own team row
//     - owner/manager may pass any team row to cross-punch (e.g. Test User)
// =====================================================================

import { T } from "../lib/theme.js";
import { StaffRequestSection, AdminApprovalQueue } from "./TimeClockEditRequests.jsx";

const YELLOW_HR = 39;
const RED_HR = 40;

// =====================================================================
// Date / week helpers
// =====================================================================
function startOfSundayWeek(date) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - d.getDay()); // 0 = Sunday
  return d;
}
function endOfSaturdayWeek(date) {
  const start = startOfSundayWeek(date);
  const end = new Date(start);
  end.setDate(end.getDate() + 7);
  return end; // exclusive
}
function addDays(date, days) {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d;
}
function fmtDate(d) {
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}
function fmtDateLong(d) {
  return d.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric", year: "numeric" });
}
function fmtTime(iso) {
  if (!iso) return "--";
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
function fmtHM(hours) {
  // Returns decimal hours, e.g. 8.50 for 8 hours 30 min.  Negative values keep sign.
  if (!Number.isFinite(hours)) return "0.00";
  return hours.toFixed(2);
}
function hoursBetween(inIso, outIso) {
  if (!inIso || !outIso) return 0;
  return (new Date(outIso) - new Date(inIso)) / 3_600_000;
}
function toLocalInput(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fromLocalInput(value) {
  if (!value) return null;
  return new Date(value).toISOString();
}

// =====================================================================
// Status logic: 39 yellow / 40 red
// =====================================================================
function weeklyStatus(hours) {
  if (!Number.isFinite(hours) || hours < YELLOW_HR) {
    return { level: "ok",     label: "On track",       bg: T.greenLt, color: T.green,  border: T.green  };
  }
  if (hours < RED_HR) {
    return { level: "warn",   label: "Near OT",        bg: T.amberLt, color: T.amber,  border: T.amber  };
  }
  return   { level: "danger", label: "Overtime",       bg: T.redLt,   color: T.red,    border: T.red    };
}

// Sum closed-block hours for a team member from a flat entries array
function sumClosedHours(entries, teamMemberId) {
  return (entries || [])
    .filter((e) => e.team_member_id === teamMemberId && e.clock_out_at)
    .reduce((acc, e) => acc + hoursBetween(e.clock_in_at, e.clock_out_at), 0);
}
// Open block (clocked-in this week, not yet out) running hours
function openBlockHours(entries, teamMemberId) {
  const open = (entries || []).find((e) => e.team_member_id === teamMemberId && !e.clock_out_at);
  if (!open) return 0;
  return hoursBetween(open.clock_in_at, new Date().toISOString());
}

// =====================================================================
// Primitives
// =====================================================================
function Card({ children, style = {} }) {
  return (
    <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: "16px 18px", ...style }}>
      {children}
    </div>
  );
}

function Pill({ children, bg = T.slate100, color = T.slate700, style = {} }) {
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 4,
      padding: "3px 8px", borderRadius: 20,
      fontSize: 10, fontWeight: 600,
      background: bg, color, whiteSpace: "nowrap", ...style,
    }}>
      {children}
    </span>
  );
}

function Button({ children, onClick, variant = "secondary", disabled = false, type = "button", style = {} }) {
  const variants = {
    primary:   { bg: T.blue,      color: T.white,    border: T.blue },
    secondary: { bg: T.white,     color: T.slate700, border: T.slate200 },
    ghost:     { bg: "transparent", color: T.blue,   border: "transparent" },
    danger:    { bg: T.white,     color: T.red,      border: T.slate200 },
    dark:      { bg: T.slate900,  color: T.white,    border: T.slate900 },
  };
  const v = variants[variant] || variants.secondary;
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled}
      style={{
        padding: "7px 13px",
        borderRadius: 7,
        border: `1px solid ${v.border}`,
        background: v.bg,
        color: v.color,
        fontSize: 12,
        fontWeight: 600,
        cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.45 : 1,
        whiteSpace: "nowrap",
        ...style,
      }}
    >
      {children}
    </button>
  );
}

function TextInput({ value, onChange, type = "text", placeholder, maxLength, inputMode, style = {} }) {
  return (
    <input
      type={type}
      value={value}
      onChange={onChange}
      placeholder={placeholder}
      maxLength={maxLength}
      inputMode={inputMode}
      style={{
        width: "100%",
        padding: "8px 10px",
        borderRadius: 7,
        border: `1px solid ${T.slate200}`,
        background: T.white,
        fontSize: 13,
        color: T.slate900,
        outline: "none",
        ...style,
      }}
    />
  );
}

// =====================================================================
// Hooks
// =====================================================================
function useCurrentUser() {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data: authData } = await supabase.auth.getUser();
      const authUserId = authData?.user?.id;
      if (!authUserId) {
        if (!cancelled) { setUser(null); setLoading(false); }
        return;
      }
      const { data: rows } = await supabase
        .from("users")
        .select("id, role, full_name, email, team_member_id")
        .eq("auth_user_id", authUserId)
        .eq("agency_id", AGENCY_ID)
        .limit(1);
      if (!cancelled) {
        setUser(rows?.[0] || null);
        setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);
  return { user, loading };
}

function useHourlyStaff() {
  const [staff, setStaff] = useState([]);
  const [loading, setLoading] = useState(true);
  const reload = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("v_time_clock_status")
      .select("*")
      .order("first_name");
    if (!error) setStaff(data || []);
    setLoading(false);
  }, []);
  useEffect(() => { reload(); }, [reload]);
  return { staff, loading, reload };
}

function useWeekEntries(weekStart, weekEnd) {
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);
  const reload = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("time_clock_entries")
      .select("id, team_member_id, clock_in_at, clock_out_at, notes, source, edited_at")
      .eq("agency_id", AGENCY_ID)
      .gte("clock_in_at", weekStart.toISOString())
      .lt("clock_in_at", weekEnd.toISOString())
      .order("clock_in_at");
    if (!error) setEntries(data || []);
    setLoading(false);
  }, [weekStart, weekEnd]);
  useEffect(() => { reload(); }, [reload]);
  return { entries, loading, reload };
}

// Filter the hourly staff list based on the logged-in user.
//   owner   -> see everyone, including is_test_user rows
//   manager -> see everyone except is_test_user rows
//   anyone with a linked team_member_id -> only their own row (and not test users)
//   otherwise -> empty
function filterVisibleStaff(staff, user) {
  const all = staff || [];
  if (!user) return [];
  if (user.role === "owner") return all;
  const realStaff = all.filter((s) => !s.is_test_user);
  if (user.role === "manager") return realStaff;
  if (user.team_member_id) {
    return realStaff.filter((s) => s.team_member_id === user.team_member_id);
  }
  return [];
}

// =====================================================================
// MAIN
// =====================================================================
export default function TimeClock() {
  const { user, loading: userLoading } = useCurrentUser();
  const canSeeAdmin = !!user && ["owner", "manager"].includes(user.role);
  const [tab, setTab] = useState("kiosk");
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";

  return (
    <div style={{ padding: _pad, maxWidth: 1200, margin: "0 auto" }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: 12, marginBottom: 18 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: T.slate900, margin: 0 }}>Time Clock</h1>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
            Hourly team clock in / out &middot; week runs Sun&ndash;Sat &middot; lunch = clock out then back in
          </div>
        </div>
        {!userLoading && canSeeAdmin && (
          <div style={{ display: "flex", gap: 3, padding: 3, background: T.slate100, borderRadius: 9 }}>
            <TabButton active={tab === "kiosk"} onClick={() => setTab("kiosk")}>Kiosk</TabButton>
            <TabButton active={tab === "admin"} onClick={() => setTab("admin")}>Admin</TabButton>
          </div>
        )}
      </div>

      {tab === "kiosk" || !canSeeAdmin
        ? <KioskView user={user} />
        : <AdminView user={user} />}
    </div>
  );
}

function TabButton({ active, onClick, children }) {
  return (
    <button
      onClick={onClick}
      style={{
        padding: "6px 14px",
        borderRadius: 7,
        border: "none",
        background: active ? T.white : "transparent",
        color: active ? T.slate900 : T.slate600,
        fontSize: 12,
        fontWeight: 600,
        cursor: "pointer",
        boxShadow: active ? "0 1px 3px rgba(15, 23, 42, 0.08)" : "none",
        transition: "all 0.12s",
      }}
    >
      {children}
    </button>
  );
}

// =====================================================================
// KIOSK VIEW  -- name tiles -> PIN pad -> punch
// =====================================================================
function KioskView({ user }) {
  const { staff: allStaff, loading: staffLoading, reload: reloadStaff } = useHourlyStaff();
  const staff = useMemo(() => filterVisibleStaff(allStaff, user), [allStaff, user]);
  const weekStart = useMemo(() => startOfSundayWeek(new Date()), []);
  const weekEnd   = useMemo(() => endOfSaturdayWeek(weekStart), [weekStart]);
  const { entries, reload: reloadEntries } = useWeekEntries(weekStart, weekEnd);

  // Without PINs, a tile tap punches that team_member directly.  `busy` holds the
  // team_member_id currently being punched (so we can disable just that tile).
  const [busy, setBusy] = useState(null);
  const [result, setResult] = useState(null);

  // refresh every 30s so counters stay live
  useEffect(() => {
    const t = setInterval(() => { reloadStaff(); reloadEntries(); }, 30_000);
    return () => clearInterval(t);
  }, [reloadStaff, reloadEntries]);

  // clear success splash
  useEffect(() => {
    if (!result?.ok) return;
    const t = setTimeout(() => setResult(null), 5000);
    return () => clearTimeout(t);
  }, [result]);

  async function punch(memberId) {
    if (busy) return;
    setBusy(memberId);
    const { data, error } = await supabase.rpc("time_clock_punch_simple", {
      p_team_member_id: memberId,
    });
    setBusy(null);
    if (error) {
      setResult({ ok: false, error: "rpc_error", message: error.message });
      return;
    }
    setResult(data);
    if (data?.ok) {
      reloadStaff();
      reloadEntries();
    }
  }

  if (staffLoading) {
    return <div style={{ textAlign: "center", color: T.slate500, padding: "48px 0", fontSize: 13 }}>Loading...</div>;
  }
  if (!staff.length) {
    const isLinkedStaff = !!user && !["owner", "manager"].includes(user.role) && !!user.team_member_id;
    return (
      <Card style={{ padding: "32px 24px", textAlign: "center", borderStyle: "dashed", background: T.slate50 }}>
        <div style={{ fontSize: 14, fontWeight: 600, color: T.slate700 }}>
          {isLinkedStaff ? "Your clock isn't set up" : "Nothing to clock here"}
        </div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
          {isLinkedStaff
            ? "Ask Peter to set your PIN, then refresh."
            : (allStaff.length
                ? "Your account isn't linked to an hourly team row. Ask Peter to link it."
                : "Add an hourly team member in Team to see them here.")}
        </div>
      </Card>
    );
  }

  // Success splash
  if (result?.ok) {
    return (
      <Card style={{ padding: "40px 24px", textAlign: "center", background: result.action === "clock_in" ? T.greenLt : T.blueLt, border: `1px solid ${result.action === "clock_in" ? T.green : T.blue}` }}>
        <div style={{ fontSize: 28, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>
          {result.action === "clock_in" ? "Clocked in" : "Clocked out"}
        </div>
        <div style={{ fontSize: 14, color: T.slate700 }}>
          {result.team_member_name} &middot; {new Date(result.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
        </div>
        {result.action === "clock_out" && Number.isFinite(result.hours_this_block) && (
          <div style={{ fontSize: 12, color: T.slate600, marginTop: 6 }}>
            This block: {fmtHM(result.hours_this_block)}
          </div>
        )}
      </Card>
    );
  }

  // Error splash (success splash is above and self-dismisses)
  // We render the tile grid below regardless, but show a non-ok result inline at top.

  // Tile grid (with inline error banner when last punch failed)
  return (
    <div>
      {result?.ok === false && (
        <Card style={{ marginBottom: 12, background: T.redLt, border: `1px solid ${T.red}`, padding: "10px 14px" }}>
          <div style={{ fontSize: 12, color: T.red, fontWeight: 600 }}>
            {result.error === "inactive_team_member" && "Account inactive."}
            {result.error === "not_hourly" && "Not an hourly position."}
            {result.error === "no_team_member_linked" && "Your account isn't linked to a team row yet. Ask Peter to link it."}
            {result.error === "not_authorized" && "You can only clock yourself in or out."}
            {result.error === "not_authenticated" && "Log in to clock in."}
            {!["inactive_team_member","not_hourly","no_team_member_linked","not_authorized","not_authenticated"].includes(result.error) && (result.message || "Something went wrong.")}
          </div>
        </Card>
      )}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))", gap: 12 }}>
      {(staff || []).map((s) => {
        const closed = sumClosedHours(entries, s.team_member_id);
        const open = openBlockHours(entries, s.team_member_id);
        const weekHours = closed + open;
        const status = weeklyStatus(weekHours);
        return (
          <KioskTile
            key={s.team_member_id}
            staff={s}
            weekHours={weekHours}
            status={status}
            busy={busy === s.team_member_id}
            onClick={() => punch(s.team_member_id)}
          />
        );
      })}
      </div>
      {user && user.role !== "owner" && user.role !== "manager" && (
        <div style={{ marginTop: 4 }}>
          <StaffRequestSection
            user={user}
            entries={entries}
            weekStart={weekStart}
            onChange={() => { reloadStaff(); reloadEntries(); }}
          />
        </div>
      )}
    </div>
  );
}

function KioskTile({ staff: s, weekHours, status, onClick, busy }) {
  const clockedIn = !!s.is_clocked_in;
  return (
    <button
      onClick={onClick}
      disabled={busy}
      style={{
        textAlign: "left",
        padding: "16px 18px",
        borderRadius: 12,
        border: `1px solid ${clockedIn ? T.green : T.slate200}`,
        background: clockedIn ? T.greenLt : T.white,
        cursor: busy ? "wait" : "pointer",
        opacity: busy ? 0.6 : 1,
        transition: "all 0.15s",
      }}
    >
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {s.first_name} {s.last_name}
          </div>
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
            {busy
              ? "Working..."
              : (clockedIn
                  ? <>Clocked in &middot; {fmtTime(s.clock_in_at)}</>
                  : "Tap to clock in")}
          </div>
        </div>
        {clockedIn && (
          <Pill bg={T.green} color={T.white}>ON</Pill>
        )}
      </div>

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 12 }}>
        <div style={{ fontSize: 11, color: T.slate500 }}>
          This week
          <div style={{ fontSize: 14, fontWeight: 600, color: T.slate900, marginTop: 1 }}>
            {fmtHM(weekHours)}
          </div>
        </div>
        <Pill bg={status.bg} color={status.color}>{status.label}</Pill>
      </div>
    </button>
  );
}

// =====================================================================
// ADMIN VIEW  -- weekly grid, edit entries, set PIN
// =====================================================================
function AdminView({ user }) {
  const userId = user?.id;
  const [anchor, setAnchor] = useState(() => startOfSundayWeek(new Date()));
  const weekStart = useMemo(() => startOfSundayWeek(anchor), [anchor]);
  const weekEnd = useMemo(() => endOfSaturdayWeek(weekStart), [weekStart]);
  const lastDay = useMemo(() => addDays(weekStart, 6), [weekStart]);

  const { staff: allStaff, loading: staffLoading, reload: reloadStaff } = useHourlyStaff();
  const staff = useMemo(() => filterVisibleStaff(allStaff, user), [allStaff, user]);
  const { entries, loading: entriesLoading, reload: reloadEntries } = useWeekEntries(weekStart, weekEnd);

  const [editing, setEditing] = useState(null);   // entry or "new"
  const [editingFor, setEditingFor] = useState(null); // staff for "new"

  const isThisWeek = useMemo(() => {
    const now = startOfSundayWeek(new Date());
    return weekStart.getTime() === now.getTime();
  }, [weekStart]);

  function goPrev()   { setAnchor(addDays(weekStart, -7)); }
  function goNext()   { setAnchor(addDays(weekStart,  7)); }
  function goToday()  { setAnchor(startOfSundayWeek(new Date())); }

  return (
    <div>
      <AdminApprovalQueue
        user={user}
        onResolved={() => { reloadStaff(); reloadEntries(); }}
      />
      {/* Week navigator */}
      <Card style={{ marginBottom: 14, padding: "12px 16px" }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: 10 }}>
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>
              {fmtDate(weekStart)} &ndash; {fmtDate(lastDay)}, {weekStart.getFullYear()}
            </div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
              {isThisWeek ? "This week" : (weekStart < startOfSundayWeek(new Date()) ? "Prior week" : "Future week")}
            </div>
          </div>
          <div style={{ display: "flex", gap: 6 }}>
            <Button onClick={goPrev}>&larr; Prev</Button>
            {!isThisWeek && <Button onClick={goToday} variant="ghost">This week</Button>}
            <Button onClick={goNext}>Next &rarr;</Button>
          </div>
        </div>
      </Card>

      {staffLoading && entriesLoading ? (
        <div style={{ textAlign: "center", color: T.slate500, padding: "32px 0", fontSize: 13 }}>Loading...</div>
      ) : !staff.length ? (
        <Card style={{ padding: "32px 24px", textAlign: "center", borderStyle: "dashed", background: T.slate50 }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: T.slate700 }}>No hourly team members yet</div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
            Add an hourly team member in Team to see them here.
          </div>
        </Card>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {(staff || []).map((s) => (
            <StaffWeekCard
              key={s.team_member_id}
              staff={s}
              weekStart={weekStart}
              entries={(entries || []).filter((e) => e.team_member_id === s.team_member_id)}
              onEdit={(entry) => setEditing(entry)}
              onAdd={() => { setEditingFor(s); setEditing("new"); }}
            />
          ))}
        </div>
      )}

      {/* Footer summary */}
      <div style={{ marginTop: 14, padding: "10px 14px", background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 9, fontSize: 11, color: T.slate600 }}>
        <span style={{ marginRight: 14 }}>
          <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: "50%", background: T.green, marginRight: 5 }} />
          On track (&lt;{YELLOW_HR}h)
        </span>
        <span style={{ marginRight: 14 }}>
          <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: "50%", background: T.amber, marginRight: 5 }} />
          Near OT ({YELLOW_HR}-{RED_HR}h)
        </span>
        <span>
          <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: "50%", background: T.red, marginRight: 5 }} />
          Overtime (&ge;{RED_HR}h)
        </span>
      </div>

      {editing && (
        <EditEntryModal
          entry={editing === "new" ? null : editing}
          forStaff={editing === "new" ? editingFor : null}
          userId={userId}
          onClose={() => { setEditing(null); setEditingFor(null); }}
          onSaved={() => { setEditing(null); setEditingFor(null); reloadEntries(); reloadStaff(); }}
        />
      )}
    </div>
  );
}

function StaffWeekCard({ staff: s, weekStart, entries, onEdit, onAdd }) {
  const closedHours = sumClosedHours(entries, s.team_member_id);
  const openHours = openBlockHours(entries, s.team_member_id);
  const totalHours = closedHours + openHours;
  const status = weeklyStatus(totalHours);
  const payRate = Number(s.pay_rate) || 0;
  const grossPay = totalHours * payRate;

  // Group entries by day
  const dayBuckets = useMemo(() => {
    const buckets = [0, 1, 2, 3, 4, 5, 6].map((i) => {
      const dayStart = addDays(weekStart, i);
      const dayEnd = addDays(dayStart, 1);
      return { date: dayStart, entries: [] };
    });
    (entries || []).forEach((e) => {
      const d = new Date(e.clock_in_at);
      const dow = Math.floor((d - weekStart) / 86_400_000);
      if (dow >= 0 && dow < 7) buckets[dow].entries.push(e);
    });
    return buckets;
  }, [entries, weekStart]);

  return (
    <Card style={{ padding: 0, overflow: "hidden", borderTop: `3px solid ${status.border}` }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: 10, padding: "14px 18px", borderBottom: `1px solid ${T.slate200}` }}>
        <div>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>
              {s.first_name} {s.last_name}
            </div>
            {s.is_clocked_in && <Pill bg={T.green} color={T.white}>ON</Pill>}
          </div>
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
            ${payRate.toFixed(2)}/hr
          </div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 14, flexWrap: "wrap" }}>
          <div style={{ textAlign: "right" }}>
            <div style={{ fontSize: 11, color: T.slate500 }}>Hours / Pay</div>
            <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
              {fmtHM(totalHours)} &middot; ${grossPay.toFixed(2)}
            </div>
          </div>
          <Pill bg={status.bg} color={status.color}>{status.label}</Pill>
          <div style={{ display: "flex", gap: 6 }}>
            <Button onClick={onAdd}>+ Add entry</Button>
          </div>
        </div>
      </div>

      {/* Day grid */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(7, 1fr)", borderBottom: `1px solid ${T.slate200}` }}>
        {dayBuckets.map((b, i) => {
          const isToday = b.date.toDateString() === new Date().toDateString();
          return (
            <div key={i} style={{
              padding: "10px 8px",
              borderRight: i < 6 ? `1px solid ${T.slate200}` : "none",
              background: isToday ? T.blueLt : T.white,
              minHeight: 90,
            }}>
              <div style={{ fontSize: 10, fontWeight: 600, color: isToday ? T.blue : T.slate500, marginBottom: 4, textTransform: "uppercase", letterSpacing: 0.5 }}>
                {b.date.toLocaleDateString([], { weekday: "short" })} {b.date.getDate()}
              </div>
              {b.entries.length === 0 ? (
                <div style={{ fontSize: 10, color: T.slate400 }}>--</div>
              ) : (
                b.entries.map((e) => {
                  const hrs = e.clock_out_at ? hoursBetween(e.clock_in_at, e.clock_out_at) : null;
                  return (
                    <button
                      key={e.id}
                      onClick={() => onEdit(e)}
                      style={{
                        display: "block", width: "100%",
                        textAlign: "left", padding: "4px 6px", marginBottom: 4,
                        background: e.clock_out_at ? T.slate50 : T.greenLt,
                        border: `1px solid ${e.clock_out_at ? T.slate200 : T.green}`,
                        borderRadius: 5,
                        fontSize: 10, color: T.slate800,
                        cursor: "pointer",
                      }}
                    >
                      <div style={{ fontWeight: 600 }}>
                        {fmtTime(e.clock_in_at)} &ndash; {e.clock_out_at ? fmtTime(e.clock_out_at) : "open"}
                      </div>
                      {hrs !== null && <div style={{ color: T.slate500, fontSize: 9 }}>{fmtHM(hrs)}</div>}
                    </button>
                  );
                })
              )}
            </div>
          );
        })}
      </div>

      {/* Detail list */}
      <div style={{ padding: "10px 18px", background: T.slate50, fontSize: 11, color: T.slate600 }}>
        {(entries || []).length === 0
          ? <span>No entries this week.</span>
          : <span>{(entries || []).length} entr{(entries || []).length === 1 ? "y" : "ies"} this week. Click any block to edit.</span>}
      </div>
    </Card>
  );
}

// =====================================================================
// MODALS
// =====================================================================
function ModalShell({ children, onClose, width = 460 }) {
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
          boxShadow: "0 20px 50px rgba(15,23,42,0.25)",
        }}
      >
        {children}
      </div>
    </div>
  );
}

function EditEntryModal({ entry, forStaff, userId, onClose, onSaved }) {
  const isNew = !entry;
  const [clockIn, setClockIn] = useState(toLocalInput(entry?.clock_in_at) || toLocalInput(new Date().toISOString()));
  const [clockOut, setClockOut] = useState(toLocalInput(entry?.clock_out_at) || "");
  const [notes, setNotes] = useState(entry?.notes || "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function save() {
    setError("");
    const inIso = fromLocalInput(clockIn);
    const outIso = fromLocalInput(clockOut);
    if (!inIso) { setError("Clock-in time required."); return; }
    if (outIso && new Date(outIso) <= new Date(inIso)) {
      setError("Clock-out must be after clock-in."); return;
    }
    setBusy(true);
    if (isNew) {
      const { error: insErr } = await supabase.from("time_clock_entries").insert({
        agency_id: AGENCY_ID,
        team_member_id: forStaff.team_member_id,
        clock_in_at: inIso,
        clock_out_at: outIso,
        notes: notes || null,
        source: "admin_create",
        edited_by_user_id: userId || null,
        edited_at: new Date().toISOString(),
      });
      setBusy(false);
      if (insErr) { setError(insErr.message); return; }
    } else {
      const { error: updErr } = await supabase.from("time_clock_entries")
        .update({
          clock_in_at: inIso,
          clock_out_at: outIso,
          notes: notes || null,
          source: "admin_edit",
          edited_by_user_id: userId || null,
          edited_at: new Date().toISOString(),
        })
        .eq("id", entry.id);
      setBusy(false);
      if (updErr) { setError(updErr.message); return; }
    }
    onSaved();
  }

  async function remove() {
    if (!entry) return;
    if (!window.confirm("Delete this time entry? This cannot be undone.")) return;
    setBusy(true);
    const { error: delErr } = await supabase.from("time_clock_entries").delete().eq("id", entry.id);
    setBusy(false);
    if (delErr) { setError(delErr.message); return; }
    onSaved();
  }

  const subject = forStaff
    ? `${forStaff.first_name} ${forStaff.last_name}`
    : "this entry";

  return (
    <ModalShell onClose={busy ? () => {} : onClose}>
      <div style={{ padding: "16px 20px", borderBottom: `1px solid ${T.slate200}` }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>
          {isNew ? `New entry for ${subject}` : "Edit time entry"}
        </div>
        {!isNew && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 3 }}>
            Source: {entry.source || "kiosk"}{entry.edited_at ? ` &middot; last edited ${fmtDate(new Date(entry.edited_at))}` : ""}
          </div>
        )}
      </div>

      <div style={{ padding: "16px 20px", display: "flex", flexDirection: "column", gap: 12 }}>
        <div>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>Clock in</div>
          <TextInput type="datetime-local" value={clockIn} onChange={(e) => setClockIn(e.target.value)} />
        </div>
        <div>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>Clock out</div>
          <TextInput type="datetime-local" value={clockOut} onChange={(e) => setClockOut(e.target.value)} />
          <div style={{ fontSize: 10, color: T.slate500, marginTop: 4 }}>Leave blank to keep this entry open.</div>
        </div>
        <div>
          <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 4 }}>Notes (optional)</div>
          <TextInput value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="e.g. forgot to clock out, fixed 3:30 -> 4:15" />
        </div>
        {error && (
          <div style={{ padding: "8px 10px", background: T.redLt, color: T.red, borderRadius: 6, fontSize: 12 }}>{error}</div>
        )}
      </div>

      <div style={{ padding: "12px 20px", borderTop: `1px solid ${T.slate200}`, display: "flex", justifyContent: "space-between", gap: 8 }}>
        <div>
          {!isNew && <Button variant="danger" onClick={remove} disabled={busy}>Delete</Button>}
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <Button onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="dark" onClick={save} disabled={busy}>{busy ? "Saving..." : "Save"}</Button>
        </div>
      </div>
    </ModalShell>
  );
}

