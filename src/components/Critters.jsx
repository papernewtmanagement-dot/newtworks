import { useMemo } from "react";
import { T } from "../lib/theme.js";

// =====================================================================
// Critters.jsx — the celebration troupe: confetti, twelve dancing animals
// on one 200x200 stage, and the keyframes they dance to. Moved out of
// ActivityLog.jsx 2026-09-22 so the team checklist and the Family page
// share one copy. Render <DayDoneStyles /> once wherever animals dance.
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
// Twelve animals, all drawn on the same 200x200 stage so they can stand
// next to each other. Each one is just the shapes; Dancer supplies the
// frame, the shadow and the beat.
// Peter 2026-09-17: one at random each day, the whole lot when the week
// is done.

function PugArt() {
  return (
    <>
      <g className="nw-wag" style={{ transformOrigin: "6% 92%" }}>
        <path d="M146 130 c15 -3 21 -13 15 -21 c-7 -8 -19 -4 -19 5 c0 8 9 10 13 5"
              fill="none" stroke="#C9964E" strokeWidth="9" strokeLinecap="round" />
      </g>
      <rect x="62" y="150" width="22" height="26" rx="10" fill="#C9964E" />
      <rect x="116" y="150" width="22" height="26" rx="10" fill="#C9964E" />
      <ellipse cx="100" cy="136" rx="48" ry="34" fill="#D8A85B" />
      <ellipse cx="100" cy="147" rx="30" ry="20" fill="#E8C288" />
      <g className="nw-up"  style={{ transformOrigin: "50% 0%" }}><rect x="56" y="138" width="21" height="36" rx="10" fill="#D8A85B" /></g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}><rect x="123" y="138" width="21" height="36" rx="10" fill="#D8A85B" /></g>
      <circle cx="100" cy="78" r="42" fill="#D8A85B" />
      <g className="nw-swayL" style={{ transformOrigin: "72% 6%" }}><path d="M62 46 q-15 -9 -17 10 q-3 21 17 25 z" fill="#3A322C" /></g>
      <g className="nw-swayR" style={{ transformOrigin: "28% 6%" }}><path d="M138 46 q15 -9 17 10 q3 21 -17 25 z" fill="#3A322C" /></g>
      <path d="M84 52 q16 -10 32 0" fill="none" stroke="#B9873F" strokeWidth="4.5" strokeLinecap="round" />
      <ellipse cx="100" cy="88" rx="32" ry="28" fill="#3A322C" />
      <ellipse cx="100" cy="97" rx="20" ry="15" fill="#2A2422" />
      <ellipse cx="100" cy="89" rx="9" ry="6.5" fill="#15100F" />
      <path d="M92 105 q8 8 16 0" fill="none" stroke="#15100F" strokeWidth="3" strokeLinecap="round" />
      <path d="M95 108 q5 13 10 0 z" fill="#E87A8F" />
      <circle cx="80" cy="72" r="10.5" fill="#15100F" />
      <circle cx="120" cy="72" r="10.5" fill="#15100F" />
      <circle cx="83.5" cy="68.5" r="3.6" fill="#FFFFFF" />
      <circle cx="123.5" cy="68.5" r="3.6" fill="#FFFFFF" />
    </>
  );
}

