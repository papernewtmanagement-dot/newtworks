import { useState, useEffect, useCallback, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// Month-view calendar of actual interview slot instances — not an abstract
// "blackout" calendar. Every day shows its bookable times with real status:
// open (available to candidates), scheduled (booked, candidate shown), or
// removed (taken off the table). You can add an extra one-off slot to any
// day, delete an individual open slot if something comes up, or stop a
// standing weekday slot going forward. The hiring-interview-scheduler edge
// function reads the same removed/manual tables when it computes offers.

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

// Mirrors PRIMARY_TIMES_BY_WEEKDAY / SECONDARY_TIMES_BY_WEEKDAY in the
// hiring-interview-scheduler edge function — the actual predefined interview
// times (Peter directive 2026-09-11). Keep these in sync if the schedule
// ever changes. Backup (secondary) times are only offered to candidates once
// the primary times in the next 7 days are booked.
const PRIMARY_TIMES_BY_WEEKDAY = {
  1: [{ h: 10, m: 0, label: "10:00 AM" }, { h: 13, m: 0, label: "1:00 PM" }, { h: 15, m: 30, label: "3:30 PM" }], // Mon
  2: [{ h: 10, m: 0, label: "10:00 AM" }, { h: 13, m: 0, label: "1:00 PM" }, { h: 15, m: 30, label: "3:30 PM" }], // Tue
  3: [{ h: 10, m: 0, label: "10:00 AM" }, { h: 13, m: 0, label: "1:00 PM" }],                                     // Wed
  4: [{ h: 13, m: 0, label: "1:00 PM" }, { h: 15, m: 30, label: "3:30 PM" }],                                     // Thu
  5: [{ h: 10, m: 0, label: "10:00 AM" }, { h: 13, m: 0, label: "1:00 PM" }, { h: 15, m: 30, label: "3:30 PM" }], // Fri
};
const SECONDARY_TIMES_BY_WEEKDAY = {
  1: [{ h: 10, m: 45, label: "10:45 AM" }, { h: 16, m: 15, label: "4:15 PM" }], // Mon
  2: [{ h: 10, m: 45, label: "10:45 AM" }, { h: 16, m: 15, label: "4:15 PM" }], // Tue
  3: [{ h: 10, m: 45, label: "10:45 AM" }],                                     // Wed (no afternoon backup)
  4: [{ h: 16, m: 15, label: "4:15 PM" }],                                      // Thu (no morning backup)
  5: [{ h: 10, m: 45, label: "10:45 AM" }, { h: 16, m: 15, label: "4:15 PM" }], // Fri
};
const FIXED_TIMES_BY_WEEKDAY = Object.fromEntries(
  [1, 2, 3, 4, 5].map((d) => [d, [
    ...PRIMARY_TIMES_BY_WEEKDAY[d].map((t) => ({ ...t, tier: "primary" })),
    ...SECONDARY_TIMES_BY_WEEKDAY[d].map((t) => ({ ...t, tier: "secondary" })),
  ]])
);
const INTERVIEW_MINUTES = 30;
const TZ = "America/Chicago";

// Mirrors fridayTimeAllowed in the edge function: first Friday of the month
// has no morning times; third Friday has no midday or end-of-day times.
function fridayOrdinal(d) { return d.getDay() === 5 ? Math.ceil(d.getDate() / 7) : null; }
function fridayTimeAllowed(d, hour) {
  const nth = fridayOrdinal(d);
  if (nth === 1 && hour < 12) return false;
  if (nth === 3 && hour >= 12) return false;
  return true;
}
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
// Every vacation week (Sunday key) that lands inside [fromISO, toISO],
// honoring per-occurrence moves. Returns Map<weekStart, {seriesId, originalWeekStart, label}>.
function vacationWeeksInRange(series, moves, fromISO, toISO) {
  const out = new Map();
  const fromMs = Date.parse(weekStartIso(fromISO) + "T12:00:00") - 7 * 86400000;
  const toMs = Date.parse(weekStartIso(toISO) + "T12:00:00") + 7 * 86400000;
  for (const sr of series) {
    if (sr.is_active === false) continue;
    const moved = new Map(moves.filter((m) => m.series_id === sr.id).map((m) => [m.original_week_start, m.moved_to_week_start]));
    const anchorMs = Date.parse(sr.anchor_week_start + "T12:00:00");
    const step = Math.max(1, Number(sr.interval_weeks) || 13) * 7 * 86400000;
    let k = Math.floor((fromMs - anchorMs) / step); if (k < 0) k = 0;
    for (let ms = anchorMs + k * step; ms <= toMs; ms += step) {
      const key = isoDayLocal(new Date(ms));
      const target = moved.get(key) || key;
      out.set(target, { seriesId: sr.id, originalWeekStart: key, label: sr.label, moved: target !== key });
    }
    for (const [orig, to] of moved) {
      const toMsX = Date.parse(to + "T12:00:00");
      if (toMsX >= fromMs && toMsX <= toMs && !out.has(to)) out.set(to, { seriesId: sr.id, originalWeekStart: orig, label: sr.label, moved: true });
    }
  }
  return out;
}
function pad2(n) { return String(n).padStart(2, "0"); }
function timeToHHMMSS(h, m) { return `${pad2(h)}:${pad2(m)}:00`; }
function addMinutesToTime(h, m, mins) {
  const total = h * 60 + m + mins;
  return { h: Math.floor(total / 60) % 24, m: total % 60 };
}
function labelForTime(h, m) {
  const match = Object.values(FIXED_TIMES_BY_WEEKDAY).flat().find((s) => s.h === h && s.m === m);
  if (match) return match.label;
  const period = h < 12 ? "AM" : "PM";
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${pad2(m)} ${period}`;
}
function recurringAppliesOn(r, dateISO, weekday) {
  return r.weekday === weekday && dateISO >= r.starts_on && (!r.ends_on || dateISO <= r.ends_on);
}
// Chicago-local "YYYY-MM-DD|HH:MM" key for matching a scheduled interview's
// UTC timestamp back to a slot instance's local date+time.
function chicagoKey(isoUtc) {
  const dtf = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  const parts = dtf.formatToParts(new Date(isoUtc)).reduce((acc, p) => { acc[p.type] = p.value; return acc; }, {});
  const hh = parts.hour === "24" ? "00" : parts.hour;
  return `${parts.year}-${parts.month}-${parts.day}|${hh}:${parts.minute}`;
}

// Build the effective list of slot instances for one date: fixed schedule +
// manual additions, each tagged open / scheduled / removed.
function slotsForDate(dateISO, dateObj, { manualByDate, blackoutsByDate, recurring, scheduledByKey, vacationByWeek, busyEvents }) {
  const weekday = dateObj.getDay();
  const vacation = vacationByWeek.get(weekStartIso(dateISO)) || null;
  const fixed = (FIXED_TIMES_BY_WEEKDAY[weekday] || [])
    .filter((s) => weekday !== 5 || fridayTimeAllowed(dateObj, s.h))
    .map((s) => ({ h: s.h, m: s.m, label: s.label, source: "fixed", tier: s.tier }));
  const manual = (manualByDate.get(dateISO) || []).map((r) => {
    const [h, m] = r.start_time.split(":").map(Number);
    return { h, m, label: labelForTime(h, m), source: "manual", manualId: r.id, note: r.note };
  });
  const oneOffRemovals = blackoutsByDate.get(dateISO) || [];
  const wholeDayRemoved = oneOffRemovals.some((r) => !r.start_time) ||
    recurring.some((r) => !r.start_time && recurringAppliesOn(r, dateISO, weekday));

  const templated = [...fixed, ...manual];
  const templatedKeys = new Set(templated.map((s) => timeToHHMMSS(s.h, s.m).slice(0, 5)));

  // Any booked interview whose time doesn't match a fixed/manual slot
  // (e.g. booked before the schedule was fixed) still needs to show up.
  const extraScheduled = [];
  for (const [key, candidate] of scheduledByKey) {
    if (!key.startsWith(`${dateISO}|`)) continue;
    const hm = key.split("|")[1];
    if (templatedKeys.has(hm)) continue;
    const [h, m] = hm.split(":").map(Number);
    extraScheduled.push({ h, m, label: labelForTime(h, m), source: "scheduled-only", status: "scheduled", candidate });
  }

  const resolved = templated.map((slot) => {
    const key = `${dateISO}|${timeToHHMMSS(slot.h, slot.m).slice(0, 5)}`;
    const scheduled = scheduledByKey.get(key);
    if (scheduled) return { ...slot, status: "scheduled", candidate: scheduled };
    if (vacation) return { ...slot, status: "removed", removedWhole: true, reason: vacation.label };
    if (wholeDayRemoved) return { ...slot, status: "removed", removedWhole: true };
    const oneOffMatch = oneOffRemovals.find((r) => r.start_time === timeToHHMMSS(slot.h, slot.m));
    if (oneOffMatch) return { ...slot, status: "removed", blackoutId: oneOffMatch.id };
    const recurringMatch = recurring.find((r) => r.start_time === timeToHHMMSS(slot.h, slot.m) && recurringAppliesOn(r, dateISO, weekday));
    if (recurringMatch) return { ...slot, status: "removed", recurringId: recurringMatch.id };
    const busy = busyOverlap(dateISO, slot, busyEvents);
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

function busyOverlap(dateISO, slot, busyEvents) {
  if (!busyEvents || busyEvents.length === 0) return null;
  const start = new Date(`${dateISO}T${timeToHHMMSS(slot.h, slot.m)}`);
  const end = new Date(start.getTime() + INTERVIEW_MINUTES * 60000);
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
  const [blackouts, setBlackouts] = useState([]);
  const [recurring, setRecurring] = useState([]);
  const [manualSlots, setManualSlots] = useState([]);
  const [scheduled, setScheduled] = useState([]);
  const [vacationSeries, setVacationSeries] = useState([]);
  const [vacationMoves, setVacationMoves] = useState([]);
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

    const [bo, rec, man, sched, vs, vm] = await Promise.all([
      supabase.from("hiring_interview_blackouts").select("id, blackout_date, start_time, end_time, note")
        .eq("agency_id", AGENCY_ID).gte("blackout_date", gridStartIso).lte("blackout_date", gridEndIso),
      supabase.from("hiring_interview_recurring_blackouts").select("id, weekday, start_time, end_time, note, starts_on, ends_on")
        .eq("agency_id", AGENCY_ID),
      supabase.from("hiring_interview_manual_slots").select("id, slot_date, start_time, end_time, note")
        .eq("agency_id", AGENCY_ID).gte("slot_date", gridStartIso).lte("slot_date", gridEndIso),
      supabase.from("hiring_candidates").select("candidate_name, first_name, interview_scheduled_start, interview_confirmed_at")
        .eq("agency_id", AGENCY_ID).eq("is_test_candidate", false)
        .not("interview_booked_at", "is", null)
        .gte("interview_scheduled_start", gridStart.toISOString())
        .lt("interview_scheduled_start", gridEndPlus1.toISOString()),
      supabase.from("hiring_interview_vacation_series").select("id, label, anchor_week_start, interval_weeks, is_active")
        .eq("agency_id", AGENCY_ID),
      supabase.from("hiring_interview_vacation_moves").select("id, series_id, original_week_start, moved_to_week_start")
        .eq("agency_id", AGENCY_ID),
    ]);
    if (!bo.error) setBlackouts(bo.data || []);
    if (!rec.error) setRecurring(rec.data || []);
    if (!man.error) setManualSlots(man.data || []);
    if (!sched.error) setScheduled(sched.data || []);
    if (!vs.error) setVacationSeries(vs.data || []);
    if (!vm.error) setVacationMoves(vm.data || []);
    setLoading(false);

    // Busy events on the Google Calendar for the visible grid — fetched
    // through the scheduler so the calendar shows exactly what the scheduler
    // would skip, and why. Failure just means no busy overlays.
    const busy = await callSchedulerAdmin("calendar_busy", { from: gridStartIso, through: gridEndIso });
    setBusyEvents(busy?.ok && Array.isArray(busy.events) ? busy.events : []);
  }, [monthDate]);

  useEffect(() => { load(); }, [load]);

  const blackoutsByDate = useMemo(() => {
    const m = new Map();
    for (const r of blackouts) {
      if (!m.has(r.blackout_date)) m.set(r.blackout_date, []);
      m.get(r.blackout_date).push(r);
    }
    return m;
  }, [blackouts]);

  const manualByDate = useMemo(() => {
    const m = new Map();
    for (const r of manualSlots) {
      if (!m.has(r.slot_date)) m.set(r.slot_date, []);
      m.get(r.slot_date).push(r);
    }
    return m;
  }, [manualSlots]);

  const scheduledByKey = useMemo(() => {
    const m = new Map();
    for (const c of scheduled) {
      const key = chicagoKey(c.interview_scheduled_start);
      m.set(key, { name: c.candidate_name || c.first_name || "Candidate", confirmed: !!c.interview_confirmed_at });
    }
    return m;
  }, [scheduled]);

  const vacationByWeek = useMemo(() => {
    const gridStart = new Date(monthDate); gridStart.setDate(1 - gridStart.getDay());
    const gridEnd = new Date(gridStart); gridEnd.setDate(gridStart.getDate() + 41);
    return vacationWeeksInRange(vacationSeries, vacationMoves, isoDayLocal(gridStart), isoDayLocal(gridEnd));
  }, [vacationSeries, vacationMoves, monthDate]);

  const ctx = { manualByDate, blackoutsByDate, recurring, scheduledByKey, vacationByWeek, busyEvents };

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
          const slots = slotsForDate(iso, d, ctx);
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
          slots={slotsForDate(openDay, new Date(openDay + "T12:00:00"), ctx)}
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
