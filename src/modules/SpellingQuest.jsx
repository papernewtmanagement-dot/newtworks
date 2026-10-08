import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";
import { useDancers, CritterIcon, DoneDancerStyles } from "../components/Critters.jsx";

// =========================================================================
// SpellingQuest.jsx — the Family spelling game (in the style of Bookworm and
// Bookworm Adventures). A board of letter tiles, 7 columns of 8, every other
// column set half a tile lower so each tile touches up to six others. Tap
// touching letters in order to spell a word, then Go. Spelled tiles disappear
// and new ones drop in from the top.
//
// Scoring: each letter is worth more the rarer it is (x10), longer words
// multiply the total, gem tiles (earned by 5, 6, 7+ letter words) add a bonus.
//
// Two modes, each with a level map and an Endless run:
//   Monsters  each word hits the monster for its exact score; the monster hits
//             back after every word that doesn't finish it. A map level is one
//             to three monsters, with a boss closing each area; your hero gets
//             tougher as the map goes on. Heroes are the family's dancing
//             characters (dancers table); a kid starts on their own animal.
//   Fire      short words can drop in fire tiles; after each word a fire burns
//             the tile under it and sinks a row. A map level is won by reaching
//             its score before fire reaches the bottom row.
//
// Difficulty (Starter, Easy, Medium, Hard) sets the letters (no hard letters
// on Starter), monster strength, how often fire comes, hints, and the shortest
// word allowed. A kid starts at the level for their age and can change it, so
// each one plays at a level they win most of the time but not all of it, where
// practice pays off most (Wilson et al. 2019, Nature Communications 10:4646).
//
// Dictionary: public/games/words.txt (about 72,000 everyday words, 3–12 letters).
// Saved per kid on family_kids.game_bests: bookworm (Fire), bookworm_battle
// (Monsters); each holds the best score and unlocked.<difficulty> = highest map
// level open. Guest progress lasts until the page closes.
// =========================================================================

const COLS = 7;
const ROWS = 8;
const LEVEL_COUNT = 12;

// How often each letter shows up (roughly English) and what it is worth.
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
const GEM_BONUS = { green: 0.5, gold: 1, diamond: 2 };
const GEM_LOOK = {
  green:   { bg: "linear-gradient(160deg,#B9F2C8,#4CBF72)", border: "#2E8B57", ink: "#0F3D22" },
  gold:    { bg: "linear-gradient(160deg,#FFE9A6,#E2B13C)", border: "#A8801F", ink: "#4A3500" },
  diamond: { bg: "linear-gradient(160deg,#E3F6FF,#8CCFF2)", border: "#3F8DB8", ink: "#0E3550" },
};

// ── Difficulty ──────────────────────────────────────────────────────────
//   hardLetters  weight of K J X Qu Z V (0 = never)
//   vowels       [low, high] share of vowels the board is kept between
//   minLen       shortest word that counts
//   monsterHp / monsterHit   multiply monster health and hits
//   fire         multiply the chance a fire drops in; burnEvery: fire burns every Nth word
//   goal         multiply the score a Fire level asks for
//   hints        hints per level (Infinity = as many as wanted)
const DIFFICULTY = {
  starter: { label: "Starter", ages: "5–7",  hardLetters: 0,   vowels: [0.38, 0.55], minLen: 3, monsterHp: 0.6,  monsterHit: 0.5,  fire: 0.5,  burnEvery: 2, goal: 0.6,  hints: Infinity },
  easy:    { label: "Easy",    ages: "8–10", hardLetters: 0.5, vowels: [0.33, 0.5],  minLen: 3, monsterHp: 0.8,  monsterHit: 0.75, fire: 0.75, burnEvery: 1, goal: 0.8,  hints: 3 },
  medium:  { label: "Medium",  ages: "11–13", hardLetters: 1,  vowels: [0.3, 0.5],   minLen: 3, monsterHp: 1,    monsterHit: 1,    fire: 1,    burnEvery: 1, goal: 1,    hints: 1 },
  hard:    { label: "Hard",    ages: "14+",  hardLetters: 1,   vowels: [0.28, 0.48], minLen: 4, monsterHp: 1.25, monsterHit: 1.2,  fire: 1.3,  burnEvery: 1, goal: 1.3,  hints: 0 },
};
const DIFF_KEYS = ["starter", "easy", "medium", "hard"];
const diffForAge = age => (age == null ? "medium" : age <= 7 ? "starter" : age <= 10 ? "easy" : age <= 13 ? "medium" : "hard");