function AxolotlArt() {
  return (
    <>
      <g className="nw-wag" style={{ transformOrigin: "50% 8%" }}>
        <path d="M100 158 q30 12 36 32 q-36 8 -72 0 q6 -20 36 -32 z" fill="#F5B8CE" />
      </g>
      <rect x="62" y="158" width="18" height="22" rx="9" fill="#EE9FBB" />
      <rect x="120" y="158" width="18" height="22" rx="9" fill="#EE9FBB" />
      <ellipse cx="100" cy="140" rx="38" ry="32" fill="#F2AFC6" />
      <ellipse cx="100" cy="150" rx="24" ry="19" fill="#FBD9E6" />
      <g className="nw-up"  style={{ transformOrigin: "50% 0%" }}><rect x="56" y="128" width="17" height="30" rx="8" fill="#F2AFC6" /></g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}><rect x="127" y="128" width="17" height="30" rx="8" fill="#F2AFC6" /></g>
      <g className="nw-swayL" style={{ transformOrigin: "95% 65%" }}>
        <path d="M62 70 L36 52" stroke="#EE8FB2" strokeWidth="6" strokeLinecap="round" />
        <path d="M60 84 L30 74" stroke="#EE8FB2" strokeWidth="6" strokeLinecap="round" />
        <path d="M62 98 L34 98" stroke="#EE8FB2" strokeWidth="6" strokeLinecap="round" />
        <circle cx="35" cy="51" r="6.5" fill="#F7A9C6" />
        <circle cx="29" cy="73" r="6.5" fill="#F7A9C6" />
        <circle cx="33" cy="98" r="6.5" fill="#F7A9C6" />
      </g>
      <g className="nw-swayR" style={{ transformOrigin: "5% 65%" }}>
        <path d="M138 70 L164 52" stroke="#EE8FB2" strokeWidth="6" strokeLinecap="round" />
        <path d="M140 84 L170 74" stroke="#EE8FB2" strokeWidth="6" strokeLinecap="round" />
        <path d="M138 98 L166 98" stroke="#EE8FB2" strokeWidth="6" strokeLinecap="round" />
        <circle cx="165" cy="51" r="6.5" fill="#F7A9C6" />
        <circle cx="171" cy="73" r="6.5" fill="#F7A9C6" />
        <circle cx="167" cy="98" r="6.5" fill="#F7A9C6" />
      </g>
      <ellipse cx="100" cy="86" rx="42" ry="33" fill="#F5B8CE" />
      <circle cx="84" cy="80" r="5.5" fill="#2A2422" />
      <circle cx="116" cy="80" r="5.5" fill="#2A2422" />
      <circle cx="86" cy="78" r="1.9" fill="#FFFFFF" />
      <circle cx="118" cy="78" r="1.9" fill="#FFFFFF" />
      <circle cx="74" cy="95" r="7" fill="#F58AAF" opacity="0.55" />
      <circle cx="126" cy="95" r="7" fill="#F58AAF" opacity="0.55" />
      <path d="M88 96 q12 11 24 0" fill="none" stroke="#C96D8C" strokeWidth="3.5" strokeLinecap="round" />
    </>
  );
}

