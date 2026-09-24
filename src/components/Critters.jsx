import { useMemo, useSyncExternalStore } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// =====================================================================
// Critters.jsx — the celebration troupe: confetti, the dancing characters
// and the keyframes they dance to. Moved out of ActivityLog.jsx 2026-09-22 so
// the team checklist and the Family page share one copy. The drawings
// themselves live in the dancers table (Peter 2026-09-23) and are read through
// useDancers(). Render <DayDoneStyles /> once wherever characters dance.
// =====================================================================
const CONFETTI_COLORS = [T.blue, T.green, T.amber, T.red, T.purple, T.teal, T.gold, T.pink];

export function DayDoneStyles() {
  return (
    <style>{`
      @keyframes nwCrumble {
        0%   { opacity: 1; transform: none; filter: blur(0px); }
        20%  { transform: translateY(-7px) rotate(-0.7deg); }
        100% { opacity: 0; transform: translateY(54px) rotate(2.6deg) scale(0.93); filter: blur(5px); }
      }
      .nw-crumble > * { animation: nwCrumble 900ms cubic-bezier(.55,.06,.68,.19) forwards; }
      .nw-crumble > *:nth-child(2) { animation-delay: 130ms; }

      @keyframes nwFall { from { transform: translateY(-14vh); } to { transform: translateY(114vh); } }
      @keyframes nwSway { from { transform: translateX(-26px); } to { transform: translateX(26px); } }
      @keyframes nwSpin { from { transform: rotate(0deg); }     to { transform: rotate(900deg); } }

      @keyframes nwRise {
        from { opacity: 0; transform: translateY(26px) scale(0.97); }
        to   { opacity: 1; transform: none; }
      }
      @keyframes nwPop {
        0%   { opacity: 0; transform: scale(0.82); }
        55%  { opacity: 1; transform: scale(1.08); }
        100% { opacity: 1; transform: scale(1); }
      }

      /* One set of moves, shared by every animal. Each drawing says where the
         part turns from with its own transform-origin; the class only carries
         the movement. --d offsets a whole animal so a row of them is not in
         lockstep, and it inherits down to every moving part inside it. */
      @keyframes nwDance {
        0%   { transform: translateY(0) rotate(-4deg); }
        25%  { transform: translateY(-12px) rotate(0deg); }
        50%  { transform: translateY(0) rotate(4deg); }
        75%  { transform: translateY(-12px) rotate(0deg); }
        100% { transform: translateY(0) rotate(-4deg); }
      }
      @keyframes nwWag   { 0%, 100% { transform: rotate(-20deg); } 50% { transform: rotate(22deg); } }
      @keyframes nwSwayL { 0%, 100% { transform: rotate(-8deg); }  50% { transform: rotate(13deg); } }
      @keyframes nwSwayR { 0%, 100% { transform: rotate(8deg); }   50% { transform: rotate(-13deg); } }
      @keyframes nwUp    { 0%, 100% { transform: translateY(0); }  50% { transform: translateY(-8px); } }
      @keyframes nwPeck  { 0%, 62%, 100% { transform: rotate(0deg); } 78% { transform: rotate(15deg); } }

      .nw-dance { animation: nwDance 900ms ease-in-out infinite; }
      .nw-wag   { animation: nwWag 260ms ease-in-out infinite; }
      .nw-swayL { animation: nwSwayL 900ms ease-in-out infinite; }
      .nw-swayR { animation: nwSwayR 900ms ease-in-out infinite; }
      .nw-up    { animation: nwUp 900ms ease-in-out infinite; }
      .nw-upB   { animation: nwUp 900ms ease-in-out infinite; }
      .nw-peck  { animation: nwPeck 900ms ease-in-out infinite; }
      .nw-dance, .nw-wag, .nw-swayL, .nw-swayR, .nw-up, .nw-upB, .nw-peck {
        transform-box: fill-box; transform-origin: 50% 50%; animation-delay: var(--d, 0ms);
      }
      .nw-upB { animation-delay: calc(var(--d, 0ms) + 450ms); }

      @media (prefers-reduced-motion: reduce) {
        .nw-crumble > *, .nw-dance, .nw-wag, .nw-swayL, .nw-swayR,
        .nw-up, .nw-upB, .nw-peck { animation: none !important; }
      }
    `}</style>
  );
}

// Falls from the top of the screen, over everything, catching no clicks.
export function Confetti() {
  const pieces = useMemo(() => Array.from({ length: 44 }, (_, i) => ({
    id: i,
    left: Math.random() * 100,
    delay: Math.random() * 2.2,
    fall: 3.6 + Math.random() * 2.6,
    sway: 1.1 + Math.random() * 1.1,
    spin: 0.9 + Math.random() * 1.4,
    w: 6 + Math.round(Math.random() * 6),
    h: 9 + Math.round(Math.random() * 9),
    round: Math.random() < 0.3,
    color: CONFETTI_COLORS[i % CONFETTI_COLORS.length],
  })), []);
  return (
    <div aria-hidden="true" style={{ position: "fixed", inset: 0, overflow: "hidden", pointerEvents: "none", zIndex: 50 }}>
      {pieces.map(p => (
        <div key={p.id} style={{ position: "absolute", top: 0, left: `${p.left}%`, animation: `nwFall ${p.fall}s linear ${p.delay}s forwards` }}>
          <div style={{ animation: `nwSway ${p.sway}s ease-in-out ${p.delay}s infinite alternate` }}>
            <div style={{
              width: p.w, height: p.h, boxSizing: "border-box",
              background: p.color, borderRadius: p.round ? "50%" : 2,
              animation: `nwSpin ${p.spin}s linear ${p.delay}s infinite`,
            }} />
          </div>
        </div>
      ))}
    </div>
  );
}

