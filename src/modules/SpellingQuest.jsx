import { useEffect, useMemo, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";
import { useDancers, CritterIcon } from "../components/Critters.jsx";
import QuestMonster from "../components/QuestMonster.jsx";
import QuestScene from "../components/QuestScene.jsx";
import {
  WORLDS, MONSTERS as QUEST_MONSTERS, LEVELS_PER_WORLD, MONSTERS_PER_LEVEL, LEVEL_TOTAL, worldOf, stepOf, levelInfo, levelName,
  monstersForLevel, heroHpForLevel, endlessMonster, endlessWorld, ENDLESS_HERO_HP, starsFor,
  POTIONS, POTION_KEYS, POTION_MAX, TREASURES, EQUIP_MAX, treasuresOwned, treasureLevel, STORY_PARTS,
} from "../lib/questWorlds.js";

// =========================================================================
// SpellingQuest.jsx — the Family spelling game (in the style of Bookworm and
// Bookworm Adventures). Two modes, each with a map and an Endless run.
//
// Monsters (like Bookworm Adventures): a 4x4 grid of letters, used in any
// order. Each word hits the monster for its exact score; the monster hits back.
// 20 worlds of 20 levels (src/lib/questWorlds.js has the story, the worlds, the
// monsters and the treasures); every level is five monsters, and level 20 of a
// world ends in its boss. Each world has a theme and each level a sub-theme,
// drawn behind the fight (src/components/QuestScene.jsx).
// Long words leave gem tiles: emerald heals, amethyst cures, sapphire freezes the
// monster, ruby hits 50% harder, diamond hits twice as hard and heals. Monsters
// may stone or set fire to a letter, poison you or weaken you. Beaten monsters
// drop potions (heal, power, freeze, cure) kept between games. Beating a boss
// wins a treasure; equip up to three. Levels earn 1–3 stars for health left.
// Treasures power up the more they're worn (level 2 at 10 wins, 3 at 25).
// Each world opens and closes with a story page that can be read aloud, with
// each word lit up as it's spoken (the browser's own voice, no files).
// Heroes are the family's dancing characters; a kid starts on their own animal.
// After each world's boss comes a one-minute bonus round (like Bookworm
// Adventures' arcade games) that wins up to three potions: Word Rush (as many
// words as you can) or Unscramble (put mixed-up words back together).
//
// Fire (like Bookworm): a 5x5 square grid; letters must touch (sideways, up,
// down or corner to corner). Short words can drop fire tiles that burn down a
// row after each word; a map level is won by reaching its score first.
//
// Difficulty (Starter, Easy, Medium, Hard) sets the letters, monster strength,
// fire speed, hints and shortest word. A kid starts at the level for their age,
// so each plays where they win most of the time but not all of it, where
// practice pays off most (Wilson et al. 2019, Nature Communications 10:4646).
//
// Saved per kid on family_kids.game_bests: bookworm (Fire), bookworm_battle
// (Monsters) — best score, unlocked.<difficulty> (highest level open, only goes
// up), items (potions), stars["<difficulty>:<level>"] (only goes up), equip
// (treasures worn) and treasure_xp["<treasure>"] (levels won wearing it). Guest progress lasts until the page closes.
// Word lists: public/games/words.txt (accepted), common.txt (hints only).
// =========================================================================

const FIRE_LEVELS = 12;
const FIRE_SIZE = 5; // Fire grid is 5x5 (was 7x7: too many letters to be a real challenge)

// How often each letter shows up (roughly English) and what it is worth (x10).
const LETTERS = [
  ["E", 12, 1], ["A", 9, 1], ["I", 8, 1], ["O", 8, 1], ["N", 6, 1], ["R", 6, 1], ["T", 6, 1], ["S", 5, 1],
  ["L", 4, 1], ["U", 4, 1], ["D", 4, 1.25], ["G", 3, 1.25], ["B", 2, 1.5], ["C", 2, 1.5], ["M", 2, 1.5],
  ["P", 2, 1.5], ["F", 2, 1.75], ["H", 2, 1.75], ["V", 2, 1.75], ["W", 2, 1.75], ["Y", 2, 1.75],
  ["K", 1, 2.75], ["J", 1, 3], ["X", 1, 3], ["QU", 1, 3.5], ["Z", 1, 3.5],
];
const HARD_LETTERS = new Set(["K", "J", "X", "QU", "Z", "V"]);
const VALUE = Object.fromEntries(LETTERS.map(([ch, , v]) => [ch, v]));
const VOWELS = new Set(["A", "E", "I", "O", "U"]);
const LEN_MULT = { 3: 1, 4: 1.25, 5: 1.5, 6: 2, 7: 2.5, 8: 3, 9: 3.5 };
const GEM_FOR_LEN = len => (len >= 7 ? "diamond" : len === 6 ? "gold" : len === 5 ? "green" : null);
const FIRE_GEM_BONUS = { green: 0.5, gold: 1, diamond: 2 };
// Monsters mode gems (like Bookworm Adventures): which one a long word leaves.
function monsterGem(len, fourToo) {
  if (len >= 7) return "diamond";
  if (len === 6) return Math.random() < 0.55 ? "ruby" : "sapphire";
  if (len === 5) return Math.random() < 0.65 ? "emerald" : "amethyst";
  if (len === 4 && fourToo) return "emerald";
  return null;
}
const GEM_LOOK = {
  green:    { bg: "linear-gradient(160deg,#B9F2C8,#4CBF72)", border: "#2E8B57", ink: "#0F3D22" },
  gold:     { bg: "linear-gradient(160deg,#FFE9A6,#E2B13C)", border: "#A8801F", ink: "#4A3500" },
  diamond:  { bg: "linear-gradient(160deg,#FFFFFF,#BCE6F7)", border: "#3F8DB8", ink: "#0E3550" },
  emerald:  { bg: "linear-gradient(160deg,#B9F2C8,#4CBF72)", border: "#2E8B57", ink: "#0F3D22" },
  ruby:     { bg: "linear-gradient(160deg,#FFC2C2,#D7261E)", border: "#8E1B14", ink: "#FFFFFF" },
  sapphire: { bg: "linear-gradient(160deg,#C9DEFF,#2F6FD6)", border: "#1B3E8E", ink: "#FFFFFF" },
  amethyst: { bg: "linear-gradient(160deg,#EBD5FF,#8E5CB8)", border: "#5C3480", ink: "#FFFFFF" },
};
const GEM_KEY = "Gems: emerald heals · amethyst cures · sapphire freezes · ruby +50% · diamond ×2 and heals";

// Treasure effects worn in a fight.
// Treasure effects worn in a fight; each worn treasure carries its powered-up value (questWorlds.treasurePower).
const eqCount = (eq, effect) => (eq || []).filter(t => t.effect === effect).length;
const eqSum = (eq, effect) => (eq || []).reduce((a, t) => a + (t.effect === effect ? t.value : 0), 0);
function treasureBoost(eq, tiles, letters) {
  let k = 1;
  for (const t of eq || []) {
    if (t.effect === "letters" && tiles.some(x => t.letters.includes(x.ch[0]))) k *= 1 + t.value / 100;
    if (t.effect === "long" && letters >= 6) k *= 1 + t.value / 100;
    if (t.extra) k *= 1 + t.extra / 100;
  }
  return k;
}

// ── Read aloud: the browser's own voice. onWord gets the index of the word being spoken.
function speak(text, onWord, onEnd) {
  try {
    const synth = window.speechSynthesis;
    if (!synth || typeof SpeechSynthesisUtterance === "undefined") return false;
    synth.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.rate = 0.9; u.pitch = 1.05;
    const voice = synth.getVoices().find(v => /^en[-_]US/i.test(v.lang)) || synth.getVoices().find(v => /^en/i.test(v.lang));
    if (voice) u.voice = voice;
    const starts = [];
    text.replace(/\S+/g, (w, at) => { starts.push(at); return w; });
    u.onboundary = e => { if (e.name === "word" || e.name === undefined) { let i = 0; while (i + 1 < starts.length && starts[i + 1] <= e.charIndex) i += 1; onWord(i); } };
    u.onend = () => onEnd();
    u.onerror = () => onEnd();
    synth.speak(u);
    return true;
  } catch { return false; }
}
function stopSpeaking() { try { if (window.speechSynthesis) window.speechSynthesis.cancel(); } catch { /* fine */ } }

// ── Sounds: tiny made-up beeps, no files. Off when muted.
const SOUND = { muted: false, ctx: null };
try { SOUND.muted = window.localStorage.getItem("sq_muted") === "1"; } catch { SOUND.muted = false; }
const TUNES = {
  hit: [["square", 520, 260, 0.12]], hurt: [["sawtooth", 200, 110, 0.18]], heal: [["sine", 520, 880, 0.22]],
  gem: [["triangle", 880, 1320, 0.12]], potion: [["sine", 660, 990, 0.18]], tap: [["triangle", 700, 700, 0.03]],
  win: [["triangle", 523, 523, 0.12], ["triangle", 659, 659, 0.12], ["triangle", 784, 784, 0.12], ["triangle", 1047, 1047, 0.25]],
  lose: [["sine", 392, 330, 0.2], ["sine", 294, 196, 0.35]], status: [["square", 300, 240, 0.14]],
};
function sound(name) {
  if (SOUND.muted || typeof window === "undefined") return;
  try {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    const ctx = SOUND.ctx || (SOUND.ctx = new AC());
    let t = ctx.currentTime;
    for (const [type, f1, f2, len] of TUNES[name] || []) {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.type = type; o.frequency.setValueAtTime(f1, t); o.frequency.linearRampToValueAtTime(f2, t + len);
      g.gain.setValueAtTime(0.08, t); g.gain.exponentialRampToValueAtTime(0.001, t + len);
      o.connect(g); g.connect(ctx.destination); o.start(t); o.stop(t + len + 0.02);
      t += len;
    }
  } catch { /* no sound on this device */ }
}

// ── Difficulty ──────────────────────────────────────────────────────────
//   hardLetters  weight of K J X Qu Z V (0 = never); vowels: share kept between
//   minLen       shortest word that counts
//   monsterHp / monsterHit   multiply monster health and hits
//   fire         multiply the chance a fire drops in; burnEvery: fire burns every Nth word
//   goal         multiply the score a Fire level asks for; hints per level
const DIFFICULTY = {
  starter: { label: "Starter", ages: "5–7",   hardLetters: 0,   vowels: [0.38, 0.55], minLen: 3, monsterHp: 0.6,  monsterHit: 0.5,  fire: 0.5,  burnEvery: 2, goal: 0.6, hints: Infinity },
  easy:    { label: "Easy",    ages: "8–10",  hardLetters: 0.5, vowels: [0.33, 0.5],  minLen: 3, monsterHp: 0.8,  monsterHit: 0.75, fire: 0.75, burnEvery: 1, goal: 0.8, hints: 3 },
  medium:  { label: "Medium",  ages: "11–13", hardLetters: 1,   vowels: [0.3, 0.5],   minLen: 3, monsterHp: 1,    monsterHit: 1,    fire: 1,    burnEvery: 1, goal: 1,   hints: 1 },
  hard:    { label: "Hard",    ages: "14+",   hardLetters: 1,   vowels: [0.28, 0.48], minLen: 4, monsterHp: 1.25, monsterHit: 1.2,  fire: 1.3,  burnEvery: 1, goal: 1.3, hints: 0 },
};
const DIFF_KEYS = ["starter", "easy", "medium", "hard"];
const diffForAge = age => (age == null ? "medium" : age <= 7 ? "starter" : age <= 10 ? "easy" : age <= 13 ? "medium" : "hard");

// ── Fire levels ─────────────────────────────────────────────────────────
function fireLevel(n, diff) {
  return {
    // Tuned for the 5x5 grid: fewer letters means fewer long words, and fire
    // only has five rows to fall, so goals and fire chances are 80% of the 7x7 ones.
    goal: Math.round(((240 + 120 * (n - 1)) * diff.goal) / 10) * 10,
    fire3: Math.min(0.6, (0.16 + 0.032 * n) * diff.fire),
    fire4: Math.min(0.36, 0.024 * n * diff.fire),
    startFires: Math.min(2, Math.floor((n - 1) / 4)),
  };
}
const endlessLevelAt = lv => 240 * (lv * (lv - 1)) / 2;

const ri = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
const pick = arr => arr[Math.floor(Math.random() * arr.length)];

// ── Word lists and hints ────────────────────────────────────────────────
const LISTS = {};
function loadList(name) {
  if (!LISTS[name]) {
    const base = (import.meta.env && import.meta.env.BASE_URL) || "/";
    LISTS[name] = fetch(`${base}games/${name}.txt`)
      .then(r => { if (!r.ok) throw new Error(`Word list didn't load (${r.status})`); return r.text(); })
      .then(t => new Set(t.split("\n").map(w => w.trim()).filter(Boolean)))
      .catch(e => { delete LISTS[name]; throw e; });
  }
  return LISTS[name];
}
const PREFIXES = new WeakMap();
function prefixesOf(words) {
  let p = PREFIXES.get(words);
  if (!p) {
    p = new Set();
    for (const w of words) for (let i = 1; i < w.length; i++) p.add(w.slice(0, i));
    PREFIXES.set(words, p);
  }
  return p;
}
const hintRank = len => (len === 4 || len === 5 ? 3 : len === 6 ? 2 : len === 3 ? 1 : 0);

// Any-order board (Monsters): the best word the letters can make, as tile ids.
function hintAnyOrder(board, words, minLen) {
  const tiles = board.flat().filter(t => !t.stone);
  let best = null;
  for (const w of words) {
    if (w.length < minLen || (best && hintRank(w.length) <= hintRank(best.word.length))) continue;
    const pool = [...tiles];
    const ids = [];
    let ok = true;
    for (let i = 0; i < w.length && ok; i++) {
      const two = w.slice(i, i + 2).toUpperCase();
      let k = two === "QU" ? pool.findIndex(t => t.ch === "QU") : -1;
      if (k >= 0) i += 1; else k = pool.findIndex(t => t.ch === w[i].toUpperCase());
      if (k < 0) ok = false; else { ids.push(pool[k].id); pool.splice(k, 1); }
    }
    if (ok) best = { word: w, ids };
    if (best && hintRank(best.word.length) === 3) break;
  }
  return best;
}
// Touching board (Fire): a word along touching tiles, as tile ids.
function hintTouching(board, words, minLen) {
  const pre = prefixesOf(words);
  const cols = board.length; const rows = board[0].length;
  let best = null;
  const walk = (path, word) => {
    if (word.length >= minLen && words.has(word) && (!best || hintRank(word.length) > hintRank(best.word.length))) best = { ids: path.map(p => p.id), word };
    if ((best && hintRank(best.word.length) === 3) || word.length >= 6 || !pre.has(word)) return;
    const last = path[path.length - 1];
    for (let c = Math.max(0, last.c - 1); c <= Math.min(cols - 1, last.c + 1); c++) {
      for (let r = Math.max(0, last.r - 1); r <= Math.min(rows - 1, last.r + 1); r++) {
        const t = board[c][r];
        if (path.some(p => p.id === t.id)) continue;
        path.push({ c, r, id: t.id });
        walk(path, word + t.ch.toLowerCase());
        path.pop();
      }
    }
  };
  for (let c = 0; c < cols; c++) for (let r = 0; r < rows; r++) {
    walk([{ c, r, id: board[c][r].id }], board[c][r].ch.toLowerCase());
    if (best && hintRank(best.word.length) === 3) return best;
  }
  return best;
}

// ── Board ───────────────────────────────────────────────────────────────
let NEXT_ID = 1;
function randomLetter(board, diff) {
  let vowels = 0; let total = 0;
  for (const col of board || []) for (const t of col) { if (t.kind === "fire") continue; total += 1; if (VOWELS.has(t.ch)) vowels += 1; }
  const share = total ? vowels / total : 0.4;
  const want = share < diff.vowels[0] && Math.random() < 0.6 ? "vowel" : share > diff.vowels[1] && Math.random() < 0.6 ? "consonant" : null;
  const table = LETTERS.map(([c, w]) => [c, HARD_LETTERS.has(c) ? w * diff.hardLetters : w]);
  const totalW = table.reduce((a, [, w]) => a + w, 0);
  for (;;) {
    let r = Math.random() * totalW;
    let ch = "E";
    for (const [c, w] of table) { r -= w; if (r <= 0) { ch = c; break; } }
    if (want === "vowel" && !VOWELS.has(ch)) continue;
    if (want === "consonant" && VOWELS.has(ch)) continue;
    return ch;
  }
}
const newTile = (board, diff, kind = "normal") => ({ id: NEXT_ID++, ch: randomLetter(board, diff), kind, stone: 0, burn: 0, fresh: true });
function newBoard(diff, cols, rows, startFires = 0) {
  const b = [];
  for (let c = 0; c < cols; c++) { b.push([]); for (let r = 0; r < rows; r++) b[c].push(newTile(b, diff)); }
  [...Array(cols).keys()].sort(() => Math.random() - 0.5).slice(0, startFires).forEach(c => { b[c][0].kind = "fire"; });
  return b;
}
const cloneBoard = b => b.map(col => col.map(t => ({ ...t, fresh: false })));
function findTile(board, id) {
  for (let c = 0; c < board.length; c++) { const r = board[c].findIndex(t => t.id === id); if (r >= 0) return { c, r }; }
  return null;
}
// Square grid: tiles touch side to side, up and down, and corner to corner.
const touching = (a, b) => !!a && !!b && Math.max(Math.abs(a.c - b.c), Math.abs(a.r - b.r)) === 1;
// Take out the used tiles; the rest fall and new ones drop in from the top. Returns the new tiles.
function refill(b, used, diff) {
  const spawn = [];
  const rows = b[0].length;
  for (let c = 0; c < b.length; c++) {
    b[c] = b[c].filter(t => !used.has(t.id));
    while (b[c].length < rows) { const t = newTile(b, diff); b[c].unshift(t); spawn.push(t); }
  }
  return spawn;
}
const basePoints = tiles => {
  const letters = tiles.reduce((a, t) => a + t.ch.length, 0);
  const base = tiles.reduce((a, t) => a + (VALUE[t.ch] || 1), 0);
  return base * 10 * (letters >= 10 ? 4 : LEN_MULT[letters] || 1);
};

// Guest progress and potions, kept until the page closes.
const GUEST = { unlocked: {}, items: { heal: 1, power: 1, freeze: 0, cure: 0 }, stars: {}, equip: [], treasure_xp: {} };

export default function SpellingQuest() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";

  const [mode, setMode] = useState("monsters"); // monsters | fire
  const gameKey = mode === "monsters" ? "bookworm_battle" : "bookworm";
  const { players, loading, error, reload } = useFamilyPlayers(gameKey);
  const { all: heroes, ready: heroesReady } = useDancers();

  const [dict, setDict] = useState(null);
  const [dictError, setDictError] = useState(null);
  const [playerId, setPlayerId] = useState("");
  const [heroKey, setHeroKey] = useState(null);
  const [diffKey, setDiffKey] = useState("medium");
  const [screen, setScreen] = useState("setup"); // setup | map | play | over
  const [worldView, setWorldView] = useState(null); // world index on the Monsters map, null = all worlds
  const [run, setRun] = useState(null); // { endless, level }
  const [board, setBoard] = useState(null);
  const [sel, setSel] = useState([]);
  const [score, setScore] = useState(0);
  const [words, setWords] = useState([]);
  const [turn, setTurn] = useState(0);
  const [fight, setFight] = useState(null);
  const [fx, setFx] = useState({ key: 0 });   // fight animation: hero / mon / fly
  const [floats, setFloats] = useState([]);   // damage and heal numbers
  const [busy, setBusy] = useState(false);
  const [bag, setBag] = useState(null);       // potions for this game
  const [hint, setHint] = useState(null);
  const [hintsLeft, setHintsLeft] = useState(0);
  const [message, setMessage] = useState(null);
  const [result, setResult] = useState(null);
  const [guestTick, setGuestTick] = useState(0);
  const [equip, setEquip] = useState([]);     // treasure numbers worn (up to 3)
  const [bonusKind, setBonusKind] = useState(null); // "rush" | "unscramble" while a bonus round is on
  const [story, setStory] = useState(null); // { world, kind: "intro" | "outro", level } while a story page is up
  const [muted, setMuted] = useState(SOUND.muted);
  const msgTimer = useRef(0);
  const timers = useRef([]);
  const boxRef = useRef(null);
  const [boxW, setBoxW] = useState(420);

  useEffect(() => { loadList("words").then(setDict).catch(e => setDictError(e.message)); }, []);
  useEffect(() => () => { clearTimeout(msgTimer.current); timers.current.forEach(clearTimeout); }, []);
  useEffect(() => {
    const el = boxRef.current; if (!el) return undefined;
    const measure = () => setBoxW(el.clientWidth || 420);
    measure();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : null;
    if (ro) ro.observe(el);
    return () => { if (ro) ro.disconnect(); };
  }, [screen]);

  const diff = DIFFICULTY[diffKey];
  const anyOrder = mode === "monsters";
  const player = players.find(p => p.id === playerId) || null;
  const hero = heroes.find(h => h.key === heroKey) || heroes[0] || null;
  const levelCount = mode === "monsters" ? LEVEL_TOTAL : FIRE_LEVELS;
  const unlocked = useMemo(() => {
    const n = player ? Number(player.bests?.unlocked?.[diffKey]) : GUEST.unlocked[`${mode}:${diffKey}`];
    return Math.min(levelCount, Math.max(1, n || 1));
  }, [player, diffKey, mode, levelCount, guestTick]); // eslint-disable-line react-hooks/exhaustive-deps
  const savedItems = useMemo(() => {
    const src = player ? (player.bests?.items || {}) : GUEST.items;
    return Object.fromEntries(POTION_KEYS.map(k => [k, Math.max(0, Math.min(POTION_MAX, Number(src[k]) || 0))]));
  }, [player, guestTick]); // eslint-disable-line react-hooks/exhaustive-deps

  const starsMap = player ? (player.bests?.stars || {}) : GUEST.stars;
  const starsOf = n => Number(starsMap[`${diffKey}:${n}`]) || 0;
  // Treasures: won by beating a world's boss on any difficulty.
  const owned = useMemo(() => {
    const src = player ? Object.values(player.bests?.unlocked || {}) : Object.entries(GUEST.unlocked).filter(([k]) => k.startsWith("monsters:")).map(([, v]) => v);
    const xp = player ? (player.bests?.treasure_xp || {}) : GUEST.treasure_xp;
    return treasuresOwned(Math.max(1, ...src.map(Number).filter(Number.isFinite)), xp);
  }, [player, guestTick]); // eslint-disable-line react-hooks/exhaustive-deps
  const worn = equip.filter(i => owned[i]?.owned).slice(0, EQUIP_MAX);
  const toggleEquip = i => {
    if (!owned[i]?.owned) return;
    const next = worn.includes(i) ? worn.filter(x => x !== i) : worn.length < EQUIP_MAX ? [...worn, i] : worn;
    setEquip(next);
    if (!player) GUEST.equip = next;
  };
  const toggleMute = () => {
    const m = !muted;
    SOUND.muted = m; setMuted(m);
    try { window.localStorage.setItem("sq_muted", m ? "1" : "0"); } catch { /* fine */ }
  };

  const choosePlayer = id => {
    setPlayerId(id);
    const kid = players.find(p => p.id === id);
    if (kid?.animal) setHeroKey(kid.animal);
    setDiffKey(diffForAge(kid ? kid.age : null));
    setEquip(kid ? (Array.isArray(kid.bests?.equip) ? kid.bests.equip : []) : GUEST.equip);
  };

  const endlessLevel = useMemo(() => { let lv = 1; while (score >= endlessLevelAt(lv + 1)) lv += 1; return lv; }, [score]);
  const fireCfg = run && mode === "fire" ? fireLevel(run.endless ? Math.min(FIRE_LEVELS, endlessLevel) : run.level, diff) : null;

  const selTiles = useMemo(() => {
    if (!board) return [];
    return sel.map(id => { const at = findTile(board, id); return at ? board[at.c][at.r] : null; }).filter(Boolean);
  }, [board, sel]);
  const word = selTiles.map(t => t.ch).join("").toLowerCase();
  const valid = !!dict && word.length >= diff.minLen && dict.has(word);
  const base = valid ? basePoints(selTiles) : 0;
  const gems = selTiles.reduce((a, t) => ({ ...a, [t.kind]: (a[t.kind] || 0) + 1 }), {});
  const firePoints = Math.round(base * (1 + Math.min(3, selTiles.reduce((a, t) => a + (FIRE_GEM_BONUS[t.kind] || 0), 0))));
  const hitPoints = Math.round(base * (1 + 0.5 * (gems.ruby || 0) + (gems.diamond || 0)) * (fight?.power ? 2 : 1) * (fight?.weak > 0 ? 0.5 : 1)
    * treasureBoost(fight?.eq, selTiles, word.length));
  const preview = mode === "monsters" ? hitPoints : firePoints;

  const say = (text, tone = "info") => {
    clearTimeout(msgTimer.current);
    setMessage({ text, tone });
    msgTimer.current = setTimeout(() => setMessage(null), 2600);
  };
  const later = (fn, ms) => { timers.current.push(setTimeout(fn, ms)); };
  const stopTimers = () => { timers.current.forEach(clearTimeout); timers.current = []; };
  const floatUp = (side, text, color) => {
    const id = Math.random();
    setFloats(f => [...f, { id, side, text, color }]);
    later(() => setFloats(f => f.filter(x => x.id !== id)), 1000);
  };
  const play = (heroMove, monMove) => setFx(f => ({ key: f.key + 1, hero: heroMove, mon: monMove, fly: null }));

  const startRun = (endless, level = null) => {
    stopTimers();
    NEXT_ID = 1;
    if (mode === "monsters") {
      setBoard(newBoard(diff, 4, 4));
      const eq = worn.map(i => owned[i]);
      const status = { freeze: 0, poison: 0, weak: 0, power: eqCount(eq, "rally") > 0, turns: 0, eq };
      if (endless) {
        const m = endlessMonster(1, diff);
        setFight({ foes: null, idx: 0, stage: 1, monster: m, mhp: m.hp, hp: ENDLESS_HERO_HP, hpMax: ENDLESS_HERO_HP, beaten: 0, ...status });
      } else {
        const foes = monstersForLevel(level, diff);
        const hpMax = heroHpForLevel(level);
        setFight({ foes, idx: 0, stage: 1, monster: foes[0], mhp: foes[0].hp, hp: hpMax, hpMax, beaten: 0, ...status });
      }
      setBag({ ...savedItems });
    } else {
      setBoard(newBoard(diff, FIRE_SIZE, FIRE_SIZE, endless ? 0 : fireLevel(level, diff).startFires));
      setFight(null); setBag(null);
    }
    setSel([]); setScore(0); setWords([]); setTurn(0); setResult(null); setMessage(null); setHint(null);
    setFloats([]); setBusy(false); setFx(f => ({ key: f.key + 1, hero: null, mon: "enter", fly: null }));
    setHintsLeft(diff.hints);
    setRun({ endless, level });
    setScreen("play");
  };

  const finishRun = async ({ won, finalScore, finalWords, fightInfo, items, stars }) => {
    stopTimers();
    sound(won ? "win" : "lose");
    const best = [...finalWords].sort((a, b) => b.points - a.points)[0] || null;
    const level = run?.level || null;
    const nextOpen = won && level ? Math.min(levelCount, level + 1) : null;
    const starKey = stars && level ? `${diffKey}:${level}` : null;
    const treasure = mode === "monsters" && won && level && stepOf(level) === LEVELS_PER_WORLD && !owned[worldOf(level)]?.owned ? TREASURES[worldOf(level)] : null;
    // Every treasure worn on a won map level gets a win toward its next power level.
    const xpAdd = mode === "monsters" && won && level ? worn : [];
    const poweredUp = xpAdd.map(i => owned[i]).filter(t => treasureLevel(t.xp + 1) > t.lv).map(t => ({ name: t.name, color: t.color, lv: t.lv + 1 }));
    const summary = { won, endless: !!run?.endless, level, score: finalScore, count: finalWords.length, best, fight: fightInfo || null, stars: stars || 0, treasure, poweredUp, saved: null, isBest: false };
    setResult(summary);
    stopSpeaking();
    if (mode === "monsters" && won && level && stepOf(level) === LEVELS_PER_WORLD) { setStory({ world: worldOf(level), kind: "outro" }); setScreen("story"); }
    else setScreen("over");
    setBusy(false);
    if (!player) {
      for (const i of xpAdd) GUEST.treasure_xp[i] = (GUEST.treasure_xp[i] || 0) + 1;
      if (nextOpen) { const k = `${mode}:${diffKey}`; GUEST.unlocked[k] = Math.max(GUEST.unlocked[k] || 1, nextOpen); }
      if (items) GUEST.items = { ...items };
      if (starKey) GUEST.stars[starKey] = Math.max(GUEST.stars[starKey] || 0, stars);
      setGuestTick(t => t + 1);
      return;
    }
    const detail = {
      difficulty: diffKey, level, endless: !!run?.endless, won: !!won, words: finalWords.length,
      best_word: best?.word || null, best_word_points: best?.points || 0,
      ...(fightInfo ? { beaten: fightInfo.beaten, hero: hero?.key || null } : {}),
      ...(nextOpen ? { unlock_key: diffKey, unlock: nextOpen } : {}),
      ...(items ? { items, equip: worn } : {}),
      ...(starKey ? { stars_key: starKey, stars } : {}),
      ...(xpAdd.length ? { treasure_xp_add: xpAdd } : {}),
    };
    const r = await recordFamilyGame(player.id, gameKey, finalScore, detail);
    setResult({ ...summary, saved: r.saved, isBest: r.isBest });
    reload();
  };

  // Map level picked: a world's first level opens with its story page the first time.
  const playLevel = n => {
    if (mode === "monsters" && stepOf(n) === 1 && n >= unlocked) { setStory({ world: worldOf(n), kind: "intro", level: n }); setScreen("story"); return; }
    startRun(false, n);
  };

  // Bonus round won: add the potions (up to the cap) and save them.
  const finishBonus = async n => {
    const items = { ...(bag || savedItems) };
    const won = [];
    for (let i = 0; i < n; i++) {
      const open = POTION_KEYS.filter(k => items[k] < POTION_MAX);
      if (!open.length) break;
      const k = pick(open); items[k] += 1; won.push(POTIONS[k].short);
    }
    setBag(items);
    setBonusKind(null);
    setResult(r => ({ ...r, bonusDone: true, bonusWon: won }));
    setScreen("over");
    if (won.length) sound("potion");
    if (!player) { GUEST.items = { ...items }; setGuestTick(t => t + 1); return; }
    if (won.length) { await recordFamilyGame(player.id, gameKey, 0, { bonus: true, items }); reload(); }
  };

  const tap = (tile) => {
    if (!board || busy || tile.stone) return;
    setHint(null);
    sound("tap");
    const idx = sel.indexOf(tile.id);
    if (anyOrder) {
      setSel(idx >= 0 ? sel.filter(id => id !== tile.id) : [...sel, tile.id]); // tap again to take it back out
      return;
    }
    if (idx >= 0) { setSel(sel.slice(0, idx)); return; }
    const at = findTile(board, tile.id);
    const lastAt = sel.length ? findTile(board, sel[sel.length - 1]) : null;
    setSel(!lastAt || touching(lastAt, at) ? [...sel, tile.id] : [tile.id]);
  };

  // ── Monsters: your word, then the monster's turn, played out as a short fight.
  const monsterTurn = (f, b, newWords, newScore, items, delay) => {
    const m = f.monster;
    const eq = f.eq || [];
    const sturdy = eqCount(eq, "sturdy") > 0;
    const antidote = eqCount(eq, "antidote") > 0;
    const frozen = f.freeze > 0;
    const turns = f.turns + 1;
    // Stones wear off a turn at a time. A burning letter burns down; one that runs out burns you and turns to ash (a new letter).
    let burnHurt = 0;
    const b2 = b.map(col => col.map(t => {
      const n = { ...t, fresh: false, stone: Math.max(0, (t.stone || 0) - 1) };
      if (t.burn > 0) {
        n.burn = t.burn - 1;
        if (n.burn === 0) { burnHurt += Math.max(2, Math.round(f.hpMax * 0.06)); n.ch = randomLetter(b, diff); n.fresh = true; }
      }
      return n;
    }));
    const poisonHurt = f.poison > 0 ? Math.max(1, Math.round(f.hpMax * 0.04)) : 0;
    let poison = Math.max(0, f.poison - 1);
    let weak = f.weak;
    let hit = 0; let mends = 0;
    const notes = [];
    if (!frozen) {
      hit = Math.max(1, ri(m.hit[0], m.hit[1]) - eqSum(eq, "shield"));
      if (m.power === "heal" && turns % 3 === 0) mends = Math.round(m.hp * 0.08);
      if (Math.random() < 0.35) {
        const open = b2.flat().filter(t => !t.stone && !t.burn && t.kind === "normal");
        if (m.power === "stone" && !sturdy && open.length) { pick(open).stone = 3; notes.push("a letter turned to stone"); }
        else if (m.power === "burn" && !sturdy && open.length) { pick(open).burn = 3; notes.push("a letter is on fire · use it within 3 turns"); }
        else if (m.power === "poison" && !antidote && !f.poison) { poison = 3; notes.push("you're poisoned"); }
        else if (m.power === "weaken" && !antidote && !f.weak) { weak = 2; notes.push("you're weakened · next 2 words hit half as hard"); }
      }
    }
    if (poisonHurt) notes.push(`poison -${poisonHurt}`);
    if (burnHurt) notes.push(`a burning letter burned you -${burnHurt}`);
    if (mends) notes.push(`it mends ${mends}`);
    const total = hit + poisonHurt + burnHurt;
    const hp = Math.max(0, f.hp - total);
    const mhp = Math.min(m.hp, f.mhp + mends);
    const next = { ...f, hp, mhp, turns, poison, weak, freeze: frozen ? f.freeze - 1 : f.freeze };
    if (!frozen) later(() => play(null, "lunge"), delay);
    later(() => {
      if (total) { play("hurt", null); floatUp("hero", `-${total}`, "#D7261E"); sound(notes.length && !mends ? "status" : "hurt"); }
      if (mends) floatUp("mon", `+${mends}`, "#2E8B57");
      setFight(next);
      setBoard(b2);
      if (hp <= 0) {
        later(() => finishRun({ won: false, finalScore: newScore, finalWords: newWords, fightInfo: { beaten: f.beaten, monster: m.name }, items }), 900);
        return;
      }
      say(`${frozen ? `${m.name} is frozen solid!` : `${m.name} hits you for ${hit}`}${notes.length ? ` · ${notes.join(" · ")}` : ""}`, frozen && !total ? "good" : "warn");
      setBusy(false);
    }, frozen ? delay : delay + 260);
  };

  const submitMonsters = () => {
    const f = fight;
    const dmg = hitPoints;
    const eq = f.eq || [];
    const regen = eqSum(eq, "regen");
    const heal = Math.round(f.hpMax * 0.1 * ((gems.emerald || 0) + (gems.diamond || 0))) + regen;
    const cured = (gems.amethyst || 0) > 0;
    const freezeAdd = gems.sapphire || 0;
    const used = new Set(sel);
    const gemKind = monsterGem(word.length, eqCount(eq, "gems") > 0);
    const b = cloneBoard(board);
    const spawn = refill(b, used, diff);
    if (gemKind && spawn.length) pick(spawn).kind = gemKind;
    if (cured) for (const col of b) for (const t of col) { t.stone = 0; t.burn = 0; }
    const newWords = [{ word, points: dmg }, ...words];
    const mhp = f.mhp - dmg;
    const hp = Math.min(f.hpMax, f.hp + heal);
    const after = { ...f, mhp, hp, power: false, weak: cured ? 0 : Math.max(0, f.weak - 1), poison: cured ? 0 : f.poison, freeze: f.freeze + freezeAdd };
    let newScore = score + dmg;
    setBusy(true); setSel([]); setHint(null); setBoard(b); setWords(newWords); setTurn(turn + 1);
    setFx(x => ({ key: x.key + 1, hero: "lunge", mon: null, fly: word.toUpperCase() }));
    later(() => {
      play(heal ? "heal" : null, "hurt");
      sound("hit");
      if (gemKind) later(() => sound("gem"), 160);
      floatUp("mon", `-${dmg}`, "#D7261E");
      if (heal) floatUp("hero", `+${heal}`, "#2E8B57");
      setFight({ ...after, mhp: Math.max(0, mhp) });
      const bits = [];
      if (cured) bits.push("amethyst cured you");
      if (freezeAdd) bits.push(`sapphire froze ${f.monster.name}`);
      if (bits.length) say(bits.join(" · "), "good");
    }, 380);

    if (mhp > 0) {
      setScore(newScore);
      monsterTurn(after, b, newWords, newScore, bag, 1100);
      return;
    }
    // Monster beaten: it may drop a potion (a boss always drops two).
    const beaten = f.beaten + 1;
    newScore += 50 * f.stage;
    const drops = [];
    const dropCount = f.monster.boss ? 2 : Math.random() < Math.min(0.85, 0.35 + eqSum(eq, "finder") / 100) ? 1 : 0;
    const items = { ...bag };
    for (let i = 0; i < dropCount; i++) { const k = pick(POTION_KEYS); if (items[k] < POTION_MAX) { items[k] += 1; drops.push(POTIONS[k].short); } }
    setScore(newScore);
    later(() => play(null, "ko"), 900);
    const last = f.foes && f.idx + 1 >= f.foes.length;
    if (last) {
      setBag(items);
      const stars = f.foes ? starsFor(hp, f.hpMax) : 0;
      later(() => finishRun({ won: true, finalScore: newScore, finalWords: newWords, fightInfo: { beaten, monster: f.monster.name }, items, stars }), 1700);
      return;
    }
    const next = f.foes ? f.foes[f.idx + 1] : endlessMonster(f.stage + 1, diff);
    const healBetween = Math.round(f.hpMax * (f.foes ? 0.1 : 0.15) * eq.reduce((a, t) => a * (t.effect === "mend" ? t.value : 1), 1));
    later(() => {
      setBag(items);
      setFight({ ...after, idx: f.idx + 1, stage: f.stage + 1, monster: next, mhp: next.hp, hp: Math.min(f.hpMax, hp + healBetween), beaten, freeze: 0, turns: 0 });
      play(null, "enter");
      floatUp("hero", `+${healBetween}`, "#2E8B57");
      say(`You beat ${f.monster.name}!${drops.length ? ` Found: ${drops.join(", ")} potion${drops.length > 1 ? "s" : ""}.` : ""} Here comes ${next.name}${next.boss ? " (boss)" : ""}!`, "good");
      setBusy(false);
    }, 1600);
  };

  const usePotion = k => {
    if (!fight || busy || !bag || bag[k] <= 0) return;
    const items = { ...bag, [k]: bag[k] - 1 };
    setBag(items);
    sound("potion");
    if (k === "cure") {
      setFight({ ...fight, poison: 0, weak: 0 });
      setBoard(cloneBoard(board).map(col => col.map(t => ({ ...t, stone: 0, burn: 0 }))));
      play("heal", null);
      say("Cure potion! Poison, weakness, stone and fire are gone.", "good");
    } else if (k === "heal") {
      const amt = Math.round(fight.hpMax * 0.4);
      setFight({ ...fight, hp: Math.min(fight.hpMax, fight.hp + amt) });
      play("heal", null); floatUp("hero", `+${amt}`, "#2E8B57");
      say("Health potion! You feel much better.", "good");
    } else if (k === "power") {
      setFight({ ...fight, power: true });
      say("Power potion! Your next word hits twice as hard.", "good");
    } else {
      setFight({ ...fight, freeze: fight.freeze + 2 });
      say(`Freeze potion! ${fight.monster.name} can't attack for 2 turns.`, "good");
    }
  };

  // ── Fire: your word, then the fire burns.
  const submitFire = () => {
    const points = firePoints;
    const used = new Set(sel);
    const putOut = selTiles.filter(t => t.kind === "fire").length;
    const gemKind = GEM_FOR_LEN(word.length);
    const nextTurn = turn + 1;
    const fireChance = word.length <= 3 ? fireCfg.fire3 : word.length === 4 ? fireCfg.fire4 : 0;
    const addFire = Math.random() < fireChance;
    const b = cloneBoard(board);
    const spawn = refill(b, used, diff);
    if (gemKind && spawn.length) pick(spawn).kind = gemKind;
    const plain = spawn.filter(t => t.kind === "normal");
    if (addFire && plain.length) pick(plain).kind = "fire";
    let lost = false;
    const rows = b[0].length;
    if (nextTurn % diff.burnEvery === 0) {
      for (let c = 0; c < b.length; c++) {
        const fires = b[c].filter(t => t.kind === "fire" && !t.fresh).map(t => t.id).reverse();
        for (const id of fires) {
          const r = b[c].findIndex(t => t.id === id);
          if (r === rows - 1) { lost = true; continue; }
          if (b[c][r + 1].kind === "fire") continue; // a fire never burns another fire
          b[c].splice(r + 1, 1);
          b[c].unshift(newTile(b, diff));
        }
      }
    }
    const newScore = score + points;
    const newWords = [{ word, points }, ...words];
    setBoard(b); setSel([]); setWords(newWords); setTurn(nextTurn); setHint(null); setScore(newScore);
    if (lost) { finishRun({ won: false, finalScore: newScore, finalWords: newWords }); return; }
    if (!run.endless && newScore >= fireCfg.goal) { finishRun({ won: true, finalScore: newScore, finalWords: newWords }); return; }
    const bits = [`${word.toUpperCase()} +${points}`];
    if (putOut) bits.push("fire out!");
    if (gemKind) bits.push(`${gemKind} tile earned`);
    if (addFire) bits.push("a fire dropped in");
    say(bits.join(" · "), addFire ? "warn" : "good");
  };

  const submit = () => {
    if (!board || !valid || busy) return;
    if (mode === "monsters") submitMonsters(); else submitFire();
  };

  const scramble = () => {
    if (!board || busy) return;
    const b = cloneBoard(board);
    for (const col of b) for (const t of col) if (t.kind === "normal" && !t.stone) t.ch = randomLetter(b, diff);
    setSel([]); setHint(null);
    if (mode === "monsters") {
      setBoard(b); setBusy(true);
      monsterTurn(fight, b, words, score, bag, 200); // a shuffle costs a turn
      return;
    }
    const top = b.map(col => col[0]).filter(t => t.kind === "normal");
    if (top.length) { const t = pick(top); t.kind = "fire"; t.fresh = true; }
    setBoard(b);
    say("Shuffled · it cost a fire tile", "warn");
  };

  const askHint = async () => {
    if (!board || !dict || hintsLeft <= 0 || busy) return;
    let common = null;
    try { common = await loadList("common"); } catch { common = null; }
    const find = anyOrder ? hintAnyOrder : hintTouching;
    const h = (common && find(board, common, diff.minLen)) || find(board, dict, diff.minLen);
    if (!h) { say("No word found · try Shuffle", "warn"); return; }
    setSel([]); setHint(h.ids);
    if (Number.isFinite(hintsLeft)) setHintsLeft(hintsLeft - 1);
  };

  const quit = () => { stopTimers(); setBusy(false); setScreen("map"); };

  // ── Screens ───────────────────────────────────────────────────────────
  const wrap = children => <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>{children}</div>;
  const title = (
    <div style={{ marginBottom: 12 }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>Spelling Quest</div>
      <div style={{ fontSize: 13, color: T.slate500 }}>
         {mode === "monsters" ? "Win back the pages and lost chapters of the Great Word Book." : "Spell words with touching letters. Keep the fire off the bottom row."}
      </div>
    </div>
  );
  const label = text => <div style={{ fontSize: 13, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>{text}</div>;

  if (screen === "setup") {
    return wrap(<>
      {title}
      {error ? <div style={{ color: T.red, fontSize: 13, marginBottom: 8 }}>{error}</div> : null}
      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 16, display: "grid", gap: 16 }}>
        <div>
          {label("Who's playing?")}
          {loading ? <div style={{ color: T.slate400, fontSize: 13 }}>Loading…</div> : <PlayerPicker players={players} value={playerId} onChange={choosePlayer} accent={T.teal} />}
        </div>
        <div>
          {label("Mode")}
          <Chips value={mode} onChange={m => { setMode(m); setWorldView(null); }} options={[["monsters", "Monsters", `A quest through ${WORLDS.length} worlds`], ["fire", "Fire", "Keep fire off the bottom"]]} />
        </div>
        <div>
          {label("Difficulty")}
          <Chips value={diffKey} onChange={setDiffKey} options={DIFF_KEYS.map(k => [k, DIFFICULTY[k].label, `Ages ${DIFFICULTY[k].ages}`])} />
        </div>
        {mode === "monsters" ? (
          <div>
            {label(<>Pick your hero{hero ? <span style={{ fontWeight: 500, color: T.slate500 }}> · {hero.label}</span> : null}</>)}
            {!heroesReady ? <div style={{ color: T.slate400, fontSize: 13 }}>Loading…</div> : (
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(56px, 1fr))", gap: 6 }}>
                {heroes.map(h => {
                  const on = hero?.key === h.key;
                  return (
                    <button key={h.key} type="button" onClick={() => setHeroKey(h.key)} title={h.label} aria-label={h.label} style={{
                      padding: 4, borderRadius: 12, cursor: "pointer", display: "flex", justifyContent: "center",
                      border: `2px solid ${on ? T.teal : "transparent"}`, background: on ? T.tealLt : T.slate50,
                    }}>
                      <CritterIcon which={h.key} size={44} />
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        ) : null}
        {dictError ? <div style={{ color: T.red, fontSize: 13 }}>{dictError}</div> : null}
        <button type="button" onClick={() => { setWorldView(mode === "monsters" ? worldOf(unlocked) : null); setScreen("map"); }} disabled={!dict}
          style={{ ...btn(dict ? T.teal : T.slate300), padding: "14px 18px", fontSize: 18 }}>
          {dict ? "To the map" : "Loading words…"}
        </button>
      </div>
    </>);
  }

  if (screen === "map") {
    const head = (
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 10 }}>
        <div style={{ fontSize: 14, color: T.slate700 }}><b>{player ? player.name : "Guest"}</b> · {mode === "monsters" ? "Monsters" : "Fire"} · {diff.label}</div>
        <button type="button" onClick={() => setScreen("setup")} style={{ ...btn(T.slate400), padding: "6px 12px", fontSize: 13 }}>Change</button>
      </div>
    );
    const endlessBtn = (
      <button type="button" onClick={() => startRun(true)} style={{ ...btn(T.purple), width: "100%", marginTop: 12, padding: "12px 16px" }}>
        Endless {mode === "monsters" ? "monsters" : "fire"} · play as long as you last
      </button>
    );
    if (mode === "fire") {
      return wrap(<>{title}{head}<FireMap diff={diff} unlocked={unlocked} onPlay={n => startRun(false, n)} />{endlessBtn}</>);
    }
    if (worldView == null) {
      const part = (n, text) => <div style={{ fontSize: 13, color: T.slate700, lineHeight: 1.5, margin: n ? "14px 0 8px" : "0 0 8px" }}><b>Part {n + 1}.</b> {text}</div>;
      return wrap(<>{title}{head}
        <TreasurePanel owned={owned} worn={worn} onToggle={toggleEquip} />
        <div style={{ display: "grid", gap: 8 }}>
          {WORLDS.map((w, i) => {
            const first = i * LEVELS_PER_WORLD + 1;
            const open = first <= unlocked;
            const done = Math.max(0, Math.min(LEVELS_PER_WORLD, unlocked - first));
            let stars = 0;
            for (let n = first; n < first + LEVELS_PER_WORLD; n++) stars += starsOf(n);
            return (
              <div key={w.name}>
                {i === 0 ? part(0, STORY_PARTS[0]) : null}
                {i === 10 ? part(1, STORY_PARTS[1]) : null}
                <button type="button" disabled={!open} onClick={() => setWorldView(i)} style={{
                  position: "relative", overflow: "hidden", width: "100%", display: "flex", alignItems: "center", gap: 12, padding: 10, borderRadius: 14, textAlign: "left", fontFamily: "inherit",
                  border: `1px solid ${T.slate200}`, cursor: open ? "pointer" : "default", opacity: open ? 1 : 0.55, background: w.sky[1], minHeight: 76,
                }}>
                  <QuestScene world={w} level={null} step={5} wide />
                  <div style={{ position: "relative", flexShrink: 0, width: 56, height: 56, display: "flex", alignItems: "center", justifyContent: "center" }}>
                    {open ? <QuestMonster m={MONSTER_OF(w.boss)} size={56} flip={false} /> : <span style={{ fontSize: 28 }}>🔒</span>}
                  </div>
                  <div style={{ position: "relative", flex: 1, minWidth: 0, background: "rgba(255,255,255,0.82)", borderRadius: 10, padding: "6px 10px" }}>
                    <div style={{ fontSize: 16, fontWeight: 800, color: T.slate900 }}>World {i + 1}: {w.name}</div>
                    <div style={{ fontSize: 12, color: T.slate800 }}>
                      {done >= LEVELS_PER_WORLD ? `✓ ${w.page[0].toUpperCase()}${w.page.slice(1)} won back` : open ? `${done} of ${LEVELS_PER_WORLD} levels done` : "Locked"}
                      {open ? <span style={{ color: "#A8801F", fontWeight: 700 }}> · ★ {stars}/{LEVELS_PER_WORLD * 3}</span> : null}
                    </div>
                  </div>
                </button>
              </div>
            );
          })}
        </div>
        {endlessBtn}
      </>);
    }
    const w = WORLDS[worldView];
    return wrap(<>{title}{head}
      <button type="button" onClick={() => setWorldView(null)} style={{ ...btn(T.slate400), padding: "6px 12px", fontSize: 13, marginBottom: 10 }}>← All worlds</button>
      <WorldMap world={w} index={worldView} unlocked={unlocked} starsOf={starsOf} onPlay={playLevel}
        onStory={() => { setStory({ world: worldView, kind: "intro", level: null }); setScreen("story"); }} />
    </>);
  }

  if (screen === "over" && result) {
    const canNext = result.won && !result.endless && result.level < levelCount;
    const isBossWin = mode === "monsters" && result.won && !result.endless && stepOf(result.level) === LEVELS_PER_WORLD;
    const headline = result.endless
      ? (result.fight ? `${result.fight.monster} won this time` : "The fire reached the bottom")
      : result.won ? `${mode === "monsters" ? levelName(result.level) : `Level ${result.level}`} cleared!` : "Not this time";
    return wrap(<>
      {title}
      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 20, textAlign: "center", display: "grid", gap: 10 }}>
        <div style={{ fontSize: 18, fontWeight: 700, color: result.won ? T.green : T.slate700 }}>{headline}</div>
        {result.stars ? <Stars n={result.stars} size={34} /> : null}
        {result.treasure ? (
          <div style={{ display: "flex", alignItems: "center", gap: 10, justifyContent: "center", background: T.tealLt, borderRadius: 10, padding: 10, textAlign: "left" }}>
            <TreasureIcon color={result.treasure.color} size={40} />
            <div style={{ fontSize: 14, color: T.slate800 }}><b>Treasure found: {result.treasure.name}!</b><br />{result.treasure.text}. Wear it from the map.</div>
          </div>
        ) : null}
        {(result.poweredUp || []).map(t => (
          <div key={t.name} style={{ display: "flex", alignItems: "center", gap: 8, justifyContent: "center", fontSize: 14, fontWeight: 700, color: "#8E5CB8" }}>
            <TreasureIcon color={t.color} size={22} /> {t.name} powered up to level {t.lv}!
          </div>
        ))}
        <div style={{ fontSize: 40, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
        {result.bonusDone ? <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>Bonus round: {result.bonusWon?.length ? `won ${result.bonusWon.join(", ")} potion${result.bonusWon.length > 1 ? "s" : ""}` : "no potions this time"}</div> : null}
        {result.isBest ? <div style={{ fontSize: 16, fontWeight: 700, color: T.gold }}>New best score!</div> : null}
        <div style={{ fontSize: 15, color: T.slate700 }}>
          {result.count} words{result.fight ? ` · beat ${result.fight.beaten} monster${result.fight.beaten === 1 ? "" : "s"}` : ""}
        </div>
        {result.best ? <div style={{ fontSize: 15, color: T.slate700 }}>Best word: <b>{result.best.word.toUpperCase()}</b> ({result.best.points.toLocaleString()})</div> : null}
        {player && result.saved === false ? <div style={{ fontSize: 13, color: T.red }}>Couldn't save this game.</div> : null}
        <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 6 }}>
          {isBossWin && !result.bonusDone ? (
            <button type="button" onClick={() => { setBonusKind(worldOf(result.level) % 2 ? "unscramble" : "rush"); setScreen("bonus"); }} style={btn(T.purple)}>Bonus round · win potions</button>
          ) : null}
          {canNext ? <button type="button" onClick={() => playLevel(result.level + 1)} style={btn(T.teal)}>Next level</button> : null}
          <button type="button" onClick={() => startRun(result.endless, result.level)} style={btn(canNext ? T.slate600 : T.teal)}>Play again</button>
          <button type="button" onClick={() => { if (mode === "monsters" && result.level) setWorldView(worldOf(Math.min(levelCount, canNext ? result.level + 1 : result.level))); setScreen("map"); }} style={btn(T.slate600)}>Map</button>
        </div>
      </div>
    </>);
  }

  if (screen === "story" && story) {
    const w = WORLDS[story.world];
    const prologue = story.kind === "intro" && (story.world === 0 || story.world === 10) ? `${STORY_PARTS[story.world === 0 ? 0 : 1]} ` : "";
    const text = story.kind === "intro" ? `${prologue}${w.intro}` : w.outro;
    const done = () => {
      stopSpeaking();
      if (story.kind === "intro" && story.level) startRun(false, story.level);
      else if (story.kind === "intro") setScreen("map");
      else setScreen("over");
      setStory(null);
    };
    return wrap(<><QuestStyles /><StoryPage key={`${story.world}${story.kind}`} world={w} index={story.world} kind={story.kind} text={text}
      button={story.kind === "intro" ? (story.level ? "Start the adventure" : "Back to the map") : "Continue"} onDone={done} /></>);
  }

  if (screen === "bonus" && bonusKind) {
    return wrap(<><QuestStyles /><BonusRound kind={bonusKind} diff={diff} diffKey={diffKey} dict={dict} width={boxW} onDone={finishBonus} /></>);
  }

  if (!board || !run) return null;
  const cols = board.length;
  const rows = board[0].length;
  const S = anyOrder
    ? Math.max(56, Math.min(84, Math.floor(boxW / 4.2)))
    : Math.max(44, Math.min(76, Math.floor(boxW / (cols + 0.2))));
  const where = run.endless ? "Endless" : mode === "monsters" ? `${worldOf(run.level) + 1}-${stepOf(run.level)} ${levelName(run.level)}` : `Level ${run.level}`;
  const progress = mode === "monsters"
    ? (run.endless ? `monster ${fight?.stage}` : `monster ${(fight?.idx || 0) + 1} of ${fight?.foes?.length}`)
    : (run.endless ? `level ${endlessLevel}` : `goal ${fireCfg.goal.toLocaleString()}`);
  const world = mode === "monsters" ? WORLDS[run.endless ? endlessWorld(fight?.stage || 1) : worldOf(run.level)] : null;
  const scene = mode === "monsters" ? { level: run.endless ? null : levelInfo(run.level), step: run.endless ? ((fight?.stage || 1) - 1) % LEVELS_PER_WORLD + 1 : stepOf(run.level) } : null;

  return wrap(<>
    <QuestStyles />
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", flexWrap: "wrap", gap: 8, marginBottom: 8 }}>
      <div style={{ fontSize: 15, fontWeight: 700, color: T.slate800 }}>{where}</div>
      <div style={{ fontSize: 13, color: T.slate600, display: "flex", alignItems: "center", gap: 8 }}>
        {score.toLocaleString()} pts · {progress}
        <button type="button" onClick={toggleMute} aria-label={muted ? "Sound on" : "Sound off"} title={muted ? "Sound on" : "Sound off"}
          style={{ border: `1px solid ${T.slate300}`, background: T.white, borderRadius: 8, padding: "2px 6px", cursor: "pointer", fontSize: 14 }}>{muted ? "🔇" : "🔊"}</button>
      </div>
    </div>
    {mode === "fire" && !run.endless ? <Bar value={score} max={fireCfg.goal} color={T.amber} label="Goal" /> : null}
    {fight ? <Arena fight={fight} hero={hero} world={world} scene={scene} fx={fx} floats={floats} wide={!_vp.isPhone} /> : null}
    {fight && bag ? (
      <div style={{ display: "flex", gap: 6, justifyContent: "center", flexWrap: "wrap", marginTop: 8 }}>
        {POTION_KEYS.map(k => (
          <button key={k} type="button" onClick={() => usePotion(k)} disabled={busy || bag[k] <= 0} title={POTIONS[k].text} style={{
            display: "flex", alignItems: "center", gap: 6, padding: "6px 10px", borderRadius: 999, fontFamily: "inherit", fontSize: 13, fontWeight: 700,
            border: `2px solid ${POTIONS[k].color}`, background: T.white, color: T.slate800, cursor: bag[k] > 0 && !busy ? "pointer" : "default", opacity: bag[k] > 0 ? 1 : 0.4,
          }}>
            <Potion color={POTIONS[k].color} /> {POTIONS[k].short} ×{bag[k]}
          </button>
        ))}
      </div>
    ) : null}

    <div style={{
      display: "flex", alignItems: "center", gap: 8, padding: "8px 10px", margin: "10px 0", borderRadius: 12, minHeight: 52,
      background: T.white, border: `2px solid ${valid ? T.green : T.slate200}`, flexWrap: "wrap",
    }}>
      <div style={{ flex: "1 1 160px", fontSize: 24, fontWeight: 800, letterSpacing: 2, color: valid ? T.slate900 : T.slate500, minWidth: 0, overflowWrap: "anywhere" }}>
        {word ? word.toUpperCase() : <span style={{ fontSize: 14, fontWeight: 500, letterSpacing: 0, color: T.slate400 }}>
          {anyOrder ? "Tap letters in any order" : "Tap touching letters"}{diff.minLen > 3 ? ` · ${diff.minLen}+ letters` : ""}
        </span>}
      </div>
      {valid ? <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>{mode === "monsters" ? `${preview} damage` : `+${preview}`}</div> : null}
      <button type="button" onClick={() => setSel([])} disabled={!sel.length} style={{ ...btn(T.slate400), padding: "8px 12px", opacity: sel.length ? 1 : 0.5 }}>Clear</button>
      <button type="button" onClick={submit} disabled={!valid || busy} style={{ ...btn(T.teal), opacity: valid && !busy ? 1 : 0.4 }}>{mode === "monsters" ? "Attack" : "Go"}</button>
    </div>

    <div ref={boxRef} style={{ width: "100%" }}>
      <div style={{ position: "relative", width: S * cols, height: S * rows, margin: "0 auto", userSelect: "none", touchAction: "manipulation" }}>
        {board.map((col, c) => col.map((t, r) => (
          <Tile key={t.id} tile={t} size={S} left={c * S} top={r * S}
            order={sel.indexOf(t.id)} hinted={!!hint && hint.includes(t.id)} danger={t.kind === "fire" && r >= rows - 2} onTap={() => tap(t)} />
        )))}
      </div>
    </div>

    {mode === "monsters" ? <div style={{ marginTop: 8, fontSize: 11, color: T.slate500, textAlign: "center" }}>{GEM_KEY}</div> : null}
    {message ? (
      <div style={{
        marginTop: 10, padding: "8px 12px", borderRadius: 10, fontSize: 14, fontWeight: 600, textAlign: "center",
        background: message.tone === "warn" ? T.amberLt : T.greenLt, color: message.tone === "warn" ? "#7A4B00" : "#0F5132",
      }}>{message.text}</div>
    ) : null}

    <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 12 }}>
      {diff.hints > 0 ? (
        <button type="button" onClick={askHint} disabled={hintsLeft <= 0 || busy} style={{ ...btn(T.blue), padding: "8px 14px", fontSize: 14, opacity: hintsLeft > 0 ? 1 : 0.4 }}>
          Hint{Number.isFinite(hintsLeft) ? ` (${hintsLeft})` : ""}
        </button>
      ) : null}
      <button type="button" onClick={scramble} disabled={busy} style={{ ...btn(T.amber), padding: "8px 14px", fontSize: 14 }}>{mode === "monsters" ? "Shuffle (monster gets a turn)" : "Shuffle (adds fire)"}</button>
      <button type="button" onClick={quit} style={{ ...btn(T.slate400), padding: "8px 14px", fontSize: 14 }}>Quit</button>
    </div>
  </>);
}

const MONSTER_OF = key => ({ key, ...(QUEST_MONSTERS[key] || {}) });

// ── Bonus round: one minute between worlds, wins up to three potions.
//   rush        4x4 letters, any order: every 3 different words = 1 potion
//   unscramble  put a mixed-up common word back together: every 2 = 1 potion
const BONUS_SECONDS = 60;
const BONUS_PER = { rush: 3, unscramble: 2 };
const UNSCRAMBLE_LEN = { starter: [3, 4], easy: [4, 5], medium: [5, 6], hard: [6, 7] };
function BonusRound({ kind, diff, diffKey, dict, width, onDone }) {
  const [pool, setPool] = useState(null);
  const [board, setBoard] = useState(() => (kind === "rush" ? newBoard(diff, 4, 4) : null));
  const [target, setTarget] = useState(null); // unscramble: the word to rebuild
  const [sel, setSel] = useState([]);
  const [got, setGot] = useState([]);
  const [left, setLeft] = useState(BONUS_SECONDS);
  const [done, setDone] = useState(false);
  const [note, setNote] = useState(null);
  const potions = Math.min(3, Math.floor(got.length / BONUS_PER[kind]));

  useEffect(() => {
    if (kind !== "unscramble") return;
    const [lo, hi] = UNSCRAMBLE_LEN[diffKey] || UNSCRAMBLE_LEN.medium;
    loadList("common").catch(() => dict).then(words => setPool([...words].filter(w => !w.includes("q") && w.length >= lo && w.length <= hi)));
  }, [kind, diffKey, dict]);
  const nextWord = () => {
    const w = pick(pool);
    let mixed = w.split("");
    for (let k = 0; k < 8 && mixed.join("") === w; k++) mixed = [...mixed].sort(() => Math.random() - 0.5);
    setBoard([mixed.map(ch => ({ id: NEXT_ID++, ch: ch.toUpperCase(), kind: "normal", stone: 0, burn: 0, fresh: true }))]);
    setTarget(w); setSel([]);
  };
  useEffect(() => { if (pool && pool.length && !target) nextWord(); }, [pool]); // eslint-disable-line react-hooks/exhaustive-deps

  const ready = kind === "rush" || !!target;
  useEffect(() => {
    if (!ready || done) return undefined;
    const t = setInterval(() => setLeft(s => { if (s <= 1) { clearInterval(t); setDone(true); return 0; } return s - 1; }), 1000);
    return () => clearInterval(t);
  }, [ready, done]);

  const tiles = board ? board.flat() : [];
  const chosen = sel.map(id => tiles.find(t => t.id === id)).filter(Boolean);
  const word = chosen.map(t => t.ch).join("").toLowerCase();
  const flash = text => { setNote(text); setTimeout(() => setNote(n => (n === text ? null : n)), 1400); };

  const tap = t => {
    if (done) return;
    sound("tap");
    const next = sel.includes(t.id) ? sel.filter(id => id !== t.id) : [...sel, t.id];
    setSel(next);
    if (kind === "unscramble" && next.length === tiles.length) {
      const w = next.map(id => tiles.find(x => x.id === id).ch).join("").toLowerCase();
      if (w === target || dict.has(w)) { sound("gem"); setGot(g => [...g, w]); flash(`${w.toUpperCase()}!`); nextWord(); }
      else { sound("status"); flash("Not a word · try again"); setSel([]); }
    }
  };
  const submitRush = () => {
    if (done || word.length < diff.minLen || !dict.has(word)) { flash("Not a word"); return; }
    if (got.includes(word)) { flash("Already found"); setSel([]); return; }
    sound("gem");
    const b = cloneBoard(board);
    refill(b, new Set(sel), diff);
    setBoard(b); setGot(g => [...g, word]); setSel([]);
  };

  const S = kind === "rush" ? Math.max(56, Math.min(84, Math.floor(width / 4.2))) : Math.max(44, Math.min(70, Math.floor(width / ((tiles.length || 5) + 0.4))));
  const cols = kind === "rush" ? 4 : tiles.length;
  const rows = kind === "rush" ? 4 : 1;
  return (
    <div style={{ display: "grid", gap: 10 }}>
      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 12, textAlign: "center" }}>
        <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Bonus round: {kind === "rush" ? "Word Rush" : "Unscramble"}</div>
        <div style={{ fontSize: 13, color: T.slate600 }}>
          {kind === "rush" ? `Spell as many different words as you can. Every ${BONUS_PER.rush} words wins a potion.` : `Tap the letters in order to fix the word. Every ${BONUS_PER.unscramble} words wins a potion.`} Up to 3.
        </div>
        <div style={{ display: "flex", justifyContent: "center", gap: 16, marginTop: 8, fontSize: 15, fontWeight: 700 }}>
          <span style={{ color: left <= 10 ? T.red : T.slate800 }}>⏱ {left}s</span>
          <span style={{ color: T.slate800 }}>{got.length} word{got.length === 1 ? "" : "s"}</span>
          <span style={{ color: "#8E5CB8" }}>{potions} potion{potions === 1 ? "" : "s"}</span>
        </div>
      </div>
      {done ? (
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 16, textAlign: "center", display: "grid", gap: 8 }}>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>Time!</div>
          <div style={{ fontSize: 14, color: T.slate700 }}>{got.length ? got.map(w => w.toUpperCase()).join(" · ") : "No words this time."}</div>
          <button type="button" onClick={() => onDone(potions)} style={{ ...btn(T.teal), justifySelf: "center" }}>{potions ? `Collect ${potions} potion${potions > 1 ? "s" : ""}` : "Back"}</button>
        </div>
      ) : !ready ? <div style={{ textAlign: "center", color: T.slate400 }}>Loading…</div> : (
        <>
          <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 10px", borderRadius: 12, minHeight: 52, background: T.white, border: `2px solid ${T.slate200}` }}>
            <div style={{ flex: 1, fontSize: 24, fontWeight: 800, letterSpacing: 2, color: T.slate900 }}>{word.toUpperCase() || <span style={{ fontSize: 14, fontWeight: 500, letterSpacing: 0, color: T.slate400 }}>Tap letters</span>}</div>
            <button type="button" onClick={() => setSel([])} disabled={!sel.length} style={{ ...btn(T.slate400), padding: "8px 12px", opacity: sel.length ? 1 : 0.5 }}>Clear</button>
            {kind === "rush" ? <button type="button" onClick={submitRush} disabled={!word} style={{ ...btn(T.teal), opacity: word ? 1 : 0.4 }}>Go</button>
              : <button type="button" onClick={() => { flash(`It was ${target.toUpperCase()}`); nextWord(); }} style={btn(T.amber)}>Skip</button>}
          </div>
          <div style={{ position: "relative", width: S * cols, height: S * rows, margin: "0 auto", userSelect: "none", touchAction: "manipulation" }}>
            {board.map((col, c) => col.map((t, r) => (
              <Tile key={t.id} tile={t} size={S} left={(kind === "rush" ? c : r) * S} top={(kind === "rush" ? r : 0) * S}
                order={sel.indexOf(t.id)} hinted={false} danger={false} onTap={() => tap(t)} />
            )))}
          </div>
          {note ? <div style={{ textAlign: "center", fontSize: 14, fontWeight: 700, color: T.slate700 }}>{note}</div> : null}
        </>
      )}
    </div>
  );
}