// ── Monsters ────────────────────────────────────────────────────────────
// hp is in points: a word hits for its exact score.
const MONSTERS = {
  dust:   { name: "Dust Bunny",    hp: 200,  hit: [2, 4],  body: "#C9C2B8", look: "ears" },
  ink:    { name: "Ink Blot",      hp: 260,  hit: [2, 5],  body: "#4A477E", look: "blob" },
  moth:   { name: "Paper Moth",    hp: 300,  hit: [3, 5],  body: "#D9C9A3", look: "wings" },
  rat:    { name: "Riddle Rat",    hp: 400,  hit: [3, 6],  body: "#8C7B6B", look: "ears" },
  gnome:  { name: "Grumble Gnome", hp: 460,  hit: [4, 7],  body: "#6E8B4E", look: "hat" },
  slug:   { name: "Spell Slug",    hp: 520,  hit: [4, 7],  body: "#8DBA5E", look: "blob" },
  toad:   { name: "Moss Toad",     hp: 560,  hit: [5, 8],  body: "#5E8C6A", look: "blob" },
  troll:  { name: "Shelf Troll",   hp: 720,  hit: [5, 9],  body: "#7A6A8C", look: "horns" },
  bat:    { name: "Quill Bat",     hp: 760,  hit: [6, 9],  body: "#3B3E32", look: "wings" },
  ghost:  { name: "Candle Ghost",  hp: 840,  hit: [6, 10], body: "#E8E6F2", look: "blob" },
  dragon: { name: "Page Dragon",   hp: 1100, hit: [7, 11], body: "#B8483A", look: "dragon" },
};
const ENDLESS_ORDER = ["dust", "ink", "moth", "rat", "gnome", "slug", "toad", "troll", "bat", "ghost", "dragon"];
const AREAS = ["Dusty Library", "Whispering Woods", "Castle Archives"];
// The Monsters map: 12 levels, 4 per area, a boss closing each area.
const MONSTER_LEVELS = [
  ["dust"], ["ink"], ["dust", "moth"], ["rat"],
  ["gnome"], ["slug"], ["toad", "gnome"], ["troll"],
  ["bat"], ["ghost"], ["bat", "ghost"], ["dragon"],
];
const isBossLevel = n => n % 4 === 0;
const heroHpForLevel = n => 50 + 10 * (n - 1); // your hero gets tougher along the map
const ENDLESS_HERO_HP = 60;
const HEAL_BETWEEN = 10;  // between monsters inside a level
const HEAL_ENDLESS = 15;  // after each Endless monster

function scaleMonster(key, diff, { boss = false, round = 0 } = {}) {
  const m = MONSTERS[key];
  const hpK = diff.monsterHp * (boss ? 1.25 : 1) * (1 + 0.4 * round);
  const hitK = diff.monsterHit * (1 + 0.4 * round);
  return {
    ...m,
    name: round ? `${m.name} ${round + 1}` : m.name,
    boss,
    hp: Math.round((m.hp * hpK) / 10) * 10,
    hit: [Math.max(1, Math.round(m.hit[0] * hitK)), Math.max(1, Math.round(m.hit[1] * hitK))],
  };
}
const endlessMonster = (stage, diff) =>
  scaleMonster(ENDLESS_ORDER[(stage - 1) % ENDLESS_ORDER.length], diff, { round: Math.floor((stage - 1) / ENDLESS_ORDER.length) });

// ── Fire levels ─────────────────────────────────────────────────────────
// Score to reach, how likely a short word drops a fire, and fires already on the board.
function fireLevel(n, diff) {
  return {
    goal: Math.round(((300 + 150 * (n - 1)) * diff.goal) / 10) * 10,
    fire3: Math.min(0.75, (0.2 + 0.04 * n) * diff.fire),
    fire4: Math.min(0.45, 0.03 * n * diff.fire),
    startFires: Math.floor((n - 1) / 3),
  };
}
// Endless fire: the level rises with the score (0, 300, 900, 1800…).
const endlessLevelAt = lv => 300 * (lv * (lv - 1)) / 2;

const ri = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