// ── The troupe ────────────────────────────────────────────────────────
// Every dancing character is a row in the dancers table (Peter 2026-09-23):
// key, label, kind and svg. kind "animal" is one of the twelve a kid can have
// as their animal; kind "guest" is a guest dancer. svg is just the shapes on
// the shared 200x200 stage; Dancer supplies the frame, the shadow and the beat.
// Peter 2026-09-17: one at random each day, the whole lot when the week is done.
//
// The table is read once per page load and shared by every caller.
let roster = null;      // the rows, in sort_order, once loaded
let inFlight = false;
const listeners = new Set();

function loadRoster() {
  if (roster || inFlight) return;
  inFlight = true;
  supabase
    .from("dancers")
    .select("key, label, kind, svg")
    .eq("agency_id", AGENCY_ID)
    .eq("is_active", true)
    .order("sort_order", { ascending: true })
    .then(({ data, error }) => {
      inFlight = false;
      if (error) { console.error("Could not load the dancers:", error.message); return; }
      roster = Array.isArray(data) ? data : [];
      listeners.forEach(fn => fn());
    });
}

function subscribeRoster(fn) {
  listeners.add(fn);
  loadRoster();
  return () => { listeners.delete(fn); };
}
const getRoster = () => roster;

const NONE = [];
let lists = { rows: undefined, all: NONE, animals: NONE, guests: NONE };
const listsFor = (rows) => {
  if (lists.rows !== rows) {
    const all = rows || NONE;
    lists = {
      rows,
      all,
      animals: all.filter(d => d.kind === "animal"),
      guests: all.filter(d => d.kind === "guest"),
    };
  }
  return lists;
};

// Every dancing character, in the table's order.
//   all      every character
//   animals  the twelve a kid can have (the week-done parade)
//   guests   the guest dancers
//   ready    false until the table has been read
export function useDancers() {
  const rows = useSyncExternalStore(subscribeRoster, getRoster, getRoster);
  const { all, animals, guests } = listsFor(rows);
  return { ready: rows !== null, all, animals, guests };
}

// A steady random number for a seed: the same seed always gets the same number.
const seedHash = (seed) => {
  const str = String(seed ?? "");
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
};

// The shadow a dancing character stands on.
const SHADOW = '<ellipse cx="100" cy="186" rx="50" ry="7" fill="#000000" opacity="0.08"></ellipse>';

// delay offsets the whole character so a row of them is not in lockstep.
// An unknown key dances as the first animal, as it always has.
export function Dancer({ which, size = 176, delay = 0 }) {
  const { all, animals } = useDancers();
  const a = all.find(d => d.key === which) || animals[0];
  return (
    <svg width={size} height={size} viewBox="0 0 200 200" role="img" aria-label={`A dancing ${a ? a.label : "character"}`}
         style={{ "--d": `${delay}ms`, overflow: "visible" }}>
      <g className="nw-dance" dangerouslySetInnerHTML={{ __html: a ? SHADOW + a.svg : "" }} />
    </svg>
  );
}

// Same character, standing still (no dance frame, no shadow). For name pills.
export function CritterIcon({ which, size = 22 }) {
  const { all } = useDancers();
  const a = all.find(d => d.key === which);
  if (!a) return null;
  return (
    <svg width={size} height={size} viewBox="0 0 200 200" role="img" aria-label={a.label}
         style={{ flexShrink: 0, display: "block" }} dangerouslySetInnerHTML={{ __html: a.svg }} />
  );
}

// A done mark (Peter 2026-09-23): one of the characters instead of a check,
// dancing in place. The pick is random but steady, so the same chore on the same
// day always gets the same character, and each one starts on its own beat. Only
// the whole body bops, so a page full of them stays light. Render
// <DoneDancerStyles /> once on any page that shows them.
export function DoneDancer({ seed, title, size = 26 }) {
  const { all } = useDancers();
  const h = seedHash(seed);
  const a = all.length ? all[h % all.length] : null;
  return (
    <span className="nw-bop" title={title} role="img" aria-label={title || (a ? a.label : "Done")}
      style={{ display: "inline-block", flexShrink: 0, verticalAlign: "middle", lineHeight: 0, animationDelay: `-${h % 900}ms` }}>
      <svg width={size} height={size} viewBox="0 0 200 200" aria-hidden="true" style={{ display: "block", overflow: "visible" }}>
        <g className="nw-still" dangerouslySetInnerHTML={{ __html: a ? a.svg : "" }} />
      </svg>
    </span>
  );
}

export function DoneDancerStyles() {
  return (
    <style>{`
      @keyframes nwBop {
        0%, 100% { transform: translateY(0) rotate(-8deg); }
        25%      { transform: translateY(-3px) rotate(0deg); }
        50%      { transform: translateY(0) rotate(8deg); }
        75%      { transform: translateY(-3px) rotate(0deg); }
      }
      .nw-bop { animation: nwBop 900ms ease-in-out infinite; transform-origin: 50% 90%; }
      .nw-still * { animation: none !important; }
      @media (prefers-reduced-motion: reduce) { .nw-bop { animation: none !important; } }
    `}</style>
  );
}