function btn(bg) {
  return { padding: "10px 18px", borderRadius: 10, border: "none", background: bg, color: T.white, fontSize: 15, fontWeight: 700, cursor: "pointer", fontFamily: "inherit" };
}

function QuestStyles() {
  return (
    <style>{`
      @keyframes sqDrop { from { transform: translateY(-16px); opacity: 0 } to { transform: none; opacity: 1 } }
      @keyframes sqFlicker { from { filter: brightness(1) } to { filter: brightness(1.18) } }
      @keyframes sqHint { from { box-shadow: 0 0 0 2px #F59E0B } to { box-shadow: 0 0 0 6px #F59E0B } }
      @keyframes sqIdle { 0%,100% { transform: translateY(0) } 50% { transform: translateY(-4px) } }
      @keyframes sqLungeR { 0% { transform: translateX(0) } 35% { transform: translateX(46px) rotate(6deg) } 100% { transform: translateX(0) } }
      @keyframes sqLungeL { 0% { transform: translateX(0) } 35% { transform: translateX(-46px) rotate(-6deg) } 100% { transform: translateX(0) } }
      @keyframes sqHurt { 0%,100% { transform: translateX(0); filter: none } 20% { transform: translateX(-8px); filter: brightness(1.6) saturate(0.4) } 50% { transform: translateX(8px) } 75% { transform: translateX(-4px) } }
      @keyframes sqHeal { 0%,100% { filter: none } 50% { filter: drop-shadow(0 0 10px #4CBF72) brightness(1.15) } }
      @keyframes sqKo { to { transform: translateY(20px) scale(0.3) rotate(25deg); opacity: 0 } }
      @keyframes sqEnter { from { transform: translateX(90px); opacity: 0 } to { transform: none; opacity: 1 } }
      @keyframes sqFloat { from { transform: translateY(0); opacity: 1 } to { transform: translateY(-46px); opacity: 0 } }
      @keyframes sqFly { 0% { left: 26%; opacity: 0; transform: translateY(0) scale(0.7) } 15% { opacity: 1 } 100% { left: 62%; opacity: 0.9; transform: translateY(-10px) scale(1.15) } }
    `}</style>
  );
}

