import { useState, useEffect } from "react";
import { supabase } from "../lib/supabase.js";
import { T, BAND } from "../lib/theme.js";

// One person's Win the Quarter trip outlook (Peter 2026-10-08): what the trip pays
// this quarter, and their local trip ideas and travel spots, each marked by whether
// that money covers it. Everything comes from trip_outlook(), which only answers the
// person and an admin. Used on the CPR page (the viewer's own) and on Earnings.

const money = (n) => "$" + Math.round(Number(n) || 0).toLocaleString();

const REACH = {
  yes:  { label: "In reach",        fg: BAND.Great.ink,   bg: BAND.Great.fill },
  mvp:  { label: "In reach as MVP", fg: T.gold,           bg: T.goldLt },
  no:   { label: "Not this quarter", fg: T.slate500,      bg: T.slate100 },
};

export default function TripOutlook({ teamId, isMe = true, firstName = "", style = null }) {
  const [o, setO] = useState(null);
  useEffect(() => {
    let alive = true;
    if (!supabase || !teamId) { setO(null); return () => { alive = false; }; }
    supabase.rpc("trip_outlook", { p_team_id: teamId })
      .then(({ data, error }) => { if (alive) setO(error ? null : data || null); });
    return () => { alive = false; };
  }, [teamId]);

  const trips = Array.isArray(o?.trips) ? o.trips : [];
  if (!o || trips.length === 0) return null;
  const local = trips.filter(t => t?.kind === "local");
  const travel = trips.filter(t => t?.kind === "travel");
  const who = isMe ? "you" : firstName || "they";

  const row = (t, i) => {
    const r = REACH[t?.reach];
    return (
      <div key={i} style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", padding: "3px 0" }}>
        <span style={{ fontSize: 13, color: T.slate800 }}>{t.place}</span>
        <span style={{ fontSize: 12, color: T.slate500 }}>
          {t.cost != null ? "about " + money(t.cost) : "cost not set yet"}
        </span>
        {r && (
          <span style={{ fontSize: 11, fontWeight: 700, color: r.fg, background: r.bg, borderRadius: 999, padding: "2px 8px" }}>
            {r.label}
          </span>
        )}
      </div>
    );
  };

  return (
    <div style={{ border: `1px solid ${T.slate200}`, background: T.white, borderRadius: 10, padding: "12px 14px", ...(style || {}) }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Win the Quarter trip</div>
      <div style={{ fontSize: 12.5, color: T.slate600, marginTop: 3, lineHeight: 1.5 }}>
        {o.on_pace
          ? `This quarter's trip is on pace to pay ${who === "you" ? "you" : who} ${money(o.rest_dollars)}, or ${money(o.mvp_dollars)} as MVP.`
          : `The team isn't on pace for the trip yet. It takes ${o.wins_needed || 9} won weeks out of 13.`}
      </div>
      {local.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <div style={{ fontSize: 11.5, fontWeight: 700, color: T.slate700, marginBottom: 2 }}>Local trips</div>
          {local.map(row)}
        </div>
      )}
      {travel.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <div style={{ fontSize: 11.5, fontWeight: 700, color: T.slate700, marginBottom: 2 }}>
            {isMe ? "Where you want to go" : `Where ${firstName || "they"} want${firstName ? "s" : ""} to go`}
          </div>
          {travel.map(row)}
        </div>
      )}
    </div>
  );
}
