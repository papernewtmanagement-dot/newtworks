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

// Mirrors FIXED_TIMES_BY_WEEKDAY in the hiring-interview-scheduler edge
// function — the actual predefined interview times. Keep these two in sync
// if the schedule ever changes.
const FIXED_TIMES_BY_WEEKDAY = {
  1: [{ h: 10, m: 0, label: "10:00 AM" }, { h: 15, m: 30, label: "3:30 PM" }], // Mon
  2: [{ h: 10, m: 0, label: "10:00 AM" }, { h: 15, m: 30, label: "3:30 PM" }], // Tue
  3: [{ h: 10, m: 0, label: "10:00 AM" }],                                     // Wed
  4: [{ h: 15, m: 30, label: "3:30 PM" }],                                     // Thu
  5: [{ h: 12, m: 30, label: "12:30 PM" }],                                    // Fri
};
const INTERVIEW_MINUTES = 35;
const TZ = "America/Chicago";

function isThirdFriday(d) {
  return d.getDay() === 5 && Math.ceil(d.getDate() / 7) === 3;
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
function slotsForDate(dateISO, dateObj, { manualByDate, blackoutsByDate, recurring, scheduledByKey }) {
  const weekday = dateObj.getDay();
  const fridayExcluded = isThirdFriday(dateObj);
  const fixed = fridayExcluded ? [] : (FIXED_TIMES_BY_WEEKDAY[weekday] || []).map((s) => ({ h: s.h, m: s.m, label: s.label, source: "fixed" }));
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
    if (wholeDayRemoved) return { ...slot, status: "removed", removedWhole: true };
    const oneOffMatch = oneOffRemovals.find((r) => r.start_time === timeToHHMMSS(slot.h, slot.m));
    if (oneOffMatch) return { ...slot, status: "removed", blackoutId: oneOffMatch.id };
    const recurringMatch = recurring.find((r) => r.start_time === timeToHHMMSS(slot.h, slot.m) && recurringAppliesOn(r, dateISO, weekday));
    if (recurringMatch) return { ...slot, status: "removed", recurringId: recurringMatch.id };
    return { ...slot, status: "open" };
  });

  return [...resolved, ...extraScheduled].sort((a, b) => (a.h * 60 + a.m) - (b.h * 60 + b.m));
}

function DayModal({ dateISO, slots, onRemoveSlot, onRestoreSlot, onDeleteManualSlot, onAddManualSlot, onClose }) {
  const [addTime, setAddTime] = useState("09:00");
  const [addNote, setAddNote] = useState("");
  const [saving, setSaving] = useState(null);
  const [showAdd, setShowAdd] = useState(false);
  const dateObj = new Date(dateISO + "T12:00:00");
  const displayDate = dateObj.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  const weekdayLabel = DOW_FULL[dateObj.getDay()];
  const fridayExcluded = isThirdFriday(dateObj);

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

        {fridayExcluded && slots.length === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
            This is the 3rd Friday of the month — no interviews are ever offered on this day by default.
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
                    <span style={{ fontSize: 11, color: "#1e40af", fontWeight: 600 }}>Scheduled</span>
                  </div>
                );
              }
              if (slot.status === "removed") {
                return (
                  <div key={key} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", border: `1px solid ${T.slate200}`, background: T.slate50 || "#f8fafc", borderRadius: 8, padding: "8px 12px" }}>
                    <div style={{ fontSize: 13, color: T.slate400, textDecoration: "line-through" }}>{slot.label}{slot.source === "manual" ? " (manual)" : ""}</div>
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
                  <div style={{ fontSize: 13, color: "#166534" }}>{slot.label}{slot.source === "manual" ? " (manual)" : ""}{slot.note ? ` — ${slot.note}` : ""}</div>
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

    const [bo, rec, man, sched] = await Promise.all([
      supabase.from("hiring_interview_blackouts").select("id, blackout_date, start_time, end_time, note")
        .eq("agency_id", AGENCY_ID).gte("blackout_date", gridStartIso).lte("blackout_date", gridEndIso),
      supabase.from("hiring_interview_recurring_blackouts").select("id, weekday, start_time, end_time, note, starts_on, ends_on")
        .eq("agency_id", AGENCY_ID),
      supabase.from("hiring_interview_manual_slots").select("id, slot_date, start_time, end_time, note")
        .eq("agency_id", AGENCY_ID).gte("slot_date", gridStartIso).lte("slot_date", gridEndIso),
      supabase.from("hiring_candidates").select("candidate_name, first_name, interview_scheduled_start")
        .eq("agency_id", AGENCY_ID).eq("is_test_candidate", false)
        .not("interview_booked_at", "is", null)
        .gte("interview_scheduled_start", gridStart.toISOString())
        .lt("interview_scheduled_start", gridEndPlus1.toISOString()),
    ]);
    if (!bo.error) setBlackouts(bo.data || []);
    if (!rec.error) setRecurring(rec.data || []);
    if (!man.error) setManualSlots(man.data || []);
    if (!sched.error) setScheduled(sched.data || []);
    setLoading(false);
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
      m.set(key, { name: c.candidate_name || c.first_name || "Candidate" });
    }
    return m;
  }, [scheduled]);

  const ctx = { manualByDate, blackoutsByDate, recurring, scheduledByKey };

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
        Green = open for scheduling, blue = already booked, gray strikethrough = removed. Click a day to add a slot or remove one if something comes up.
      </div>

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
              onClick={() => setOpenDay(iso)}
              style={{
                minHeight: 76, borderRadius: 8, padding: 6, cursor: "pointer",
                border: `1px solid ${iso === todayIso ? (T.blue600 || "#2563eb") : T.slate200}`,
                background: "#fff",
                opacity: inMonth ? 1 : 0.4,
              }}
            >
              <div style={{ fontSize: 12, fontWeight: iso === todayIso ? 700 : 500, color: iso === todayIso ? (T.blue600 || "#2563eb") : T.slate600 }}>
                {d.getDate()}
              </div>
              {slots.slice(0, 4).map((s, i) => (
                <div
                  key={i}
                  style={{
                    fontSize: 9.5, marginTop: 2, lineHeight: 1.4,
                    padding: s.status === "removed" ? 0 : "1px 4px",
                    borderRadius: 4,
                    display: "inline-block",
                    background: s.status === "open" ? "#bbf7d0" : s.status === "scheduled" ? "#2563eb" : "transparent",
                    color: s.status === "open" ? "#14532d" : s.status === "scheduled" ? "#ffffff" : T.slate400,
                    textDecoration: s.status === "removed" ? "line-through" : "none",
                    fontWeight: s.status === "scheduled" ? 700 : s.status === "open" ? 600 : 400,
                    width: "fit-content",
                    maxWidth: "100%",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {labelForTime(s.h, s.m)}{s.status === "scheduled" ? ` ${s.candidate.name.split(" ")[0]}` : ""}
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