// The fight: your hero on the left, the monster on the right, in the world's colors.
const POWER_TEXT = { stone: "Turns letters to stone", burn: "Sets letters on fire", poison: "Poisons", weaken: "Weakens", heal: "Mends itself" };
function Chip({ color, children }) {
  return <span style={{ fontSize: 11, fontWeight: 800, color: T.white, background: color, borderRadius: 999, padding: "1px 7px", whiteSpace: "nowrap" }}>{children}</span>;
}
function Arena({ fight, hero, world, scene, fx, floats, wide }) {
  const m = fight.monster;
  const size = wide ? 130 : 104;
  const anim = a => a === "lunge" ? "sqLungeR 0.55s ease-out" : a === "hurt" ? "sqHurt 0.45s" : a === "heal" ? "sqHeal 0.7s" : "none";
  const monAnim = fx.mon === "lunge" ? "sqLungeL 0.55s ease-out" : fx.mon === "hurt" ? "sqHurt 0.45s"
    : fx.mon === "ko" ? "sqKo 0.6s forwards" : fx.mon === "enter" ? "sqEnter 0.5s ease-out" : "none";
  return (
    <div style={{
      position: "relative", marginTop: 8, borderRadius: 16, overflow: "hidden", height: wide ? 250 : 214,
      background: world ? world.sky[1] : "#CCC", border: `1px solid ${T.slate200}`,
    }}>
      <QuestScene world={world} level={scene?.level} step={scene?.step || 1} />
      {/* health bars and what's going on */}
      <div style={{ position: "absolute", top: 6, left: 8, right: 8, display: "flex", gap: 10, zIndex: 2 }}>
        <div style={{ flex: 1, background: "rgba(255,255,255,0.82)", borderRadius: 10, padding: "4px 8px" }}>
          <Bar value={fight.hp} max={fight.hpMax} color={T.green} label={hero ? hero.label : "You"} small />
          <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginTop: 3, minHeight: 16 }}>
            {fight.power ? <Chip color="#A8801F">Power ×2</Chip> : null}
            {fight.poison ? <Chip color="#6E8B3E">Poison {fight.poison}</Chip> : null}
            {fight.weak ? <Chip color="#7A6A8C">Weak {fight.weak}</Chip> : null}
            {(fight.eq || []).map(t => <span key={t.name} title={`${t.name}: ${t.text}`}><TreasureIcon color={t.color} size={16} /></span>)}
          </div>
        </div>
        <div style={{ flex: 1, background: "rgba(255,255,255,0.82)", borderRadius: 10, padding: "4px 8px" }}>
          <Bar value={fight.mhp} max={m.hp} color={T.red} label={m.boss ? `${m.name} ★` : m.name} small />
          <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginTop: 3, minHeight: 16 }}>
            {fight.freeze ? <Chip color="#3F8DB8">Frozen {fight.freeze}</Chip> : null}
            {m.power ? <span style={{ fontSize: 11, color: T.slate600 }}>{POWER_TEXT[m.power]}</span> : null}
          </div>
        </div>
      </div>
      {/* hero */}
      <div style={{ position: "absolute", left: "6%", bottom: "12%" }}>
        <div key={`h${fx.key}`} style={{ animation: anim(fx.hero) }}>
          <div style={{ animation: "sqIdle 1.6s ease-in-out infinite" }}>
            {hero ? <CritterIcon which={hero.key} size={size} /> : null}
          </div>
        </div>
      </div>
      {/* monster */}
      <div style={{ position: "absolute", right: "6%", bottom: "10%" }}>
        <div key={`m${fx.key}-${m.key}`} style={{ animation: monAnim }}>
          <div style={{ animation: "sqIdle 1.9s ease-in-out infinite" }}>
            <QuestMonster m={m} size={m.boss ? size * 1.25 : size} />
          </div>
        </div>
      </div>
      {/* the word flying at the monster */}
      {fx.fly ? (
        <div key={`f${fx.key}`} style={{
          position: "absolute", top: "44%", left: "26%", zIndex: 3, padding: "4px 10px", borderRadius: 10, fontWeight: 900, fontSize: wide ? 22 : 18,
          background: "#FFF3CD", color: "#5B4300", border: "2px solid #E2B13C", animation: "sqFly 0.42s ease-in forwards", whiteSpace: "nowrap",
        }}>{fx.fly}</div>
      ) : null}
      {/* damage and heal numbers */}
      {floats.map(f => (
        <div key={f.id} style={{
          position: "absolute", zIndex: 4, top: "36%", [f.side === "hero" ? "left" : "right"]: "16%",
          fontSize: wide ? 30 : 24, fontWeight: 900, color: f.color, textShadow: "0 2px 0 #fff, 0 0 6px #fff", animation: "sqFloat 1s ease-out forwards",
        }}>{f.text}</div>
      ))}
    </div>
  );
}

