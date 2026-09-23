import { useMemo } from "react";
import { T } from "../lib/theme.js";

// =====================================================================
// Critters.jsx — the celebration troupe: confetti, twelve dancing animals
// and the guest dancers on one 200x200 stage, and the keyframes they dance to. Moved out of
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

function NinjaArt() {
  return (
    <>
      {/* A friendly little ninja who sneaks into the end-of-day dance now and then.
          Dark suit, red headband with tails that flutter, big eyes. Peter 2026-09-22. */}
      <rect x="76" y="150" width="20" height="30" rx="8" fill="#23262E" />
      <rect x="104" y="150" width="20" height="30" rx="8" fill="#23262E" />
      <rect x="72" y="174" width="26" height="9" rx="4.5" fill="#15171C" />
      <rect x="102" y="174" width="26" height="9" rx="4.5" fill="#15171C" />
      <rect x="68" y="100" width="64" height="60" rx="22" fill="#2E323C" />
      <path d="M84 104 L100 126 L116 104" fill="none" stroke="#23262E" strokeWidth="4" strokeLinejoin="round" />
      <rect x="68" y="134" width="64" height="9" fill="#D63B33" />
      <path d="M100 138 l-8 16 l6 -2 z M100 138 l8 16 l-6 -2 z" fill="#D63B33" />
      <g className="nw-up" style={{ transformOrigin: "50% 0%" }}>
        <rect x="50" y="106" width="20" height="40" rx="10" fill="#2E323C" />
        <circle cx="60" cy="148" r="9" fill="#23262E" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}>
        <rect x="130" y="106" width="20" height="40" rx="10" fill="#2E323C" />
        <circle cx="140" cy="148" r="9" fill="#23262E" />
      </g>
      <circle cx="100" cy="70" r="36" fill="#2E323C" />
      <g className="nw-swayR" style={{ transformOrigin: "0% 50%" }}>
        <path d="M132 52 q20 -6 30 6 q-14 -2 -24 8 z" fill="#D63B33" />
        <path d="M132 58 q22 4 26 20 q-10 -10 -26 -12 z" fill="#B82F28" />
      </g>
      <path d="M66 50 q34 -16 68 0 v10 q-34 -14 -68 0 z" fill="#D63B33" />
      <rect x="72" y="62" width="56" height="22" rx="11" fill="#F2C9A0" />
      <circle cx="88" cy="73" r="6" fill="#15100F" />
      <circle cx="112" cy="73" r="6" fill="#15100F" />
      <circle cx="90" cy="71" r="2" fill="#FFFFFF" />
      <circle cx="114" cy="71" r="2" fill="#FFFFFF" />
      <path d="M80 63 l12 4 M120 63 l-12 4" fill="none" stroke="#15100F" strokeWidth="3" strokeLinecap="round" />
    </>
  );
}

function BossCatArt() {
  return (
    <>
      {/* A big round cat in a business suit and sunglasses who drops in on the
          end-of-day dance now and then. Peter 2026-09-22. */}
      <g className="nw-wag" style={{ transformOrigin: "10% 90%" }}>
        <path d="M150 150 c22 -4 30 -22 22 -38 c-5 -10 -16 -8 -14 2 c2 12 -6 22 -16 24"
              fill="none" stroke="#E0913F" strokeWidth="11" strokeLinecap="round" />
      </g>
      <ellipse cx="82" cy="180" rx="16" ry="8" fill="#15171C" />
      <ellipse cx="118" cy="180" rx="16" ry="8" fill="#15171C" />
      <ellipse cx="100" cy="140" rx="54" ry="44" fill="#2B3440" />
      <path d="M86 100 L100 150 L114 100 z" fill="#FFFFFF" />
      <path d="M100 106 l-6 8 l6 34 l6 -34 z" fill="#C73A33" />
      <path d="M86 100 L100 132 L78 124 z" fill="#1F2630" />
      <path d="M114 100 L100 132 L122 124 z" fill="#1F2630" />
      <circle cx="100" cy="160" r="2.5" fill="#E8C34A" />
      <circle cx="100" cy="172" r="2.5" fill="#E8C34A" />
      <g className="nw-up" style={{ transformOrigin: "50% 0%" }}>
        <rect x="38" y="112" width="22" height="42" rx="11" fill="#2B3440" />
        <circle cx="49" cy="156" r="10" fill="#F2B866" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "50% 0%" }}>
        <rect x="140" y="112" width="22" height="42" rx="11" fill="#2B3440" />
        <circle cx="151" cy="156" r="10" fill="#F2B866" />
      </g>
      <path d="M62 44 L70 12 L90 36 z" fill="#E0913F" />
      <path d="M138 44 L130 12 L110 36 z" fill="#E0913F" />
      <path d="M68 38 L72 22 L82 34 z" fill="#F7C9C0" />
      <path d="M132 38 L128 22 L118 34 z" fill="#F7C9C0" />
      <ellipse cx="100" cy="66" rx="46" ry="40" fill="#E0913F" />
      <path d="M84 34 q4 8 0 16 M100 30 v18 M116 34 q-4 8 0 16" fill="none" stroke="#C4762B" strokeWidth="4" strokeLinecap="round" />
      <ellipse cx="100" cy="84" rx="26" ry="18" fill="#FBE3C4" />
      <rect x="62" y="54" width="34" height="18" rx="8" fill="#15100F" />
      <rect x="104" y="54" width="34" height="18" rx="8" fill="#15100F" />
      <path d="M96 60 h8" stroke="#15100F" strokeWidth="4" />
      <path d="M68 58 l8 -2 M110 58 l8 -2" stroke="#FFFFFF" strokeWidth="3" strokeLinecap="round" opacity="0.7" />
      <path d="M95 78 h10 l-5 6 z" fill="#E87A8F" />
      <path d="M90 90 q10 8 20 0" fill="none" stroke="#15100F" strokeWidth="3" strokeLinecap="round" />
      <path d="M74 84 h-22 M74 90 l-20 5 M126 84 h22 M126 90 l20 5" fill="none" stroke="#FFFFFF" strokeWidth="2" strokeLinecap="round" />
    </>
  );
}

