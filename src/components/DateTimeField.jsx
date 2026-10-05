// DateTimeField.jsx — a date box and a time box side by side, in place of the
// browser's combined date-and-time box. The combined box drops a half-made
// pick (a date with no time yet) the moment you click away, and it is wide
// enough to push out of a narrow pop-up. Here each half keeps what you picked
// until the other half is filled in.
//
// value / onChange use the same "YYYY-MM-DDTHH:MM" text the combined box did,
// or "" when empty. defaultDate fills the date when only a time is picked.
import { useEffect, useState } from "react";
import { T } from "../lib/theme.js";

const split = (v) => (v ? [v.slice(0, 10), v.slice(11, 16)] : ["", ""]);

const box = {
  width: "100%", minWidth: 0, maxWidth: "100%", boxSizing: "border-box",
  padding: "8px 10px", borderRadius: 7, border: `1px solid ${T.slate200}`,
  background: T.white, fontSize: 13, color: T.slate900, outline: "none",
  fontFamily: "inherit",
};

export default function DateTimeField({ value, onChange, defaultDate = "" }) {
  const [date, setDate] = useState(split(value)[0]);
  const [time, setTime] = useState(split(value)[1]);

  // A value set from outside (a loaded entry, a reset) shows up here. An empty
  // value only clears the boxes when both halves were filled; a half-made pick
  // stays put.
  useEffect(() => {
    if (value) {
      const [d, t] = split(value);
      setDate(d); setTime(t);
    } else {
      setDate(d => (d && time ? "" : d));
      setTime(t => (date && t ? "" : t));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  const send = (d, t) => onChange(d && t ? `${d}T${t}` : "");

  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1.25fr) minmax(0, 1fr)", gap: 8 }}>
      <input type="date" value={date} style={box}
        onChange={(e) => { const d = e.target.value; setDate(d); send(d, time); }} />
      <input type="time" value={time} style={box}
        onChange={(e) => {
          const t = e.target.value;
          const d = date || (t ? defaultDate : "");
          setTime(t); if (d !== date) setDate(d); send(d, t);
        }} />
    </div>
  );
}
