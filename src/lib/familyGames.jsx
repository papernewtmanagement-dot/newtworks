import { useEffect, useState } from "react";
import { supabase, AGENCY_ID } from "./supabase.js";
import { T } from "./theme.js";

// =========================================================================
// familyGames.jsx — shared by the Family games (WordWorm.jsx, MathBlast.jsx).
// One job each:
//   useFamilyPlayers(game)   the active kids, their chore-chart animal and saved bests for that game
//   recordFamilyGame(...)    saves one finished game (database: family_game_record)
//   PlayerPicker             the "who's playing?" chips, Guest included
//   ageOf(birthday)          whole years
// Bests live on each kid's own row (family_kids.game_bests). Guest games are not saved.
// =========================================================================

export function ageOf(birthday) {
  if (!birthday) return null;
  const b = new Date(birthday + "T12:00:00");
  if (!Number.isFinite(b.getTime())) return null;
  const now = new Date();
  let a = now.getFullYear() - b.getFullYear();
  const m = now.getMonth() - b.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < b.getDate())) a -= 1;
  return a;
}

export function useFamilyPlayers(game) {
  const [players, setPlayers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error: err } = await supabase
        .from("family_kids")
        .select("id,name,birthday,sort_order,animal,game_bests")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true)
        .order("sort_order");
      if (!alive) return;
      if (err) setError(err.message);
      setPlayers((data || []).map(k => ({
        id: k.id,
        name: k.name,
        age: ageOf(k.birthday),
        animal: k.animal || null, // their chore-chart character (dancers.key)
        bests: (k.game_bests && k.game_bests[game]) || {},
      })));
      setLoading(false);
    })();
    return () => { alive = false; };
  }, [game, nonce]);

  return { players, loading, error, reload: () => setNonce(n => n + 1) };
}

// Returns { saved, isBest, bests } — never throws; a failed save shows as saved:false.
export async function recordFamilyGame(kidId, game, score, detail) {
  if (!kidId) return { saved: false, isBest: false, bests: null };
  const { data, error } = await supabase.rpc("family_game_record", {
    p_kid_id: kidId, p_game: game, p_score: Math.max(0, Math.round(score || 0)), p_detail: detail || {},
  });
  if (error) return { saved: false, isBest: false, bests: null, error: error.message };
  const isBest = !!data && Number(data.best) === Math.round(score || 0) && data.best_at === data.last_at;
  return { saved: true, isBest, bests: data };
}

export function PlayerPicker({ players, value, onChange, accent = T.blue }) {
  const chip = (id, label, sub) => {
    const on = value === id;
    return (
      <button
        key={id || "guest"}
        type="button"
        onClick={() => onChange(id)}
        style={{
          flexShrink: 0, padding: "8px 14px", borderRadius: 999, cursor: "pointer",
          border: `2px solid ${on ? accent : T.slate300}`,
          background: on ? accent : T.white, color: on ? T.white : T.slate800,
          fontFamily: "inherit", fontSize: 14, fontWeight: 600, lineHeight: 1.2, textAlign: "center",
        }}
      >
        {label}
        {sub ? <div style={{ fontSize: 11, fontWeight: 500, opacity: 0.85 }}>{sub}</div> : null}
      </button>
    );
  };
  return (
    <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
      {(players || []).map(p => chip(p.id, p.name, p.bests?.best != null ? `Best ${Number(p.bests.best).toLocaleString()}` : null))}
      {chip("", "Guest", "not saved")}
    </div>
  );
}