function BoxerDolphinArt() {
  return (
    <>
      {/* A dolphin standing tall on its tail with huge biceps and red boxing
          gloves. Joins the end-of-day dance now and then. Peter 2026-09-22. */}
      <path d="M86 172 q-26 4 -34 16 q20 -2 36 -8 z" fill="#4E7FA8" />
      <path d="M114 172 q26 4 34 16 q-20 -2 -36 -8 z" fill="#4E7FA8" />
      <path d="M100 30 C132 30 142 70 138 110 C134 150 118 178 100 178 C82 178 66 150 62 110 C58 70 68 30 100 30 z" fill="#5B93C2" />
      <path d="M100 70 C120 72 126 104 122 132 C118 158 108 172 100 172 C92 172 82 158 78 132 C74 104 80 72 100 70 z" fill="#DCEAF5" />
      <path d="M66 70 q-22 -6 -26 -26 q18 6 30 16 z" fill="#4E7FA8" />
      <path d="M124 52 q26 0 34 10 q-8 8 -30 6 z" fill="#5B93C2" />
      <path d="M130 60 q14 2 26 2" fill="none" stroke="#3E6A8F" strokeWidth="2" strokeLinecap="round" />
      <circle cx="116" cy="48" r="5" fill="#15100F" />
      <circle cx="117.5" cy="46.5" r="1.6" fill="#FFFFFF" />
      <path d="M108 64 q10 8 22 2" fill="none" stroke="#15100F" strokeWidth="2.5" strokeLinecap="round" />
      {/* Double-biceps flex: upper arms straight out, forearms up, gloves high. */}
      <g className="nw-up" style={{ transformOrigin: "80% 80%" }}>
        <rect x="26" y="98" width="42" height="18" rx="9" fill="#5B93C2" />
        <ellipse cx="46" cy="94" rx="20" ry="17" fill="#6FA3CF" />
        <path d="M34 90 q12 -12 24 0" fill="none" stroke="#3E6A8F" strokeWidth="2.5" strokeLinecap="round" />
        <rect x="22" y="62" width="18" height="44" rx="9" fill="#5B93C2" />
        <circle cx="31" cy="52" r="17" fill="#D63B33" />
        <rect x="21" y="64" width="20" height="7" rx="3" fill="#FBF6EE" />
        <path d="M24 48 q7 -6 14 0" fill="none" stroke="#A82A24" strokeWidth="2" strokeLinecap="round" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "20% 80%" }}>
        <rect x="132" y="98" width="42" height="18" rx="9" fill="#5B93C2" />
        <ellipse cx="154" cy="94" rx="20" ry="17" fill="#6FA3CF" />
        <path d="M142 90 q12 -12 24 0" fill="none" stroke="#3E6A8F" strokeWidth="2.5" strokeLinecap="round" />
        <rect x="160" y="62" width="18" height="44" rx="9" fill="#5B93C2" />
        <circle cx="169" cy="52" r="17" fill="#D63B33" />
        <rect x="159" y="64" width="20" height="7" rx="3" fill="#FBF6EE" />
        <path d="M162 48 q7 -6 14 0" fill="none" stroke="#A82A24" strokeWidth="2" strokeLinecap="round" />
      </g>
    </>
  );
}

function LemoosterArt() {
  return (
    <>
      {/* Half lemur, half rooster: lemur face, ears and ringed tail; rooster
          comb, beak, wattles, wings, tail feathers and feet. Peter 2026-09-22. */}
      <rect x="86" y="164" width="7" height="18" rx="3" fill="#E8B13A" />
      <rect x="107" y="164" width="7" height="18" rx="3" fill="#E8B13A" />
      <path d="M78 182 h18 M82 177 h14" fill="none" stroke="#C98A26" strokeWidth="4" strokeLinecap="round" />
      <path d="M104 182 h18 M104 177 h14" fill="none" stroke="#C98A26" strokeWidth="4" strokeLinecap="round" />
      <g className="nw-wag" style={{ transformOrigin: "10% 95%" }}>
        <path d="M130 150 q40 -12 36 -66" fill="none" stroke="#EFEAE0" strokeWidth="13" strokeLinecap="round" />
        <path d="M130 150 q40 -12 36 -66" fill="none" stroke="#2A2422" strokeWidth="13" strokeDasharray="10 10" />
        <path d="M128 140 q30 -24 24 -62" fill="none" stroke="#3E7A63" strokeWidth="6" strokeLinecap="round" />
        <path d="M126 134 q16 -30 4 -54" fill="none" stroke="#1C332E" strokeWidth="6" strokeLinecap="round" />
      </g>
      <ellipse cx="100" cy="138" rx="36" ry="34" fill="#9B9384" />
      <ellipse cx="100" cy="148" rx="23" ry="21" fill="#EFEAE0" />
      <g className="nw-swayL" style={{ transformOrigin: "80% 20%" }}><ellipse cx="68" cy="138" rx="15" ry="20" fill="#B5502F" /></g>
      <g className="nw-swayR" style={{ transformOrigin: "20% 20%" }}><ellipse cx="132" cy="138" rx="15" ry="20" fill="#B5502F" /></g>
      <circle cx="70" cy="56" r="12" fill="#9B9384" />
      <circle cx="130" cy="56" r="12" fill="#9B9384" />
      <circle cx="88" cy="48" r="8" fill="#D63B33" />
      <circle cx="100" cy="43" r="10" fill="#D63B33" />
      <circle cx="112" cy="48" r="8" fill="#D63B33" />
      <circle cx="100" cy="80" r="34" fill="#EFEAE0" />
      <ellipse cx="85" cy="74" rx="12" ry="13.5" fill="#2A2422" />
      <ellipse cx="115" cy="74" rx="12" ry="13.5" fill="#2A2422" />
      <circle cx="85" cy="74" r="6.5" fill="#E0A53C" />
      <circle cx="85" cy="74" r="3" fill="#15100F" />
      <circle cx="115" cy="74" r="6.5" fill="#E0A53C" />
      <circle cx="115" cy="74" r="3" fill="#15100F" />
      <path d="M100 86 l11 9 l-22 0 z" fill="#E8B13A" />
      <ellipse cx="95" cy="104" rx="4.5" ry="9" fill="#D63B33" />
      <ellipse cx="105" cy="104" rx="4.5" ry="9" fill="#D63B33" />
    </>
  );
}

