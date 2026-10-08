// =========================================================================
// QuestScene.jsx — the picture behind a Spelling Quest fight.
// The world's theme gives the sky, the ground and its far-off scenery ("base");
// the level's sub-theme adds two nearer pieces of scenery ("props"); the step
// inside the world sets the time of day (levels 1–8 day, 9–14 sunset, 15–20
// night, with stars and a moon). Data: src/lib/questWorlds.js.
// =========================================================================
import { useMemo } from "react";

const INK = "#2D2F26";
const W = 400, H = 200, GY = 150; // picture size and ground line

// Where a piece sits: on the ground (default), flat on the ground, up in the sky,
// hanging from the top, or a little way up a wall.
const SKY = new Set(["cloud", "moon", "planet", "rainbow"]);
const HANG = new Set(["stalactite", "banner", "vine"]);
const FLAT = new Set(["pool", "lava", "wave", "dune", "lily"]);
const LIFT = { window: 46 };

// Each piece is drawn standing on (0,0), about 60 wide and up to ~90 tall.
const PROPS = {
  shelf: () => (<g stroke={INK} strokeWidth="2"><rect x="-30" y="-78" width="60" height="78" fill="#8C5A3C" />
    {[-56, -30].map(y => <line key={y} x1="-30" x2="30" y1={y} y2={y} />)}
    {[[-56, [-26, -18, -10, 4], 18], [-30, [-24, -14, 10, 18], 22], [0, [-22, -6, 8], 26]].flatMap(([y, xs, h], b) => xs.map((x, i) => <rect key={`${b}${i}`} x={x} y={y - h + (i % 2) * 3} width="7" height={h - (i % 2) * 3} fill={["#B8483A", "#3F8DB8", "#E2B13C", "#4E8B3E", "#6C5B9C"][(b + i) % 5]} strokeWidth="1" />))}</g>),
  books: () => (<g stroke={INK} strokeWidth="1.5"><rect x="-22" y="-10" width="44" height="10" fill="#B8483A" /><rect x="-18" y="-20" width="38" height="10" fill="#3F8DB8" /><rect x="-20" y="-30" width="34" height="10" fill="#E2B13C" /><rect x="-14" y="-38" width="28" height="8" fill="#4E8B3E" /></g>),
  lamp: () => (<g stroke={INK} strokeWidth="2"><circle cx="0" cy="-62" r="22" fill="#FFF3CD" opacity="0.45" stroke="none" /><line x1="0" y1="0" x2="0" y2="-56" /><rect x="-10" y="-2" width="20" height="4" fill="#6E5B3E" /><path d="M-14 -56 L14 -56 L8 -74 L-8 -74 Z" fill="#E2B13C" /></g>),
  window: () => (<g stroke={INK} strokeWidth="2.5"><path d="M-22 0 L-22 -40 A22 22 0 0 1 22 -40 L22 0 Z" fill="#CFE6F5" /><line x1="0" y1="0" x2="0" y2="-62" /><line x1="-22" y1="-28" x2="22" y2="-28" /><rect x="-26" y="0" width="52" height="5" fill="#A8875E" /></g>),
  ladder: () => (<g stroke="#6E4E2E" strokeWidth="4" strokeLinecap="round"><line x1="-12" y1="0" x2="-8" y2="-92" /><line x1="12" y1="0" x2="8" y2="-92" />{[-14, -32, -50, -68, -86].map(y => <line key={y} x1="-11" x2="11" y1={y} y2={y} strokeWidth="3" />)}</g>),
  block: () => (<g stroke={INK} strokeWidth="2"><rect x="-26" y="-22" width="22" height="22" fill="#E2557A" /><rect x="-2" y="-22" width="22" height="22" fill="#3F8DB8" /><rect x="-14" y="-44" width="22" height="22" fill="#E2B13C" /><text x="-15" y="-6" fontSize="14" fontWeight="800" fill="#fff" stroke="none" textAnchor="middle">A</text><text x="9" y="-6" fontSize="14" fontWeight="800" fill="#fff" stroke="none" textAnchor="middle">B</text><text x="-3" y="-28" fontSize="14" fontWeight="800" fill="#fff" stroke="none" textAnchor="middle">C</text></g>),
  flowers: () => (<g>{[[-16, -26, "#E2557A"], [0, -36, "#E2B13C"], [16, -22, "#B86FA8"]].map(([x, y, c]) => <g key={x}><line x1={x} y1="0" x2={x} y2={y} stroke="#4E8B3E" strokeWidth="3" /><circle cx={x} cy={y} r="7" fill={c} stroke={INK} strokeWidth="1.5" /><circle cx={x} cy={y} r="2.5" fill="#FFF3CD" /></g>)}</g>),
  lantern: () => (<g stroke={INK} strokeWidth="2"><circle cx="0" cy="-60" r="18" fill="#FFE680" opacity="0.4" stroke="none" /><line x1="0" y1="0" x2="0" y2="-48" strokeWidth="3" /><rect x="-8" y="-70" width="16" height="20" rx="3" fill="#FFD27A" /><path d="M-10 -70 L0 -78 L10 -70 Z" fill="#5C4A6E" /></g>),
  planet: () => (<g><circle cx="0" cy="0" r="18" fill="#E2A35B" stroke={INK} strokeWidth="2" /><ellipse cx="0" cy="0" rx="32" ry="8" fill="none" stroke="#F2DDDA" strokeWidth="3" transform="rotate(-18)" /></g>),
  column: () => (<g stroke={INK} strokeWidth="2" fill="#E8E2D1"><rect x="-16" y="-8" width="32" height="8" /><rect x="-11" y="-80" width="22" height="72" />{[-5, 0, 5].map(x => <line key={x} x1={x} x2={x} y1="-78" y2="-10" strokeWidth="1" />)}<rect x="-16" y="-88" width="32" height="8" /></g>),
  torch: () => (<g><circle cx="0" cy="-62" r="16" fill="#FFB347" opacity="0.35" /><rect x="-3" y="-52" width="6" height="52" fill="#6E4E2E" stroke={INK} strokeWidth="1.5" /><path d="M0 -76 Q10 -62 4 -54 L-4 -54 Q-10 -62 0 -76 Z" fill="#FF9F2F" stroke="#D7261E" strokeWidth="1.5" /></g>),
  tree: () => (<g stroke={INK} strokeWidth="2"><rect x="-6" y="-40" width="12" height="40" fill="#8C5A3C" /><circle cx="0" cy="-62" r="26" fill="#5E8C6A" /><circle cx="-16" cy="-48" r="15" fill="#4E7A5A" /><circle cx="17" cy="-50" r="15" fill="#6E9B6A" /></g>),
  bush: () => (<g stroke={INK} strokeWidth="2" fill="#5E8C6A"><circle cx="-14" cy="-12" r="13" /><circle cx="14" cy="-12" r="13" /><circle cx="0" cy="-20" r="15" fill="#6E9B6A" /><circle cx="-5" cy="-22" r="2.5" fill="#B8483A" stroke="none" /><circle cx="8" cy="-14" r="2.5" fill="#B8483A" stroke="none" /></g>),
  fence: () => (<g stroke={INK} strokeWidth="1.5" fill="#C9A27A"><rect x="-30" y="-24" width="60" height="5" /><rect x="-30" y="-12" width="60" height="5" />{[-26, -9, 8, 25].map(x => <path key={x} d={`M${x - 4} 0 L${x - 4} -28 L${x} -33 L${x + 4} -28 L${x + 4} 0 Z`} />)}</g>),
  mushroom: () => (<g stroke={INK} strokeWidth="2"><rect x="-6" y="-24" width="12" height="24" rx="4" fill="#F2E8D5" /><path d="M-22 -22 Q0 -54 22 -22 Z" fill="#B8483A" /><circle cx="-8" cy="-32" r="3" fill="#fff" stroke="none" /><circle cx="7" cy="-36" r="3.5" fill="#fff" stroke="none" /></g>),
  moon: () => (<g><circle cx="0" cy="0" r="22" fill="#FFF3CD" opacity="0.25" /><path d="M6 -16 A16 16 0 1 0 6 16 A12 12 0 1 1 6 -16 Z" fill="#FFF3CD" stroke="#E2B13C" strokeWidth="1.5" /></g>),
  pool: () => (<g><ellipse cx="0" cy="4" rx="40" ry="9" fill="#5E8FB0" stroke={INK} strokeWidth="1.5" /><path d="M-24 3 Q-18 0 -12 3 M8 6 Q14 3 20 6" stroke="#CFE6F5" strokeWidth="2" fill="none" /></g>),
  rock: () => (<path d="M-26 0 L-20 -18 L-6 -26 L12 -22 L24 -10 L28 0 Z" fill="#8A8478" stroke={INK} strokeWidth="2" />),
  fern: () => (<g fill="none" stroke="#4E8B3E" strokeWidth="4" strokeLinecap="round"><path d="M0 0 Q-6 -30 -28 -40" /><path d="M0 0 Q4 -36 20 -48" /><path d="M0 0 Q-2 -24 -10 -54" stroke="#5E9B4E" /><path d="M0 0 Q12 -14 30 -20" /></g>),
  house: () => (<g stroke={INK} strokeWidth="2"><rect x="-24" y="-36" width="48" height="36" fill="#F2E8D5" /><path d="M-30 -34 L0 -60 L30 -34 Z" fill="#B8483A" /><rect x="-6" y="-20" width="12" height="20" fill="#8C5A3C" /><rect x="10" y="-28" width="9" height="9" fill="#FFE680" /></g>),
  bridge: () => (<g stroke={INK} strokeWidth="2"><path d="M-44 0 Q0 -40 44 0" fill="none" stroke="#8C5A3C" strokeWidth="7" /><path d="M-44 -14 Q0 -54 44 -14" fill="none" stroke="#6E4E2E" strokeWidth="2.5" />{[-30, -15, 0, 15, 30].map(x => <line key={x} x1={x} x2={x} y1={-20 + Math.abs(x) * 0.45 - 14} y2={-20 + Math.abs(x) * 0.45 + (Math.abs(x) > 20 ? 6 : 0)} stroke="#6E4E2E" />)}</g>),
  leaf: () => (<g stroke={INK} strokeWidth="2"><path d="M0 0 L0 -30" stroke="#4E7A3E" strokeWidth="4" /><path d="M0 -30 Q-40 -50 -6 -96 Q34 -60 0 -30 Z" fill="#6E9B4E" /><path d="M0 -32 Q-6 -60 -6 -92" fill="none" stroke="#4E7A3E" /></g>),
  tent: () => (<g stroke={INK} strokeWidth="2"><path d="M-32 0 L0 -54 L32 0 Z" fill="#E2557A" /><path d="M-16 0 L0 -54 L16 0 Z" fill="#FFF3CD" /><path d="M-6 0 L0 -20 L6 0 Z" fill={INK} /><path d="M0 -54 L0 -66 L12 -62 L0 -58" fill="#E2B13C" /></g>),
  stalactite: () => (<g fill="#6E6380" stroke={INK} strokeWidth="1.5"><path d="M-30 0 L-22 34 L-14 0 Z" /><path d="M-10 0 L0 50 L10 0 Z" /><path d="M14 0 L20 26 L28 0 Z" /></g>),
  crystal: () => (<g stroke={INK} strokeWidth="1.5"><path d="M-14 0 L-20 -30 L-10 -42 L-4 -28 L-4 0 Z" fill="#B9E3F2" /><path d="M-4 0 L0 -54 L10 -40 L10 0 Z" fill="#C9B6F2" /><path d="M10 0 L18 -26 L24 -18 L22 0 Z" fill="#8CCFF2" /></g>),
  bones: () => (<g fill="#F2E8D5" stroke={INK} strokeWidth="1.5"><path d="M-30 -4 L18 -14" strokeWidth="5" stroke="#F2E8D5" /><circle cx="-32" cy="-6" r="4" /><circle cx="-30" cy="-1" r="4" /><circle cx="20" cy="-16" r="4" /><circle cx="22" cy="-11" r="4" /><path d="M2 0 Q2 -22 16 -22 Q30 -22 30 -8 L28 0 Z" /><circle cx="12" cy="-12" r="3" fill={INK} /><circle cx="22" cy="-12" r="3" fill={INK} /></g>),
  lava: () => (<g><ellipse cx="0" cy="4" rx="42" ry="9" fill="#E2552E" stroke="#8E2E1E" strokeWidth="2" /><ellipse cx="-6" cy="3" rx="24" ry="4" fill="#FFB347" /><circle cx="14" cy="-6" r="3" fill="#FF9F2F" /></g>),
  wave: () => (<g><path d="M-50 6 Q-37 -10 -25 0 Q-12 -14 0 0 Q12 -14 25 0 Q37 -10 50 6 Z" fill="#3E6E8C" stroke={INK} strokeWidth="1.5" /><path d="M-30 -2 Q-20 -10 -10 -4 M14 -4 Q24 -12 34 -2" stroke="#fff" strokeWidth="2.5" fill="none" /></g>),
  palm: () => (<g stroke={INK} strokeWidth="2"><path d="M-2 0 Q-8 -40 6 -76" fill="none" stroke="#8C6B4E" strokeWidth="7" /><g fill="#4E8B3E"><path d="M6 -76 Q-20 -88 -36 -66 Q-14 -76 6 -76 Z" /><path d="M6 -76 Q30 -92 46 -70 Q24 -78 6 -76 Z" /><path d="M6 -76 Q-6 -100 -22 -98 Q-4 -88 6 -76 Z" /><path d="M6 -76 Q22 -102 36 -94 Q18 -88 6 -76 Z" /></g><circle cx="2" cy="-72" r="4" fill="#8C5A3C" /><circle cx="10" cy="-71" r="4" fill="#8C5A3C" /></g>),
  ship: () => (<g stroke={INK} strokeWidth="2"><path d="M-36 -16 L36 -16 L26 0 L-26 0 Z" fill="#8C5A3C" /><line x1="0" y1="-16" x2="0" y2="-80" strokeWidth="3" /><path d="M2 -76 L30 -26 L2 -26 Z" fill="#F2F0EA" /><path d="M-2 -70 L-24 -28 L-2 -28 Z" fill="#E8E2D1" /><path d="M0 -80 L14 -76 L0 -72" fill="#B8483A" /></g>),
  tower: () => (<g stroke={INK} strokeWidth="2"><rect x="-14" y="-82" width="28" height="82" fill="#C9C2B8" /><path d="M-20 -80 L0 -110 L20 -80 Z" fill="#5C4A6E" /><rect x="-5" y="-66" width="10" height="14" rx="5" fill="#FFE680" /><rect x="-5" y="-36" width="10" height="14" rx="5" fill="#2D2F26" /></g>),
  cloud: () => (<g fill="#fff" opacity="0.92"><circle cx="-16" cy="2" r="12" /><circle cx="0" cy="-6" r="16" /><circle cx="18" cy="2" r="12" /><rect x="-28" y="2" width="58" height="12" rx="6" /></g>),
  cactus: () => (<g stroke={INK} strokeWidth="2" fill="#6E9B4E"><rect x="-8" y="-66" width="16" height="66" rx="8" /><path d="M-8 -30 L-20 -30 Q-26 -30 -26 -38 L-26 -50 Q-26 -54 -22 -54 Q-18 -54 -18 -50 L-18 -40 L-8 -40" /><path d="M8 -38 L20 -38 Q24 -38 24 -46 L24 -58 Q24 -62 20 -62 Q16 -62 16 -58 L16 -46 L8 -46" /></g>),
  dune: () => (<path d="M-60 6 Q-30 -22 0 -10 Q28 -26 60 6 Z" fill="#E2B87A" stroke="#B88B5A" strokeWidth="1.5" />),
  pyramid: () => (<g stroke={INK} strokeWidth="2"><path d="M-46 0 L0 -64 L46 0 Z" fill="#E2B13C" /><path d="M0 -64 L46 0 L14 0 Z" fill="#C9963A" /><rect x="-6" y="-14" width="12" height="14" fill={INK} /></g>),
  mountain: () => (<g stroke={INK} strokeWidth="2"><path d="M-56 0 L-4 -96 L50 0 Z" fill="#8A8C9C" /><path d="M-4 -96 L-20 -66 L-10 -70 L-2 -60 L8 -72 L14 -62 Z" fill="#fff" /></g>),
  snow: () => (<g stroke={INK} strokeWidth="1.5"><path d="M-40 4 Q-20 -14 0 -6 Q20 -16 40 4 Z" fill="#fff" /><circle cx="14" cy="-18" r="12" fill="#fff" /><circle cx="14" cy="-38" r="9" fill="#fff" /><circle cx="11" cy="-40" r="1.5" fill={INK} /><circle cx="17" cy="-40" r="1.5" fill={INK} /><path d="M14 -37 L22 -35 L14 -34 Z" fill="#F28C3E" stroke="none" /></g>),
  igloo: () => (<g stroke={INK} strokeWidth="2"><path d="M-36 0 A36 36 0 0 1 36 0 Z" fill="#F4F7FA" /><path d="M-10 0 A10 12 0 0 1 10 0 Z" fill="#4D5A6E" /><path d="M-32 -14 L32 -14 M-22 -27 L22 -27 M-8 0 L-8 -14 M14 -14 L14 -27 M-12 -27 L-12 -34" stroke="#B9C7D6" strokeWidth="1.5" /></g>),
  castle: () => (<g stroke={INK} strokeWidth="2" fill="#9A9488"><path d="M-46 0 L-46 -50 L-40 -50 L-40 -44 L-34 -44 L-34 -50 L-28 -50 L-28 -44 L28 -44 L28 -50 L34 -50 L34 -44 L40 -44 L40 -50 L46 -50 L46 0 Z" /><rect x="-16" y="-86" width="32" height="44" /><path d="M-20 -84 L0 -108 L20 -84 Z" fill="#8E3B5C" /><path d="M-10 0 L-10 -18 A10 10 0 0 1 10 -18 L10 0 Z" fill="#4D3B32" /><rect x="-4" y="-72" width="8" height="12" fill="#FFE680" /></g>),
  rainbow: () => (<g fill="none" strokeWidth="5" opacity="0.85">{["#E2552E", "#E2B13C", "#9BC46A", "#3F8DB8", "#8E5CB8"].map((c, i) => <path key={c} d={`M${-60 + i * 5} 30 A${60 - i * 5} ${60 - i * 5} 0 0 1 ${60 - i * 5} 30`} stroke={c} />)}</g>),
  gear: () => (<g><circle cx="0" cy="-34" r="26" fill="none" stroke="#A88B5F" strokeWidth="10" strokeDasharray="8 6" /><circle cx="0" cy="-34" r="22" fill="#C9A27A" stroke={INK} strokeWidth="2" /><circle cx="0" cy="-34" r="7" fill="#6E5B3E" stroke={INK} strokeWidth="2" /><rect x="-3" y="-8" width="6" height="8" fill="#6E5B3E" /></g>),
  pipe: () => (<g stroke={INK} strokeWidth="2"><path d="M-30 0 L-30 -50 Q-30 -60 -20 -60 L20 -60 L20 -44 L-14 -44 L-14 0 Z" fill="#B87333" /><rect x="14" y="-64" width="12" height="24" fill="#9A5C28" /><g fill="#fff" opacity="0.8" stroke="none"><circle cx="34" cy="-56" r="7" /><circle cx="42" cy="-66" r="9" /></g></g>),
  reed: () => (<g stroke="#5E7A3E" strokeWidth="3" strokeLinecap="round">{[[-12, -52], [0, -64], [12, -48]].map(([x, y]) => <g key={x}><line x1={x} y1="0" x2={x} y2={y} /><rect x={x - 3} y={y} width="6" height="16" rx="3" fill="#6B4E30" stroke="none" /></g>)}<path d="M-20 0 Q-26 -20 -34 -26 M20 0 Q26 -18 34 -24" fill="none" /></g>),
  lily: () => (<g><ellipse cx="0" cy="4" rx="40" ry="8" fill="#3E5E6E" opacity="0.7" /><path d="M-18 2 A14 6 0 1 1 -4 2 L-11 1 Z" fill="#6E9B4E" stroke={INK} strokeWidth="1.2" /><path d="M6 6 A14 6 0 1 1 22 4 L14 4 Z" fill="#5E8C4E" stroke={INK} strokeWidth="1.2" /><circle cx="14" cy="0" r="4" fill="#F2A6C0" /></g>),
  candy: () => (<g strokeLinecap="round"><path d="M0 0 L0 -54 Q0 -68 -12 -68 Q-22 -68 -22 -58" fill="none" stroke="#fff" strokeWidth="9" /><path d="M0 0 L0 -54 Q0 -68 -12 -68 Q-22 -68 -22 -58" fill="none" stroke="#D7261E" strokeWidth="9" strokeDasharray="6 6" /></g>),
  lollipop: () => (<g><line x1="0" y1="0" x2="0" y2="-44" stroke="#F2E8D5" strokeWidth="4" /><circle cx="0" cy="-58" r="16" fill="#E2557A" stroke={INK} strokeWidth="2" /><path d="M0 -58 m-10 0 a10 10 0 1 1 10 10 a6 6 0 1 1 -6 -6" fill="none" stroke="#fff" strokeWidth="3" /></g>),
  vine: () => (<g><path d="M0 0 Q-14 22 0 44 Q12 62 -2 82" fill="none" stroke="#4E7A3E" strokeWidth="4" />{[[-8, 18], [8, 40], [-6, 64]].map(([x, y]) => <ellipse key={y} cx={x} cy={y} rx="8" ry="4" fill="#6E9B4E" transform={`rotate(${x > 0 ? 30 : -30} ${x} ${y})`} />)}</g>),
  volcano: () => (<g stroke={INK} strokeWidth="2"><circle cx="0" cy="-86" r="10" fill="#9A9488" opacity="0.6" stroke="none" /><circle cx="10" cy="-100" r="13" fill="#9A9488" opacity="0.45" stroke="none" /><path d="M-56 0 L-14 -70 L14 -70 L56 0 Z" fill="#6B4E3E" /><path d="M-14 -70 L14 -70 L8 -60 L2 -66 L-4 -56 L-10 -64 Z" fill="#FF7A2F" /></g>),
  wheel: () => (<g stroke={INK} strokeWidth="2"><path d="M-22 0 L0 -50 L22 0" fill="none" stroke="#6E7163" strokeWidth="3" /><circle cx="0" cy="-50" r="38" fill="none" stroke="#E2557A" strokeWidth="3" />{[0, 45, 90, 135].map(a => <line key={a} x1={-38 * Math.cos(a * Math.PI / 180)} y1={-50 - 38 * Math.sin(a * Math.PI / 180)} x2={38 * Math.cos(a * Math.PI / 180)} y2={-50 + 38 * Math.sin(a * Math.PI / 180)} stroke="#E2B13C" strokeWidth="1.5" />)}{[0, 60, 120, 180, 240, 300].map(a => <rect key={a} x={38 * Math.cos(a * Math.PI / 180) - 5} y={-50 + 38 * Math.sin(a * Math.PI / 180) - 4} width="10" height="8" rx="2" fill="#3F8DB8" />)}</g>),
  rocket: () => (<g stroke={INK} strokeWidth="2"><path d="M-10 -14 L-22 0 L-10 -2 Z M10 -14 L22 0 L10 -2 Z" fill="#B8483A" /><path d="M-10 -2 L-10 -60 Q0 -84 10 -60 L10 -2 Z" fill="#F2F0EA" /><circle cx="0" cy="-48" r="5" fill="#8CCFF2" /><path d="M-6 -2 L0 12 L6 -2 Z" fill="#FF9F2F" stroke="none" /></g>),
  mirror: () => (<g stroke={INK} strokeWidth="2"><line x1="-10" y1="0" x2="0" y2="-20" /><line x1="10" y1="0" x2="0" y2="-20" /><ellipse cx="0" cy="-50" rx="20" ry="30" fill="#E2B13C" /><ellipse cx="0" cy="-50" rx="15" ry="25" fill="#DCE8F2" /><path d="M-8 -64 L4 -40" stroke="#fff" strokeWidth="3" /></g>),
  spire: () => (<g stroke={INK} strokeWidth="2"><path d="M-16 0 L-8 -110 L0 -140 L8 -110 L16 0 Z" fill="#3B3E4E" /><rect x="-3" y="-90" width="6" height="10" fill="#B86FA8" /><rect x="-3" y="-50" width="6" height="10" fill="#B86FA8" /></g>),
};