function BeagleArt() {
  return (
    <>
      {/* White beagle. Every brown marking sits on HIS right, which is the
          left as you look at him: the big body patch and the big ear spots.
          His left ear carries the small ones. The near-white coat is a shade
          off pure white with a soft outline, or he vanishes into the card.
          Peter 2026-09-17. */}
      <defs>
        <clipPath id="nwBeagleBody"><ellipse cx="100" cy="138" rx="43" ry="32" /></clipPath>
        <clipPath id="nwBeagleEarHisR"><ellipse cx="63" cy="88" rx="14" ry="29" /></clipPath>
        <clipPath id="nwBeagleEarHisL"><ellipse cx="137" cy="88" rx="14" ry="29" /></clipPath>
      </defs>
      <g className="nw-wag" style={{ transformOrigin: "10% 90%" }}>
        <path d="M140 128 q24 -10 28 -30" fill="none" stroke="#F4EFE6" strokeWidth="10" strokeLinecap="round" />
      </g>
      <rect x="64" y="150" width="20" height="28" rx="9" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" />
      <rect x="116" y="150" width="20" height="28" rx="9" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" />
      <ellipse cx="100" cy="138" rx="43" ry="32" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" />
      <g clipPath="url(#nwBeagleBody)">
        <ellipse cx="76" cy="150" rx="18" ry="17" fill="#A06A33" />
      </g>
      <g className="nw-up"  style={{ transformOrigin: "50% 0%" }}><rect x="60" y="140" width="19" height="34" rx="9" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" /></g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}><rect x="121" y="140" width="19" height="34" rx="9" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" /></g>
      <circle cx="100" cy="78" r="37" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" />
      <g className="nw-swayL" style={{ transformOrigin: "50% 6%" }}>
        <ellipse cx="63" cy="88" rx="14" ry="29" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" />
        <g clipPath="url(#nwBeagleEarHisR)">
          <ellipse cx="60" cy="71" rx="13" ry="14" fill="#A06A33" />
          <ellipse cx="68" cy="101" rx="12" ry="13" fill="#A06A33" />
        </g>
      </g>
      <g className="nw-swayR" style={{ transformOrigin: "50% 6%" }}>
        <ellipse cx="137" cy="88" rx="14" ry="29" fill="#F4EFE6" stroke="#D8D1C2" strokeWidth="2" />
        <g clipPath="url(#nwBeagleEarHisL)">
          <circle cx="134" cy="72" r="4.5" fill="#A06A33" />
          <circle cx="142" cy="84" r="3.5" fill="#A06A33" />
          <circle cx="133" cy="95" r="4" fill="#A06A33" />
          <circle cx="140" cy="106" r="3" fill="#A06A33" />
        </g>
      </g>
      <ellipse cx="100" cy="100" rx="17" ry="13" fill="#F4EFE6" />
      <ellipse cx="100" cy="92" rx="8.5" ry="6.5" fill="#2A2422" />
      <path d="M92 105 q8 8 16 0" fill="none" stroke="#9A9184" strokeWidth="3" strokeLinecap="round" />
      <circle cx="84" cy="72" r="6.5" fill="#2A2422" />
      <circle cx="116" cy="72" r="6.5" fill="#2A2422" />
      <circle cx="86" cy="69.5" r="2.2" fill="#FFFFFF" />
      <circle cx="118" cy="69.5" r="2.2" fill="#FFFFFF" />
    </>
  );
}

function TurtleArt() {
  return (
    <>
      {/* Shell goes on his BACK, so it is drawn first and shows as a rim
          around him; the pale plastron is his front. Peter 2026-09-17. */}
      <g className="nw-wag" style={{ transformOrigin: "6% 50%" }}>
        <path d="M152 144 q19 4 23 16" fill="none" stroke="#7FA86A" strokeWidth="9" strokeLinecap="round" />
      </g>
      <ellipse cx="100" cy="128" rx="58" ry="44" fill="#4E7A46" />
      <ellipse cx="100" cy="126" rx="47" ry="34" fill="#6B9B5C" />
      <path d="M100 100 l18 12 -7 21 h-23 l-7 -21 z" fill="#4E7A46" />
      <circle cx="64" cy="124" r="9" fill="#4E7A46" />
      <circle cx="136" cy="124" r="9" fill="#4E7A46" />
      <circle cx="80" cy="150" r="8" fill="#4E7A46" />
      <circle cx="120" cy="150" r="8" fill="#4E7A46" />
      <rect x="58" y="152" width="24" height="26" rx="11" fill="#7FA86A" />
      <rect x="118" y="152" width="24" height="26" rx="11" fill="#7FA86A" />
      <g className="nw-up"  style={{ transformOrigin: "50% 0%" }}><rect x="42" y="128" width="21" height="32" rx="10" fill="#7FA86A" /></g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}><rect x="137" y="128" width="21" height="32" rx="10" fill="#7FA86A" /></g>
      <ellipse cx="100" cy="146" rx="38" ry="30" fill="#C3D9A6" />
      <path d="M78 130 h44 M76 146 h48 M80 162 h40" fill="none" stroke="#A8C489" strokeWidth="3" strokeLinecap="round" />
      <rect x="86" y="96" width="28" height="24" rx="9" fill="#8FBB77" />
      <ellipse cx="100" cy="74" rx="32" ry="28" fill="#8FBB77" />
      <circle cx="88" cy="69" r="5.5" fill="#2A2422" />
      <circle cx="112" cy="69" r="5.5" fill="#2A2422" />
      <circle cx="90" cy="67" r="1.9" fill="#FFFFFF" />
      <circle cx="114" cy="67" r="1.9" fill="#FFFFFF" />
      <path d="M89 86 q11 9 22 0" fill="none" stroke="#4E7A46" strokeWidth="3" strokeLinecap="round" />
    </>
  );
}