// A five-point star as a path, for hats, wands and emblems.
const starPath = (cx, cy, r) => {
  const pts = [];
  for (let i = 0; i < 10; i++) {
    const a = -Math.PI / 2 + (i * Math.PI) / 5;
    const rr = i % 2 ? r * 0.45 : r;
    pts.push(`${(cx + rr * Math.cos(a)).toFixed(1)} ${(cy + rr * Math.sin(a)).toFixed(1)}`);
  }
  return `M${pts.join(" L")} Z`;
};

function KnightHamsterArt() {
  return (
    <>
      {/* A round hamster in a knight's helmet and breastplate, sword up,
          shield out, cheeks full. Peter 2026-09-23. */}
      <ellipse cx="82" cy="181" rx="13" ry="6" fill="#F2A7A0" />
      <ellipse cx="118" cy="181" rx="13" ry="6" fill="#F2A7A0" />
      <ellipse cx="100" cy="142" rx="44" ry="38" fill="#E0A15A" />
      <path d="M72 124 C72 110 128 110 128 124 L126 158 C120 172 80 172 74 158 Z" fill="#C9D1DB" />
      <path d="M78 124 C80 116 120 116 122 124" fill="none" stroke="#E9EDF2" strokeWidth="4" strokeLinecap="round" />
      <path d="M100 118 V166" stroke="#AEB7C3" strokeWidth="3" />
      <path d="M100 132 c-6 0 -9 5 -9 10 c0 6 5 11 9 13 c4 -2 9 -7 9 -13 c0 -5 -3 -10 -9 -10 z" fill="#3B3B3B" />
      <path d="M97 136 v14 M103 136 v14" stroke="#FFFFFF" strokeWidth="2" strokeLinecap="round" />
      <g className="nw-up" style={{ transformOrigin: "50% 100%" }}>
        <rect x="38" y="116" width="19" height="34" rx="9.5" fill="#E0A15A" />
        <path d="M42 58 L46 46 L50 58 Z" fill="#DDE3EA" />
        <rect x="42" y="58" width="8" height="52" fill="#DDE3EA" />
        <path d="M46 60 V108" stroke="#AEB7C3" strokeWidth="2" />
        <rect x="33" y="108" width="26" height="6" rx="3" fill="#E8C34A" />
        <rect x="43" y="113" width="6" height="10" rx="2" fill="#6B4A2B" />
        <circle cx="47" cy="120" r="8" fill="#F2B874" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "50% 100%" }}>
        <rect x="136" y="118" width="19" height="32" rx="9.5" fill="#E0A15A" />
        <path d="M134 116 H170 V132 C170 150 160 160 152 164 C144 160 134 150 134 132 Z" fill="#3F6FB5" stroke="#E8C34A" strokeWidth="4" strokeLinejoin="round" />
        <path d={starPath(152, 136, 11)} fill="#E8C34A" />
      </g>
      <circle cx="100" cy="86" r="40" fill="#E0A15A" />
      <ellipse cx="72" cy="100" rx="19" ry="16" fill="#F0B874" />
      <ellipse cx="128" cy="100" rx="19" ry="16" fill="#F0B874" />
      <ellipse cx="100" cy="104" rx="15" ry="11" fill="#F8E3C2" />
      <circle cx="68" cy="100" r="6" fill="#F2A7A0" opacity="0.7" />
      <circle cx="132" cy="100" r="6" fill="#F2A7A0" opacity="0.7" />
      <path d="M80 102 h-22 M80 107 l-20 4 M120 102 h22 M120 107 l20 4" fill="none" stroke="#8A5A2B" strokeWidth="1.8" strokeLinecap="round" />
      <ellipse cx="100" cy="98" rx="5" ry="3.6" fill="#D9707F" />
      <path d="M93 104 q3.5 4 7 0 q3.5 4 7 0" fill="none" stroke="#15100F" strokeWidth="2.2" strokeLinecap="round" />
      <rect x="96.5" y="106" width="3.2" height="5" rx="1" fill="#FFFFFF" />
      <rect x="100.3" y="106" width="3.2" height="5" rx="1" fill="#FFFFFF" />
      <circle cx="85" cy="88" r="7" fill="#15100F" />
      <circle cx="115" cy="88" r="7" fill="#15100F" />
      <circle cx="87.5" cy="85.5" r="2.4" fill="#FFFFFF" />
      <circle cx="117.5" cy="85.5" r="2.4" fill="#FFFFFF" />
      <g className="nw-swayR" style={{ transformOrigin: "0% 100%" }}>
        <path d="M102 38 C98 18 112 4 130 10 C118 14 112 24 112 38 Z" fill="#D63B33" />
        <path d="M106 38 C108 24 122 16 136 22 C124 24 118 30 116 40 Z" fill="#B82F28" />
      </g>
      <path d="M58 80 C58 46 78 36 100 36 C122 36 142 46 142 80 Z" fill="#C9D1DB" />
      <path d="M72 58 C78 46 90 42 100 42" fill="none" stroke="#E9EDF2" strokeWidth="4" strokeLinecap="round" />
      <rect x="56" y="70" width="88" height="11" rx="5.5" fill="#9AA4B1" />
      <circle cx="68" cy="75.5" r="2" fill="#E9EDF2" />
      <circle cx="100" cy="75.5" r="2" fill="#E9EDF2" />
      <circle cx="132" cy="75.5" r="2" fill="#E9EDF2" />
    </>
  );
}

