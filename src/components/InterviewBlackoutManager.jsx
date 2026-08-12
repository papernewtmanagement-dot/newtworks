import { useState, useEffect, useCallback, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// Month-view calendar for interview scheduling blackouts, styled after the
// Team > PTO weekly calendar (TimeOffRequests.jsx HistoryView). Blackouts
// have no per-person dimension, so this is a simple month grid rather than
// a roster grid: click any day to add or manage blackouts on it.

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

function DayModal({ dateISO, existing, onAdd, onDelete, onClose }) {
  const [wholeDay, setWholeDay] = useState(existing.length === 0);
  const [startTime, setStartTime] = useState("09:00");
  const [endTime, setEndTime] = useState("17:00");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const displayDate = new Date(dateISO + "T12:00:00").toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });

  const handleAdd = async () => {
    setSaving(true);
    await onAdd({ blackout_date: dateISO, start_time: wholeDay ? null : startTime, end_time: wholeDay ? null : endTime, note: note || null });
    setSaving(false);
    setNote("");
  };

  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)", display: "flex", alignItems: "center", justifyContent: "center", padding: 20, zIndex: 1000 }} onClick={onClose}>
      <div style={{ background: "#fff", borderRadius: 10, padding: 20, width: "min(440px, 100%)", maxHeight: "92vh", overflow: "auto" }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
          <h3 style={{ margin: 0, fontSize: 16 }}>{displayDate}</h3>
          <button onClick={onClose} style={{ background: "transparent", border: "none", fontSize: 22, cursor: "pointer", color: T.slate400, lineHeight: 1 }}>×</button>
        </div>

        {existing.length > 0 && (
          <div style={{ display: "flex", flexDirection: "column", gap: 6, marginBottom: 16 }}>
            {existing.map((r) => (
              <div key={r.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", background: T.slate50 || "#f8fafc", border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "8px 12px" }}>
                <div style={{ fontSize: 13 }}>
                  {r.start_time && r.end_time ? `${r.start_time.slice(0, 5)}–${r.end_time.slice(0, 5)}` : "Whole day"}
                  {r.note ? ` — ${r.note}` : ""}
                </div>
                <button onClick={() => onDelete(r.id)} style={{ border: "none", background: "transparent", color: T.slate400, cursor: "pointer", fontSize: 12 }}>Remove</button>
              </div>
            ))}
          </div>
        )}

        <div style={{ fontSize: 12, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>
          {existing.some((r) => !r.start_time) ? "Whole day already blacked out" : "Add a blackout"}
        </div>
        {!existing.some((r) => !r.start_time) && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: T.slate600 }}>
              <input type="checkbox" checked={wholeDay} onChange={(e) => setWholeDay(e.target.checked)} />
              Whole day
            </label>
            {!wholeDay && (
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
            )}
            <div>
              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Note (optional)</div>
              <input type="text" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. out of office" style={{ width: "100%", padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13, boxSizing: "border-box" }} />
            </div>
            <button
              onClick={handleAdd}
              disabled={saving}
              style={{ padding: "8px 16px", borderRadius: 7, border: "none", background: saving ? T.slate200 : (T.blue600 || "#2563eb"), color: "#fff", fontSize: 13, fontWeight: 600, cursor: saving ? "default" : "pointer" }}
            >
              {saving ? "Adding…" : "Add blackout"}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

export default function InterviewBlackoutManager() {
  const [monthDate, setMonthDate] = useState(() => startOfMonth(new Date()));
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [openDay, setOpenDay] = useState(null);

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) return;
    setLoading(true);
    const gridStart = new Date(monthDate);
    gridStart.setDate(1 - gridStart.getDay());
    const gridEnd = new Date(gridStart);
    gridEnd.setDate(gridStart.getDate() + 41);
    const { data, error } = await supabase
      .from("hiring_interview_blackouts")
      .select("id, blackout_date, start_time, end_time, note")
      .eq("agency_id", AGENCY_ID)
      .gte("blackout_date", isoDayLocal(gridStart))
      .lte("blackout_date", isoDayLocal(gridEnd))
      .order("blackout_date", { ascending: true });
    if (!error) setRows(data || []);
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

  const handleAdd = async (payload) => {
    await supabase.from("hiring_interview_blackouts").insert({ agency_id: AGENCY_ID, ...payload });
    await load();
  };
  const handleDelete = async (id) => {
    await supabase.from("hiring_interview_blackouts").delete().eq("id", id);
    await load();
  };

  const days = buildMonthGrid(monthDate);
  const todayIso = isoDayLocal(new Date());
  const thisMonth = monthDate.getMonth();

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        Click a day to block it (whole day or a specific window) or manage blackouts already on it. Anything on your calendar is checked automatically — this is for anything not on there yet.
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
          const blackouts = byDate.get(iso) || [];
          const isWholeDay = blackouts.some((r) => !r.start_time);
          const isPartial = !isWholeDay && blackouts.length > 0;
          return (
            <div
              key={iso}
              onClick={() => setOpenDay(iso)}
              style={{
                minHeight: 64, borderRadius: 8, padding: 6, cursor: "pointer",
                border: `1px solid ${iso === todayIso ? (T.blue600 || "#2563eb") : T.slate200}`,
                background: isWholeDay ? "#fecaca" : isPartial ? "#fed7aa" : "#fff",
                opacity: inMonth ? 1 : 0.4,
              }}
            >
              <div style={{ fontSize: 12, fontWeight: iso === todayIso ? 700 : 500, color: iso === todayIso ? (T.blue600 || "#2563eb") : T.slate600 }}>
                {d.getDate()}
              </div>
              {blackouts.length > 0 && (
                <div style={{ fontSize: 10, color: "#7c2d12", marginTop: 4, lineHeight: 1.3 }}>
                  {isWholeDay ? "Blacked out" : `${blackouts.length} window${blackouts.length > 1 ? "s" : ""}`}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {loading && <div style={{ fontSize: 12, color: T.slate400 }}>Loading…</div>}

      {openDay && (
        <DayModal
          dateISO={openDay}
          existing={byDate.get(openDay) || []}
          onAdd={handleAdd}
          onDelete={handleDelete}
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