function DuckArt() {
  return (
    <>
      <rect x="82" y="168" width="15" height="13" rx="4" fill="#E8913A" />
      <rect x="103" y="168" width="15" height="13" rx="4" fill="#E8913A" />
      <path d="M144 124 q24 -8 26 -24 q-16 6 -30 16 z" fill="#EFC23C" />
      <ellipse cx="100" cy="134" rx="46" ry="34" fill="#F5CE4E" />
      <g className="nw-swayL" style={{ transformOrigin: "90% 18%" }}><ellipse cx="66" cy="132" rx="20" ry="26" fill="#EFC23C" /></g>
      <g className="nw-swayR" style={{ transformOrigin: "10% 18%" }}><ellipse cx="134" cy="132" rx="20" ry="26" fill="#EFC23C" /></g>
      <circle cx="100" cy="76" r="34" fill="#F5CE4E" />
      <ellipse cx="100" cy="93" rx="23" ry="11" fill="#E8913A" />
      <path d="M79 93 h42" fill="none" stroke="#C9762B" strokeWidth="2" strokeLinecap="round" />
      <circle cx="88" cy="68" r="5.5" fill="#2A2422" />
      <circle cx="112" cy="68" r="5.5" fill="#2A2422" />
      <circle cx="90" cy="66" r="1.9" fill="#FFFFFF" />
      <circle cx="114" cy="66" r="1.9" fill="#FFFFFF" />
    </>
  );
}

function GooseArt() {
  return (
    <>
      <rect x="84" y="170" width="14" height="12" rx="4" fill="#E8913A" />
      <rect x="102" y="170" width="14" height="12" rx="4" fill="#E8913A" />
      <path d="M146 134 q26 -6 30 -24 q-20 4 -36 14 z" fill="#8F8A7B" />
      <ellipse cx="100" cy="144" rx="47" ry="31" fill="#A8A396" />
      <ellipse cx="100" cy="154" rx="33" ry="18" fill="#DCD7C8" />
      <g className="nw-swayL" style={{ transformOrigin: "88% 16%" }}><ellipse cx="64" cy="142" rx="20" ry="24" fill="#8F8A7B" /></g>
      <g className="nw-swayR" style={{ transformOrigin: "12% 16%" }}><ellipse cx="136" cy="142" rx="20" ry="24" fill="#8F8A7B" /></g>
      <path d="M90 128 q-8 -52 10 -66 q18 14 10 66 z" fill="#B5B0A2" />
      <ellipse cx="100" cy="56" rx="24" ry="21" fill="#B5B0A2" />
      <path d="M82 66 q18 14 36 0 q-18 10 -36 0 z" fill="#DCD7C8" />
      <path d="M100 54 q19 4 19 15 q0 13 -19 18 q-19 -5 -19 -18 q0 -11 19 -15 z" fill="#E8913A" />
      <path d="M100 87 q-9 -3 -13 -9 q13 5 26 0 q-4 6 -13 9 z" fill="#C9762B" />
      <circle cx="92" cy="68" r="2" fill="#C9762B" />
      <circle cx="108" cy="68" r="2" fill="#C9762B" />
      <circle cx="88" cy="50" r="4.6" fill="#2A2422" />
      <circle cx="112" cy="50" r="4.6" fill="#2A2422" />
      <circle cx="89.6" cy="48" r="1.6" fill="#FFFFFF" />
      <circle cx="113.6" cy="48" r="1.6" fill="#FFFFFF" />
    </>
  );
}