function PiratePancakeArt() {
  return (
    <>
      {/* A stack of three pancakes with a pirate hat, an eye patch, syrup
          dripping down, and a fork for a sword. Peter 2026-09-23. */}
      <path d="M86 164 V178 M114 164 V178" stroke="#6B4A2B" strokeWidth="5" strokeLinecap="round" />
      <path d="M72 184 C72 176 80 174 88 176 L90 184 Z" fill="#23262E" />
      <path d="M128 184 C128 176 120 174 112 176 L110 184 Z" fill="#23262E" />
      <g className="nw-up" style={{ transformOrigin: "100% 100%" }}>
        <path d="M52 124 L34 104" stroke="#6B4A2B" strokeWidth="5" strokeLinecap="round" />
        <path d="M34 108 L30 64" stroke="#AEB7C3" strokeWidth="4" strokeLinecap="round" />
        <path d="M22 66 C22 54 38 54 38 66 Z" fill="#AEB7C3" />
        <path d="M24 58 V42 M30 58 V40 M36 58 V42" stroke="#AEB7C3" strokeWidth="3" strokeLinecap="round" />
        <circle cx="34" cy="106" r="7" fill="#FFFFFF" stroke="#D6D9DE" strokeWidth="1.5" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "0% 100%" }}>
        <path d="M148 124 L166 104" stroke="#6B4A2B" strokeWidth="5" strokeLinecap="round" />
        <circle cx="168" cy="101" r="7" fill="#FFFFFF" stroke="#D6D9DE" strokeWidth="1.5" />
      </g>
      <rect x="46" y="136" width="108" height="30" rx="15" fill="#C8843F" />
      <rect x="50" y="145" width="100" height="11" rx="5.5" fill="#F1C98A" />
      <rect x="44" y="108" width="112" height="31" rx="15.5" fill="#CF8C45" />
      <rect x="48" y="117" width="104" height="11" rx="5.5" fill="#F4D095" />
      <rect x="48" y="80" width="104" height="31" rx="15.5" fill="#D6944C" />
      <rect x="52" y="89" width="96" height="11" rx="5.5" fill="#F6D8A0" />
      <path d="M52 86 C60 78 140 78 148 86 C146 92 142 96 140 104 C138 112 132 112 132 104 C132 98 128 96 124 96 C120 96 76 96 72 96 C68 98 66 108 62 110 C58 112 56 106 56 100 C56 94 54 92 52 86 Z" fill="#9A5212" />
      <path d="M62 84 C74 80 96 80 108 81" fill="none" stroke="#C7782E" strokeWidth="3" strokeLinecap="round" />
      <rect x="54" y="68" width="22" height="14" rx="3" fill="#FFE58A" stroke="#EFCB55" strokeWidth="2" transform="rotate(-10 65 75)" />
      <circle cx="84" cy="104" r="9" fill="#FFFFFF" />
      <circle cx="86" cy="105" r="4.8" fill="#15100F" />
      <circle cx="87.5" cy="103.5" r="1.6" fill="#FFFFFF" />
      <path d="M74 92 l18 4" stroke="#6B3A12" strokeWidth="3" strokeLinecap="round" />
      <path d="M70 84 L128 110" stroke="#15100F" strokeWidth="2.5" />
      <ellipse cx="116" cy="104" rx="10" ry="9" fill="#15100F" />
      <path d="M86 122 C92 132 108 132 114 122 Z" fill="#7A2E1E" />
      <rect x="95" y="122" width="5" height="4" fill="#FFFFFF" />
      <rect x="101" y="122" width="5" height="4" fill="#E8C34A" />
      <path d="M50 74 C58 52 80 46 100 46 C120 46 142 52 150 74 C132 66 116 66 100 70 C84 66 68 66 50 74 Z" fill="#23262E" />
      <path d="M70 62 C72 36 128 36 130 62 Z" fill="#23262E" />
      <path d="M50 74 C68 66 84 66 100 70 C116 66 132 66 150 74" fill="none" stroke="#E8C34A" strokeWidth="3" strokeLinecap="round" />
      <path d="M92 44 L108 56 M108 44 L92 56" stroke="#FFFFFF" strokeWidth="3" strokeLinecap="round" />
      <circle cx="100" cy="47" r="6" fill="#FFFFFF" />
      <circle cx="98" cy="46.5" r="1.5" fill="#23262E" />
      <circle cx="102" cy="46.5" r="1.5" fill="#23262E" />
    </>
  );
}

