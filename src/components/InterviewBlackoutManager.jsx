import { useState, useEffect, useCallback, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// Month-view calendar for interview scheduling blackouts, styled after the
// Team > PTO weekly calendar (TimeOffRequests.jsx HistoryView). Supports
// one-off dated blackouts (hiring_interview_blackouts) and standing weekly
// rules (hiring_interview_recurring_blackouts) — both are checked by the
// hiring-interview-scheduler edge function when it offers slots.

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

function DayModal({ dateISO, existing, recurring, onAdd, onDelete, onAddRecurring, onDeleteRecurring, onClose }) {
  const [showCustom, setShowCustom] = useState(false);
  const [startTime, setStartTime] = useState("09:00");
  const [endTime, setEndTime] = useState("17:00");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(null);
  const dateObj = new Date(dateISO + "T12:00:00");
  const displayDate = dateObj.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  const weekday = dateObj.getDay();
  const weekdayLabel = DOW_FULL[weekday];

  const wholeDayRow = existing.find((r) => !r.start_time);
  const wholeDayRecurring = recurring.find((r) => !r.start_time && recurringAppliesOn(r, dateISO, weekday));
  const isFridayExcluded = isThirdFriday(dateObj);
  const daySlots = isFridayExcluded ? [] : (FIXED_TIMES_BY_WEEKDAY[weekday] || []);

  const findExistingForSlot = (h, m) => existing.find((r) => r.start_time === timeToHHMMSS(h, m));
  const findRecurringForSlot = (h, m) => recurring.find((r) => r.start_time === timeToHHMMSS(h, m) && recurringAppliesOn(r, dateISO, weekday));

  const handleBlockSlot = async (slot) => {
    setSaving(`slot-${slot.h}-${slot.m}`);
    const end = addMinutesToTime(slot.h, slot.m, INTERVIEW_MINUTES);
    await onAdd({ blackout_date: dateISO, start_time: timeToHHMMSS(slot.h, slot.m), end_time: timeToHHMMSS(end.h, end.m), note: null });
    setSaving(null);
  };
  const handleBlockSlotRecurring = async (slot) => {
    setSaving(`slotrec-${slot.h}-${slot.m}`);
    const end = addMinutesToTime(slot.h, slot.m, INTERVIEW_MINUTES);
    await onAddRecurring({ weekday, start_time: timeToHHMMSS(slot.h, slot.m), end_time: timeToHHMMSS(end.h, end.m), starts_on: dateISO, note: null });
    setSaving(null);
  };
  const handleBlockWholeDay = async () => {
    setSaving("whole");
    await onAdd({ blackout_date: dateISO, start_time: null, end_time: null, note: note || null });
    setSaving(null);
    setNote("");
  };
  const handleBlockWholeDayRecurring = async () => {
    setSaving("wholerec");
    await onAddRecurring({ weekday, start_time: null, end_time: null, starts_on: dateISO, note: note || null });
    setSaving(null);
    setNote("");
  };
  const handleAddCustom = async () => {
    setSaving("custom");
    await onAdd({ blackout_date: dateISO, start_time: startTime, end_time: endTime, note: note || null });
    setSaving(null);
    setNote("");
  };

  const otherBlocked = existing.filter((r) => r.start_time && !daySlots.some((s) => timeToHHMMSS(s.h, s.m) === r.start_time));

  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)", display: "flex", alignItems: "center", justifyContent: "center", padding: 20, zIndex: 1000 }} onClick={onClose}>
      <div style={{ background: "#fff", borderRadius: 10, padding: 20, width: "min(460px, 100%)", maxHeight: "92vh", overflow: "auto" }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
          <h3 style={{ margin: 0, fontSize: 16 }}>{displayDate}</h3>
          <button onClick={onClose} style={{ background: "transparent", border: "none", fontSize: 22, cursor: "pointer", color: T.slate400, lineHeight: 1 }}>×</button>
        </div>

        {(wholeDayRow || wholeDayRecurring) ? (
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", background: "#fecaca", borderRadius: 8, padding: "10px 12px", marginBottom: 10 }}>
            <div style={{ fontSize: 13, color: "#7c2d12" }}>
              Whole day blocked{wholeDayRecurring ? ` — every ${weekdayLabel}` : ""}{(wholeDayRow?.note || wholeDayRecurring?.note) ? ` — ${wholeDayRow?.note || wholeDayRecurring?.note}` : ""}
            </div>
            <button
              onClick={() => wholeDayRow ? onDelete(wholeDayRow.id) : onDeleteRecurring(wholeDayRecurring.id)}
              style={{ border: "none", background: "transparent", color: "#7c2d12", cursor: "pointer", fontSize: 12, fontWeight: 600 }}
            >
              {wholeDayRecurring ? "Stop recurring" : "Unblock"}
            </button>
          </div>
        ) : (
          <>
            {isFridayExcluded && (
              <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
                This is the 3rd Friday of the month — no interviews are ever offered on this day.
              </div>
            )}

            {daySlots.length > 0 && (
              <div style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>Interview times this day</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                  {daySlots.map((slot) => {
                    const key = `slot-${slot.h}-${slot.m}`;
                    const existingRow = findExistingForSlot(slot.h, slot.m);
                    const recurringRow = findRecurringForSlot(slot.h, slot.m);
                    const blocked = existingRow || recurringRow;
                    return (
                      <div key={key} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", border: `1px solid ${blocked ? "#fca5a5" : T.slate200}`, background: blocked ? "#fef2f2" : "#fff", borderRadius: 8, padding: "8px 12px" }}>
                        <div style={{ fontSize: 13, color: blocked ? "#991b1b" : T.slate700 }}>
                          {slot.label}{recurringRow ? ` — blocked (every ${weekdayLabel})` : existingRow ? " — blocked" : ""}
                        </div>
                        {blocked ? (
                          <button
                            onClick={() => existingRow ? onDelete(existingRow.id) : onDeleteRecurring(recurringRow.id)}
                            style={{ border: "none", background: "transparent", color: "#991b1b", cursor: "pointer", fontSize: 12, fontWeight: 600 }}
                          >
                            {recurringRow ? "Stop recurring" : "Unblock"}
                          </button>
                        ) : (
                          <div style={{ display: "flex", gap: 6 }}>
                            <button onClick={() => handleBlockSlot(slot)} disabled={saving === key} style={{ border: "none", background: T.slate100 || "#f1f5f9", color: T.slate700 || "#334155", cursor: saving === key ? "default" : "pointer", fontSize: 12, fontWeight: 600, padding: "4px 10px", borderRadius: 6 }}>
                              {saving === key ? "…" : "Block"}
                            </button>
                            <button
                              onClick={() => handleBlockSlotRecurring(slot)}
                              disabled={saving === `slotrec-${slot.h}-${slot.m}`}
                              title={`Block every ${weekdayLabel} at ${slot.label}, going forward`}
                              style={{ border: `1px solid ${T.slate200}`, background: "#fff", color: T.slate500, cursor: "pointer", fontSize: 12, fontWeight: 600, padding: "4px 10px", borderRadius: 6 }}
                            >
                              🔁 Every {weekdayLabel}
                            </button>
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

            {otherBlocked.length > 0 && (
              <div style={{ display: "flex", flexDirection: "column", gap: 6, marginBottom: 16 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: T.slate600 }}>Other blocked windows</div>
                {otherBlocked.map((r) => (
                  <div key={r.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", background: T.slate50 || "#f8fafc", border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "8px 12px" }}>
                    <div style={{ fontSize: 13 }}>{r.start_time.slice(0, 5)}–{r.end_time.slice(0, 5)}{r.note ? ` — ${r.note}` : ""}</div>
                    <button onClick={() => onDelete(r.id)} style={{ border: "none", background: "transparent", color: T.slate400, cursor: "pointer", fontSize: 12 }}>Remove</button>
                  </div>
                ))}
              </div>
            )}

            <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              <button onClick={handleBlockWholeDay} disabled={saving === "whole"} style={{ padding: "8px 14px", borderRadius: 7, border: `1px solid ${T.slate200}`, background: "#fff", color: "#991b1b", fontSize: 13, fontWeight: 600, cursor: saving === "whole" ? "default" : "pointer" }}>
                {saving === "whole" ? "Blocking…" : "Block whole day"}
              </button>
              <button onClick={handleBlockWholeDayRecurring} disabled={saving === "wholerec"} title={`Block every ${weekdayLabel}, going forward`} style={{ padding: "8px 14px", borderRadius: 7, border: `1px solid ${T.slate200}`, background: "#fff", color: T.slate500, fontSize: 13, fontWeight: 600, cursor: saving === "wholerec" ? "default" : "pointer" }}>
                {saving === "wholerec" ? "…" : `🔁 Every ${weekdayLabel}`}
              </button>
              <button onClick={() => setShowCustom((v) => !v)} style={{ padding: "8px 14px", borderRadius: 7, border: `1px solid ${T.slate200}`, background: "#fff", color: T.slate600, fontSize: 13, fontWeight: 600, cursor: "pointer" }}>
                {showCustom ? "Hide custom range" : "Custom time range"}
              </button>
            </div>

            {showCustom && (
              <div style={{ display: "flex", flexDirection: "column", gap: 10, marginTop: 12, paddingTop: 12, borderTop: `1px solid ${T.slate200}` }}>
                <div style={{ display: "flex", gap: 10 }}>
                  <div>
                    <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>From</div>
                    <input type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} style={{ padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
                  </div>
                  <div>
                    <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>To</div>
                    <input type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} style={{ padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
                  </div>
                </div>
                <div>
                  <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Note (optional)</div>
                  <input type="text" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. out of office" style={{ width: "100%", padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13, boxSizing: "border-box" }} />
                </div>
                <button
                  onClick={handleAddCustom}
                  disabled={saving === "custom"}
                  style={{ padding: "8px 16px", borderRadius: 7, border: "none", background: saving === "custom" ? T.slate200 : (T.blue600 || "#2563eb"), color: "#fff", fontSize: 13, fontWeight: 600, cursor: saving === "custom" ? "default" : "pointer", alignSelf: "flex-start" }}
                >
                  {saving === "custom" ? "Adding…" : "Add custom blackout (this day only)"}
                </button>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function RecurringRulesList({ recurring, onDelete }) {
  if (recurring.length === 0) return null;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: T.slate600 }}>Standing (recurring) blackouts</div>
      {recurring.map((r) => (
        <div key={r.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", background: "#fff", border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "8px 12px" }}>
          <div style={{ fontSize: 13 }}>
            Every {DOW_FULL[r.weekday]} — {r.start_time ? labelForTime(...r.start_time.split(":").map(Number)) : "whole day"}
            {r.ends_on ? ` (through ${r.ends_on})` : ""}
            {r.note ? ` — ${r.note}` : ""}
          </div>
          <button onClick={() => onDelete(r.id)} style={{ border: "none", background: "transparent", color: T.slate400, cursor: "pointer", fontSize: 12 }}>Remove</button>
        </div>
      ))}
    </div>
  );
}

export default function InterviewBlackoutManager() {
  const [monthDate, setMonthDate] = useState(() => startOfMonth(new Date()));
  const [rows, setRows] = useState([]);
  const [recurringRows, setRecurringRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [openDay, setOpenDay] = useState(null);

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) return;
    setLoading(true);
    const gridStart = new Date(monthDate);
    gridStart.setDate(1 - gridStart.getDay());
    const gridEnd = new Date(gridStart);
    gridEnd.setDate(gridStart.getDate() + 41);
    const [oneOff, standing] = await Promise.all([
      supabase
        .from("hiring_interview_blackouts")
        .select("id, blackout_date, start_time, end_time, note")
        .eq("agency_id", AGENCY_ID)
        .gte("blackout_date", isoDayLocal(gridStart))
        .lte("blackout_date", isoDayLocal(gridEnd))
        .order("blackout_date", { ascending: true }),
      supabase
        .from("hiring_interview_recurring_blackouts")
        .select("id, weekday, start_time, end_time, note, starts_on, ends_on")
        .eq("agency_id", AGENCY_ID)
        .order("weekday", { ascending: true }),
    ]);
    if (!oneOff.error) setRows(oneOff.data || []);
    if (!standing.error) setRecurringRows(standing.data || []);
    setLoading(false);
  }, [monthDate]);

  useEffect(() => { load(); }, [load]);

  const byDate = useMemo(() => {
    const m = new Map();
    for (const r of rows) {
      if (!m.has(r.blackout_date)) m.set(r.blackout_date, []);
      m.get(r.blackout_date).push(r);
    }
    return m;
  }, [rows]);

  // Effective blocks per visible day = one-off rows + any recurring rule
  // that applies on that date. Used only for calendar-cell display.
  const effectiveByDate = useMemo(() => {
    const m = new Map();
    for (const [dateISO, list] of byDate) m.set(dateISO, [...list]);
    const days = buildMonthGrid(monthDate);
    for (const d of days) {
      const iso = isoDayLocal(d);
      const weekday = d.getDay();
      const applicable = recurringRows.filter((r) => recurringAppliesOn(r, iso, weekday));
      if (applicable.length === 0) continue;
      const existingList = m.get(iso) || [];
      m.set(iso, [...existingList, ...applicable]);
    }
    return m;
  }, [byDate, recurringRows, monthDate]);

  const handleAdd = async (payload) => {
    await supabase.from("hiring_interview_blackouts").insert({ agency_id: AGENCY_ID, ...payload });
    await load();
  };
  const handleDelete = async (id) => {
    await supabase.from("hiring_interview_blackouts").delete().eq("id", id);
    await load();
  };
  const handleAddRecurring = async (payload) => {
    await supabase.from("hiring_interview_recurring_blackouts").insert({ agency_id: AGENCY_ID, ...payload });
    await load();
  };
  const handleDeleteRecurring = async (id) => {
    await supabase.from("hiring_interview_recurring_blackouts").delete().eq("id", id);
    await load();
  };

  const days = buildMonthGrid(monthDate);
  const todayIso = isoDayLocal(new Date());
  const thisMonth = monthDate.getMonth();

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        Click a day to block it — a single time, the whole day, or every occurrence of that weekday going forward. Anything already on your calendar is checked automatically; this is for anything not on there yet.
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
          const blocks = effectiveByDate.get(iso) || [];
          const isWholeDay = blocks.some((r) => !r.start_time);
          return (
            <div
              key={iso}
              onClick={() => setOpenDay(iso)}
              style={{
                minHeight: 72, borderRadius: 8, padding: 6, cursor: "pointer",
                border: `1px solid ${iso === todayIso ? (T.blue600 || "#2563eb") : T.slate200}`,
                background: isWholeDay ? "#fecaca" : blocks.length > 0 ? "#fed7aa" : "#fff",
                opacity: inMonth ? 1 : 0.4,
              }}
            >
              <div style={{ fontSize: 12, fontWeight: iso === todayIso ? 700 : 500, color: iso === todayIso ? (T.blue600 || "#2563eb") : T.slate600 }}>
                {d.getDate()}
              </div>
              {isWholeDay ? (
                <div style={{ fontSize: 10, color: "#7c2d12", marginTop: 4, lineHeight: 1.3 }}>Whole day</div>
              ) : (
                blocks.slice(0, 3).map((b, i) => (
                  <div key={i} style={{ fontSize: 9.5, color: "#7c2d12", marginTop: 2, lineHeight: 1.2 }}>
                    {labelForTime(...b.start_time.split(":").map(Number))}
                  </div>
                ))
              )}
            </div>
          );
        })}
      </div>

      {loading && <div style={{ fontSize: 12, color: T.slate400 }}>Loading…</div>}

      <RecurringRulesList recurring={recurringRows} onDelete={handleDeleteRecurring} />

      {openDay && (
        <DayModal
          dateISO={openDay}
          existing={byDate.get(openDay) || []}
          recurring={recurringRows}
          onAdd={handleAdd}
          onDelete={handleDelete}
          onAddRecurring={handleAddRecurring}
          onDeleteRecurring={handleDeleteRecurring}
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