function LizardArt() {
  return (
    <>
      {/* Side on. A ridge down the back cannot be seen at all on an animal
          facing you, which is why the spines kept reading as side fins.
          The head is a tapering wedge with a separate lower jaw, not a
          ball - a round head on a lizard reads as a frog. Peter 2026-09-17. */}
      <g className="nw-wag" style={{ transformOrigin: "92% 30%" }}>
        <path d="M54 138 q-30 8 -34 34" fill="none" stroke="#6BA84F" strokeWidth="13" strokeLinecap="round" />
        <path d="M50 143 l-6 -12 l-7 14 l-7 -11 l-7 14" fill="none" stroke="#4C8038" strokeWidth="5" strokeLinecap="round" />
      </g>
      <path d="M52 124 l10 -26 l10 26 l10 -26 l10 26 l10 -26 l10 26 l10 -26 l10 26 z" fill="#4C8038" />
      <ellipse cx="94" cy="136" rx="50" ry="27" fill="#6BA84F" />
      <ellipse cx="94" cy="146" rx="36" ry="14" fill="#A8CF8A" />
      <rect x="58" y="152" width="17" height="28" rx="8" fill="#5A9342" />
      <path d="M56 178 h22 M58 172 h18" fill="none" stroke="#4C8038" strokeWidth="4" strokeLinecap="round" />
      <g className="nw-up" style={{ transformOrigin: "50% 0%" }}>
        <rect x="116" y="150" width="17" height="30" rx="8" fill="#6BA84F" />
        <path d="M112 178 h22 M114 172 h18" fill="none" stroke="#5A9342" strokeWidth="4" strokeLinecap="round" />
      </g>
      <path d="M124 96 l7 -17 l6 15 l7 -13 l6 14 z" fill="#4C8038" />
      <path d="M122 94 Q148 85 166 93 Q183 100 183 107 L122 113 Z" fill="#6BA84F" />
      <g className="nw-up" style={{ transformOrigin: "20% 0%" }}>
        <path d="M130 116 Q128 146 146 146 Q163 144 163 116 Q147 124 130 116 Z" fill="#7FB061" />
        <path d="M140 128 q1 12 4 15 M150 127 q0 12 -2 16" fill="none" stroke="#5A9342" strokeWidth="2.5" strokeLinecap="round" />
      </g>
      <path d="M122 113 L183 107 Q182 117 164 121 Q142 126 122 120 Z" fill="#5A9342" />
      <path d="M124 113 L181 107" fill="none" stroke="#2F5223" strokeWidth="2.5" strokeLinecap="round" />
      <path d="M134 95 q14 -6 26 -1" fill="none" stroke="#4C8038" strokeWidth="4" strokeLinecap="round" />
      <circle cx="146" cy="101" r="8.5" fill="#F2D24E" />
      <ellipse cx="146" cy="101" rx="2" ry="5.5" fill="#15100F" />
      <circle cx="176" cy="102" r="2.2" fill="#3E6B2E" />
    </>
  );
}

function LemurArt() {
  return (
    <>
      <g className="nw-wag" style={{ transformOrigin: "10% 95%" }}>
        <path d="M142 138 q38 -16 32 -70" fill="none" stroke="#EFEAE0" strokeWidth="14" strokeLinecap="round" />
        <path d="M142 138 q38 -16 32 -70" fill="none" stroke="#2A2422" strokeWidth="14" strokeDasharray="11 11" />
      </g>
      <rect x="66" y="152" width="20" height="26" rx="9" fill="#9B9384" />
      <rect x="114" y="152" width="20" height="26" rx="9" fill="#9B9384" />
      <ellipse cx="100" cy="138" rx="42" ry="32" fill="#9B9384" />
      <ellipse cx="100" cy="148" rx="28" ry="20" fill="#EFEAE0" />
      <g className="nw-up"  style={{ transformOrigin: "50% 0%" }}><rect x="60" y="136" width="17" height="32" rx="8" fill="#9B9384" /></g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}><rect x="123" y="136" width="17" height="32" rx="8" fill="#9B9384" /></g>
      <g className="nw-swayL" style={{ transformOrigin: "70% 90%" }}><circle cx="68" cy="52" r="13" fill="#9B9384" /></g>
      <g className="nw-swayR" style={{ transformOrigin: "30% 90%" }}><circle cx="132" cy="52" r="13" fill="#9B9384" /></g>
      <circle cx="100" cy="80" r="36" fill="#EFEAE0" />
      <ellipse cx="84" cy="74" rx="13" ry="14.5" fill="#2A2422" />
      <ellipse cx="116" cy="74" rx="13" ry="14.5" fill="#2A2422" />
      <circle cx="84" cy="74" r="7" fill="#E0A53C" />
      <circle cx="84" cy="74" r="3.2" fill="#15100F" />
      <circle cx="116" cy="74" r="7" fill="#E0A53C" />
      <circle cx="116" cy="74" r="3.2" fill="#15100F" />
      <ellipse cx="100" cy="99" rx="14" ry="11" fill="#2A2422" />
      <ellipse cx="100" cy="94" rx="6" ry="4" fill="#15100F" />
    </>
  );
}