function SpaceLlamaArt() {
  return (
    <>
      {/* A llama in a white space suit with a bubble helmet, ears up
          inside it. Peter 2026-09-23. */}
      <rect x="54" y="118" width="92" height="42" rx="12" fill="#AEB7C3" />
      <path d="M140 120 L152 96" stroke="#9AA4B1" strokeWidth="3" strokeLinecap="round" />
      <circle cx="153" cy="94" r="5" fill="#D63B33" />
      <rect x="76" y="160" width="20" height="18" rx="8" fill="#F4F6F8" stroke="#C9D1DB" strokeWidth="2" />
      <rect x="104" y="160" width="20" height="18" rx="8" fill="#F4F6F8" stroke="#C9D1DB" strokeWidth="2" />
      <ellipse cx="84" cy="182" rx="14" ry="6" fill="#9AA4B1" />
      <ellipse cx="116" cy="182" rx="14" ry="6" fill="#9AA4B1" />
      <rect x="60" y="110" width="80" height="58" rx="26" fill="#F4F6F8" stroke="#C9D1DB" strokeWidth="2" />
      <rect x="84" y="128" width="32" height="20" rx="4" fill="#DDE3EA" />
      <circle cx="92" cy="138" r="3" fill="#D63B33" />
      <circle cx="100" cy="138" r="3" fill="#3FA564" />
      <circle cx="108" cy="138" r="3" fill="#3F6FB5" />
      <rect x="64" y="118" width="14" height="8" rx="3" fill="#F28C28" />
      <g className="nw-up" style={{ transformOrigin: "50% 100%" }}>
        <rect x="38" y="104" width="20" height="44" rx="10" fill="#F4F6F8" stroke="#C9D1DB" strokeWidth="2" />
        <rect x="38" y="120" width="20" height="6" fill="#F28C28" />
        <circle cx="48" cy="102" r="10" fill="#9AA4B1" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "50% 100%" }}>
        <rect x="142" y="104" width="20" height="44" rx="10" fill="#F4F6F8" stroke="#C9D1DB" strokeWidth="2" />
        <rect x="142" y="120" width="20" height="6" fill="#F28C28" />
        <circle cx="152" cy="102" r="10" fill="#9AA4B1" />
      </g>
      <rect x="62" y="104" width="76" height="12" rx="6" fill="#9AA4B1" />
      <rect x="86" y="66" width="28" height="44" rx="10" fill="#D9B98C" />
      <path d="M88 76 q4 -3 8 0 q4 -3 8 0 q4 -3 8 0 M88 88 q4 -3 8 0 q4 -3 8 0 q4 -3 8 0" fill="none" stroke="#C8A574" strokeWidth="2.5" strokeLinecap="round" />
      <g className="nw-swayL" style={{ transformOrigin: "50% 100%" }}>
        <ellipse cx="82" cy="30" rx="7" ry="15" fill="#D9B98C" transform="rotate(-18 82 30)" />
        <ellipse cx="82" cy="31" rx="3.5" ry="10" fill="#E8B5A8" transform="rotate(-18 82 31)" />
      </g>
      <g className="nw-swayR" style={{ transformOrigin: "50% 100%" }}>
        <ellipse cx="118" cy="30" rx="7" ry="15" fill="#D9B98C" transform="rotate(18 118 30)" />
        <ellipse cx="118" cy="31" rx="3.5" ry="10" fill="#E8B5A8" transform="rotate(18 118 31)" />
      </g>
      <ellipse cx="100" cy="52" rx="24" ry="20" fill="#D9B98C" />
      <circle cx="92" cy="34" r="6" fill="#FBF6EE" />
      <circle cx="100" cy="31" r="7" fill="#FBF6EE" />
      <circle cx="108" cy="34" r="6" fill="#FBF6EE" />
      <ellipse cx="100" cy="64" rx="14" ry="11" fill="#FBF6EE" />
      <path d="M96 62 q-2 3 0 5 M104 62 q2 3 0 5" fill="none" stroke="#6B4A3A" strokeWidth="2" strokeLinecap="round" />
      <path d="M94 70 q6 5 12 0" fill="none" stroke="#6B4A3A" strokeWidth="2" strokeLinecap="round" />
      <circle cx="90" cy="50" r="5" fill="#15100F" />
      <circle cx="110" cy="50" r="5" fill="#15100F" />
      <circle cx="91.5" cy="48.5" r="1.7" fill="#FFFFFF" />
      <circle cx="111.5" cy="48.5" r="1.7" fill="#FFFFFF" />
      <path d="M84 45 l-4 -3 M116 45 l4 -3" stroke="#15100F" strokeWidth="1.8" strokeLinecap="round" />
      <ellipse cx="100" cy="62" rx="44" ry="50" fill="#CFE8F7" fillOpacity="0.2" stroke="#9AA4B1" strokeWidth="3" />
      <path d="M72 36 C78 24 90 18 102 17" fill="none" stroke="#FFFFFF" strokeWidth="5" strokeLinecap="round" opacity="0.85" />
    </>
  );
}