function Prop({ k, x, scale = 1, far = false }) {
  const draw = PROPS[k];
  if (!draw) return null;
  const y = SKY.has(k) ? 34 + (Math.abs(x * 7) % 22) : HANG.has(k) ? 0 : FLAT.has(k) ? GY + 6 : GY - (LIFT[k] || 0);
  return <g transform={`translate(${x} ${y}) scale(${scale})`} opacity={far ? 0.5 : 1}>{draw()}</g>;
}

// Small seeded jitter so the stars sit in the same place every time for a level.
const seeded = n => { const s = Math.sin(n * 9301 + 49297) * 233280; return s - Math.floor(s); };

// wide: a short, wide strip (map banners); shows more of the sides and the tops of things.
export default function QuestScene({ world, level = null, step = 1, wide = false, style }) {
  const id = useMemo(() => `qs${Math.random().toString(36).slice(2, 8)}`, []);
  if (!world) return null;
  const time = step >= 15 ? "night" : step >= 9 ? "dusk" : "day";
  const near = level?.props || [];
  const base = world.base || [];
  return (
    <svg viewBox={wide ? `-150 20 ${W + 300} ${H - 20}` : `0 0 ${W} ${H}`} preserveAspectRatio="xMidYMax slice" aria-hidden="true"
      style={{ position: "absolute", inset: 0, width: "100%", height: "100%", display: "block", ...style }}>
      <defs>
        <linearGradient id={`${id}s`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={world.sky[0]} /><stop offset="1" stopColor={world.sky[1]} />
        </linearGradient>
      </defs>
      <rect x="-150" y="0" width={W + 300} height={GY} fill={`url(#${id}s)`} />
      {/* far scenery: the world's theme */}
      {base.flatMap(k => [-150, -10, 130, 270, 410, 550].map((x, i) => <Prop key={`${k}${i}`} k={k} x={x + (i % 2 ? 10 : 0)} scale={SKY.has(k) || HANG.has(k) ? 0.9 : 1.15} far />))}
      <rect x="-150" y={GY} width={W + 300} height={H - GY} fill={world.ground} />
      <rect x="-150" y={GY} width={W + 300} height="4" fill="#fff" opacity="0.18" />
      {/* near scenery: the level's sub-theme, kept to the middle so the fighters stay clear */}
      {near.map((k, i) => <Prop key={`n${i}`} k={k} x={i === 0 ? 150 : 255} scale={0.95} />)}
      {/* time of day */}
      {time === "dusk" ? <rect x="-150" y="0" width={W + 300} height={H} fill="#F28C3E" opacity="0.16" /> : null}
      {time === "night" ? (
        <g>
          <rect x="-150" y="0" width={W + 300} height={H} fill="#1E2340" opacity="0.38" />
          {Array.from({ length: 22 }, (_, i) => <circle key={i} cx={seeded(i + 1) * W} cy={seeded(i + 40) * (GY - 50)} r={seeded(i + 80) > 0.7 ? 1.6 : 1} fill="#fff" opacity="0.85" />)}
          {near.includes("moon") || base.includes("moon") ? null : <g transform="translate(352 30) scale(0.7)">{PROPS.moon()}</g>}
        </g>
      ) : null}
    </svg>
  );
}