function SlothArt() {
  return (
    <>
      <rect x="72" y="158" width="20" height="23" rx="9" fill="#7A6A56" />
      <rect x="108" y="158" width="20" height="23" rx="9" fill="#7A6A56" />
      <ellipse cx="100" cy="136" rx="40" ry="34" fill="#9C8B73" />
      <ellipse cx="100" cy="144" rx="26" ry="24" fill="#C6B69C" />
      <g className="nw-swayL" style={{ transformOrigin: "92% 6%" }}>
        <path d="M72 108 q-34 22 -28 58" fill="none" stroke="#6E5C46" strokeWidth="17" strokeLinecap="round" />
        <path d="M46 168 q-8 -8 -2 -14 M52 170 q-8 -8 -2 -14" fill="none" stroke="#4A3C2E" strokeWidth="4" strokeLinecap="round" />
      </g>
      <g className="nw-swayR" style={{ transformOrigin: "8% 6%" }}>
        <path d="M128 108 q34 22 28 58" fill="none" stroke="#6E5C46" strokeWidth="17" strokeLinecap="round" />
        <path d="M154 168 q8 -8 2 -14 M148 170 q8 -8 2 -14" fill="none" stroke="#4A3C2E" strokeWidth="4" strokeLinecap="round" />
      </g>
      <circle cx="100" cy="78" r="38" fill="#C6B69C" />
      <path d="M63 76 q37 -36 74 0 q-37 -13 -74 0 z" fill="#9C8B73" />
      <ellipse cx="84" cy="77" rx="12.5" ry="10.5" fill="#6E5C46" />
      <ellipse cx="116" cy="77" rx="12.5" ry="10.5" fill="#6E5C46" />
      <circle cx="84" cy="77" r="5" fill="#15100F" />
      <circle cx="116" cy="77" r="5" fill="#15100F" />
      <circle cx="86" cy="75" r="1.8" fill="#FFFFFF" />
      <circle cx="118" cy="75" r="1.8" fill="#FFFFFF" />
      <ellipse cx="100" cy="93" rx="7" ry="5" fill="#4A3C2E" />
      <path d="M86 103 q14 12 28 0" fill="none" stroke="#6E5C46" strokeWidth="3.5" strokeLinecap="round" />
    </>
  );
}