function WizardFrogArt() {
  return (
    <>
      {/* A frog in a tall starry wizard's hat, waving a star wand.
          Peter 2026-09-23 ("come up with some more"). */}
      <path d="M66 182 l-12 2 l8 -8 l-2 -8 l10 6 z M134 182 l12 2 l-8 -8 l2 -8 l-10 6 z" fill="#4E9A40" />
      <ellipse cx="74" cy="170" rx="16" ry="12" fill="#5DAE4C" />
      <ellipse cx="126" cy="170" rx="16" ry="12" fill="#5DAE4C" />
      <ellipse cx="100" cy="142" rx="42" ry="36" fill="#6BBF59" />
      <ellipse cx="100" cy="150" rx="27" ry="23" fill="#D9F2C4" />
      <g className="nw-up" style={{ transformOrigin: "50% 100%" }}>
        <rect x="44" y="112" width="16" height="34" rx="8" fill="#6BBF59" />
        <path d="M52 114 L40 70" stroke="#6B4A2B" strokeWidth="5" strokeLinecap="round" />
        <path d={starPath(38, 64, 12)} fill="#F2C94C" stroke="#E0A93A" strokeWidth="1.5" strokeLinejoin="round" />
        <path d="M22 50 l4 4 M56 48 l-3 5 M28 80 l4 -3" stroke="#F2C94C" strokeWidth="2.5" strokeLinecap="round" />
        <circle cx="52" cy="112" r="8" fill="#5DAE4C" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "50% 100%" }}>
        <rect x="140" y="112" width="16" height="34" rx="8" fill="#6BBF59" />
        <circle cx="148" cy="110" r="8" fill="#5DAE4C" />
      </g>
      <ellipse cx="100" cy="98" rx="46" ry="30" fill="#6BBF59" />
      <path d="M84 72 L104 10 C106 4 114 4 116 10 L122 72 Z" fill="#6A4C9C" />
      <path d="M116 10 C124 12 128 20 124 26 C120 20 116 16 112 16 Z" fill="#6A4C9C" />
      <path d={starPath(102, 50, 7)} fill="#F2C94C" />
      <path d={starPath(112, 30, 5)} fill="#F2C94C" />
      <circle cx="96" cy="64" r="2.2" fill="#F2C94C" />
      <circle cx="116" cy="58" r="2" fill="#F2C94C" />
      <ellipse cx="103" cy="72" rx="32" ry="7" fill="#553C80" />
      <circle cx="74" cy="74" r="16" fill="#6BBF59" />
      <circle cx="126" cy="74" r="16" fill="#6BBF59" />
      <circle cx="74" cy="74" r="11" fill="#FFFFFF" />
      <circle cx="126" cy="74" r="11" fill="#FFFFFF" />
      <circle cx="76" cy="75" r="6" fill="#15100F" />
      <circle cx="128" cy="75" r="6" fill="#15100F" />
      <circle cx="78" cy="73" r="2" fill="#FFFFFF" />
      <circle cx="130" cy="73" r="2" fill="#FFFFFF" />
      <circle cx="70" cy="104" r="6" fill="#F2A7A0" opacity="0.6" />
      <circle cx="130" cy="104" r="6" fill="#F2A7A0" opacity="0.6" />
      <path d="M72 104 C86 118 114 118 128 104" fill="none" stroke="#2F5E27" strokeWidth="3" strokeLinecap="round" />
      <circle cx="94" cy="92" r="1.8" fill="#2F5E27" />
      <circle cx="106" cy="92" r="1.8" fill="#2F5E27" />
    </>
  );
}

function VikingPenguinArt() {
  return (
    <>
      {/* A penguin in a horned helmet with a round wooden shield.
          Peter 2026-09-23 ("come up with some more"). */}
      <ellipse cx="84" cy="182" rx="14" ry="6" fill="#F2A33A" />
      <ellipse cx="116" cy="182" rx="14" ry="6" fill="#F2A33A" />
      <ellipse cx="100" cy="124" rx="46" ry="58" fill="#2B2F38" />
      <ellipse cx="100" cy="138" rx="30" ry="42" fill="#F7F7F2" />
      <g className="nw-up" style={{ transformOrigin: "80% 10%" }}>
        <path d="M58 104 C40 114 32 136 36 150 C46 142 56 128 62 118 Z" fill="#2B2F38" />
        <circle cx="42" cy="138" r="21" fill="#8B5A2B" stroke="#9AA4B1" strokeWidth="4" />
        <path d="M30 128 L54 148 M28 140 L42 152 M40 124 L56 138" stroke="#6E4520" strokeWidth="2" strokeLinecap="round" />
        <circle cx="42" cy="138" r="6" fill="#C9D1DB" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "20% 90%" }}>
        <path d="M142 106 C160 98 170 80 166 68 C158 74 148 88 140 98 Z" fill="#2B2F38" />
      </g>
      <circle cx="86" cy="94" r="9" fill="#FFFFFF" />
      <circle cx="114" cy="94" r="9" fill="#FFFFFF" />
      <circle cx="87" cy="95" r="4.8" fill="#15100F" />
      <circle cx="115" cy="95" r="4.8" fill="#15100F" />
      <circle cx="88.5" cy="93.5" r="1.6" fill="#FFFFFF" />
      <circle cx="116.5" cy="93.5" r="1.6" fill="#FFFFFF" />
      <path d="M88 104 L112 104 L100 118 Z" fill="#F2A33A" />
      <path d="M90 105 L110 105" stroke="#D9861F" strokeWidth="2" strokeLinecap="round" />
      <circle cx="76" cy="108" r="5" fill="#F2A7A0" opacity="0.5" />
      <circle cx="124" cy="108" r="5" fill="#F2A7A0" opacity="0.5" />
      <g className="nw-swayL" style={{ transformOrigin: "100% 100%" }}>
        <path d="M62 72 C46 70 36 56 38 36 C44 48 52 54 64 58 Z" fill="#F3E6CF" stroke="#D8C4A0" strokeWidth="1.5" />
        <path d="M38 36 C39 42 41 46 44 49" fill="none" stroke="#B8A27A" strokeWidth="3" strokeLinecap="round" />
      </g>
      <g className="nw-swayR" style={{ transformOrigin: "0% 100%" }}>
        <path d="M138 72 C154 70 164 56 162 36 C156 48 148 54 136 58 Z" fill="#F3E6CF" stroke="#D8C4A0" strokeWidth="1.5" />
        <path d="M162 36 C161 42 159 46 156 49" fill="none" stroke="#B8A27A" strokeWidth="3" strokeLinecap="round" />
      </g>
      <path d="M58 82 C58 50 78 38 100 38 C122 38 142 50 142 82 Z" fill="#B8C0CC" />
      <path d="M72 60 C78 50 88 45 98 44" fill="none" stroke="#E9EDF2" strokeWidth="4" strokeLinecap="round" />
      <rect x="56" y="74" width="88" height="11" rx="5.5" fill="#9AA4B1" />
      <path d="M100 40 V76" stroke="#9AA4B1" strokeWidth="6" />
      <circle cx="70" cy="79.5" r="2" fill="#E9EDF2" />
      <circle cx="85" cy="79.5" r="2" fill="#E9EDF2" />
      <circle cx="115" cy="79.5" r="2" fill="#E9EDF2" />
      <circle cx="130" cy="79.5" r="2" fill="#E9EDF2" />
    </>
  );
}

