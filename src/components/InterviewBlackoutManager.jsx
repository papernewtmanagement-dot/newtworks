import { useState, useEffect, useCallback } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// Lets Peter block off interview slots when something comes up. A row with
// no start/end time blocks the whole day; a row with both blocks just that
// window. Read directly by the hiring-interview-scheduler edge function
// when it computes offers, and re-checked live at claim time too.
export default function InterviewBlackoutManager() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [date, setDate] = useState("");
  const [wholeDay, setWholeDay] = useState(true);
  const [startTime, setStartTime] = useState("09:00");
  const [endTime, setEndTime] = useState("17:00");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) return;
    setLoading(true);
    const { data, error } = await supabase
      .from("hiring_interview_blackouts")
      .select("id, blackout_date, start_time, end_time, note")
      .eq("agency_id", AGENCY_ID)
      .gte("blackout_date", new Date().toISOString().slice(0, 10))
      .order("blackout_date", { ascending: true });
    if (!error) setRows(data || []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const handleAdd = async () => {
    if (!date) return;
    setSaving(true);
    const { error } = await supabase.from("hiring_interview_blackouts").insert({
      agency_id: AGENCY_ID,
      blackout_date: date,
      start_time: wholeDay ? null : startTime,
      end_time: wholeDay ? null : endTime,
      note: note || null,
    });
    setSaving(false);
    if (!error) {
      setDate(""); setNote(""); setWholeDay(true);
      load();
    }
  };

  const handleDelete = async (id) => {
    await supabase.from("hiring_interview_blackouts").delete().eq("id", id);
    load();
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        Block off dates or specific time windows so they never get offered to a candidate. Anything already on your calendar is checked automatically — this is for things not on the calendar yet, or a day you just want reserved.
      </div>

      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 16, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "flex-end" }}>
        <div>
          <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Date</div>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} style={{ padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
        </div>
        <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: T.slate600 }}>
          <input type="checkbox" checked={wholeDay} onChange={(e) => setWholeDay(e.target.checked)} />
          Whole day
        </label>
        {!wholeDay && (
          <>
            <div>
              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>From</div>
              <input type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} style={{ padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
            </div>
            <div>
              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>To</div>
              <input type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} style={{ padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
            </div>
          </>
        )}
        <div style={{ flex: 1, minWidth: 140 }}>
          <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Note (optional)</div>
          <input type="text" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. out of office" style={{ width: "100%", padding: "6px 8px", border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 13 }} />
        </div>
        <button
          onClick={handleAdd}
          disabled={!date || saving}
          style={{
            padding: "7px 16px", borderRadius: 7, border: "none",
            background: !date || saving ? T.slate200 : (T.blue600 || "#2563eb"),
            color: "#fff", fontSize: 13, fontWeight: 600, cursor: !date || saving ? "default" : "pointer",
          }}
        >
          {saving ? "Adding…" : "Add blackout"}
        </button>
      </div>

      {loading ? (
        <div style={{ fontSize: 12, color: T.slate400 }}>Loading…</div>
      ) : rows.length === 0 ? (
        <div style={{ fontSize: 12, color: T.slate400 }}>No upcoming blackouts.</div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          {rows.map((r) => (
            <div key={r.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "8px 12px" }}>
              <div style={{ fontSize: 13 }}>
                <strong>{r.blackout_date}</strong>{" "}
                <span style={{ color: T.slate500 }}>
                  {r.start_time && r.end_time ? `${r.start_time.slice(0, 5)}–${r.end_time.slice(0, 5)}` : "whole day"}
                  {r.note ? ` — ${r.note}` : ""}
                </span>
              </div>
              <button
                onClick={() => handleDelete(r.id)}
                style={{ border: "none", background: "transparent", color: T.slate400, cursor: "pointer", fontSize: 12 }}
              >
                Remove
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