function RoosterArt() {
  return (
    <>
      {/* A rooster, not a turkey: three separate arching sickle feathers with
          daylight between them instead of a fan, and a taller body than a
          turkey's. Peter 2026-09-17. */}
      <rect x="90" y="162" width="7" height="20" rx="3" fill="#E8B13A" />
      <rect x="103" y="162" width="7" height="20" rx="3" fill="#E8B13A" />
      <path d="M82 182 h18 M85 177 h15" fill="none" stroke="#C98A26" strokeWidth="4" strokeLinecap="round" />
      <path d="M100 182 h18 M100 177 h15" fill="none" stroke="#C98A26" strokeWidth="4" strokeLinecap="round" />
      <g className="nw-swayL" style={{ transformOrigin: "8% 96%" }}>
        <path d="M126 148 q46 -6 52 -54" fill="none" stroke="#1C332E" strokeWidth="8" strokeLinecap="round" />
        <path d="M126 142 q34 -22 30 -60" fill="none" stroke="#3E7A63" strokeWidth="7" strokeLinecap="round" />
        <path d="M124 136 q20 -30 8 -56" fill="none" stroke="#2F5E4E" strokeWidth="7" strokeLinecap="round" />
      </g>
      <ellipse cx="97" cy="142" rx="33" ry="36" fill="#B5502F" />
      <ellipse cx="94" cy="150" rx="23" ry="24" fill="#D2703F" />
      <g className="nw-swayR" style={{ transformOrigin: "16% 18%" }}><ellipse cx="119" cy="140" rx="17" ry="16" fill="#8E3B22" /></g>
      <path d="M87 114 q-4 -30 13 -40 q17 12 13 40 z" fill="#D98B3A" />
      <circle cx="100" cy="66" r="23" fill="#C05B34" />
      <path d="M85 48 q3 -15 9 -8 q3 -16 9 -8 q4 -15 10 -6 q3 -11 8 -3 q-18 10 -36 12 z" fill="#D63B33" />
      <path d="M100 72 l12 9 l-24 0 z" fill="#E8B13A" />
      <ellipse cx="95" cy="88" rx="4.5" ry="10" fill="#D63B33" />
      <ellipse cx="105" cy="88" rx="4.5" ry="10" fill="#D63B33" />
      <ellipse cx="85" cy="76" rx="4.5" ry="6.5" fill="#FBF6EE" />
      <ellipse cx="115" cy="76" rx="4.5" ry="6.5" fill="#FBF6EE" />
      <circle cx="91" cy="61" r="5" fill="#15100F" />
      <circle cx="109" cy="61" r="5" fill="#15100F" />
      <circle cx="92.6" cy="59" r="1.8" fill="#FFFFFF" />
      <circle cx="110.6" cy="59" r="1.8" fill="#FFFFFF" />
    </>
  );
}

function PuffinArt() {
  return (
    <>
      {/* Side on, because the bill is the whole point: a deep triangle in
          grey, yellow and orange bands. Peter 2026-09-17. */}
      <path d="M62 150 q-16 10 -14 22 l22 -6 z" fill="#1A1614" />
      <path d="M88 168 q-10 12 2 14 h22 q12 -2 2 -14 z" fill="#E8913A" />
      <path d="M92 178 v6 M100 178 v6 M108 178 v6" fill="none" stroke="#C9762B" strokeWidth="2" />
      <ellipse cx="100" cy="130" rx="40" ry="43" fill="#2A2422" />
      <ellipse cx="114" cy="140" rx="26" ry="33" fill="#FBF6EE" />
      <g className="nw-swayL" style={{ transformOrigin: "72% 10%" }}>
        <ellipse cx="80" cy="132" rx="17" ry="28" fill="#1A1614" />
      </g>
      <circle cx="106" cy="68" r="30" fill="#2A2422" />
      <ellipse cx="118" cy="70" rx="19" ry="22" fill="#FBF6EE" />
      <circle cx="122" cy="58" r="5" fill="#15100F" />
      <ellipse cx="122" cy="58" rx="8" ry="4" fill="none" stroke="#D6602F" strokeWidth="2" />
      <path d="M130 52 L136 56 L136 90 L130 88 q-4 -18 0 -36 z" fill="#8F9BA2" />
      <path d="M136 56 L143 59 L143 88 L136 90 z" fill="#E8C34A" />
      <path d="M143 59 L167 74 L143 88 z" fill="#E8702F" />
      <path d="M150 64 q4 10 0 20 M157 68 q3 7 0 13" fill="none" stroke="#C4501F" strokeWidth="2.5" strokeLinecap="round" />
      <path d="M130 74 L165 74" fill="none" stroke="#C4501F" strokeWidth="2" />
    </>
  );
}