function Potion({ color }) {
  return (
    <svg viewBox="0 0 20 24" width="16" height="19" aria-hidden="true">
      <rect x="7" y="1" width="6" height="5" rx="1" fill="#A88B5F" />
      <path d="M6 6 h8 v3 l4 6 a6 6 0 0 1 -5 8 h-6 a6 6 0 0 1 -5 -8 l4 -6 z" fill={color} stroke="#2D2F26" strokeWidth="1.2" />
      <circle cx="8" cy="15" r="1.6" fill="#fff" opacity="0.7" />
    </svg>
  );
}

function Chips({ value, onChange, options }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))", gap: 8 }}>
      {options.map(([id, text, sub]) => {
        const on = value === id;
        return (
          <button key={id} type="button" onClick={() => onChange(id)} style={{
            padding: "8px 10px", borderRadius: 12, cursor: "pointer", fontFamily: "inherit", textAlign: "left",
            border: `2px solid ${on ? T.teal : T.slate300}`, background: on ? T.tealLt : T.white, color: T.slate800,
          }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>{text}</div>
            <div style={{ fontSize: 12, color: T.slate600 }}>{sub}</div>
          </button>
        );
      })}
    </div>
  );
}

// One world of the Monsters map: its picture and story, then its 20 levels.
function WorldMap({ world, index, unlocked, starsOf, onPlay, onStory }) {
  const treasure = TREASURES[index];
  return (
    <div style={{ borderRadius: 16, overflow: "hidden", border: `1px solid ${T.slate200}`, background: `linear-gradient(180deg, ${world.sky[0]}, ${world.sky[1]})` }}>
      <div style={{ position: "relative", height: 150 }}>
        <QuestScene world={world} level={null} step={5} wide />
        <div style={{ position: "absolute", left: 10, bottom: 8, background: "rgba(255,255,255,0.85)", borderRadius: 10, padding: "4px 10px", fontSize: 18, fontWeight: 800, color: T.slate900 }}>
          World {index + 1}: {world.name}
        </div>
      </div>
      <div style={{ padding: 12 }}>
        <div style={{ fontSize: 13, color: T.slate800, lineHeight: 1.5, marginBottom: 10, background: "rgba(255,255,255,0.8)", borderRadius: 10, padding: 10 }}>
          {world.intro}
          <div style={{ marginTop: 6 }}>
            <button type="button" onClick={onStory} style={{ ...btn(T.blue), padding: "6px 12px", fontSize: 13 }}>📖 Read the story to me</button>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 6, fontSize: 12, color: T.slate600 }}>
            <TreasureIcon color={treasure.color} size={18} /> Boss treasure: <b>{treasure.name}</b> · {treasure.text}
          </div>
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))", gap: 6 }}>
          {world.levels.map((lv, i) => {
            const n = index * LEVELS_PER_WORLD + i + 1;
            const open = n <= unlocked;
            const done = n < unlocked;
            const boss = i === LEVELS_PER_WORLD - 1;
            return (
              <button key={lv.name} type="button" disabled={!open} onClick={() => onPlay(n)} title={lv.name} style={{
                display: "flex", alignItems: "center", gap: 8, padding: "6px 8px", borderRadius: 12, fontFamily: "inherit", textAlign: "left",
                background: !open ? "rgba(255,255,255,0.45)" : done ? "rgba(209,250,229,0.95)" : T.white,
                border: `2px solid ${!open ? T.slate300 : boss ? T.red : done ? T.green : T.teal}`,
                boxShadow: open && !done ? `0 0 0 3px ${T.tealLt}` : "none", cursor: open ? "pointer" : "default",
              }}>
                <div style={{
                  flexShrink: 0, width: 28, height: 28, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center",
                  background: !open ? T.slate300 : done ? T.green : boss ? T.red : T.teal, color: T.white, fontWeight: 800, fontSize: 13,
                }}>{!open ? "🔒" : i + 1}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{lv.name}</div>
                  <div style={{ fontSize: 11, color: T.slate600 }}>{done ? <Stars n={starsOf(n)} size={12} /> : boss ? "Boss!" : `${MONSTERS_PER_LEVEL} monsters`}</div>
                </div>
                {boss && open ? <QuestMonster m={MONSTER_OF(world.boss)} size={28} flip={false} /> : null}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// A story page: the world's picture, its boss, and the text, read aloud with each word lit up as it's spoken.
function StoryPage({ world, index, kind, text, button, onDone }) {
  const words = text.split(/\s+/).filter(Boolean);
  const [at, setAt] = useState(-1);
  const [reading, setReading] = useState(false);
  const canSpeak = typeof window !== "undefined" && !!window.speechSynthesis;
  const read = () => {
    if (reading) { stopSpeaking(); setReading(false); setAt(-1); return; }
    if (speak(text, setAt, () => { setReading(false); setAt(-1); })) setReading(true);
  };
  useEffect(() => {
    if (!SOUND.muted && canSpeak) { const t = setTimeout(read, 300); return () => { clearTimeout(t); stopSpeaking(); }; }
    return () => stopSpeaking();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div style={{ borderRadius: 16, overflow: "hidden", border: `1px solid ${T.slate200}`, background: T.white }}>
      <div style={{ position: "relative", height: 170, background: world.sky[1] }}>
        <QuestScene world={world} level={null} step={kind === "outro" ? 17 : 5} wide />
        <div style={{ position: "absolute", right: 16, bottom: 10, animation: kind === "outro" ? "none" : "sqIdle 1.9s ease-in-out infinite", opacity: kind === "outro" ? 0.75 : 1, transform: kind === "outro" ? "rotate(-8deg)" : "none" }}>
          <QuestMonster m={MONSTER_OF(world.boss)} size={96} />
        </div>
        <div style={{ position: "absolute", left: 12, top: 10, background: "rgba(255,255,255,0.88)", borderRadius: 10, padding: "4px 10px", fontSize: 13, fontWeight: 800, color: T.slate800 }}>
          World {index + 1}: {world.name} · {kind === "outro" ? "The End of the Chapter" : "The Story"}
        </div>
      </div>
      <div style={{ padding: 16, display: "grid", gap: 14 }}>
        <div style={{ fontSize: 20, lineHeight: 1.6, color: T.slate900, fontFamily: "Georgia, 'Times New Roman', serif" }}>
          {words.map((w, i) => (
            <span key={i} style={{ background: i === at ? "#FFE680" : "transparent", borderRadius: 4, transition: "background 0.1s" }}>{w}{i < words.length - 1 ? " " : ""}</span>
          ))}
        </div>
        <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap" }}>
          {canSpeak ? <button type="button" onClick={read} style={btn(T.blue)}>{reading ? "⏹ Stop reading" : "🔊 Read to me"}</button> : null}
          <button type="button" onClick={onDone} style={btn(T.teal)}>{button}</button>
        </div>
      </div>
    </div>
  );
}

function Stars({ n, size = 14 }) {
  return (
    <span aria-label={`${n} of 3 stars`} style={{ fontSize: size, letterSpacing: 1, lineHeight: 1 }}>
      {[0, 1, 2].map(i => <span key={i} style={{ color: i < n ? "#E2B13C" : "#C9CCB8" }}>★</span>)}
    </span>
  );
}

function TreasureIcon({ color, size = 24 }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true" style={{ display: "inline-block", verticalAlign: "middle", flexShrink: 0 }}>
      <path d="M12 2 L20 7 L20 15 L12 22 L4 15 L4 7 Z" fill={color} stroke="#2D2F26" strokeWidth="1.5" strokeLinejoin="round" />
      <path d="M12 2 L12 22 M4 7 L20 15 M20 7 L4 15" stroke="#fff" strokeWidth="0.8" opacity="0.5" />
      <circle cx="9" cy="8" r="1.6" fill="#fff" opacity="0.85" />
    </svg>
  );
}

// Treasures won from bosses: wear up to three.
function TreasurePanel({ owned, worn, onToggle }) {
  const have = owned.filter(t => t.owned).length;
  return (
    <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 10, marginBottom: 12 }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>
        Treasures · {have} of {owned.length} found · wearing {worn.length} of {EQUIP_MAX}
      </div>
      {have ? (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))", gap: 6 }}>
          {owned.filter(t => t.owned).map(t => {
            const on = worn.includes(t.i);
            return (
              <button key={t.i} type="button" onClick={() => onToggle(t.i)} title={t.text} style={{
                display: "flex", alignItems: "center", gap: 6, padding: "6px 8px", borderRadius: 10, fontFamily: "inherit", textAlign: "left", cursor: "pointer",
                border: `2px solid ${on ? T.teal : T.slate200}`, background: on ? T.tealLt : T.white,
              }}>
                <TreasureIcon color={t.color} size={22} />
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900 }}>{t.name}{on ? " ✓" : ""}</div>
                  <div style={{ fontSize: 10, color: T.slate600 }}>{t.text}</div>
                  <div style={{ fontSize: 10, fontWeight: 700, color: "#8E5CB8" }}>Level {t.lv}{t.next ? ` · ${t.xp}/${t.next} wins to level ${t.lv + 1}` : " · fully powered"}</div>
                </div>
              </button>
            );
          })}
        </div>
      ) : <div style={{ fontSize: 12, color: T.slate500 }}>Beat a world's boss to find its treasure.</div>}
    </div>
  );
}