function ChefOctopusArt() {
  return (
    <>
      {/* An octopus in a chef's hat with a curly mustache, whisk in one arm,
          frying pan (egg in it) in another. Peter 2026-09-23 ("come up with some more"). */}
      <g className="nw-swayL" style={{ transformOrigin: "100% 0%" }}>
        <path d="M80 118 C72 142 62 160 70 176 C74 182 84 180 82 172" fill="none" stroke="#EF7F6E" strokeWidth="13" strokeLinecap="round" />
      </g>
      <path d="M94 122 C92 148 88 166 96 180" fill="none" stroke="#EF7F6E" strokeWidth="13" strokeLinecap="round" />
      <path d="M106 122 C108 148 112 166 104 180" fill="none" stroke="#EF7F6E" strokeWidth="13" strokeLinecap="round" />
      <g className="nw-swayR" style={{ transformOrigin: "0% 0%" }}>
        <path d="M120 118 C128 142 138 160 130 176 C126 182 116 180 118 172" fill="none" stroke="#EF7F6E" strokeWidth="13" strokeLinecap="round" />
      </g>
      <circle cx="93" cy="160" r="2.4" fill="#F9C2B8" />
      <circle cx="94" cy="170" r="2.4" fill="#F9C2B8" />
      <circle cx="107" cy="160" r="2.4" fill="#F9C2B8" />
      <circle cx="106" cy="170" r="2.4" fill="#F9C2B8" />
      <g className="nw-up" style={{ transformOrigin: "100% 100%" }}>
        <path d="M66 112 C46 114 36 100 38 84" fill="none" stroke="#EF7F6E" strokeWidth="13" strokeLinecap="round" />
        <path d="M38 84 L40 66" stroke="#9AA4B1" strokeWidth="4" strokeLinecap="round" />
        <ellipse cx="40" cy="50" rx="7" ry="16" fill="none" stroke="#9AA4B1" strokeWidth="2" />
        <ellipse cx="40" cy="50" rx="3" ry="16" fill="none" stroke="#9AA4B1" strokeWidth="2" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "0% 100%" }}>
        <path d="M134 112 C154 114 164 100 162 84" fill="none" stroke="#EF7F6E" strokeWidth="13" strokeLinecap="round" />
        <path d="M162 84 L158 68" stroke="#3A3F48" strokeWidth="5" strokeLinecap="round" />
        <ellipse cx="154" cy="58" rx="22" ry="8" fill="#3A3F48" />
        <ellipse cx="154" cy="56" rx="12" ry="4.5" fill="#FFFFFF" />
        <circle cx="156" cy="55" r="3.5" fill="#F2C230" />
      </g>
      <ellipse cx="100" cy="84" rx="44" ry="42" fill="#EF7F6E" />
      <ellipse cx="86" cy="62" rx="10" ry="6" fill="#F59B8C" transform="rotate(-20 86 62)" />
      <circle cx="86" cy="86" r="9.5" fill="#FFFFFF" />
      <circle cx="114" cy="86" r="9.5" fill="#FFFFFF" />
      <circle cx="87" cy="87" r="5" fill="#15100F" />
      <circle cx="115" cy="87" r="5" fill="#15100F" />
      <circle cx="88.6" cy="85.4" r="1.7" fill="#FFFFFF" />
      <circle cx="116.6" cy="85.4" r="1.7" fill="#FFFFFF" />
      <circle cx="72" cy="100" r="5.5" fill="#E0566A" opacity="0.45" />
      <circle cx="128" cy="100" r="5.5" fill="#E0566A" opacity="0.45" />
      <path d="M100 102 C94 97 84 97 78 104 C74 108 76 111 80 108 C86 104 94 104 100 106 C106 104 114 104 120 108 C124 111 126 108 122 104 C116 97 106 97 100 102 Z" fill="#4A3222" />
      <path d="M92 112 q8 6 16 0" fill="none" stroke="#15100F" strokeWidth="2.5" strokeLinecap="round" />
      <rect x="72" y="36" width="56" height="16" rx="4" fill="#FFFFFF" stroke="#DDE1E6" strokeWidth="2" />
      <circle cx="80" cy="28" r="15" fill="#FFFFFF" stroke="#DDE1E6" strokeWidth="2" />
      <circle cx="120" cy="28" r="15" fill="#FFFFFF" stroke="#DDE1E6" strokeWidth="2" />
      <circle cx="100" cy="20" r="18" fill="#FFFFFF" stroke="#DDE1E6" strokeWidth="2" />
      <rect x="70" y="30" width="60" height="16" fill="#FFFFFF" />
      <path d="M86 44 V52 M100 44 V52 M114 44 V52" stroke="#E6E9ED" strokeWidth="2" />
    </>
  );
}

