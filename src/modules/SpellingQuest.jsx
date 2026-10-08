import { useEffect, useMemo, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";
import { useDancers, CritterIcon } from "../components/Critters.jsx";
import QuestMonster from "../components/QuestMonster.jsx";
import {
  WORLDS, MONSTERS as QUEST_MONSTERS, LEVELS_PER_WORLD, LEVEL_TOTAL, worldOf, stepOf, levelName, monstersForLevel, heroHpForLevel,
  endlessMonster, endlessWorld, ENDLESS_HERO_HP, POTIONS, POTION_KEYS, POTION_MAX,
} from "../lib/questWorlds.js";

// =========================================================================
// SpellingQuest.jsx — the Family spelling game (in the style of Bookworm and
// Bookworm Adventures). Two modes, each with a map and an Endless run.
//
// Monsters (like Bookworm Adventures): a 4x4 grid of letters, used in any
// order. Each word hits the monster for its exact score; the monster hits back.
// Ten worlds of ten levels (src/lib/questWorlds.js has the story, the worlds
// and the monsters); each level is 2–4 monsters and each world ends in a boss.
// Long words leave gem tiles: green heals you, gold hits 50% harder, diamond
// hits twice as hard and heals. Beaten monsters drop potions (heal, power,
// freeze) that are kept between games. Some monsters turn a letter to stone.
// Heroes are the family's dancing characters; a kid starts on their own animal.
//
// Fire (like Bookworm): a 7x7 square grid; letters must touch (sideways, up,
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
// up) and items (potions). Guest progress lasts until the page closes.
// Word lists: public/games/words.txt (accepted), common.txt (hints only).
// =========================================================================

const FIRE_LEVELS = 12;

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
const GEM_LOOK = {
  green:   { bg: "linear-gradient(160deg,#B9F2C8,#4CBF72)", border: "#2E8B57", ink: "#0F3D22" },
  gold:    { bg: "linear-gradient(160deg,#FFE9A6,#E2B13C)", border: "#A8801F", ink: "#4A3500" },
  diamond: { bg: "linear-gradient(160deg,#E3F6FF,#8CCFF2)", border: "#3F8DB8", ink: "#0E3550" },
};

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
    goal: Math.round(((300 + 150 * (n - 1)) * diff.goal) / 10) * 10,
    fire3: Math.min(0.75, (0.2 + 0.04 * n) * diff.fire),
    fire4: Math.min(0.45, 0.03 * n * diff.fire),
    startFires: Math.floor((n - 1) / 3),
  };
}
const endlessLevelAt = lv => 300 * (lv * (lv - 1)) / 2;

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
const newTile = (board, diff, kind = "normal") => ({ id: NEXT_ID++, ch: randomLetter(board, diff), kind, stone: 0, fresh: true });
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
const GUEST = { unlocked: {}, items: { heal: 1, power: 1, freeze: 0 } };

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

  const choosePlayer = id => {
    setPlayerId(id);
    const kid = players.find(p => p.id === id);
    if (kid?.animal) setHeroKey(kid.animal);
    setDiffKey(diffForAge(kid ? kid.age : null));
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
  const hitPoints = Math.round(base * (1 + 0.5 * (gems.gold || 0) + (gems.diamond || 0)) * (fight?.power ? 2 : 1));
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
      if (endless) {
        const m = endlessMonster(1, diff);
        setFight({ foes: null, idx: 0, stage: 1, monster: m, mhp: m.hp, hp: ENDLESS_HERO_HP, hpMax: ENDLESS_HERO_HP, beaten: 0, freeze: 0, power: false, turns: 0 });
      } else {
        const foes = monstersForLevel(level, diff);
        const hpMax = heroHpForLevel(level);
        setFight({ foes, idx: 0, stage: 1, monster: foes[0], mhp: foes[0].hp, hp: hpMax, hpMax, beaten: 0, freeze: 0, power: false, turns: 0 });
      }
      setBag({ ...savedItems });
    } else {
      setBoard(newBoard(diff, 7, 7, endless ? 0 : fireLevel(level, diff).startFires));
      setFight(null); setBag(null);
    }
    setSel([]); setScore(0); setWords([]); setTurn(0); setResult(null); setMessage(null); setHint(null);
    setFloats([]); setBusy(false); setFx(f => ({ key: f.key + 1, hero: null, mon: "enter", fly: null }));
    setHintsLeft(diff.hints);
    setRun({ endless, level });
    setScreen("play");
  };

  const finishRun = async ({ won, finalScore, finalWords, fightInfo, items }) => {
    stopTimers();
    const best = [...finalWords].sort((a, b) => b.points - a.points)[0] || null;
    const level = run?.level || null;
    const nextOpen = won && level ? Math.min(levelCount, level + 1) : null;
    const summary = { won, endless: !!run?.endless, level, score: finalScore, count: finalWords.length, best, fight: fightInfo || null, saved: null, isBest: false };
    setResult(summary);
    setScreen("over");
    setBusy(false);
    if (!player) {
      if (nextOpen) { const k = `${mode}:${diffKey}`; GUEST.unlocked[k] = Math.max(GUEST.unlocked[k] || 1, nextOpen); }
      if (items) GUEST.items = { ...items };
      setGuestTick(t => t + 1);
      return;
    }
    const detail = {
      difficulty: diffKey, level, endless: !!run?.endless, won: !!won, words: finalWords.length,
      best_word: best?.word || null, best_word_points: best?.points || 0,
      ...(fightInfo ? { beaten: fightInfo.beaten, hero: hero?.key || null } : {}),
      ...(nextOpen ? { unlock_key: diffKey, unlock: nextOpen } : {}),
      ...(items ? { items } : {}),
    };
    const r = await recordFamilyGame(player.id, gameKey, finalScore, detail);
    setResult({ ...summary, saved: r.saved, isBest: r.isBest });
    reload();
  };

  const tap = (tile) => {
    if (!board || busy || tile.stone) return;
    setHint(null);
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
    if (f.freeze > 0) {
      later(() => { setFight({ ...f, freeze: f.freeze - 1 }); say(`${f.monster.name} is frozen solid!`, "good"); setBusy(false); }, delay);
      return;
    }
    const turns = f.turns + 1;
    const hit = ri(f.monster.hit[0], f.monster.hit[1]);
    const hp = Math.max(0, f.hp - hit);
    const mends = f.monster.power === "heal" && turns % 3 === 0 ? Math.round(f.monster.hp * 0.08) : 0;
    const mhp = Math.min(f.monster.hp, f.mhp + mends);
    // Stones wear off a turn at a time; a stone monster may turn one more letter to stone.
    const b2 = b.map(col => col.map(t => ({ ...t, fresh: false, stone: Math.max(0, (t.stone || 0) - 1) })));
    let stoned = false;
    if (f.monster.power === "stone" && Math.random() < 0.35) {
      const open = b2.flat().filter(t => !t.stone && t.kind === "normal");
      if (open.length) { pick(open).stone = 3; stoned = true; }
    }
    later(() => play(null, "lunge"), delay);
    later(() => {
      play("hurt", null);
      floatUp("hero", `-${hit}`, "#D7261E");
      if (mends) floatUp("mon", `+${mends}`, "#2E8B57");
      setFight({ ...f, hp, mhp, turns });
      setBoard(b2);
      if (hp <= 0) {
        later(() => finishRun({ won: false, finalScore: newScore, finalWords: newWords, fightInfo: { beaten: f.beaten, monster: f.monster.name }, items }), 900);
        return;
      }
      say(`${f.monster.name} hits you for ${hit}${stoned ? " · a letter turned to stone" : ""}${mends ? ` · it mends ${mends}` : ""}`, "warn");
      setBusy(false);
    }, delay + 260);
  };

  const submitMonsters = () => {
    const f = fight;
    const dmg = hitPoints;
    const heal = Math.round(f.hpMax * 0.1 * ((gems.green || 0) + (gems.diamond || 0)));
    const used = new Set(sel);
    const gemKind = GEM_FOR_LEN(word.length);
    const b = cloneBoard(board);
    const spawn = refill(b, used, diff);
    if (gemKind && spawn.length) pick(spawn).kind = gemKind;
    const newWords = [{ word, points: dmg }, ...words];
    const mhp = f.mhp - dmg;
    const hp = Math.min(f.hpMax, f.hp + heal);
    let newScore = score + dmg;
    setBusy(true); setSel([]); setHint(null); setBoard(b); setWords(newWords); setTurn(turn + 1);
    setFx(x => ({ key: x.key + 1, hero: "lunge", mon: null, fly: word.toUpperCase() }));
    later(() => {
      play(null, "hurt");
      floatUp("mon", `-${dmg}`, "#D7261E");
      if (heal) floatUp("hero", `+${heal}`, "#2E8B57");
      setFight({ ...f, mhp: Math.max(0, mhp), hp, power: false });
    }, 380);

    if (mhp > 0) {
      setScore(newScore);
      monsterTurn({ ...f, mhp, hp, power: false }, b, newWords, newScore, bag, 1100);
      return;
    }
    // Monster beaten: it may drop a potion (a boss always drops two).
    const beaten = f.beaten + 1;
    newScore += 50 * f.stage;
    const drops = [];
    const dropCount = f.monster.boss ? 2 : Math.random() < 0.35 ? 1 : 0;
    const items = { ...bag };
    for (let i = 0; i < dropCount; i++) { const k = pick(POTION_KEYS); if (items[k] < POTION_MAX) { items[k] += 1; drops.push(POTIONS[k].short); } }
    setScore(newScore);
    later(() => play(null, "ko"), 900);
    const last = f.foes && f.idx + 1 >= f.foes.length;
    if (last) {
      setBag(items);
      later(() => finishRun({ won: true, finalScore: newScore, finalWords: newWords, fightInfo: { beaten, monster: f.monster.name }, items }), 1700);
      return;
    }
    const next = f.foes ? f.foes[f.idx + 1] : endlessMonster(f.stage + 1, diff);
    const healBetween = Math.round(f.hpMax * (f.foes ? 0.1 : 0.15));
    later(() => {
      setBag(items);
      setFight({ ...f, idx: f.idx + 1, stage: f.stage + 1, monster: next, mhp: next.hp, hp: Math.min(f.hpMax, hp + healBetween), beaten, power: false, turns: 0 });
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
    if (k === "heal") {
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
         {mode === "monsters" ? "Win back the ten pages of the Great Word Book." : "Spell words with touching letters. Keep the fire off the bottom row."}
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
          <Chips value={mode} onChange={m => { setMode(m); setWorldView(null); }} options={[["monsters", "Monsters", "A quest through 10 worlds"], ["fire", "Fire", "Keep fire off the bottom"]]} />
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
      return wrap(<>{title}{head}
        <div style={{ fontSize: 13, color: T.slate600, marginBottom: 10, lineHeight: 1.5 }}>
          The Great Word Book kept every word in the land bright, until Grumblegloom, a dragon who hates noise, tore out its ten pages and woke the monsters. Win the pages back!
        </div>
        <div style={{ display: "grid", gap: 8 }}>
          {WORLDS.map((w, i) => {
            const first = i * LEVELS_PER_WORLD + 1;
            const open = first <= unlocked;
            const done = Math.max(0, Math.min(LEVELS_PER_WORLD, unlocked - first));
            return (
              <button key={w.name} type="button" disabled={!open} onClick={() => setWorldView(i)} style={{
                display: "flex", alignItems: "center", gap: 12, padding: 10, borderRadius: 14, textAlign: "left", fontFamily: "inherit",
                border: `1px solid ${T.slate200}`, cursor: open ? "pointer" : "default", opacity: open ? 1 : 0.55,
                background: `linear-gradient(120deg, ${w.sky[0]}, ${w.sky[1]})`,
              }}>
                <div style={{ flexShrink: 0, width: 56, height: 56, display: "flex", alignItems: "center", justifyContent: "center" }}>
                  {open ? <QuestMonster m={MONSTER_OF(w.boss)} size={56} flip={false} /> : <span style={{ fontSize: 28 }}>🔒</span>}
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 16, fontWeight: 800, color: T.slate900 }}>World {i + 1}: {w.name}</div>
                  <div style={{ fontSize: 12, color: T.slate800 }}>{done >= LEVELS_PER_WORLD ? `✓ ${w.page[0].toUpperCase()}${w.page.slice(1)} won back` : open ? `${done} of ${LEVELS_PER_WORLD} levels done` : "Locked"}</div>
                </div>
              </button>
            );
          })}
        </div>
        {endlessBtn}
      </>);
    }
    const w = WORLDS[worldView];
    return wrap(<>{title}{head}
      <button type="button" onClick={() => setWorldView(null)} style={{ ...btn(T.slate400), padding: "6px 12px", fontSize: 13, marginBottom: 10 }}>← All worlds</button>
      <WorldMap world={w} index={worldView} unlocked={unlocked} onPlay={n => startRun(false, n)} />
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
        {isBossWin ? <div style={{ fontSize: 14, color: T.slate700, lineHeight: 1.5, background: T.goldLt, borderRadius: 10, padding: 10 }}>{WORLDS[worldOf(result.level)].outro}</div> : null}
        <div style={{ fontSize: 40, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
        {result.isBest ? <div style={{ fontSize: 16, fontWeight: 700, color: T.gold }}>New best score!</div> : null}
        <div style={{ fontSize: 15, color: T.slate700 }}>
          {result.count} words{result.fight ? ` · beat ${result.fight.beaten} monster${result.fight.beaten === 1 ? "" : "s"}` : ""}
        </div>
        {result.best ? <div style={{ fontSize: 15, color: T.slate700 }}>Best word: <b>{result.best.word.toUpperCase()}</b> ({result.best.points.toLocaleString()})</div> : null}
        {player && result.saved === false ? <div style={{ fontSize: 13, color: T.red }}>Couldn't save this game.</div> : null}
        <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 6 }}>
          {canNext ? <button type="button" onClick={() => startRun(false, result.level + 1)} style={btn(T.teal)}>Next level</button> : null}
          <button type="button" onClick={() => startRun(result.endless, result.level)} style={btn(canNext ? T.slate600 : T.teal)}>Play again</button>
          <button type="button" onClick={() => { if (mode === "monsters" && result.level) setWorldView(worldOf(Math.min(levelCount, canNext ? result.level + 1 : result.level))); setScreen("map"); }} style={btn(T.slate600)}>Map</button>
        </div>
      </div>
    </>);
  }

  if (!board || !run) return null;
  const cols = board.length;
  const rows = board[0].length;
  const S = anyOrder
    ? Math.max(56, Math.min(84, Math.floor(boxW / 4.2)))
    : Math.max(40, Math.min(60, Math.floor(boxW / (cols + 0.2))));
  const where = run.endless ? "Endless" : mode === "monsters" ? `${worldOf(run.level) + 1}-${stepOf(run.level)} ${levelName(run.level)}` : `Level ${run.level}`;
  const progress = mode === "monsters"
    ? (run.endless ? `monster ${fight?.stage}` : `monster ${(fight?.idx || 0) + 1} of ${fight?.foes?.length}`)
    : (run.endless ? `level ${endlessLevel}` : `goal ${fireCfg.goal.toLocaleString()}`);
  const world = mode === "monsters" ? WORLDS[run.endless ? endlessWorld(fight?.stage || 1) : worldOf(run.level)] : null;

  return wrap(<>
    <QuestStyles />
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", flexWrap: "wrap", gap: 8, marginBottom: 8 }}>
      <div style={{ fontSize: 15, fontWeight: 700, color: T.slate800 }}>{where}</div>
      <div style={{ fontSize: 13, color: T.slate600 }}>{score.toLocaleString()} pts · {progress}</div>
    </div>
    {mode === "fire" && !run.endless ? <Bar value={score} max={fireCfg.goal} color={T.amber} label="Goal" /> : null}
    {fight ? <Arena fight={fight} hero={hero} world={world} fx={fx} floats={floats} wide={!_vp.isPhone} /> : null}
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
        {fight.power ? <span style={{ alignSelf: "center", fontSize: 12, fontWeight: 700, color: "#A8801F" }}>Power ready!</span> : null}
        {fight.freeze ? <span style={{ alignSelf: "center", fontSize: 12, fontWeight: 700, color: "#3F8DB8" }}>Frozen {fight.freeze}</span> : null}
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
function Arena({ fight, hero, world, fx, floats, wide }) {
  const m = fight.monster;
  const size = wide ? 130 : 104;
  const anim = a => a === "lunge" ? "sqLungeR 0.55s ease-out" : a === "hurt" ? "sqHurt 0.45s" : a === "heal" ? "sqHeal 0.7s" : "none";
  const monAnim = fx.mon === "lunge" ? "sqLungeL 0.55s ease-out" : fx.mon === "hurt" ? "sqHurt 0.45s"
    : fx.mon === "ko" ? "sqKo 0.6s forwards" : fx.mon === "enter" ? "sqEnter 0.5s ease-out" : "none";
  const sky = world ? world.sky : ["#EEE", "#CCC"];
  return (
    <div style={{
      position: "relative", marginTop: 8, borderRadius: 16, overflow: "hidden", height: wide ? 250 : 214,
      background: `linear-gradient(180deg, ${sky[0]} 0%, ${sky[1]} 72%, ${world ? world.ground : "#999"} 72%)`, border: `1px solid ${T.slate200}`,
    }}>
      {/* health bars */}
      <div style={{ position: "absolute", top: 8, left: 10, right: 10, display: "flex", gap: 12, zIndex: 2 }}>
        <div style={{ flex: 1 }}><Bar value={fight.hp} max={fight.hpMax} color={T.green} label={hero ? hero.label : "You"} small /></div>
        <div style={{ flex: 1 }}><Bar value={fight.mhp} max={m.hp} color={T.red} label={m.boss ? `${m.name} ★` : m.name} small /></div>
      </div>
      {/* hero */}
      <div style={{ position: "absolute", left: "8%", bottom: "16%" }}>
        <div key={`h${fx.key}`} style={{ animation: anim(fx.hero) }}>
          <div style={{ animation: "sqIdle 1.6s ease-in-out infinite" }}>
            {hero ? <CritterIcon which={hero.key} size={size} /> : null}
          </div>
        </div>
      </div>
      {/* monster */}
      <div style={{ position: "absolute", right: "8%", bottom: "14%" }}>
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

// One world of the Monsters map: its story, then a winding trail of eight levels.
function WorldMap({ world, index, unlocked, onPlay }) {
  return (
    <div style={{ borderRadius: 16, padding: 12, background: `linear-gradient(180deg, ${world.sky[0]}, ${world.sky[1]})`, border: `1px solid ${T.slate200}` }}>
      <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>World {index + 1}: {world.name}</div>
      <div style={{ fontSize: 13, color: T.slate800, lineHeight: 1.5, margin: "6px 0 12px", background: "rgba(255,255,255,0.7)", borderRadius: 10, padding: 10 }}>{world.intro}</div>
      <div style={{ display: "grid", gap: 6 }}>
        {world.levels.map((name, i) => {
          const n = index * LEVELS_PER_WORLD + i + 1;
          const open = n <= unlocked;
          const done = n < unlocked;
          const boss = i === LEVELS_PER_WORLD - 1;
          const foes = monstersForLevel(n, DIFFICULTY.medium);
          return (
            <div key={name} style={{ display: "flex", justifyContent: i % 2 ? "flex-end" : "flex-start" }}>
              <button type="button" disabled={!open} onClick={() => onPlay(n)} style={{
                width: "78%", display: "flex", alignItems: "center", gap: 10, padding: "8px 10px", borderRadius: 14, fontFamily: "inherit", textAlign: "left",
                background: !open ? "rgba(255,255,255,0.45)" : done ? "rgba(209,250,229,0.95)" : T.white,
                border: `2px solid ${!open ? T.slate300 : boss ? T.red : done ? T.green : T.teal}`,
                boxShadow: open && !done ? `0 0 0 4px ${T.tealLt}` : "none", cursor: open ? "pointer" : "default",
              }}>
                <div style={{
                  flexShrink: 0, width: 34, height: 34, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center",
                  background: !open ? T.slate300 : done ? T.green : boss ? T.red : T.teal, color: T.white, fontWeight: 800, fontSize: 15,
                }}>{!open ? "🔒" : done ? "✓" : i + 1}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{name}{boss ? " · Boss" : ""}</div>
                  <div style={{ fontSize: 11, color: T.slate600 }}>{foes.length} monsters</div>
                </div>
                {open ? <div style={{ display: "flex" }}>{foes.slice(-2).map((f, k) => <QuestMonster key={k} m={f} size={30} />)}</div> : null}
              </button>
            </div>
          );
        })}
      </div>
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
  const bg = stone ? "linear-gradient(170deg,#B5B2A8,#7A7C6E)" : chosen ? T.blue : fire ? "linear-gradient(170deg,#FFD27A 0%,#FF7A2F 45%,#D7261E 100%)" : gem ? gem.bg : "linear-gradient(170deg,#FFF9EC,#EADFC4)";
  const ink = stone ? "#4D503F" : chosen ? T.white : fire ? "#fff" : gem ? gem.ink : T.slate900;
  const border = stone ? "#5C5E50" : chosen ? T.chromeBgDeep : fire ? "#9E1B14" : gem ? gem.border : "#C9BB98";
  return (
    <button
      type="button"
      onClick={onTap}
      disabled={stone}
      aria-label={`${tile.ch}${fire ? " fire" : gem ? ` ${tile.kind}` : ""}${stone ? " stone" : ""}`}
      style={{
        position: "absolute", left: left + 3, top: top + 3, width: size - 6, height: size - 6, padding: 0, cursor: stone ? "default" : "pointer",
        borderRadius: Math.round(size * 0.16), border: `2px solid ${border}`, background: bg, color: ink,
        boxShadow: danger ? "0 0 0 3px rgba(239,68,68,0.55)" : "0 3px 0 rgba(0,0,0,0.15)",
        transition: "top 0.25s ease-out, background 0.15s", fontFamily: "Georgia, 'Times New Roman', serif",
        animation: hinted ? "sqHint 0.6s ease-in-out infinite alternate" : tile.fresh ? "sqDrop 0.3s ease-out" : fire ? "sqFlicker 0.9s ease-in-out infinite alternate" : "none",
      }}
    >
      <span style={{ fontSize: Math.round(size * (tile.ch.length > 1 ? 0.4 : 0.5)), fontWeight: 700, lineHeight: 1 }}>{tile.ch === "QU" ? "Qu" : tile.ch}</span>
      <span style={{ position: "absolute", right: 5, bottom: 3, fontSize: Math.max(9, Math.round(size * 0.17)), opacity: 0.7 }}>
        {stone ? tile.stone : Math.round((VALUE[tile.ch] || 1) * 10)}
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