function FireMap({ diff, unlocked, onPlay }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(92px, 1fr))", gap: 8 }}>
      {Array.from({ length: FIRE_LEVELS }, (_, i) => {
        const n = i + 1;
        const open = n <= unlocked;
        const done = n < unlocked;
        return (
          <button key={n} type="button" disabled={!open} onClick={() => onPlay(n)} style={{
            padding: "10px 6px", borderRadius: 14, fontFamily: "inherit", cursor: open ? "pointer" : "default",
            background: !open ? T.slate200 : done ? T.greenLt : T.white, border: `2px solid ${!open ? T.slate300 : done ? T.green : T.amber}`,
          }}>
            <div style={{ fontSize: 20, fontWeight: 800, color: open ? T.slate900 : T.slate400 }}>{open ? (done ? "✓" : n) : "🔒"}</div>
            <div style={{ fontSize: 11, color: T.slate600 }}>Level {n}</div>
            <div style={{ fontSize: 11, color: T.slate600 }}>{fireLevel(n, diff).goal.toLocaleString()} pts</div>
          </button>
        );
      })}
    </div>
  );
}

function Tile({ tile, size, left, top, order, hinted, danger, onTap }) {
  const chosen = order >= 0;
  const gem = GEM_LOOK[tile.kind];
  const fire = tile.kind === "fire";
  const stone = tile.stone > 0;
  const burning = tile.burn > 0;
  const bg = burning ? "linear-gradient(170deg,#FFE3B0 0%,#FFB067 60%,#FF7A2F 100%)" : stone ? "linear-gradient(170deg,#B5B2A8,#7A7C6E)" : chosen ? T.blue : fire ? "linear-gradient(170deg,#FFD27A 0%,#FF7A2F 45%,#D7261E 100%)" : gem ? gem.bg : "linear-gradient(170deg,#FFF9EC,#EADFC4)";
  const ink = stone ? "#4D503F" : chosen ? T.white : fire ? "#fff" : gem ? gem.ink : T.slate900;
  const border = stone ? "#5C5E50" : chosen ? T.chromeBgDeep : fire ? "#9E1B14" : gem ? gem.border : "#C9BB98";
  return (
    <button
      type="button"
      onClick={onTap}
      disabled={stone}
      aria-label={`${tile.ch}${fire ? " fire" : gem ? ` ${tile.kind}` : ""}${stone ? " stone" : ""}${burning ? " burning" : ""}`}
      style={{
        position: "absolute", left: left + 3, top: top + 3, width: size - 6, height: size - 6, padding: 0, cursor: stone ? "default" : "pointer",
        borderRadius: Math.round(size * 0.16), border: `2px solid ${border}`, background: bg, color: ink,
        boxShadow: danger || burning ? "0 0 0 3px rgba(239,68,68,0.6)" : "0 3px 0 rgba(0,0,0,0.15)",
        transition: "top 0.25s ease-out, background 0.15s", fontFamily: "Georgia, 'Times New Roman', serif",
        animation: hinted ? "sqHint 0.6s ease-in-out infinite alternate" : tile.fresh ? "sqDrop 0.3s ease-out" : fire || burning ? "sqFlicker 0.9s ease-in-out infinite alternate" : "none",
      }}
    >
      <span style={{ fontSize: Math.round(size * (tile.ch.length > 1 ? 0.4 : 0.5)), fontWeight: 700, lineHeight: 1 }}>{tile.ch === "QU" ? "Qu" : tile.ch}</span>
      <span style={{ position: "absolute", right: 5, bottom: 3, fontSize: Math.max(9, Math.round(size * 0.17)), opacity: 0.7 }}>
        {stone ? tile.stone : burning ? `🔥${tile.burn}` : Math.round((VALUE[tile.ch] || 1) * 10)}
      </span>
      {chosen ? <span style={{ position: "absolute", left: 5, top: 3, fontSize: Math.max(9, Math.round(size * 0.19)), fontWeight: 700, opacity: 0.85 }}>{order + 1}</span> : null}
    </button>
  );
}

function Bar({ value, max, color, label, small = false }) {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", gap: 6, fontSize: small ? 11 : 12, fontWeight: 700, color: T.slate800, marginBottom: 2 }}>
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{label}</span><span>{Math.max(0, value).toLocaleString()}/{max.toLocaleString()}</span>
      </div>
      <div style={{ height: small ? 8 : 10, borderRadius: 6, background: "rgba(0,0,0,0.12)", overflow: "hidden" }}>
        <div style={{ width: `${pct}%`, height: "100%", background: color, transition: "width 0.35s" }} />
      </div>
    </div>
  );
}