function CowboyArmadilloArt() {
  return (
    <>
      {/* A Texas armadillo in a cowboy hat, bandana and boots, twirling a
          lasso. Peter 2026-09-23 ("come up with some more"). */}
      <g className="nw-wag" style={{ transformOrigin: "0% 50%" }}>
        <path d="M136 160 C152 166 164 164 176 154" fill="none" stroke="#9C8E7A" strokeWidth="9" strokeLinecap="round" />
        <path d="M150 164 v-8 M162 162 v-8" stroke="#7E725F" strokeWidth="2" />
      </g>
      <path d="M78 162 h16 v10 h8 c4 0 6 4 4 8 h-30 z" fill="#8B5A2B" />
      <path d="M106 162 h16 v10 c0 4 -2 8 -6 8 h-12 c-2 -4 0 -8 2 -8 z" fill="#8B5A2B" />
      <rect x="76" y="178" width="22" height="6" rx="2" fill="#5B3A1E" />
      <rect x="102" y="178" width="22" height="6" rx="2" fill="#5B3A1E" />
      <ellipse cx="100" cy="134" rx="46" ry="42" fill="#9C8E7A" />
      <path d="M58 118 C62 112 68 108 74 106 M56 134 C60 128 66 124 72 122 M58 150 C62 144 68 140 74 138 M142 118 C138 112 132 108 126 106 M144 134 C140 128 134 124 128 122 M142 150 C138 144 132 140 126 138" fill="none" stroke="#7E725F" strokeWidth="3" strokeLinecap="round" />
      <ellipse cx="100" cy="140" rx="28" ry="34" fill="#E8D2BA" />
      <g className="nw-up" style={{ transformOrigin: "50% 100%" }}>
        <rect x="44" y="106" width="16" height="36" rx="8" fill="#A89A86" />
        <path d="M52 106 C50 96 46 90 42 82" fill="none" stroke="#C9A56B" strokeWidth="3" strokeLinecap="round" />
        <g className="nw-wag" style={{ transformOrigin: "50% 50%" }}>
          <ellipse cx="42" cy="66" rx="26" ry="11" fill="none" stroke="#C9A56B" strokeWidth="4" />
        </g>
        <circle cx="52" cy="106" r="7" fill="#A89A86" />
      </g>
      <g className="nw-upB" style={{ transformOrigin: "50% 100%" }}>
        <rect x="140" y="106" width="16" height="36" rx="8" fill="#A89A86" />
        <circle cx="148" cy="106" r="7" fill="#A89A86" />
      </g>
      <g className="nw-swayL" style={{ transformOrigin: "50% 100%" }}>
        <ellipse cx="72" cy="46" rx="8" ry="15" fill="#A89A86" transform="rotate(-24 72 46)" />
        <ellipse cx="72" cy="47" rx="4" ry="9" fill="#E3B5A4" transform="rotate(-24 72 47)" />
      </g>
      <g className="nw-swayR" style={{ transformOrigin: "50% 100%" }}>
        <ellipse cx="128" cy="46" rx="8" ry="15" fill="#A89A86" transform="rotate(24 128 46)" />
        <ellipse cx="128" cy="47" rx="4" ry="9" fill="#E3B5A4" transform="rotate(24 128 47)" />
      </g>
      <ellipse cx="100" cy="80" rx="30" ry="24" fill="#A89A86" />
      <path d="M86 70 h28 M84 76 h32" stroke="#8E8170" strokeWidth="2.5" strokeLinecap="round" />
      <ellipse cx="100" cy="98" rx="12" ry="14" fill="#B8AA96" />
      <ellipse cx="100" cy="108" rx="6" ry="4" fill="#6B4A3A" />
      <path d="M94 114 q6 4 12 0" fill="none" stroke="#6B4A3A" strokeWidth="2" strokeLinecap="round" />
      <circle cx="87" cy="84" r="5" fill="#15100F" />
      <circle cx="113" cy="84" r="5" fill="#15100F" />
      <circle cx="88.5" cy="82.5" r="1.6" fill="#FFFFFF" />
      <circle cx="114.5" cy="82.5" r="1.6" fill="#FFFFFF" />
      <path d="M74 112 L126 112 L100 132 Z" fill="#D63B33" />
      <circle cx="90" cy="117" r="1.8" fill="#FFFFFF" />
      <circle cx="104" cy="121" r="1.8" fill="#FFFFFF" />
      <circle cx="112" cy="116" r="1.8" fill="#FFFFFF" />
      <circle cx="98" cy="126" r="1.6" fill="#FFFFFF" />
      <path d="M72 52 C72 30 86 24 100 30 C114 24 128 30 128 52 Z" fill="#8B5A2B" />
      <path d="M100 30 V42" stroke="#6E4520" strokeWidth="3" strokeLinecap="round" />
      <rect x="72" y="46" width="56" height="7" fill="#5B3A1E" />
      <path d="M46 52 C60 62 140 62 154 52 C154 60 142 68 100 68 C58 68 46 60 46 52 Z" fill="#8B5A2B" />
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

// Guest dancers: not animals a kid picks. They drop into the Family day-done
// dance now and then, and they are in the team's random day-done draw too.
export const GUESTS = [
  { key: "ninja", label: "ninja", Art: NinjaArt },
  { key: "bosscat", label: "cat in a business suit", Art: BossCatArt },
  { key: "boxerdolphin", label: "dolphin in boxing gloves", Art: BoxerDolphinArt },
  { key: "lemooster", label: "lemur-rooster", Art: LemoosterArt },
  { key: "knighthamster", label: "hamster knight", Art: KnightHamsterArt },
  { key: "piratepancake", label: "pirate pancake", Art: PiratePancakeArt },
  { key: "spacellama", label: "llama in a space suit", Art: SpaceLlamaArt },
  { key: "wizardfrog", label: "wizard frog", Art: WizardFrogArt },
  { key: "vikingpenguin", label: "viking penguin", Art: VikingPenguinArt },
  { key: "chefoctopus", label: "octopus chef", Art: ChefOctopusArt },
  { key: "cowboyarmadillo", label: "cowboy armadillo", Art: CowboyArmadilloArt },
];
export const ALL_DANCERS = [...DANCERS, ...GUESTS];

// A steady random pick of one character: the same seed always gets the same
// one, so a done chore keeps its character from one visit to the next.
export function critterFor(seed) {
  const str = String(seed ?? "");
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
  return ALL_DANCERS[(h >>> 0) % ALL_DANCERS.length].key;
}

// delay offsets the whole animal so a row of them is not in lockstep.
export function Dancer({ which, size = 176, delay = 0 }) {
  const a = ALL_DANCERS.find(d => d.key === which) || DANCERS[0];
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
  const a = ALL_DANCERS.find(d => d.key === which);
  if (!a) return null;
  const Art = a.Art;
  return (
    <svg width={size} height={size} viewBox="0 0 200 200" role="img" aria-label={a.label} style={{ flexShrink: 0, display: "block" }}>
      <Art />
    </svg>
  );
}
