import { useState, useEffect, useCallback, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// Month-view calendar of actual interview slot instances — not an abstract
// "blackout" calendar. Every day shows its bookable times with real status:
// open (available to candidates), scheduled (booked, candidate shown), or
// removed (taken off the table). You can add an extra one-off slot to any
// day, delete an individual open slot if something comes up, or stop a
// standing weekday slot going forward. The slots themselves come from the
// database function interview_slot_grid — the same one the
// hiring-interview-scheduler edge function and the coaching blocks read — so
// this page never keeps its own copy of the slot times.

function isoDayLocal(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function startOfMonth(d) { return new Date(d.getFullYear(), d.getMonth(), 1); }
function addMonths(d, n) { return new Date(d.getFullYear(), d.getMonth() + n, 1); }
function monthLabel(d) { return d.toLocaleDateString(undefined, { month: "long", year: "numeric" }); }

function buildMonthGrid(monthDate) {
  const first = startOfMonth(monthDate);
  const gridStart = new Date(first);
  gridStart.setDate(first.getDate() - first.getDay());
  const days = [];
  for (let i = 0; i < 42; i++) {
    const d = new Date(gridStart);
    d.setDate(gridStart.getDate() + i);
    days.push(d);
  }
  return days;
}

const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DOW_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

// Length of a slot written from this page (manual slots, blackouts).
const INTERVIEW_MINUTES = 30;
const TZ = "America/Chicago";

// Explains the Friday rule in the day view; the rule itself lives in interview_slot_grid.
function fridayOrdinal(d) { return d.getDay() === 5 ? Math.ceil(d.getDate() / 7) : null; }
function fridayRuleNote(d) {
  const nth = fridayOrdinal(d);
  if (nth === 1) return "First Friday of the month — no morning times.";
  if (nth === 3) return "Third Friday of the month — no midday or end-of-day times.";
  return null;
}
// Vacation weeks: Sun–Sat, keyed by the Sunday.
function weekStartIso(dateISO) {
  const d = new Date(dateISO + "T12:00:00");
  d.setDate(d.getDate() - d.getDay());
  return isoDayLocal(d);
}
function addDaysIso(dateISO, n) {
  const d = new Date(dateISO + "T12:00:00");
  d.setDate(d.getDate() + n);
  return isoDayLocal(d);
}
function pad2(n) { return String(n).padStart(2, "0"); }
function timeToHHMMSS(h, m) { return `${pad2(h)}:${pad2(m)}:00`; }
function addMinutesToTime(h, m, mins) {
  const total = h * 60 + m + mins;
  return { h: Math.floor(total / 60) % 24, m: total % 60 };
}
function labelForTime(h, m) {
  const period = h < 12 ? "AM" : "PM";
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${pad2(m)} ${period}`;
}
// Chicago-local "YYYY-MM-DD|HH:MM" key for matching a scheduled interview's
// UTC timestamp back to a slot instance's local date+time.
function chicagoKey(isoUtc) {
  const dtf = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  const parts = dtf.formatToParts(new Date(isoUtc)).reduce((acc, p) => { acc[p.type] = p.value; return acc; }, {});
  const hh = parts.hour === "24" ? "00" : parts.hour;
  return `${parts.year}-${parts.month}-${parts.day}|${hh}:${parts.minute}`;
}

// The slot instances for one date: every row interview_slot_grid returned
// for it, tagged open / scheduled / removed, plus any booked interview that
// sits off the grid.
function slotsForDate(dateISO, { gridByDate, scheduledByKey, busyEvents }) {
  const templated = (gridByDate.get(dateISO) || []).map((r) => {
    const [h, m] = chicagoKey(r.start_at).split("|")[1].split(":").map(Number);
    return {
      h, m, label: labelForTime(h, m), source: r.source, tier: r.source === "manual" ? null : r.tier,
      manualId: r.manual_slot_id, note: r.manual_note, startAt: r.start_at, endAt: r.end_at, row: r,
    };
  });
  const templatedKeys = new Set(templated.map((s) => timeToHHMMSS(s.h, s.m).slice(0, 5)));

  // Any booked interview whose time doesn't match a slot
  // (e.g. booked before the schedule was fixed) still needs to show up.
  const extraScheduled = [];
  for (const [key, candidate] of scheduledByKey) {
    if (!key.startsWith(`${dateISO}|`)) continue;
    const hm = key.split("|")[1];
    if (templatedKeys.has(hm)) continue;
    const [h, m] = hm.split(":").map(Number);
    extraScheduled.push({ h, m, label: labelForTime(h, m), source: "scheduled-only", status: "scheduled", candidate });
  }

  const resolved = templated.map(({ row, ...slot }) => {
    const key = `${dateISO}|${timeToHHMMSS(slot.h, slot.m).slice(0, 5)}`;
    const scheduled = scheduledByKey.get(key);
    if (scheduled) return { ...slot, status: "scheduled", candidate: scheduled };
    if (row.blacked_out) {
      if (row.removed_whole) return { ...slot, status: "removed", removedWhole: true, reason: row.vacation_label || undefined };
      if (row.blackout_id) return { ...slot, status: "removed", blackoutId: row.blackout_id };
      return { ...slot, status: "removed", recurringId: row.recurring_blackout_id };
    }
    const busy = busyOverlap(slot, busyEvents);
    if (busy) return { ...slot, status: "removed", removedWhole: true, reason: `busy: ${busy}` };
    return { ...slot, status: "open" };
  });

  return [...resolved, ...extraScheduled].sort((a, b) => (a.h * 60 + a.m) - (b.h * 60 + b.m));
}

// Google Calendar events (from the edge function) that would knock a slot
// out. The scheduler skips any slot overlapping a busy event, so the calendar
// has to show the same thing — with the event's name.
const SCHEDULER_ENDPOINT = `${import.meta.env.VITE_SUPABASE_URL || ""}/functions/v1/hiring-interview-scheduler`;
async function callSchedulerAdmin(mode, extra = {}) {
  try {
    const { data: sess } = await supabase.auth.getSession();
    const token = sess?.session?.access_token;
    if (!token) return null;
    const res = await fetch(SCHEDULER_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}`, apikey: import.meta.env.VITE_SUPABASE_ANON_KEY || "" },
      body: JSON.stringify({ mode, agency_id: AGENCY_ID, ...extra }),
    });
    return await res.json().catch(() => null);
  } catch {
    return null;
  }
}