function WoodpeckerArt() {
  return (
    <>
      {/* Side on, because a woodpecker is its silhouette: long chisel bill,
          red crest, stiff tail braced under it. Peter 2026-09-17. */}
      <path d="M80 158 l-16 36 l24 -8 z" fill="#1A1614" />
      <rect x="90" y="168" width="11" height="13" rx="4" fill="#8A7A62" />
      <rect x="106" y="168" width="11" height="13" rx="4" fill="#8A7A62" />
      <ellipse cx="100" cy="130" rx="34" ry="43" fill="#2A2422" />
      <ellipse cx="112" cy="140" rx="22" ry="32" fill="#FBF6EE" />
      <g className="nw-swayL" style={{ transformOrigin: "70% 10%" }}>
        <ellipse cx="82" cy="130" rx="17" ry="31" fill="#1A1614" />
        <path d="M70 112 h20 M68 126 h22 M68 140 h22 M70 154 h18" fill="none" stroke="#FBF6EE" strokeWidth="5" strokeLinecap="round" />
      </g>
      <g className="nw-peck" style={{ transformOrigin: "34% 86%" }}>
        <circle cx="106" cy="70" r="27" fill="#2A2422" />
        <path d="M112 44 q-6 -22 10 -26 q-2 12 6 16 q-10 2 -16 10 z" fill="#D63B33" />
        <path d="M84 60 q14 -22 36 -16 q-22 2 -36 16 z" fill="#D63B33" />
        <path d="M118 82 q-24 6 -32 -4 q18 -9 32 -5 z" fill="#FBF6EE" />
        <circle cx="119" cy="62" r="5" fill="#FBF6EE" />
        <circle cx="119" cy="62" r="2.4" fill="#15100F" />
        <path d="M130 66 L178 76 L130 84 z" fill="#C9C2B4" />
        <path d="M130 76 L176 76" fill="none" stroke="#8F8A7B" strokeWidth="2" />
      </g>
    </>
  );
}

export const DANCERS = [
  { key: "pug",        label: "pug",        Art: PugArt },
  { key: "axolotl",    label: "axolotl",    Art: AxolotlArt },
  { key: "beagle",     label: "beagle",     Art: BeagleArt },
  { key: "turtle",     label: "turtle",     Art: TurtleArt },
  { key: "duck",       label: "duck",       Art: DuckArt },
  { key: "goose",      label: "goose",      Art: GooseArt },
  { key: "lizard",     label: "lizard",     Art: LizardArt },
  { key: "lemur",      label: "lemur",      Art: LemurArt },
  { key: "sloth",      label: "sloth",      Art: SlothArt },
  { key: "rooster",    label: "rooster",    Art: RoosterArt },
  { key: "puffin",     label: "puffin",     Art: PuffinArt },
  { key: "woodpecker", label: "woodpecker", Art: WoodpeckerArt },
];

// delay offsets the whole animal so a row of them is not in lockstep.
export function Dancer({ which, size = 176, delay = 0 }) {
  const a = DANCERS.find(d => d.key === which) || DANCERS[0];
  const Art = a.Art;
  return (
    <svg width={size} height={size} viewBox="0 0 200 200" role="img" aria-label={`A dancing ${a.label}`}
         style={{ "--d": `${delay}ms` }}>
      <g className="nw-dance">
        <ellipse cx="100" cy="186" rx="50" ry="7" fill="#000000" opacity="0.08" />
        <Art />
      </g>
    </svg>
  );
}

// Same animal, standing still (no dance frame, no shadow). For name pills.
export function CritterIcon({ which, size = 22 }) {
  const a = DANCERS.find(d => d.key === which);
  if (!a) return null;
  const Art = a.Art;
  return (
    <svg width={size} height={size} viewBox="0 0 200 200" role="img" aria-label={a.label} style={{ flexShrink: 0, display: "block" }}>
      <Art />
    </svg>
  );
}