// ── Dictionary and hints ────────────────────────────────────────────────
// words.txt: every word the game accepts. common.txt: about 6,000 everyday words
// (SCOWL sizes 10–20, 3–7 letters), the only ones a hint suggests.
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
const loadDictionary = () => loadList("words");
const PREFIXES = new WeakMap(); // per word list, built the first time a hint is asked for
function prefixesOf(dict) {
  let p = PREFIXES.get(dict);
  if (!p) {
    p = new Set();
    for (const w of dict) for (let i = 1; i < w.length; i++) p.add(w.slice(0, i));
    PREFIXES.set(dict, p);
  }
  return p;
}
// A word on the board, as tile ids. Prefers 4–5 letters, the kind a kid can learn from.
function findHint(board, dict, minLen) {
  const pre = prefixesOf(dict);
  let best = null;
  const score = len => (len === 4 || len === 5 ? 3 : len === 3 ? 2 : 1);
  const walk = (path, word) => {
    if (word.length >= minLen && dict.has(word) && (!best || score(word.length) > score(best.word.length))) best = { ids: path.map(p => p.id), word };
    if (best && score(best.word.length) === 3) return;
    if (word.length >= 6 || !pre.has(word)) return;
    const last = path[path.length - 1];
    for (let c = Math.max(0, last.c - 1); c <= Math.min(COLS - 1, last.c + 1); c++) {
      for (let r = 0; r < ROWS; r++) {
        const t = board[c][r];
        if (path.some(p => p.id === t.id) || !touching(last, { c, r })) continue;
        path.push({ c, r, id: t.id });
        walk(path, word + t.ch.toLowerCase());
        path.pop();
      }
    }
  };
  for (let c = 0; c < COLS; c++) for (let r = 0; r < ROWS; r++) {
    walk([{ c, r, id: board[c][r].id }], board[c][r].ch.toLowerCase());
    if (best && score(best.word.length) === 3) return best;
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
const newTile = (board, diff, kind = "normal") => ({ id: NEXT_ID++, ch: randomLetter(board, diff), kind, fresh: true });

function newBoard(diff, startFires = 0) {
  const b = [];
  for (let c = 0; c < COLS; c++) { b.push([]); for (let r = 0; r < ROWS; r++) b[c].push(newTile(b, diff)); }
  const cols = [...Array(COLS).keys()].sort(() => Math.random() - 0.5).slice(0, startFires);
  cols.forEach(c => { b[c][0].kind = "fire"; });
  return b;
}
const cloneBoard = b => b.map(col => col.map(t => ({ ...t, fresh: false })));

function findTile(board, id) {
  for (let c = 0; c < COLS; c++) { const r = board[c].findIndex(t => t.id === id); if (r >= 0) return { c, r }; }
  return null;
}
// Odd columns sit half a tile lower, so a tile touches the two nearest tiles in each next-door column.
function touching(a, b) {
  if (!a || !b) return false;
  if (a.c === b.c) return Math.abs(a.r - b.r) === 1;
  if (Math.abs(a.c - b.c) !== 1) return false;
  const ya = a.r + (a.c % 2 ? 0.5 : 0);
  const yb = b.r + (b.c % 2 ? 0.5 : 0);
  return Math.abs(ya - yb) === 0.5;
}

function scoreWord(tiles) {
  const letters = tiles.reduce((a, t) => a + t.ch.length, 0);
  const base = tiles.reduce((a, t) => a + (VALUE[t.ch] || 1), 0);
  const mult = letters >= 10 ? 4 : LEN_MULT[letters] || 1;
  const gem = Math.min(3, tiles.reduce((a, t) => a + (GEM_BONUS[t.kind] || 0), 0));
  return Math.round(base * 10 * mult * (1 + gem));
}

// Guest map progress, kept until the page closes.
const GUEST_UNLOCKED = {};

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
  const [run, setRun] = useState(null); // { endless, level }
  const [board, setBoard] = useState(null);
  const [sel, setSel] = useState([]);
  const [score, setScore] = useState(0);
  const [words, setWords] = useState([]);
  const [turn, setTurn] = useState(0);
  const [battle, setBattle] = useState(null);
  const [hint, setHint] = useState(null); // tile ids
  const [hintsLeft, setHintsLeft] = useState(0);
  const [message, setMessage] = useState(null);
  const [result, setResult] = useState(null);
  const [guestTick, setGuestTick] = useState(0);
  const msgTimer = useRef(0);
  const boxRef = useRef(null);
  const [boxW, setBoxW] = useState(420);

  useEffect(() => { loadDictionary().then(setDict).catch(e => setDictError(e.message)); }, []);
  useEffect(() => () => clearTimeout(msgTimer.current), []);
  useEffect(() => {
    const el = boxRef.current; if (!el) return undefined;
    const measure = () => setBoxW(el.clientWidth || 420);
    measure();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : null;
    if (ro) ro.observe(el);
    return () => { if (ro) ro.disconnect(); };
  }, [screen]);

  const diff = DIFFICULTY[diffKey];
  const player = players.find(p => p.id === playerId) || null;
  const hero = heroes.find(h => h.key === heroKey) || heroes[0] || null;
  const unlocked = useMemo(() => {
    if (player) return Math.max(1, Number(player.bests?.unlocked?.[diffKey]) || 1);
    return GUEST_UNLOCKED[`${mode}:${diffKey}`] || 1;
  }, [player, diffKey, mode, guestTick]); // eslint-disable-line react-hooks/exhaustive-deps

  const choosePlayer = id => {
    setPlayerId(id);
    const kid = players.find(p => p.id === id);
    if (kid?.animal) setHeroKey(kid.animal);
    setDiffKey(diffForAge(kid ? kid.age : null));
  };

  const endlessLevel = useMemo(() => { let lv = 1; while (score >= endlessLevelAt(lv + 1)) lv += 1; return lv; }, [score]);
  const fireCfg = run && mode === "fire" ? (run.endless ? fireLevel(Math.min(LEVEL_COUNT, endlessLevel), diff) : fireLevel(run.level, diff)) : null;

  const selTiles = useMemo(() => {
    if (!board) return [];
    return sel.map(id => { const at = findTile(board, id); return at ? board[at.c][at.r] : null; }).filter(Boolean);
  }, [board, sel]);
  const word = selTiles.map(t => t.ch).join("").toLowerCase();
  const letterCount = word.length;
  const valid = !!dict && letterCount >= diff.minLen && dict.has(word);
  const preview = valid ? scoreWord(selTiles) : 0;

  const say = (text, tone = "info") => {
    clearTimeout(msgTimer.current);
    setMessage({ text, tone });
    msgTimer.current = setTimeout(() => setMessage(null), 2400);
  };

  const startRun = (endless, level = null) => {
    NEXT_ID = 1;
    const fl = mode === "fire" && !endless ? fireLevel(level, diff) : null;
    setBoard(newBoard(diff, fl ? fl.startFires : 0));
    setSel([]); setScore(0); setWords([]); setTurn(0); setResult(null); setMessage(null); setHint(null);
    setHintsLeft(diff.hints);
    setRun({ endless, level });
    if (mode === "monsters") {
      if (endless) {
        const m = endlessMonster(1, diff);
        setBattle({ foes: null, idx: 0, stage: 1, monster: m, mhp: m.hp, hp: ENDLESS_HERO_HP, hpMax: ENDLESS_HERO_HP, beaten: 0, hurt: null });
      } else {
        const keys = MONSTER_LEVELS[level - 1];
        const foes = keys.map((k, i) => scaleMonster(k, diff, { boss: isBossLevel(level) && i === keys.length - 1 }));
        const hpMax = heroHpForLevel(level);
        setBattle({ foes, idx: 0, stage: 1, monster: foes[0], mhp: foes[0].hp, hp: hpMax, hpMax, beaten: 0, hurt: null });
      }
    } else {
      setBattle(null);
    }
    setScreen("play");
  };

  // won: a map level was beaten. fight: monsters info for the result screen.
  const finishRun = useCallback(async ({ won, finalScore, finalWords, fight }) => {
    const best = [...finalWords].sort((a, b) => b.points - a.points)[0] || null;
    const level = run?.level || null;
    const nextOpen = won && level ? Math.min(LEVEL_COUNT, level + 1) : null;
    const summary = { won, endless: !!run?.endless, level, score: finalScore, count: finalWords.length, best, fight: fight || null, saved: null, isBest: false };
    setResult(summary);
    setScreen("over");
    if (!player) {
      if (nextOpen) {
        const k = `${mode}:${diffKey}`;
        GUEST_UNLOCKED[k] = Math.max(GUEST_UNLOCKED[k] || 1, nextOpen);
        setGuestTick(t => t + 1);
      }
      return;
    }
    const detail = {
      difficulty: diffKey, level, endless: !!run?.endless, won: !!won, words: finalWords.length,
      best_word: best?.word || null, best_word_points: best?.points || 0,
      ...(fight ? { beaten: fight.beaten, hero: hero?.key || null } : {}),
      ...(nextOpen ? { unlock_key: diffKey, unlock: nextOpen } : {}),
    };
    const r = await recordFamilyGame(player.id, gameKey, finalScore, detail);
    setResult({ ...summary, saved: r.saved, isBest: r.isBest, bestScore: r.bests?.best });
    reload();
  }, [run, player, mode, diffKey, gameKey, hero, reload]);

  const tap = (tile) => {
    if (!board) return;
    setHint(null);
    const idx = sel.indexOf(tile.id);
    if (idx >= 0) { setSel(sel.slice(0, idx)); return; } // tap a chosen letter: back up to before it
    const at = findTile(board, tile.id);
    const lastAt = sel.length ? findTile(board, sel[sel.length - 1]) : null;
    if (!lastAt || touching(lastAt, at)) setSel([...sel, tile.id]);
    else setSel([tile.id]); // not touching: start a new word here
  };

  // The monster's turn. bt is the fight as it stands after your word.
  const monsterHits = (bt, nextWords, newScore, label) => {
    const hit = ri(bt.monster.hit[0], bt.monster.hit[1]);
    const hp = bt.hp - hit;
    setBattle({ ...bt, hp: Math.max(0, hp), hurt: Date.now() });
    if (hp <= 0) {
      finishRun({ won: false, finalScore: newScore, finalWords: nextWords, fight: { beaten: bt.beaten, monster: bt.monster.name } });
      return;
    }
    say(`${label} · ${bt.monster.name} hits you for ${hit}`, "warn");
  };

  const submit = () => {
    if (!board || !valid) return;
    const points = preview;
    const used = new Set(sel);
    const putOut = selTiles.filter(t => t.kind === "fire").length;
    const gemKind = GEM_FOR_LEN(letterCount);
    const nextTurn = turn + 1;
    const fireOn = mode === "fire" && fireCfg;
    const fireChance = !fireOn ? 0 : letterCount <= 3 ? fireCfg.fire3 : letterCount === 4 ? fireCfg.fire4 : 0;
    const addFire = Math.random() < fireChance;

    // 1. Take out the spelled tiles and drop new ones in from the top.
    const b = cloneBoard(board).map(col => col.filter(t => !used.has(t.id)));
    const spawn = [];
    for (let c = 0; c < COLS; c++) {
      while (b[c].length < ROWS) { const t = newTile(b, diff); b[c].unshift(t); spawn.push(t); }
    }
    if (gemKind && spawn.length) pick(spawn).kind = gemKind;
    const plain = spawn.filter(t => t.kind === "normal");
    if (addFire && plain.length) pick(plain).kind = "fire";

    // 2. Fire mode: fires already on the board burn the tile under them and sink a row
    //    (every word, or every other word on Starter). Lowest fire first.
    let lost = false;
    if (fireOn && nextTurn % diff.burnEvery === 0) {
      for (let c = 0; c < COLS; c++) {
        const fires = b[c].filter(t => t.kind === "fire" && !t.fresh).map(t => t.id).reverse();
        for (const id of fires) {
          const r = b[c].findIndex(t => t.id === id);
          if (r === ROWS - 1) { lost = true; continue; }
          if (b[c][r + 1].kind === "fire") continue; // a fire never burns another fire
          b[c].splice(r + 1, 1);
          b[c].unshift(newTile(b, diff));
        }
      }
    }

    let newScore = score + points;
    const newWords = [{ word, points }, ...words];
    setBoard(b); setSel([]); setWords(newWords); setTurn(nextTurn); setHint(null);

    if (mode === "monsters" && battle) {
      const mhp = battle.mhp - points; // exact score as damage
      if (mhp <= 0) {
        const beaten = battle.beaten + 1;
        if (run.endless) {
          const bonus = 100 * battle.stage;
          newScore += bonus;
          const next = endlessMonster(battle.stage + 1, diff);
          setScore(newScore);
          setBattle({ ...battle, stage: battle.stage + 1, monster: next, mhp: next.hp, hp: Math.min(battle.hpMax, battle.hp + HEAL_ENDLESS), beaten, hurt: null });
          say(`${word.toUpperCase()} beat ${battle.monster.name}! +${bonus} · here comes ${next.name}`, "good");
          return;
        }
        const nextIdx = battle.idx + 1;
        if (nextIdx >= battle.foes.length) {
          setScore(newScore);
          finishRun({ won: true, finalScore: newScore, finalWords: newWords, fight: { beaten, monster: battle.monster.name } });
          return;
        }
        const next = battle.foes[nextIdx];
        setScore(newScore);
        setBattle({ ...battle, idx: nextIdx, monster: next, mhp: next.hp, hp: Math.min(battle.hpMax, battle.hp + HEAL_BETWEEN), beaten, hurt: null });
        say(`${word.toUpperCase()} beat ${battle.monster.name}! · here comes ${next.name}`, "good");
        return;
      }
      setScore(newScore);
      monsterHits({ ...battle, mhp }, newWords, newScore, `${word.toUpperCase()} hits for ${points}`);
      return;
    }

    setScore(newScore);
    if (lost) { finishRun({ won: false, finalScore: newScore, finalWords: newWords }); return; }
    if (!run.endless && newScore >= fireCfg.goal) { finishRun({ won: true, finalScore: newScore, finalWords: newWords }); return; }
    const bits = [`${word.toUpperCase()} +${points}`];
    if (putOut) bits.push("fire out!");
    if (gemKind) bits.push(`${gemKind} tile earned`);
    if (addFire) bits.push("a fire dropped in");
    say(bits.join(" · "), addFire ? "warn" : "good");
  };

  const scramble = () => {
    if (!board) return;
    const b = cloneBoard(board);
    for (const col of b) for (const t of col) if (t.kind === "normal") t.ch = randomLetter(b, diff);
    setSel([]); setHint(null);
    if (mode === "monsters" && battle) {
      setBoard(b);
      monsterHits(battle, words, score, "Shuffled"); // a shuffle costs a turn
      return;
    }
    const top = [];
    for (let c = 0; c < COLS; c++) if (b[c][0].kind === "normal") top.push(b[c][0]);
    if (top.length) { const t = pick(top); t.kind = "fire"; t.fresh = true; }
    setBoard(b);
    say("Shuffled · it cost a fire tile", "warn");
  };

  const askHint = async () => {
    if (!board || !dict || hintsLeft <= 0) return;
    let common = null;
    try { common = await loadList("common"); } catch { common = null; }
    const h = (common && findHint(board, common, diff.minLen)) || findHint(board, dict, diff.minLen);
    if (!h) { say("No word found · try Shuffle", "warn"); return; }
    setSel([]); setHint(h.ids);
    if (Number.isFinite(hintsLeft)) setHintsLeft(hintsLeft - 1);
  };

  // ── Screens ───────────────────────────────────────────────────────────
  const wrap = children => <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>{children}</div>;
  const title = (
    <div style={{ marginBottom: 12 }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>Spelling Quest</div>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        {mode === "monsters" ? "Spell words with touching letters to beat the monsters." : "Spell words with touching letters. Keep the fire off the bottom row."}
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
          <Chips value={mode} onChange={setMode} options={[["monsters", "Monsters", "Beat them with words"], ["fire", "Fire", "Keep fire off the bottom"]]} />
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
        <button type="button" onClick={() => setScreen("map")} disabled={!dict} style={{ ...btn(dict ? T.teal : T.slate300), padding: "14px 18px", fontSize: 18 }}>
          {dict ? "To the map" : "Loading words…"}
        </button>
      </div>
    </>);
  }

  if (screen === "map") {
    return wrap(<>
      {title}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 10 }}>
        <div style={{ fontSize: 14, color: T.slate700 }}>
          <b>{player ? player.name : "Guest"}</b> · {mode === "monsters" ? "Monsters" : "Fire"} · {diff.label}
        </div>
        <button type="button" onClick={() => setScreen("setup")} style={{ ...btn(T.slate400), padding: "6px 12px", fontSize: 13 }}>Change</button>
      </div>
      <QuestMap mode={mode} diff={diff} unlocked={unlocked} onPlay={n => startRun(false, n)} />
      <button type="button" onClick={() => startRun(true)} style={{ ...btn(T.purple), width: "100%", marginTop: 12, padding: "12px 16px" }}>
        Endless {mode === "monsters" ? "monsters" : "fire"} · play as long as you last
      </button>
      {player?.bests?.best != null ? (
        <div style={{ fontSize: 13, color: T.slate500, textAlign: "center", marginTop: 8 }}>{player.name}'s best: {Number(player.bests.best).toLocaleString()}</div>
      ) : null}
    </>);
  }

  if (screen === "over" && result) {
    const canNext = result.won && !result.endless && result.level < LEVEL_COUNT;
    const headline = result.endless
      ? (result.fight ? `${result.fight.monster} won this time` : "The fire reached the bottom")
      : result.won ? `Level ${result.level} cleared!` : `Level ${result.level} · not this time`;
    return wrap(<>
      {title}
      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 20, textAlign: "center", display: "grid", gap: 10 }}>
        <div style={{ fontSize: 18, fontWeight: 700, color: result.won ? T.green : T.slate700 }}>{headline}</div>
        <div style={{ fontSize: 44, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
        {result.isBest ? <div style={{ fontSize: 16, fontWeight: 700, color: T.gold }}>New best score!</div> : null}
        <div style={{ fontSize: 15, color: T.slate700 }}>
          {result.count} words{result.fight ? ` · beat ${result.fight.beaten} monster${result.fight.beaten === 1 ? "" : "s"}` : ""}
        </div>
        {result.best ? <div style={{ fontSize: 15, color: T.slate700 }}>Best word: <b>{result.best.word.toUpperCase()}</b> ({result.best.points.toLocaleString()} pts)</div> : null}
        {result.won && !result.endless && result.level === LEVEL_COUNT ? <div style={{ fontSize: 15, fontWeight: 700, color: T.gold }}>You finished the whole map!</div> : null}
        {player && result.saved === false ? <div style={{ fontSize: 13, color: T.red }}>Couldn't save this game.</div> : null}
        <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 6 }}>
          {canNext ? <button type="button" onClick={() => startRun(false, result.level + 1)} style={btn(T.teal)}>Next level</button> : null}
          <button type="button" onClick={() => startRun(result.endless, result.level)} style={btn(canNext ? T.slate600 : T.teal)}>Play again</button>
          <button type="button" onClick={() => setScreen("map")} style={btn(T.slate600)}>Map</button>
        </div>
      </div>
    </>);
  }

  if (!board || !run) return null;
  const S = Math.max(40, Math.min(64, Math.floor(boxW / (COLS + 0.15))));
  const boardW = S * COLS;
  const boardH = S * (ROWS + 0.5);
  const where = run.endless ? "Endless" : `Level ${run.level}`;
  const progress = mode === "monsters"
    ? (run.endless ? `${where} · monster ${battle?.stage}` : `${where} · monster ${(battle?.idx || 0) + 1} of ${battle?.foes?.length}`)
    : (run.endless ? `${where} · level ${endlessLevel}` : `${where} · goal ${fireCfg.goal.toLocaleString()}`);

  return wrap(<>
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", flexWrap: "wrap", gap: 8, marginBottom: 8 }}>
      <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>{score.toLocaleString()} pts</div>
      <div style={{ fontSize: 13, color: T.slate600 }}>{progress}</div>
    </div>
    {mode === "fire" && !run.endless ? <Bar value={score} max={fireCfg.goal} color={T.amber} label="Goal" /> : null}
    {battle ? <BattleBar battle={battle} hero={hero} /> : null}

    <div style={{
      display: "flex", alignItems: "center", gap: 8, padding: "8px 10px", margin: "10px 0", borderRadius: 12, minHeight: 52,
      background: T.white, border: `2px solid ${valid ? T.green : T.slate200}`, flexWrap: "wrap",
    }}>
      <div style={{ flex: "1 1 160px", fontSize: 24, fontWeight: 800, letterSpacing: 2, color: valid ? T.slate900 : T.slate500, minWidth: 0, overflowWrap: "anywhere" }}>
        {word ? word.toUpperCase() : <span style={{ fontSize: 14, fontWeight: 500, letterSpacing: 0, color: T.slate400 }}>Tap touching letters{diff.minLen > 3 ? ` · ${diff.minLen}+ letters` : ""}</span>}
      </div>
      {valid ? <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>+{preview}{battle ? " damage" : ""}</div> : null}
      <button type="button" onClick={() => setSel([])} disabled={!sel.length} style={{ ...btn(T.slate400), padding: "8px 12px", opacity: sel.length ? 1 : 0.5 }}>Clear</button>
      <button type="button" onClick={submit} disabled={!valid} style={{ ...btn(T.teal), opacity: valid ? 1 : 0.4 }}>Go</button>
    </div>

    <div ref={boxRef} style={{ width: "100%" }}>
      <div style={{ position: "relative", width: boardW, height: boardH, margin: "0 auto", userSelect: "none", touchAction: "manipulation" }}>
        <style>{"@keyframes wwDrop{from{transform:translateY(-14px);opacity:0}to{transform:none;opacity:1}}@keyframes wwFlicker{from{filter:brightness(1)}to{filter:brightness(1.18)}}@keyframes wwHint{from{box-shadow:0 0 0 2px #F59E0B}to{box-shadow:0 0 0 5px #F59E0B}}"}</style>
        {board.map((col, c) => col.map((t, r) => (
          <Tile key={t.id} tile={t} size={S} left={c * S} top={(r + (c % 2 ? 0.5 : 0)) * S}
            order={sel.indexOf(t.id)} hinted={!!hint && hint.includes(t.id)} danger={t.kind === "fire" && r >= ROWS - 2} onTap={() => tap(t)} />
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
        <button type="button" onClick={askHint} disabled={hintsLeft <= 0} style={{ ...btn(T.blue), padding: "8px 14px", fontSize: 14, opacity: hintsLeft > 0 ? 1 : 0.4 }}>
          Hint{Number.isFinite(hintsLeft) ? ` (${hintsLeft})` : ""}
        </button>
      ) : null}
      <button type="button" onClick={scramble} style={{ ...btn(T.amber), padding: "8px 14px", fontSize: 14 }}>{battle ? "Shuffle (monster gets a turn)" : "Shuffle (adds fire)"}</button>
      <button type="button" onClick={() => setScreen("map")} style={{ ...btn(T.slate400), padding: "8px 14px", fontSize: 14 }}>Quit</button>
    </div>

    {words.length ? (
      <div style={{ marginTop: 14, fontSize: 13, color: T.slate600, textAlign: "center" }}>
        {words.slice(0, 6).map((w, i) => <span key={i} style={{ display: "inline-block", margin: "2px 6px" }}><b>{w.word.toUpperCase()}</b> {w.points}</span>)}
      </div>
    ) : null}
  </>);
}

function btn(bg) {
  return { padding: "10px 18px", borderRadius: 10, border: "none", background: bg, color: T.white, fontSize: 15, fontWeight: 700, cursor: "pointer", fontFamily: "inherit" };
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

// The level map: three areas of four levels, a winding trail of stops.
function QuestMap({ mode, diff, unlocked, onPlay }) {
  return (
    <div style={{ display: "grid", gap: 10 }}>
      {AREAS.map((area, ai) => (
        <div key={area} style={{ borderRadius: 14, padding: "10px 12px", background: [T.goldLt, T.greenLt, T.purpleLt][ai], border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate800, marginBottom: 8 }}>{area}</div>
          <div style={{ position: "relative", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <div style={{ position: "absolute", left: "8%", right: "8%", top: "50%", borderTop: `3px dashed ${T.slate400}`, opacity: 0.5 }} />
            {[1, 2, 3, 4].map(i => {
              const n = ai * 4 + i;
              const open = n <= unlocked;
              const done = n < unlocked;
              const boss = isBossLevel(n);
              const sub = mode === "monsters"
                ? MONSTER_LEVELS[n - 1].map(k => MONSTERS[k].name).join(" + ")
                : `${fireLevel(n, diff).goal.toLocaleString()} pts`;
              return (
                <button key={n} type="button" disabled={!open} onClick={() => onPlay(n)} title={sub} style={{
                  position: "relative", zIndex: 1, width: 70, display: "grid", justifyItems: "center", gap: 2,
                  background: "none", border: "none", padding: 0, cursor: open ? "pointer" : "default", fontFamily: "inherit",
                }}>
                  <div style={{
                    width: boss ? 58 : 50, height: boss ? 58 : 50, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center",
                    background: !open ? T.slate300 : done ? T.green : T.white, border: `3px solid ${!open ? T.slate400 : boss ? T.red : T.teal}`,
                    boxShadow: open && !done ? `0 0 0 4px ${T.tealLt}` : "none",
                  }}>
                    {mode === "monsters" && open
                      ? <Monster m={MONSTERS[MONSTER_LEVELS[n - 1][MONSTER_LEVELS[n - 1].length - 1]]} size={boss ? 44 : 38} />
                      : <span style={{ fontSize: 18, fontWeight: 800, color: !open ? T.slate500 : done ? T.white : T.slate800 }}>{open ? n : "🔒"}</span>}
                  </div>
                  <div style={{ fontSize: 11, fontWeight: 600, color: T.slate700, textAlign: "center", lineHeight: 1.2 }}>
                    {done ? "✓ " : ""}{boss ? "Boss" : `Level ${n}`}
                  </div>
                </button>
              );
            })}
          </div>
        </div>
      ))}
    </div>
  );
}

function Tile({ tile, size, left, top, order, hinted, danger, onTap }) {
  const chosen = order >= 0;
  const gem = GEM_LOOK[tile.kind];
  const fire = tile.kind === "fire";
  const bg = chosen ? T.blue : fire ? "linear-gradient(170deg,#FFD27A 0%,#FF7A2F 45%,#D7261E 100%)" : gem ? gem.bg : "linear-gradient(170deg,#FFF9EC,#EADFC4)";
  const ink = chosen ? T.white : fire ? "#fff" : gem ? gem.ink : T.slate900;
  const border = chosen ? T.chromeBgDeep : fire ? "#9E1B14" : gem ? gem.border : "#C9BB98";
  const value = VALUE[tile.ch] || 1;
  return (
    <button
      type="button"
      onClick={onTap}
      aria-label={`${tile.ch}${fire ? " fire" : gem ? ` ${tile.kind}` : ""}`}
      style={{
        position: "absolute", left: left + 2, top: top + 2, width: size - 4, height: size - 4, padding: 0, cursor: "pointer",
        borderRadius: Math.round(size * 0.18), border: `2px solid ${border}`, background: bg, color: ink,
        boxShadow: danger ? "0 0 0 3px rgba(239,68,68,0.55)" : "0 2px 0 rgba(0,0,0,0.12)",
        transition: "top 0.25s ease-out, background 0.15s", fontFamily: "Georgia, 'Times New Roman', serif",
        animation: hinted ? "wwHint 0.6s ease-in-out infinite alternate" : tile.fresh ? "wwDrop 0.3s ease-out" : fire ? "wwFlicker 0.9s ease-in-out infinite alternate" : "none",
      }}
    >
      <span style={{ fontSize: Math.round(size * (tile.ch.length > 1 ? 0.4 : 0.5)), fontWeight: 700, lineHeight: 1 }}>
        {tile.ch === "QU" ? "Qu" : tile.ch}
      </span>
      <span style={{ position: "absolute", right: 4, bottom: 2, fontSize: Math.max(9, Math.round(size * 0.18)), fontFamily: "inherit", opacity: 0.7 }}>
        {Math.round(value * 10)}
      </span>
      {chosen ? <span style={{ position: "absolute", left: 4, top: 2, fontSize: Math.max(9, Math.round(size * 0.2)), fontWeight: 700, opacity: 0.85 }}>{order + 1}</span> : null}
    </button>
  );
}

function Bar({ value, max, color, label }) {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, fontWeight: 600, color: T.slate700, marginBottom: 2 }}>
        <span>{label}</span><span>{Math.max(0, value).toLocaleString()} / {max.toLocaleString()}</span>
      </div>
      <div style={{ height: 10, borderRadius: 6, background: T.slate200, overflow: "hidden" }}>
        <div style={{ width: `${pct}%`, height: "100%", background: color, transition: "width 0.35s" }} />
      </div>
    </div>
  );
}

function BattleBar({ battle, hero }) {
  const m = battle.monster;
  return (
    <div style={{ display: "flex", gap: 10, alignItems: "center", padding: 10, marginTop: 8, borderRadius: 12, background: T.white, border: `1px solid ${T.slate200}` }}>
      <DoneDancerStyles />
      <style>{"@keyframes wwHit{0%{transform:translateX(0)}25%{transform:translateX(-6px)}50%{transform:translateX(6px)}75%{transform:translateX(-3px)}100%{transform:none}}"}</style>
      {hero ? (
        <div key={`h-${battle.hurt || 0}`} style={{ flexShrink: 0, animation: battle.hurt ? "wwHit 0.35s" : "none" }}>
          <span className="nw-bop" style={{ display: "inline-block", lineHeight: 0 }}><CritterIcon which={hero.key} size={60} /></span>
        </div>
      ) : null}
      <div style={{ flex: 1, minWidth: 0, display: "grid", gap: 8 }}>
        <Bar value={battle.mhp} max={m.hp} color={T.red} label={m.boss ? `${m.name} (boss)` : m.name} />
        <Bar value={battle.hp} max={battle.hpMax} color={T.green} label={hero ? `You · ${hero.label}` : "You"} />
      </div>
      <div key={`${m.name}-${battle.mhp}`} style={{ flexShrink: 0, animation: battle.mhp < m.hp ? "wwHit 0.35s" : "none" }}>
        <Monster m={m} size={m.boss ? 72 : 60} />
      </div>
    </div>
  );
}

// Original monsters: one body with a few add-ons, colored per monster.
function Monster({ m, size }) {
  const c = m.body;
  return (
    <svg viewBox="0 0 100 100" width={size} height={size} aria-label={m.name}>
      {m.look === "wings" || m.look === "dragon" ? (
        <g fill={c} opacity="0.75" stroke="#2D2F26" strokeWidth="2"><path d="M28 50 L4 26 L10 58 Z" /><path d="M72 50 L96 26 L90 58 Z" /></g>
      ) : null}
      {m.look === "ears" ? (
        <g fill={c} stroke="#2D2F26" strokeWidth="2"><ellipse cx="34" cy="20" rx="8" ry="16" /><ellipse cx="66" cy="20" rx="8" ry="16" /></g>
      ) : null}
      {m.look === "horns" || m.look === "dragon" ? (
        <g fill="#F2E8D5" stroke="#2D2F26" strokeWidth="2"><path d="M32 30 L26 8 L42 26 Z" /><path d="M68 30 L74 8 L58 26 Z" /></g>
      ) : null}
      {m.look === "blob" ? (
        <path d="M14 78 C10 50 26 26 50 26 C74 26 92 48 86 78 C80 92 20 92 14 78 Z" fill={c} stroke="#2D2F26" strokeWidth="2.5" />
      ) : (
        <ellipse cx="50" cy="60" rx="32" ry="30" fill={c} stroke="#2D2F26" strokeWidth="2.5" />
      )}
      {m.look === "hat" ? <path d="M24 38 L50 2 L76 38 Z" fill="#B8483A" stroke="#2D2F26" strokeWidth="2" /> : null}
      <circle cx="38" cy="56" r="8" fill="#fff" stroke="#2D2F26" strokeWidth="1.5" />
      <circle cx="62" cy="56" r="8" fill="#fff" stroke="#2D2F26" strokeWidth="1.5" />
      <circle cx="40" cy="58" r="3.5" fill="#2D2F26" />
      <circle cx="60" cy="58" r="3.5" fill="#2D2F26" />
      <path d="M30 46 L44 50 M70 46 L56 50" stroke="#2D2F26" strokeWidth="3" strokeLinecap="round" />
      <path d="M38 76 Q50 68 62 76" fill="none" stroke="#2D2F26" strokeWidth="3" strokeLinecap="round" />
      {m.look === "dragon" ? <path d="M42 77 L45 82 L48 77 M52 77 L55 82 L58 77" fill="#fff" stroke="#2D2F26" strokeWidth="1" /> : null}
    </svg>
  );
}