function busyOverlap(slot, busyEvents) {
  if (!busyEvents || busyEvents.length === 0) return null;
  const start = new Date(slot.startAt);
  const end = new Date(slot.endAt);
  for (const e of busyEvents) {
    const es = new Date(e.start), ee = new Date(e.end);
    if (es < end && ee > start) return e.summary;
  }
  return null;
}

function DayModal({ dateISO, slots, vacation, onRemoveSlot, onRestoreSlot, onDeleteManualSlot, onAddManualSlot, onMoveVacation, onClose }) {
  const [addTime, setAddTime] = useState("09:00");
  const [addNote, setAddNote] = useState("");
  const [saving, setSaving] = useState(null);
  const [showAdd, setShowAdd] = useState(false);
  const dateObj = new Date(dateISO + "T12:00:00");
  const displayDate = dateObj.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  const weekdayLabel = DOW_FULL[dateObj.getDay()];
  const fridayNote = fridayRuleNote(dateObj);

  const handleAdd = async () => {
    setSaving("add");
    const [h, m] = addTime.split(":").map(Number);
    const end = addMinutesToTime(h, m, INTERVIEW_MINUTES);
    await onAddManualSlot({ slot_date: dateISO, start_time: timeToHHMMSS(h, m), end_time: timeToHHMMSS(end.h, end.m), note: addNote || null });
    setSaving(null);
    setAddNote("");
  };

  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)", display: "flex", alignItems: "center", justifyContent: "center", padding: 20, zIndex: 1000 }} onClick={onClose}>
      <div style={{ background: "#fff", borderRadius: 10, padding: 20, width: "min(460px, 100%)", maxHeight: "92vh", overflow: "auto" }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
          <h3 style={{ margin: 0, fontSize: 16 }}>{displayDate}</h3>
          <button onClick={onClose} style={{ background: "transparent", border: "none", fontSize: 22, cursor: "pointer", color: T.slate400, lineHeight: 1 }}>×</button>
        </div>

        {fridayNote && (
          <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>{fridayNote}</div>
        )}

        {vacation && (
          <div style={{ border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "10px 12px", marginBottom: 14 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: "#92400e" }}>
              {vacation.label} — {new Date(weekStartIso(dateISO) + "T12:00:00").toLocaleDateString(undefined, { month: "short", day: "numeric" })} to {new Date(addDaysIso(weekStartIso(dateISO), 6) + "T12:00:00").toLocaleDateString(undefined, { month: "short", day: "numeric" })}
              {vacation.moved ? " (moved)" : ""}
            </div>
            <div style={{ fontSize: 12, color: "#92400e", marginTop: 4 }}>No interview slots this week. Every 13 weeks by default.</div>
            <button
              onClick={() => onMoveVacation(vacation)}
              style={{ marginTop: 8, border: "1px solid #f59e0b", background: "#fff", color: "#92400e", borderRadius: 6, padding: "6px 10px", fontSize: 12, fontWeight: 600, cursor: "pointer" }}
            >
              Move this vacation week…
            </button>
          </div>
        )}

        {slots.length > 0 && (
          <div style={{ display: "flex", flexDirection: "column", gap: 6, marginBottom: 16 }}>
            {slots.map((slot, i) => {
              const key = `${slot.source}-${slot.h}-${slot.m}-${i}`;
              if (slot.status === "scheduled") {
                return (
                  <div key={key} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", border: "1px solid #bfdbfe", background: "#eff6ff", borderRadius: 8, padding: "8px 12px" }}>
                    <div style={{ fontSize: 13, color: "#1e40af" }}>{slot.label} — {slot.candidate.name}</div>
                    <span style={{ fontSize: 11, color: slot.candidate.confirmed ? "#166534" : "#1e40af", fontWeight: 600 }}>{slot.candidate.confirmed ? "Confirmed ✓" : "Scheduled, not confirmed"}</span>
                  </div>
                );
              }
              if (slot.status === "removed") {
                return (
                  <div key={key} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", border: `1px solid ${T.slate200}`, background: T.slate50 || "#f8fafc", borderRadius: 8, padding: "8px 12px" }}>
                    <div style={{ fontSize: 13, color: T.slate400 }}><span style={{ textDecoration: "line-through" }}>{slot.label}{slot.source === "manual" ? " (manual)" : ""}</span>{slot.reason ? <span style={{ marginLeft: 8, fontSize: 11 }}>{slot.reason}</span> : null}</div>
                    {!slot.removedWhole && (
                      <button
                        onClick={() => onRestoreSlot(slot.blackoutId || slot.recurringId, !!slot.recurringId)}
                        style={{ border: "none", background: "transparent", color: T.slate500, cursor: "pointer", fontSize: 12, fontWeight: 600 }}
                      >
                        Restore
                      </button>
                    )}
                  </div>
                );
              }
              return (
                <div key={key} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", border: "1px solid #bbf7d0", background: "#f0fdf4", borderRadius: 8, padding: "8px 12px" }}>
                  <div style={{ fontSize: 13, color: "#166534" }}>{slot.label}{slot.source === "manual" ? " (manual)" : ""}{slot.tier === "secondary" ? " (backup)" : ""}{slot.note ? ` — ${slot.note}` : ""}</div>
                  <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
                    {slot.source === "fixed" && (
                      <button
                        onClick={() => onRemoveSlot(dateISO, slot, true)}
                        title={`Remove every ${weekdayLabel} at ${slot.label}, going forward`}
                        style={{ border: "none", background: "transparent", color: "#166534", cursor: "pointer", fontSize: 12 }}
                      >
                        🔁 every {weekdayLabel}
                      </button>
                    )}
                    <button
                      onClick={() => slot.source === "manual" ? onDeleteManualSlot(slot.manualId) : onRemoveSlot(dateISO, slot, false)}
                      style={{ border: "none", background: "transparent", color: "#991b1b", cursor: "pointer", fontSize: 12, fontWeight: 600 }}
                    >
                      Remove
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {!showAdd ? (
          <button onClick={() => setShowAdd(true)} style={{ padding: "8px 14px", borderRadius: 7, border: `1px solid ${T.slate200}`, background: "#fff", color: T.slate600, fontSize: 13, fontWeight: 600, cursor: "pointer" }}>
            + Add a slot this day
          </button>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 8, borderTop: `1px solid ${T.slate200}` }}>
            <div>
              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Time</div>
              <input type="time" value={addTime} onChange={(e) => setAddTime(e.target.value)} style={{ padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
            </div>
            <div>
              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Note (optional)</div>
              <input type="text" value={addNote} onChange={(e) => setAddNote(e.target.value)} placeholder="e.g. squeezed in for a strong candidate" style={{ width: "100%", padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13, boxSizing: "border-box" }} />
            </div>
            <button
              onClick={handleAdd}
              disabled={saving === "add"}
              style={{ padding: "8px 16px", borderRadius: 7, border: "none", background: saving === "add" ? T.slate200 : (T.blue600 || "#2563eb"), color: "#fff", fontSize: 13, fontWeight: 600, cursor: saving === "add" ? "default" : "pointer", alignSelf: "flex-start" }}
            >
              {saving === "add" ? "Adding…" : "Add slot"}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

export default function InterviewSlotsManager() {
  const [monthDate, setMonthDate] = useState(() => startOfMonth(new Date()));
  const [grid, setGrid] = useState([]);
  const [scheduled, setScheduled] = useState([]);
  const [busyEvents, setBusyEvents] = useState([]);
  const [moveMode, setMoveMode] = useState(null); // { seriesId, originalWeekStart, label } while picking the new week
  const [movingMsg, setMovingMsg] = useState("");
  const [loading, setLoading] = useState(true);
  const [openDay, setOpenDay] = useState(null);

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) return;
    setLoading(true);
    const gridStart = new Date(monthDate);
    gridStart.setDate(1 - gridStart.getDay());
    const gridEnd = new Date(gridStart);
    gridEnd.setDate(gridStart.getDate() + 41);
    const gridStartIso = isoDayLocal(gridStart);
    const gridEndIso = isoDayLocal(gridEnd);
    const gridEndPlus1 = new Date(gridEnd); gridEndPlus1.setDate(gridEndPlus1.getDate() + 1);

    const [gr, sched] = await Promise.all([
      supabase.rpc("interview_slot_grid", { p_agency_id: AGENCY_ID, p_from: gridStartIso, p_to: gridEndIso, p_include_vacation: true }),
      supabase.from("hiring_candidates").select("candidate_name, first_name, interview_scheduled_start, interview_confirmed_at")
        .eq("agency_id", AGENCY_ID).eq("is_test_candidate", false)
        .not("interview_booked_at", "is", null)
        .gte("interview_scheduled_start", gridStart.toISOString())
        .lt("interview_scheduled_start", gridEndPlus1.toISOString()),
    ]);
    if (!gr.error) setGrid(Array.isArray(gr.data) ? gr.data : []);
    if (!sched.error) setScheduled(sched.data || []);
    setLoading(false);

    // Busy events on the Google Calendar for the visible grid — fetched
    // through the scheduler so the calendar shows exactly what the scheduler
    // would skip, and why. Failure just means no busy overlays.
    const busy = await callSchedulerAdmin("calendar_busy", { from: gridStartIso, through: gridEndIso });
    setBusyEvents(busy?.ok && Array.isArray(busy.events) ? busy.events : []);
  }, [monthDate]);

  useEffect(() => { load(); }, [load]);

  const gridByDate = useMemo(() => {
    const m = new Map();
    for (const r of grid) {
      if (!m.has(r.slot_date)) m.set(r.slot_date, []);
      m.get(r.slot_date).push(r);
    }
    return m;
  }, [grid]);

  const scheduledByKey = useMemo(() => {
    const m = new Map();
    for (const c of scheduled) {
      const key = chicagoKey(c.interview_scheduled_start);
      m.set(key, { name: c.candidate_name || c.first_name || "Candidate", confirmed: !!c.interview_confirmed_at });
    }
    return m;
  }, [scheduled]);

  // Vacation weeks (Sun–Sat, keyed by the Sunday), from the grid's labeled rows.
  const vacationByWeek = useMemo(() => {
    const m = new Map();
    for (const r of grid) {
      if (!r.vacation_series_id) continue;
      const wk = weekStartIso(r.slot_date);
      if (!m.has(wk)) m.set(wk, { seriesId: r.vacation_series_id, originalWeekStart: r.vacation_original_week_start, label: r.vacation_label, moved: !!r.vacation_moved });
    }
    return m;
  }, [grid]);

  const ctx = { gridByDate, scheduledByKey, busyEvents };

  // Move a vacation occurrence to the week containing the clicked day. The
  // week it leaves opens back up; the week it lands on closes, and anyone
  // booked there is unbooked and emailed fresh times by the scheduler.
  const handleMoveVacationTo = async (targetDateISO) => {
    if (!moveMode) return;
    const targetWeek = weekStartIso(targetDateISO);
    setMovingMsg("Moving…");
    if (targetWeek === moveMode.originalWeekStart) {
      await supabase.from("hiring_interview_vacation_moves").delete()
        .eq("agency_id", AGENCY_ID).eq("series_id", moveMode.seriesId).eq("original_week_start", moveMode.originalWeekStart);
    } else {
      await supabase.from("hiring_interview_vacation_moves").upsert(
        { agency_id: AGENCY_ID, series_id: moveMode.seriesId, original_week_start: moveMode.originalWeekStart, moved_to_week_start: targetWeek },
        { onConflict: "series_id,original_week_start" },
      );
    }
    const res = await callSchedulerAdmin("move_bookings", { from: targetWeek, through: addDaysIso(targetWeek, 6), reason: "Peter is out of the office that week," });
    const n = Array.isArray(res?.moved) ? res.moved.length : 0;
    setMovingMsg(n > 0 ? `Vacation week moved. ${n} booked candidate${n === 1 ? "" : "s"} emailed new times.` : "Vacation week moved.");
    setMoveMode(null);
    await load();
    setTimeout(() => setMovingMsg(""), 6000);
  };

  const handleAddManualSlot = async (payload) => {
    await supabase.from("hiring_interview_manual_slots").insert({ agency_id: AGENCY_ID, ...payload });
    await load();
  };
  const handleDeleteManualSlot = async (id) => {
    await supabase.from("hiring_interview_manual_slots").delete().eq("id", id);
    await load();
  };
  const handleRemoveSlot = async (dateISO, slot, recurringMode) => {
    const end = addMinutesToTime(slot.h, slot.m, INTERVIEW_MINUTES);
    if (recurringMode) {
      const dateObj = new Date(dateISO + "T12:00:00");
      await supabase.from("hiring_interview_recurring_blackouts").insert({
        agency_id: AGENCY_ID, weekday: dateObj.getDay(),
        start_time: timeToHHMMSS(slot.h, slot.m), end_time: timeToHHMMSS(end.h, end.m),
        starts_on: dateISO, note: null,
      });
    } else {
      await supabase.from("hiring_interview_blackouts").insert({
        agency_id: AGENCY_ID, blackout_date: dateISO,
        start_time: timeToHHMMSS(slot.h, slot.m), end_time: timeToHHMMSS(end.h, end.m),
        note: null,
      });
    }
    await load();
  };
  const handleRestoreSlot = async (id, isRecurring) => {
    if (isRecurring) await supabase.from("hiring_interview_recurring_blackouts").delete().eq("id", id);
    else await supabase.from("hiring_interview_blackouts").delete().eq("id", id);
    await load();
  };

  const days = buildMonthGrid(monthDate);
  const todayIso = isoDayLocal(new Date());
  const thisMonth = monthDate.getMonth();

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        Green = open for scheduling, dashed green = backup (offered once the main times that week are booked), blue = already booked (✓ = confirmed), gray strikethrough = removed — with the reason. Click a day to add a slot or remove one if something comes up.
      </div>
      {moveMode && (
        <div style={{ border: "1px solid #f59e0b", background: "#fffbeb", color: "#92400e", borderRadius: 8, padding: "8px 12px", fontSize: 13, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span>Click any day to move the {moveMode.label.toLowerCase()} to that week. The week it leaves opens back up.</span>
          <button onClick={() => setMoveMode(null)} style={{ border: "none", background: "transparent", color: "#92400e", fontWeight: 600, cursor: "pointer", fontSize: 12 }}>Cancel</button>
        </div>
      )}
      {movingMsg && <div style={{ fontSize: 12, color: T.slate500 }}>{movingMsg}</div>}

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", gap: 6 }}>
          <button onClick={() => setMonthDate(addMonths(monthDate, -1))} style={navBtn}>←</button>
          <button onClick={() => setMonthDate(startOfMonth(new Date()))} style={{ ...navBtn, background: "#eff6ff", color: "#1e40af" }}>Today</button>
          <button onClick={() => setMonthDate(addMonths(monthDate, 1))} style={navBtn}>→</button>
        </div>
        <div style={{ fontSize: 15, fontWeight: 700 }}>{monthLabel(monthDate)}</div>
        <div style={{ width: 90 }} />
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(7, 1fr)", gap: 4 }}>
        {DOW.map((d) => (
          <div key={d} style={{ fontSize: 11, fontWeight: 600, color: T.slate400, textAlign: "center", padding: "4px 0" }}>{d}</div>
        ))}
        {days.map((d) => {
          const iso = isoDayLocal(d);
          const inMonth = d.getMonth() === thisMonth;
          const slots = slotsForDate(iso, ctx);
          return (
            <div
              key={iso}
              onClick={() => moveMode ? handleMoveVacationTo(iso) : setOpenDay(iso)}
              style={{
                minHeight: 76, borderRadius: 8, padding: 6, cursor: "pointer",
                border: `1px solid ${moveMode ? "#f59e0b" : iso === todayIso ? (T.blue600 || "#2563eb") : T.slate200}`,
                background: vacationByWeek.has(weekStartIso(iso)) ? "#fffbeb" : "#fff",
                opacity: inMonth ? 1 : 0.4,
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
                <div style={{ fontSize: 12, fontWeight: iso === todayIso ? 700 : 500, color: iso === todayIso ? (T.blue600 || "#2563eb") : T.slate600 }}>
                  {d.getDate()}
                </div>
                {vacationByWeek.has(weekStartIso(iso)) && d.getDay() >= 1 && d.getDay() <= 5 && (
                  <div style={{ fontSize: 9, color: "#92400e", fontWeight: 600 }}>vacation</div>
                )}
              </div>
              {slots.map((s, i) => (
                <div
                  key={i}
                  style={{
                    fontSize: 9.5, marginTop: 2, lineHeight: 1.4,
                    padding: s.status === "removed" ? 0 : "1px 4px",
                    borderRadius: 4,
                    display: "block",
                    background: s.status === "open" ? (s.tier === "secondary" ? "transparent" : "#dcfce7") : s.status === "scheduled" ? "#e0f2fe" : "transparent",
                    border: s.status === "open" && s.tier === "secondary" ? "1px dashed #86efac" : "none",
                    color: s.status === "open" ? "#166534" : s.status === "scheduled" ? "#1e40af" : T.slate400,
                    textDecoration: s.status === "removed" ? "line-through" : "none",
                    fontWeight: s.status === "scheduled" ? 700 : s.status === "open" ? 600 : 400,
                    width: "100%",
                    boxSizing: "border-box",
                    maxWidth: "100%",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {labelForTime(s.h, s.m)}{s.status === "scheduled" ? ` ${s.candidate.name.split(" ")[0]}${s.candidate.confirmed ? " ✓" : ""}` : (s.tier === "secondary" ? " backup" : "")}
                </div>
              ))}
            </div>
          );
        })}
      </div>

      {loading && <div style={{ fontSize: 12, color: T.slate400 }}>Loading…</div>}

      {openDay && (
        <DayModal
          dateISO={openDay}
          slots={slotsForDate(openDay, ctx)}
          vacation={vacationByWeek.get(weekStartIso(openDay)) || null}
          onMoveVacation={(v) => { setMoveMode(v); setOpenDay(null); }}
          onRemoveSlot={handleRemoveSlot}
          onRestoreSlot={handleRestoreSlot}
          onDeleteManualSlot={handleDeleteManualSlot}
          onAddManualSlot={handleAddManualSlot}
          onClose={() => setOpenDay(null)}
        />
      )}
    </div>
  );
}

const navBtn = {
  padding: "6px 12px", borderRadius: 7, border: "1px solid #e2e8f0",
  background: "#fff", color: "#0f172a", fontSize: 13, fontWeight: 600, cursor: "pointer",
};
