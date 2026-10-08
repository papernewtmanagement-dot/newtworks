// =========================================================================
// QuestMonster.jsx — draws a Spelling Quest monster (src/lib/questWorlds.js).
// One body shape plus add-ons ("bits"), colored per monster. Original designs.
// =========================================================================

const INK = "#2D2F26";

function shade(hex, amt) {
  const n = parseInt(hex.slice(1), 16);
  const c = v => Math.max(0, Math.min(255, v + amt));
  const r = c(n >> 16), g = c((n >> 8) & 255), b = c(n & 255);
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, "0")}`;
}

export default function QuestMonster({ m, size = 100, flip = true }) {
  if (!m) return null;
  const c = m.body;
  const dark = shade(c, -45);
  const light = shade(c, 40);
  const bits = new Set(m.bits || []);
  const eyes = m.eyes || 2;
  const tall = m.look === "tall";
  const cy = tall ? 58 : 62;
  return (
    <svg viewBox="0 0 120 120" width={size} height={size} aria-label={m.name}
      style={{ display: "block", overflow: "visible", transform: flip ? "scaleX(-1)" : "none" }}>
      {/* behind the body */}
      {bits.has("wings") ? (
        <g fill={light} stroke={INK} strokeWidth="2.5" opacity="0.9">
          <path d="M34 58 Q6 30 4 56 Q14 66 34 70 Z" /><path d="M86 58 Q114 30 116 56 Q106 66 86 70 Z" />
        </g>
      ) : null}
      {bits.has("tail") ? <path d="M90 86 Q114 90 108 70 Q104 64 100 70" fill="none" stroke={dark} strokeWidth="6" strokeLinecap="round" /> : null}
      {bits.has("tentacles") ? (
        <g stroke={dark} strokeWidth="7" fill="none" strokeLinecap="round">
          <path d="M42 92 Q36 106 44 112" /><path d="M54 94 Q52 108 58 114" /><path d="M66 94 Q70 108 64 114" /><path d="M78 92 Q86 104 78 112" />
        </g>
      ) : null}
      {bits.has("ears") ? (
        <g fill={c} stroke={INK} strokeWidth="2.5">
          <ellipse cx="40" cy="26" rx="9" ry="20" /><ellipse cx="80" cy="26" rx="9" ry="20" />
          <ellipse cx="40" cy="28" rx="4" ry="12" fill="#F2DDDA" stroke="none" /><ellipse cx="80" cy="28" rx="4" ry="12" fill="#F2DDDA" stroke="none" />
        </g>
      ) : null}
      {bits.has("antennae") ? (
        <g stroke={INK} strokeWidth="2.5" fill={dark}>
          <path d="M48 34 Q42 14 34 12" fill="none" /><path d="M72 34 Q78 14 86 12" fill="none" />
          <circle cx="34" cy="12" r="4" /><circle cx="86" cy="12" r="4" />
        </g>
      ) : null}
      {bits.has("horns") ? (
        <g fill="#F2E8D5" stroke={INK} strokeWidth="2.5"><path d="M38 38 L28 10 L50 32 Z" /><path d="M82 38 L92 10 L70 32 Z" /></g>
      ) : null}
      {bits.has("claws") ? (
        <g fill={c} stroke={INK} strokeWidth="2.5">
          <path d="M14 64 a12 12 0 1 1 10 -14 l-8 6 z" /><path d="M106 64 a12 12 0 1 0 -10 -14 l8 6 z" />
        </g>
      ) : null}

      {/* body */}
      {m.look === "blob" ? (
        <path d={`M18 ${cy + 26} C10 ${cy - 10} 34 ${cy - 34} 60 ${cy - 34} C86 ${cy - 34} 110 ${cy - 10} 102 ${cy + 26} C96 ${cy + 40} 24 ${cy + 40} 18 ${cy + 26} Z`} fill={c} stroke={INK} strokeWidth="3" />
      ) : m.look === "tall" ? (
        <rect x="32" y="22" width="56" height="80" rx="26" fill={c} stroke={INK} strokeWidth="3" />
      ) : m.look === "wide" ? (
        <ellipse cx="60" cy={cy + 4} rx="46" ry="32" fill={c} stroke={INK} strokeWidth="3" />
      ) : m.look === "bug" ? (
        <g stroke={INK} strokeWidth="3">
          <ellipse cx="60" cy="80" rx="26" ry="22" fill={dark} />
          <circle cx="60" cy="50" r="28" fill={c} />
        </g>
      ) : (
        <circle cx="60" cy={cy} r="38" fill={c} stroke={INK} strokeWidth="3" />
      )}
      {/* belly */}
      <ellipse cx="60" cy={m.look === "bug" ? 82 : cy + 16} rx="18" ry="12" fill={light} opacity="0.55" />

      {/* on top of the body */}
      {bits.has("stripes") ? <g stroke={dark} strokeWidth="5" strokeLinecap="round" opacity="0.55" fill="none"><path d={`M30 ${cy - 4} Q36 ${cy + 4} 32 ${cy + 14}`} /><path d={`M90 ${cy - 4} Q84 ${cy + 4} 88 ${cy + 14}`} /><path d={`M42 ${cy + 26} Q60 ${cy + 32} 78 ${cy + 26}`} /></g> : null}
      {bits.has("spots") ? <g fill={dark} opacity="0.6"><circle cx="34" cy={cy} r="5" /><circle cx="88" cy={cy - 6} r="6" /><circle cx="80" cy={cy + 18} r="4" /></g> : null}
      {bits.has("spikes") ? <g fill={dark} stroke={INK} strokeWidth="2"><path d="M44 26 L50 10 L56 24 Z" /><path d="M58 22 L64 6 L70 22 Z" /><path d="M72 26 L80 12 L82 28 Z" /></g> : null}
      {bits.has("crystals") ? <g fill="#B9E3F2" stroke={INK} strokeWidth="2"><path d="M30 40 L36 18 L44 38 Z" /><path d="M76 36 L86 14 L90 40 Z" /></g> : null}
      {bits.has("fins") ? <g fill={light} stroke={INK} strokeWidth="2"><path d="M22 60 L6 52 L10 72 Z" /><path d="M98 60 L114 52 L110 72 Z" /></g> : null}
      {bits.has("cap") ? <path d="M18 40 Q60 -6 102 40 Q60 30 18 40 Z" fill="#B8483A" stroke={INK} strokeWidth="3" /> : null}
      {bits.has("cap") ? <g fill="#fff"><circle cx="42" cy="26" r="4" /><circle cx="64" cy="18" r="5" /><circle cx="82" cy="30" r="3.5" /></g> : null}
      {bits.has("hat") ? <path d="M30 34 L60 -6 L90 34 Z" fill="#5C4A6E" stroke={INK} strokeWidth="3" /> : null}
      {bits.has("helmet") ? <g><path d="M30 46 Q60 4 90 46 Z" fill="#8A8478" stroke={INK} strokeWidth="3" /><rect x="34" y="46" width="52" height="6" fill="#6E7163" stroke={INK} strokeWidth="2" /></g> : null}
      {bits.has("flame") ? <path d="M60 4 Q74 18 66 28 Q72 20 60 26 Q50 22 54 14 Q48 22 54 30 Q44 22 60 4 Z" fill="#FF9F2F" stroke="#D7261E" strokeWidth="2" /> : null}
      {bits.has("crown") ? <path d="M38 30 L42 12 L52 24 L60 8 L68 24 L78 12 L82 30 Z" fill="#E2B13C" stroke={INK} strokeWidth="2.5" /> : null}
      {bits.has("leaf") ? <g stroke={INK} strokeWidth="2"><path d="M60 26 Q40 2 22 14 Q38 30 60 26 Z" fill="#6E9B4E" /><path d="M60 26 Q80 2 98 14 Q82 30 60 26 Z" fill="#8DBA5E" /><path d="M60 26 L60 14" fill="none" /></g> : null}
      {bits.has("star") ? <path d="M60 2 L66 16 L81 16 L69 25 L74 40 L60 31 L46 40 L51 25 L39 16 L54 16 Z" fill="#FFE680" stroke={INK} strokeWidth="2.5" strokeLinejoin="round" /> : null}
      {bits.has("beard") ? <path d="M40 74 Q60 112 80 74 Q60 84 40 74 Z" fill="#F2F0EA" stroke={INK} strokeWidth="2" /> : null}

      {/* face */}
      {eyes === 1 ? (
        <g><circle cx="60" cy={cy - 6} r="13" fill="#fff" stroke={INK} strokeWidth="2" /><circle cx="63" cy={cy - 4} r="6" fill={INK} /></g>
      ) : eyes === 3 ? (
        <g>{[44, 60, 76].map(x => <g key={x}><circle cx={x} cy={cy - 6} r="7" fill="#fff" stroke={INK} strokeWidth="1.5" /><circle cx={x + 2} cy={cy - 5} r="3" fill={INK} /></g>)}</g>
      ) : (
        <g>
          <circle cx="47" cy={cy - 6} r="9" fill="#fff" stroke={INK} strokeWidth="2" /><circle cx="73" cy={cy - 6} r="9" fill="#fff" stroke={INK} strokeWidth="2" />
          <circle cx="49" cy={cy - 4} r="4" fill={INK} /><circle cx="75" cy={cy - 4} r="4" fill={INK} />
          <path d={`M36 ${cy - 18} L54 ${cy - 13} M84 ${cy - 18} L66 ${cy - 13}`} stroke={INK} strokeWidth="3" strokeLinecap="round" />
        </g>
      )}
      {m.mouth === "fangs" ? (
        <g><path d={`M44 ${cy + 12} Q60 ${cy + 22} 76 ${cy + 12}`} fill="none" stroke={INK} strokeWidth="3" strokeLinecap="round" />
          <path d={`M50 ${cy + 15} l3 7 l3 -6 M64 ${cy + 16} l3 6 l3 -7`} fill="#fff" stroke={INK} strokeWidth="1.5" /></g>
      ) : m.mouth === "o" ? (
        <ellipse cx="60" cy={cy + 14} rx="6" ry="7" fill={INK} />
      ) : m.mouth === "frown" ? (
        <path d={`M46 ${cy + 18} Q60 ${cy + 8} 74 ${cy + 18}`} fill="none" stroke={INK} strokeWidth="3" strokeLinecap="round" />
      ) : (
        <path d={`M46 ${cy + 10} Q60 ${cy + 22} 74 ${cy + 10}`} fill="none" stroke={INK} strokeWidth="3" strokeLinecap="round" />
      )}
    </svg>
  );
}
