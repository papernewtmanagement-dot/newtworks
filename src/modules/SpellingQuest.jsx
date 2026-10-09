import { useEffect, useMemo, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";
import { useDancers, CritterIcon } from "../components/Critters.jsx";
import QuestMonster from "../components/QuestMonster.jsx";
import QuestScene from "../components/QuestScene.jsx";
import {
  WORLDS, MONSTERS as QUEST_MONSTERS, LEVELS_PER_WORLD, MONSTERS_PER_LEVEL, LEVEL_TOTAL, worldOf, stepOf, levelInfo, levelName,
  monstersForLevel, heroHpForLevel, endlessMonster, endlessWorld, ENDLESS_HERO_HP, heroAttackForLevel, ENDLESS_HERO_ATK, starsFor,
  POTIONS, POTION_KEYS, POTION_MAX, TREASURES, EQUIP_MAX, treasuresOwned, treasureLevel, STORY_PARTS,
} from "../lib/questWorlds.js";
import { levelStory } from "../lib/questStories.js";
import { SOUND, setMuted, tone, noise, notes, playSound, speak, stopSpeaking, gameBtn as btn, ReadAloud, useFullscreen } from "../lib/gameKit.jsx";

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
// Long words leave gem tiles, as in Bookworm Adventures: every gem adds damage (amethyst
// +15% up to diamond +100%) and has its own effect: amethyst poisons the monster, emerald
// heals you, sapphire freezes it, garnet weakens it, ruby sets it on fire, crystal cleans you
// and the board and shields you, diamond heals you fully and gives one of each potion. Monsters
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
// Gems hold off fire, like Bookworm: a fire has to burn this many times to get through one.
const GEM_TOUGH = { green: 2, gold: 3, diamond: 4 };

// Bonus word (Fire): one word to find; spelling it pays ×3, the next bonus word ×4, and so on.
const BONUS_LEN = { starter: [3, 4], easy: [4, 5], medium: [4, 6], hard: [5, 6] };
const BONUS_POOL = {};
function pickBonusWord(common, dict, diffKey, skip) {
  const [lo, hi] = BONUS_LEN[diffKey] || [4, 5];
  const key = `${diffKey}`;
  if (!BONUS_POOL[key]) BONUS_POOL[key] = [...common].filter(w => w.length >= lo && w.length <= hi && /^[a-pr-z]+$/.test(w) && dict.has(w));
  const pool = BONUS_POOL[key].filter(w => w !== skip);
  return pool.length ? pool[Math.floor(Math.random() * pool.length)] : null;
}
// New letters lean toward the bonus word's missing letters, so it can actually be spelled.
function seedBonus(board, tiles, word, chance) {
  if (!word) return;
  const have = {};
  for (const col of board) for (const t of col) if (t.kind !== "fire") have[t.ch] = (have[t.ch] || 0) + 1;
  const missing = [];
  for (const ch of word.toUpperCase()) { if (have[ch] > 0) have[ch] -= 1; else missing.push(ch); }
  for (const t of tiles) {
    if (!missing.length) return;
    if (t.kind !== "normal" || Math.random() >= chance) continue;
    t.ch = missing.splice(Math.floor(Math.random() * missing.length), 1)[0];
  }
}

// Word books (Fire), like Bookworm's books: spell any word in a book to open it; the book then
// lists its other words. Found words stay found from game to game; 10 finds a book.
const BOOK_GOAL = 10;
const BOOK_DONE_POINTS = 1000;
const WORD_BOOKS = [
  { key: "animals", name: "Animals", icon: "🐾", words: "cat dog pig cow hen fox owl bat ant bee bear deer frog goat lion wolf".split(" ") },
  { key: "food",    name: "Food",    icon: "🍎", words: "egg ham pie jam bun tea rice bean corn cake meat soup pear plum nut pea".split(" ") },
  { key: "body",    name: "Body",    icon: "🖐️", words: "arm leg ear eye toe lip hip jaw rib hand foot nose knee chin neck hair".split(" ") },
  { key: "colors",  name: "Colors",  icon: "🎨", words: "red tan blue pink gold gray teal rose rust navy jade ruby sand mint plum lime".split(" ") },
  { key: "weather", name: "Weather", icon: "⛅", words: "sun fog ice wet hot dry rain snow wind hail mist cold warm heat gust storm".split(" ") },
  { key: "home",    name: "Home",    icon: "🏠", words: "bed mat cup pan pot rug mop lamp sofa sink door wall desk fork bowl dish".split(" ") },
  { key: "sea",     name: "Sea",     icon: "🌊", words: "sea eel ray cod ship boat wave reef tide clam kelp gull shell salt dock fish".split(" ") },
  { key: "play",    name: "Play",    icon: "🪁", words: "toy ball kite game doll bike swim run hop top card drum slide swing tag jump".split(" ") },
];
// Book words this word fills that weren't found before (saved finds plus this game's).
function newBookFinds(word, found) {
  return WORD_BOOKS.filter(bk => bk.words.includes(word) && !(found[bk.key] || []).includes(word)).map(bk => bk.key);
}
// Monsters mode gems (like Bookworm Adventures): which one a long word leaves.
function monsterGem(len, fiveToo) {
  if (len >= 10) return "diamond";
  if (len === 9) return "crystal";
  if (len === 8) return "ruby";
  if (len === 7) return Math.random() < 0.5 ? "garnet" : "sapphire";
  if (len === 6 || (len === 5 && fiveToo)) return Math.random() < 0.55 ? "emerald" : "amethyst";
  return null;
}
// Overkill (hitting for more than the monster had left) earns a gem too, as in the original.
function overkillGem(hearts) {
  if (hearts >= 8) return "diamond";
  if (hearts >= 5) return "crystal";
  if (hearts >= 3) return "ruby";
  if (hearts >= 1.5) return Math.random() < 0.5 ? "garnet" : "sapphire";
  if (hearts >= 0.5) return Math.random() < 0.55 ? "emerald" : "amethyst";
  return null;
}
// Monsters mode damage is Bookworm Adventures' own: harder letters count as more than one letter
// (B C F H M P 1.25, V W Y 1.5, J K 1.75, X Z 2, Qu 2.75), and that length sets the hearts:
// 3 letters 1/2 heart, 4 = 3/4, 5 = 1, 6 = 1 1/2, 7 = 2, 8 = 2 3/4, 9 = 3 1/2 ... 16 = 13 hearts.
// 100 points to a heart, so the damage shown is still the word's score.
const LETTER_WEIGHT = { B: 1.25, C: 1.25, F: 1.25, H: 1.25, M: 1.25, P: 1.25, V: 1.5, W: 1.5, Y: 1.5, J: 1.75, K: 1.75, X: 2, Z: 2, QU: 2.75 };
const DAMAGE_HEARTS = [0, 0, 0, 0.5, 0.75, 1, 1.5, 2, 2.75, 3.5, 4.5, 5.5, 6.75, 8, 9.5, 11, 13];
function wordDamage(tiles) {
  const len = tiles.reduce((a, t) => a + (LETTER_WEIGHT[t.ch] || 1), 0);
  if (len >= 16) return Math.round(100 * (13 + (len - 16) * 2));
  const lo = Math.floor(len);
  return Math.round(100 * (DAMAGE_HEARTS[lo] + (DAMAGE_HEARTS[lo + 1] - DAMAGE_HEARTS[lo]) * (len - lo)));
}
// Extra damage each gem in the word adds (Bookworm Adventures' values).
const GEM_BONUS = { amethyst: 15, emerald: 20, sapphire: 25, garnet: 30, ruby: 35, crystal: 50, diamond: 100 };
// Gem effects on the monster: poison and fire hurt it each time you attack.
const MON_POISON = { turns: 2, share: 0.05 };
const MON_BURN = { turns: 3, share: 0.07 };
// Cut-gem colors: hi = top/table glint, mid = left facet, base = body, lo = right facet, deep = bottom facet.
const GEM_LOOK = {
  green:    { hi: "#D9FBE3", mid: "#6FDB93", base: "#34B464", lo: "#1E8A49", deep: "#11602F", border: "#0D4A24" },
  emerald:  { hi: "#D9FBE3", mid: "#6FDB93", base: "#34B464", lo: "#1E8A49", deep: "#11602F", border: "#0D4A24" },
  gold:     { hi: "#FFF6CF", mid: "#FFD866", base: "#F0B429", lo: "#C98A10", deep: "#8F5E05", border: "#6E4700" },
  diamond:  { hi: "#FFFFFF", mid: "#E4F6FF", base: "#B8E3F7", lo: "#8CC6E8", deep: "#6AA6D1", border: "#3F7FAE", rainbow: true },
  ruby:     { hi: "#FFD6D6", mid: "#FF6B6B", base: "#E0201A", lo: "#A8130E", deep: "#6E0905", border: "#560603" },
  sapphire: { hi: "#DCE9FF", mid: "#6FA0FF", base: "#2A62D9", lo: "#1A44A6", deep: "#0E2A6E", border: "#0A1F55" },
  amethyst: { hi: "#F1E2FF", mid: "#C08AF0", base: "#9255C9", lo: "#6A3699", deep: "#45206A", border: "#341650" },
  garnet:   { hi: "#FFE3C9", mid: "#FFA05C", base: "#E8651E", lo: "#B04712", deep: "#742C08", border: "#5A2105" },
  crystal:  { hi: "#FFF0F8", mid: "#FFC2E2", base: "#F48FC6", lo: "#D267A3", deep: "#A84680", border: "#8A3468" },
};
const GEM_KEY = "Gems add damage. Amethyst poisons · emerald heals · sapphire freezes · garnet weakens · ruby burns · crystal cleans and shields · diamond heals fully + potions";

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

// ── Sounds: tiny made-up beeps, no files (building blocks in gameKit). Off when muted.
const SFX = {
  // tapping letters: each letter a step higher, like Bookworm's rising chime
  tap: (ctx, t, n = 1) => tone(ctx, "triangle", 330 * 2 ** ((Math.min(n, 14) - 1) * 2 / 12), 330 * 2 ** ((Math.min(n, 14) - 1) * 2 / 12), t, 0.08, 0.07),
  valid: (ctx, t, n = 3) => { const f = 660 * 2 ** ((Math.min(n, 12) - 3) * 2 / 12); notes(ctx, t, [f, f * 1.5], "sine", 0.05, 0.05); },
  whoosh: (ctx, t) => noise(ctx, t, 0.32, 500, 3500, 0.12),
  hit: (ctx, t, tier = 0) => {
    noise(ctx, t, 0.18, 1800, 250, 0.3);
    tone(ctx, "sine", 170, 45, t, 0.3, 0.3);
    if (tier >= 6) { tone(ctx, "square", 110, 40, t + 0.03, 0.25, 0.08); noise(ctx, t + 0.05, 0.3, 900, 120, 0.2); }
    if (tier >= 8) { tone(ctx, "sawtooth", 80, 30, t + 0.08, 0.45, 0.1); noise(ctx, t + 0.1, 0.5, 3000, 200, 0.18); }
  },
  growl: (ctx, t) => { tone(ctx, "sawtooth", 120, 70, t, 0.45, 0.07); tone(ctx, "sawtooth", 127, 74, t, 0.45, 0.05); noise(ctx, t, 0.35, 300, 150, 0.08); },
  hurt: (ctx, t) => { noise(ctx, t, 0.15, 900, 200, 0.22); tone(ctx, "sawtooth", 220, 110, t, 0.2, 0.08); },
  status: (ctx, t) => { tone(ctx, "square", 300, 240, t, 0.14, 0.06); tone(ctx, "square", 250, 180, t + 0.12, 0.18, 0.06); },
  ko: (ctx, t) => { tone(ctx, "square", 700, 70, t, 0.55, 0.07); noise(ctx, t + 0.45, 0.2, 2000, 400, 0.15); },
  heal: (ctx, t) => notes(ctx, t, [660, 880, 1100, 1320], "sine", 0.07, 0.06),
  gem: (ctx, t) => notes(ctx, t, [1320, 1760, 2093], "triangle", 0.06, 0.05),
  freeze: (ctx, t) => { tone(ctx, "sine", 1500, 2600, t, 0.4, 0.05); tone(ctx, "sine", 2000, 3200, t + 0.1, 0.35, 0.04); },
  potion: (ctx, t) => { tone(ctx, "sine", 400, 900, t, 0.18, 0.07); notes(ctx, t + 0.15, [880, 1175], "sine", 0.08, 0.05); },
  // praise fanfare: more notes for bigger words
  fanfare: (ctx, t, tier = 5) => notes(ctx, t, [523, 659, 784, 1047, 1319, 1568, 2093].slice(0, Math.max(2, tier - 2)), "square", 0.08, 0.045),
  win: (ctx, t) => notes(ctx, t, [523, 659, 784, 1047, 784, 1047], "triangle", 0.12, 0.08),
  lose: (ctx, t) => { tone(ctx, "sine", 392, 330, t, 0.2, 0.08); tone(ctx, "sine", 294, 196, t + 0.2, 0.4, 0.08); },
};
const sound = (name, arg) => playSound(SFX, name, arg);

// Praise for a word, like Bookworm's announcer: longer words (and gem words) get bigger praise.
const PRAISE = ["", "", "", "", "Good!", "Great!", "Awesome!", "Fantastic!", "Amazing!", "Incredible!", "Spectacular!"];
const praiseTier = (letters, gemmed) => Math.min(PRAISE.length - 1, letters + (gemmed ? 1 : 0));
const PRAISE_COLOR = ["", "", "", "", "#2E8B57", "#3F8DB8", "#8E5CB8", "#D2553E", "#D7261E", "#E2B13C", "#E2B13C"];
// Big praise is said out loud too (5+ letters), quick and cheerful.
function announce(text) {
  if (SOUND.muted || !text) return;
  speak(text.replace("!", ""), () => {}, () => {}, { rate: 1.05, pitch: 1.3 });
}

// ── Difficulty ──────────────────────────────────────────────────────────
//   hardLetters  weight of K J X Qu Z V (0 = never); vowels: share kept between
//   minLen       shortest word that counts
//   monsterHp / monsterHit   multiply monster health and hits
//   fire         multiply the chance a fire drops in; burnEvery: fire burns every Nth word
//   goal         multiply the score a Fire level asks for; hints per level
const DIFFICULTY = {
  starter: { label: "Starter", ages: "5–7",   hardLetters: 0,   vowels: [0.38, 0.55], minLen: 3, monsterHp: 0.25, monsterHit: 1,    fire: 0.5,  burnEvery: 2, goal: 0.6, hints: Infinity },
  easy:    { label: "Easy",    ages: "8–10",  hardLetters: 0.5, vowels: [0.33, 0.5],  minLen: 3, monsterHp: 0.8,  monsterHit: 0.8,  fire: 0.75, burnEvery: 1, goal: 0.8, hints: 3 },
  medium:  { label: "Medium",  ages: "11–13", hardLetters: 1,   vowels: [0.3, 0.5],   minLen: 3, monsterHp: 1,    monsterHit: 1.05, fire: 1,    burnEvery: 1, goal: 1,   hints: 1 },
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
const GUEST = { unlocked: {}, items: { heal: 1, power: 1, freeze: 0, cure: 0 }, stars: {}, equip: [], treasure_xp: {}, books: {} };

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
  const [muted, setMutedState] = useState(SOUND.muted);
  const fs = useFullscreen();
  const [bonus, setBonus] = useState(null);     // Fire: { word, n } the bonus word to find and how many found this game
  const [runBooks, setRunBooks] = useState({}); // Fire: book words found this game, { bookKey: [words] }
  const runBooksRef = useRef({});
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

  const savedBooks = player ? (player.bests?.books || {}) : GUEST.books;
  const foundBooks = useMemo(() => {
    const out = {};
    for (const bk of WORD_BOOKS) out[bk.key] = [...new Set([...(savedBooks[bk.key] || []), ...(runBooks[bk.key] || [])])];
    return out;
  }, [savedBooks, runBooks]);
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
    setMuted(m); setMutedState(m);
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
  const base = valid ? (mode === "monsters" ? wordDamage(selTiles) : basePoints(selTiles)) : 0;
  const gems = selTiles.reduce((a, t) => ({ ...a, [t.kind]: (a[t.kind] || 0) + 1 }), {});
  const bonusHit = mode === "fire" && valid && !!bonus && word === bonus.word;
  const bookHits = mode === "fire" && valid ? newBookFinds(word, foundBooks) : [];
  const firePoints = Math.round(base * (1 + Math.min(3, selTiles.reduce((a, t) => a + (FIRE_GEM_BONUS[t.kind] || 0), 0)))
    * (bonusHit ? 3 + bonus.n : 1) * (bookHits.length ? 2 : 1));
  const gemBonus = Object.entries(gems).reduce((a, [k, n]) => a + (GEM_BONUS[k] || 0) * n, 0) / 100;
  const hitPoints = Math.round(base * (fight?.atk || 1) * (1 + gemBonus) * (fight?.power ? 2 : 1) * (fight?.weak > 0 ? 0.5 : 1)
    * treasureBoost(fight?.eq, selTiles, word.length));
  const preview = mode === "monsters" ? hitPoints : firePoints;
  const gemmed = selTiles.some(t => t.kind !== "normal" && t.kind !== "fire");
  const tier = valid ? praiseTier(selTiles.reduce((a, t) => a + t.ch.length, 0), gemmed) : 0;
  useEffect(() => { if (valid) sound("valid", word.length); }, [valid, word]); // eslint-disable-line react-hooks/exhaustive-deps

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
  const play = (heroMove, monMove) => setFx(f => ({ key: f.key + 1, hero: heroMove, mon: monMove, fly: null, praise: null }));

  // Pick the next bonus word and nudge the board toward its letters.
  const newBonusWord = (n, skip, fresh) => {
    loadList("common").then(common => {
      const w = dict ? pickBonusWord(common, dict, diffKey, skip) : null;
      if (!w) return;
      setBonus({ word: w, n });
      if (!fresh) return; // mid-game, only new letters lean toward it (see submitFire)
      setBoard(b => {
        if (!b) return b;
        const nb = cloneBoard(b);
        seedBonus(nb, nb.flat().sort(() => Math.random() - 0.5), w, fresh ? 0.5 : 0.25);
        return nb;
      });
    }).catch(() => {});
  };

  const startRun = (endless, level = null) => {
    stopTimers();
    NEXT_ID = 1;
    if (mode === "monsters") {
      setBoard(newBoard(diff, 4, 4));
      const eq = worn.map(i => owned[i]);
      const status = { freeze: 0, poison: 0, weak: 0, shield: 0, mpoison: 0, mburn: 0, mweak: 0, power: eqCount(eq, "rally") > 0, turns: 0, eq,
        atk: endless ? ENDLESS_HERO_ATK : heroAttackForLevel(level) };
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
      runBooksRef.current = {}; setRunBooks({}); setBonus(null);
      newBonusWord(0, null, true);
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
      if (mode === "fire") for (const [k, list] of Object.entries(runBooksRef.current)) GUEST.books[k] = [...new Set([...(GUEST.books[k] || []), ...list])];
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
      ...(mode === "fire" && Object.keys(runBooksRef.current).length ? { books_add: runBooksRef.current } : {}),
    };
    const r = await recordFamilyGame(player.id, gameKey, finalScore, detail);
    setResult({ ...summary, saved: r.saved, isBest: r.isBest });
    reload();
  };

  // Map level picked: a world's first level opens with its story page the first time.
  const playLevel = n => {
    // Every new level opens with its story beat (a world's first level adds the world's intro).
    if (mode === "monsters" && n >= unlocked) { setStory({ world: worldOf(n), kind: "level", level: n }); setScreen("story"); return; }
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
    const idx = sel.indexOf(tile.id);
    sound("tap", idx >= 0 ? Math.max(1, idx) : sel.length + 1);
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
    const shieldLeft = !frozen && f.shield > 0 ? f.shield - 1 : f.shield;
    const mweakLeft = !frozen && f.mweak > 0 ? f.mweak - 1 : f.mweak;
    if (!frozen) {
      hit = Math.max(1, ri(m.hit[0], m.hit[1]) - eqSum(eq, "shield"));
      if (f.mweak > 0) { hit = Math.max(1, Math.round(hit / 2)); notes.push("garnet weakened its hit"); }
      if (f.shield > 0) { hit = 0; notes.push("your crystal shield blocked it"); }
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
    const next = { ...f, hp, mhp, turns, poison, weak, shield: shieldLeft, mweak: mweakLeft, freeze: frozen ? f.freeze - 1 : f.freeze };
    if (!frozen) later(() => { play(null, "lunge"); sound("growl"); }, delay);
    later(() => {
      if (total) { play("hurt", null); floatUp("hero", `-${total}`, "#D7261E"); sound(notes.length && !mends ? "status" : "hurt"); }
      if (mends) floatUp("mon", `+${mends}`, "#2E8B57");
      setFight(next);
      setBoard(b2);
      if (hp <= 0) {
        later(() => finishRun({ won: false, finalScore: newScore, finalWords: newWords, fightInfo: { beaten: f.beaten, monster: m.name }, items }), 900);
        return;
      }
      say(`${frozen ? `${m.name} is frozen solid!` : hit ? `${m.name} hits you for ${hit}` : `${m.name} can't hurt you`}${notes.length ? ` · ${notes.join(" · ")}` : ""}`, frozen && !total ? "good" : "warn");
      setBusy(false);
    }, frozen ? delay : delay + 260);
  };

  const submitMonsters = () => {
    const f = fight;
    const dmg = hitPoints;
    const eq = f.eq || [];
    const regen = eqSum(eq, "regen");
    // Gem effects (Bookworm Adventures): emerald heals a big chunk, diamond heals fully.
    const heal = gems.diamond ? f.hpMax : 200 * (gems.emerald || 0) + regen; // emerald: 2 hearts, as in the original
    const cured = (gems.crystal || 0) > 0;
    const freezeAdd = gems.sapphire || 0;
    const mpoison = gems.amethyst ? MON_POISON.turns : Math.max(0, f.mpoison - 1);
    const mburn = gems.ruby ? MON_BURN.turns : Math.max(0, f.mburn - 1);
    const mweak = gems.garnet ? 1 : f.mweak;
    // Poison and fire already on the monster hurt it again with this attack.
    const dot = (f.mpoison > 0 ? Math.round(f.monster.hp * MON_POISON.share) : 0) + (f.mburn > 0 ? Math.round(f.monster.hp * MON_BURN.share) : 0);
    // Diamond: one of each potion too.
    const bagNow = gems.diamond && bag ? Object.fromEntries(POTION_KEYS.map(k => [k, Math.min(POTION_MAX, (bag[k] || 0) + 1)])) : bag;
    if (bagNow !== bag) setBag(bagNow);
    const used = new Set(sel);
    // A gem from a long word, or from overkill; the better of the two.
    const overkill = Math.max(0, dmg + (f.mpoison > 0 ? Math.round(f.monster.hp * MON_POISON.share) : 0) + (f.mburn > 0 ? Math.round(f.monster.hp * MON_BURN.share) : 0) - f.mhp) / 100;
    const gemKind = [monsterGem(word.length, eqCount(eq, "gems") > 0), overkillGem(overkill)].filter(Boolean)
      .sort((a, z) => GEM_BONUS[z] - GEM_BONUS[a])[0] || null;
    const b = cloneBoard(board);
    const spawn = refill(b, used, diff);
    if (gemKind && spawn.length) pick(spawn).kind = gemKind;
    if (cured) for (const col of b) for (const t of col) { t.stone = 0; t.burn = 0; }
    const newWords = [{ word, points: dmg }, ...words];
    const mhp = f.mhp - dmg - dot;
    const hp = Math.min(f.hpMax, f.hp + heal);
    const after = { ...f, mhp, hp, power: false, weak: cured ? 0 : Math.max(0, f.weak - 1), poison: cured ? 0 : f.poison, freeze: f.freeze + freezeAdd,
      shield: cured ? 1 : f.shield, mpoison, mburn, mweak };
    let newScore = score + dmg;
    setBusy(true); setSel([]); setHint(null); setBoard(b); setWords(newWords); setTurn(turn + 1);
    const praise = PRAISE[tier];
    setFx(x => ({ key: x.key + 1, hero: "lunge", mon: null, fly: word.toUpperCase(), praise, tier }));
    sound("whoosh");
    if (tier >= 5) { later(() => announce(praise), 120); later(() => sound("fanfare", tier), 520); }
    later(() => {
      play(heal ? "heal" : null, "hurt");
      sound("hit", tier);
      if (heal) later(() => sound("heal"), 200);
      if (freezeAdd) later(() => sound("freeze"), 250);
      if (gemKind) later(() => sound("gem"), 160);
      floatUp("mon", `-${dmg + dot}`, "#D7261E");
      if (heal) floatUp("hero", `+${heal}`, "#2E8B57");
      setFight({ ...after, mhp: Math.max(0, mhp) });
      const bits = [];
      if (dot) bits.push(`poison and fire hurt it ${dot} more`);
      if (gems.amethyst) bits.push(`amethyst poisoned ${f.monster.name}`);
      if (gems.ruby) bits.push(`ruby set ${f.monster.name} on fire`);
      if (gems.garnet) bits.push(`garnet weakened ${f.monster.name}`);
      if (cured) bits.push("crystal cleaned you and the board · shield up");
      if (freezeAdd) bits.push(`sapphire froze ${f.monster.name}`);
      if (gems.diamond) bits.push("diamond healed you fully · +1 of each potion");
      if (bits.length) say(bits.join(" · "), "good");
    }, 380);

    if (mhp > 0) {
      setScore(newScore);
      monsterTurn(after, b, newWords, newScore, bagNow, 1100);
      return;
    }
    // Monster beaten: it may drop a potion (a boss always drops two).
    const beaten = f.beaten + 1;
    newScore += 50 * f.stage;
    const drops = [];
    const dropCount = f.monster.boss ? 2 : Math.random() < Math.min(0.85, 0.35 + eqSum(eq, "finder") / 100) ? 1 : 0;
    const items = { ...bagNow };
    for (let i = 0; i < dropCount; i++) { const k = pick(POTION_KEYS); if (items[k] < POTION_MAX) { items[k] += 1; drops.push(POTIONS[k].short); } }
    setScore(newScore);
    later(() => { play(null, "ko"); sound("ko"); }, 900);
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
      setFight({ ...after, idx: f.idx + 1, stage: f.stage + 1, monster: next, mhp: next.hp, hp: Math.min(f.hpMax, hp + healBetween), beaten, freeze: 0, turns: 0, mpoison: 0, mburn: 0, mweak: 0, shield: 0 });
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
      sound("freeze");
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
    // Bonus word found: the next one pays more. New letters lean toward whichever bonus word is up.
    const nextBonusN = bonusHit ? bonus.n + 1 : bonus?.n || 0;
    if (!bonusHit) seedBonus(b, spawn, bonus?.word, 0.3);
    // Word books: new finds this game, and any book that just reached its goal.
    const books = { ...runBooksRef.current };
    const finished = [];
    for (const k of bookHits) {
      books[k] = [...(books[k] || []), word];
      const had = foundBooks[k].length;
      if (had < BOOK_GOAL && had + 1 >= BOOK_GOAL) finished.push(k);
    }
    runBooksRef.current = books;
    if (bookHits.length) setRunBooks(books);
    const bookPoints = finished.length * BOOK_DONE_POINTS;
    let lost = false;
    const rows = b[0].length;
    if (nextTurn % diff.burnEvery === 0) {
      for (let c = 0; c < b.length; c++) {
        const fires = b[c].filter(t => t.kind === "fire" && !t.fresh).map(t => t.id).reverse();
        for (const id of fires) {
          const r = b[c].findIndex(t => t.id === id);
          if (r === rows - 1) { lost = true; continue; }
          const below = b[c][r + 1];
          if (below.kind === "fire") continue; // a fire never burns another fire
          // A gem takes a few burns before it gives way.
          if (GEM_TOUGH[below.kind] && (below.heat || 0) + 1 < GEM_TOUGH[below.kind]) { below.heat = (below.heat || 0) + 1; continue; }
          b[c].splice(r + 1, 1);
          b[c].unshift(newTile(b, diff));
        }
      }
    }
    const newScore = score + points + bookPoints;
    const newWords = [{ word, points }, ...words];
    setBoard(b); setSel([]); setWords(newWords); setTurn(nextTurn); setHint(null); setScore(newScore);
    if (bonusHit) newBonusWord(nextBonusN, word, false);
    if (lost) { finishRun({ won: false, finalScore: newScore, finalWords: newWords }); return; }
    if (!run.endless && newScore >= fireCfg.goal) { finishRun({ won: true, finalScore: newScore, finalWords: newWords }); return; }
    if (tier >= 5 || bonusHit || finished.length) { announce(bonusHit ? "Bonus word!" : PRAISE[tier] || "Book finished!"); sound("fanfare", Math.max(tier, 7)); } else sound("gem");
    const bits = [`${PRAISE[tier] ? `${PRAISE[tier]} ` : ""}${word.toUpperCase()} +${points}`];
    if (bonusHit) bits.push(`bonus word ×${3 + bonus.n}!`);
    for (const k of bookHits) {
      const bk = WORD_BOOKS.find(x => x.key === k);
      const n = foundBooks[k].length + 1;
      bits.push(finished.includes(k) ? `${bk.icon} ${bk.name} book finished! +${BOOK_DONE_POINTS}` : n === 1 ? `${bk.icon} ${bk.name} book opened!` : `${bk.icon} ${bk.name} ${Math.min(n, BOOK_GOAL)}/${BOOK_GOAL}`);
    }
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
  const wrap = children => <div ref={fs.ref} style={fs.frame}><div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>{children}</div></div>;
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
      return wrap(<>{title}{head}<FireMap diff={diff} unlocked={unlocked} onPlay={n => startRun(false, n)} />{endlessBtn}<BooksPanel found={foundBooks} /></>);
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
    const firstLevel = story.kind === "level" && stepOf(story.level) === 1;
    const prologue = (story.kind === "intro" || firstLevel) && (story.world === 0 || story.world === 10) ? `${STORY_PARTS[story.world === 0 ? 0 : 1]} ` : "";
    const text = story.kind === "outro" ? w.outro
      : story.kind === "level" ? `${firstLevel ? `${prologue}${w.intro} ` : ""}${levelStory(story.level)}`
      : `${prologue}${w.intro}`;
    const label = story.kind === "outro" ? "The End of the Chapter" : story.kind === "level" ? `Level ${stepOf(story.level)}: ${levelName(story.level)}` : "The Story";
    const done = () => {
      stopSpeaking();
      if (story.kind === "level") startRun(false, story.level);
      else if (story.kind === "intro") setScreen("map");
      else setScreen("over");
      setStory(null);
    };
    return wrap(<><QuestStyles /><StoryPage key={`${story.world}${story.kind}${story.level || ""}`} world={w} index={story.world} kind={story.kind} text={text} label={label}
      level={story.kind === "level" ? levelInfo(story.level) : null} step={story.kind === "level" ? stepOf(story.level) : null}
      button={story.kind === "level" ? (stepOf(story.level) === LEVELS_PER_WORLD ? "Face the boss!" : "Fight!") : story.kind === "intro" ? "Back to the map" : "Continue"} onDone={done} /></>);
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
        {fs.button}
      </div>
    </div>
    {mode === "fire" && !run.endless ? <Bar value={score} max={fireCfg.goal} color={T.amber} label="Goal" /> : null}
    {mode === "fire" && bonus ? (
      <div style={{ display: "flex", justifyContent: "center", margin: "6px 0" }}>
        <span style={{ display: "inline-flex", alignItems: "center", gap: 8, padding: "4px 12px", borderRadius: 999, background: "#FFF3CD", border: "1px solid #E2B13C", fontSize: 13, color: "#5B4300" }}>
          ⭐ Bonus word <b style={{ fontSize: 16, letterSpacing: 2 }}>{bonus.word.toUpperCase()}</b> ×{3 + bonus.n}
        </span>
      </div>
    ) : null}
    {mode === "monsters" && !run.endless ? (
      <div style={{ display: "flex", gap: 8, alignItems: "flex-start", fontSize: 13, color: T.slate600, lineHeight: 1.45, fontStyle: "italic", marginBottom: 4 }}>
        <button type="button" title="Read it to me" aria-label="Read the story to me" onClick={() => speak(levelStory(run.level), () => {}, () => {})}
          style={{ border: `1px solid ${T.slate300}`, background: T.white, borderRadius: 8, padding: "1px 6px", cursor: "pointer", fontSize: 13, fontStyle: "normal", flexShrink: 0 }}>📖</button>
        <span>{levelStory(run.level)}</span>
      </div>
    ) : null}
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
      {valid && PRAISE[tier] ? <div key={tier} style={{ fontSize: 15, fontWeight: 900, color: PRAISE_COLOR[tier], animation: "sqPop 0.3s ease-out" }}>{PRAISE[tier]}</div> : null}
      {valid ? <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>{mode === "monsters" ? `${preview} damage` : `+${preview}`}</div> : null}
      <button type="button" onClick={() => setSel([])} disabled={!sel.length} style={{ ...btn(T.slate400), padding: "8px 12px", opacity: sel.length ? 1 : 0.5 }}>Clear</button>
      <button type="button" onClick={submit} disabled={!valid || busy} style={{ ...btn(T.teal), opacity: valid && !busy ? 1 : 0.4 }}>{mode === "monsters" ? "Attack" : "Go"}</button>
    </div>

    <div ref={boxRef} style={{ width: "100%" }}>
      <div style={{ position: "relative", width: S * cols, height: S * rows, margin: "0 auto", userSelect: "none", touchAction: "manipulation" }}>
        {board.map((col, c) => col.map((t, r) => (
          <Tile key={t.id} tile={t} size={S} left={c * S} top={r * S} value={anyOrder ? Math.round((LETTER_WEIGHT[t.ch] || 1) * 10) : null}
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


function QuestStyles() {
  return (
    <style>{`
      @keyframes sqDrop { from { transform: translateY(-16px); opacity: 0 } to { transform: none; opacity: 1 } }
      @keyframes sqFlicker { from { filter: brightness(1) } to { filter: brightness(1.18) } }
      @keyframes sqTwinkle { 0%,70%,100% { opacity: 0; transform: scale(0.3) rotate(0deg) } 82% { opacity: 1; transform: scale(1) rotate(45deg) } }
      @keyframes sqHint { from { box-shadow: 0 0 0 2px #F59E0B } to { box-shadow: 0 0 0 6px #F59E0B } }
      @keyframes sqIdle { 0%,100% { transform: translateY(0) } 50% { transform: translateY(-4px) } }
      @keyframes sqLungeR { 0% { transform: translateX(0) } 35% { transform: translateX(46px) rotate(6deg) } 100% { transform: translateX(0) } }
      @keyframes sqLungeL { 0% { transform: translateX(0) } 35% { transform: translateX(-46px) rotate(-6deg) } 100% { transform: translateX(0) } }
      @keyframes sqHurt { 0%,100% { transform: translateX(0); filter: none } 20% { transform: translateX(-8px); filter: brightness(1.6) saturate(0.4) } 50% { transform: translateX(8px) } 75% { transform: translateX(-4px) } }
      @keyframes sqHeal { 0%,100% { filter: none } 50% { filter: drop-shadow(0 0 10px #4CBF72) brightness(1.15) } }
      @keyframes sqKo { to { transform: translateY(20px) scale(0.3) rotate(25deg); opacity: 0 } }
      @keyframes sqEnter { from { transform: translateX(90px); opacity: 0 } to { transform: none; opacity: 1 } }
      @keyframes sqPraise { 0% { transform: scale(0.3) rotate(-8deg); opacity: 0 } 20% { transform: scale(1.25) rotate(3deg); opacity: 1 } 35% { transform: scale(1) rotate(0) } 80% { opacity: 1 } 100% { transform: translateY(-20px); opacity: 0 } }
      @keyframes sqPop { from { transform: scale(0.4) } 60% { transform: scale(1.3) } to { transform: scale(1) } }
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
            {fight.atk > 1.05 ? <Chip color="#5C5E50">Attack ×{fight.atk.toFixed(1)}</Chip> : null}
            {fight.power ? <Chip color="#A8801F">Power ×2</Chip> : null}
            {fight.poison ? <Chip color="#6E8B3E">Poison {fight.poison}</Chip> : null}
            {fight.weak ? <Chip color="#7A6A8C">Weak {fight.weak}</Chip> : null}
            {fight.shield ? <Chip color="#D267A3">Shield</Chip> : null}
            {(fight.eq || []).map(t => <span key={t.name} title={`${t.name}: ${t.text}`}><TreasureIcon color={t.color} size={16} /></span>)}
          </div>
        </div>
        <div style={{ flex: 1, background: "rgba(255,255,255,0.82)", borderRadius: 10, padding: "4px 8px" }}>
          <Bar value={fight.mhp} max={m.hp} color={T.red} label={m.boss ? `${m.name} ★` : m.name} small />
          <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginTop: 3, minHeight: 16 }}>
            {fight.freeze ? <Chip color="#3F8DB8">Frozen {fight.freeze}</Chip> : null}
            {fight.mpoison ? <Chip color="#6E8B3E">Poisoned {fight.mpoison}</Chip> : null}
            {fight.mburn ? <Chip color="#D7261E">Burning {fight.mburn}</Chip> : null}
            {fight.mweak ? <Chip color="#E8651E">Weak</Chip> : null}
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
      {/* praise, like Bookworm's announcer */}
      {fx.praise ? (
        <div key={`p${fx.key}`} style={{
          position: "absolute", left: 0, right: 0, top: "26%", zIndex: 5, textAlign: "center", pointerEvents: "none",
          fontSize: (wide ? 34 : 26) + Math.max(0, (fx.tier || 0) - 4) * 3, fontWeight: 900, color: PRAISE_COLOR[fx.tier] || "#E2B13C",
          textShadow: "0 3px 0 #fff, 0 0 10px #fff", animation: "sqPraise 1.1s ease-out forwards", fontFamily: "Georgia, serif",
        }}>{fx.praise}</div>
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
function StoryPage({ world, index, kind, text, label, level, step, button, onDone }) {
  return (
    <div style={{ borderRadius: 16, overflow: "hidden", border: `1px solid ${T.slate200}`, background: T.white }}>
      <div style={{ position: "relative", height: 170, background: world.sky[1] }}>
        <QuestScene world={world} level={level} step={step || (kind === "outro" ? 17 : 5)} wide />
        <div style={{ position: "absolute", right: 16, bottom: 10, animation: kind === "outro" ? "none" : "sqIdle 1.9s ease-in-out infinite", opacity: kind === "outro" ? 0.75 : 1, transform: kind === "outro" ? "rotate(-8deg)" : "none" }}>
          <QuestMonster m={MONSTER_OF(world.boss)} size={96} />
        </div>
        <div style={{ position: "absolute", left: 12, top: 10, background: "rgba(255,255,255,0.88)", borderRadius: 10, padding: "4px 10px", fontSize: 13, fontWeight: 800, color: T.slate800 }}>
          World {index + 1}: {world.name} · {label}
        </div>
      </div>
      <ReadAloud text={text} button={button} onDone={onDone} />
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

// Word books: closed until one of their words is spelled; then the book shows every word, found ones filled in.
function BooksPanel({ found }) {
  const [openKey, setOpenKey] = useState(null);
  const done = WORD_BOOKS.filter(bk => found[bk.key].length >= BOOK_GOAL).length;
  const shown = WORD_BOOKS.find(bk => bk.key === openKey && found[bk.key].length);
  return (
    <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 12, marginTop: 12 }}>
      <div style={{ fontSize: 14, fontWeight: 700, color: T.slate800 }}>Word books · {done} of {WORD_BOOKS.length} finished</div>
      <div style={{ fontSize: 12, color: T.slate500, marginBottom: 8 }}>Spell a word from a book to open it. Book words score double the first time; find {BOOK_GOAL} to finish a book for +{BOOK_DONE_POINTS}.</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(88px, 1fr))", gap: 6 }}>
        {WORD_BOOKS.map(bk => {
          const n = found[bk.key].length;
          const open = n > 0;
          const fin = n >= BOOK_GOAL;
          return (
            <button key={bk.key} type="button" disabled={!open} onClick={() => setOpenKey(openKey === bk.key ? null : bk.key)} style={{
              padding: "8px 4px", borderRadius: 10, fontFamily: "inherit", cursor: open ? "pointer" : "default",
              background: fin ? T.greenLt : open ? (openKey === bk.key ? "#FFF3CD" : T.white) : T.slate100,
              border: `2px solid ${fin ? T.green : open ? "#E2B13C" : T.slate200}`,
            }}>
              <div style={{ fontSize: 20, filter: open ? "none" : "grayscale(1)", opacity: open ? 1 : 0.5 }}>{open ? bk.icon : "📕"}</div>
              <div style={{ fontSize: 12, fontWeight: 700, color: open ? T.slate800 : T.slate400 }}>{open ? bk.name : "Closed"}</div>
              <div style={{ fontSize: 11, color: T.slate500 }}>{fin ? "Finished ✓" : `${n} / ${BOOK_GOAL}`}</div>
            </button>
          );
        })}
      </div>
      {shown ? (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 10 }}>
          {shown.words.map(w => {
            const got = found[shown.key].includes(w);
            return <span key={w} style={{ padding: "3px 8px", borderRadius: 8, fontSize: 13, fontWeight: got ? 700 : 400, background: got ? T.greenLt : T.slate100, color: got ? T.green : T.slate500, letterSpacing: 1 }}>{got ? `✓ ${w.toUpperCase()}` : w.toUpperCase()}</span>;
          })}
        </div>
      ) : null}
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

// A cut gem drawn under the letter: bright center table, four slanted facets,
// a glossy streak and a twinkle. Same drawing for every gem kind; colors come from GEM_LOOK.
function GemCut({ gem, id }) {
  const g = `gc${id}`;
  return (
    <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true"
      style={{ position: "absolute", inset: 0, width: "100%", height: "100%", pointerEvents: "none" }}>
      <defs>
        <radialGradient id={`${g}t`} cx="38%" cy="32%" r="75%">
          <stop offset="0%" stopColor={gem.hi} />
          <stop offset="55%" stopColor={gem.mid} />
          <stop offset="100%" stopColor={gem.base} />
        </radialGradient>
        {gem.rainbow ? (
          <linearGradient id={`${g}r`} x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stopColor="#FFB3E6" />
            <stop offset="35%" stopColor="#FFF3A6" />
            <stop offset="65%" stopColor="#A6FFE0" />
            <stop offset="100%" stopColor="#B3C8FF" />
          </linearGradient>
        ) : null}
      </defs>
      <polygon points="0,0 100,0 78,22 22,22" fill={gem.mid} />
      <polygon points="0,0 22,22 22,78 0,100" fill={gem.base} />
      <polygon points="100,0 100,100 78,78 78,22" fill={gem.lo} />
      <polygon points="0,100 22,78 78,78 100,100" fill={gem.deep} />
      <rect x="22" y="22" width="56" height="56" fill={`url(#${g}t)`} />
      {gem.rainbow ? <rect x="0" y="0" width="100" height="100" fill={`url(#${g}r)`} opacity="0.35" /> : null}
      <g stroke="#FFFFFF" strokeOpacity="0.45" strokeWidth="1.2" fill="none">
        <path d="M0,0 L22,22 M100,0 L78,22 M0,100 L22,78 M100,100 L78,78" />
        <rect x="22" y="22" width="56" height="56" />
        <path d="M22,22 L50,36 L78,22 M22,78 L50,64 L78,78" strokeOpacity="0.2" />
      </g>
      <polygon points="6,4 40,4 14,44 4,40" fill="#FFFFFF" opacity="0.4" />
      <g style={{ transformOrigin: "80px 18px", animation: `sqTwinkle ${2.6 + (id % 5) * 0.4}s ease-in-out ${(id % 7) * 0.45}s infinite` }}>
        <path d="M80,6 L83,15 L92,18 L83,21 L80,30 L77,21 L68,18 L77,15 Z" fill="#FFFFFF" />
      </g>
    </svg>
  );
}

function Tile({ tile, size, left, top, order, hinted, danger, onTap, value = null }) {
  const chosen = order >= 0;
  const fire = tile.kind === "fire";
  const stone = tile.stone > 0;
  const burning = tile.burn > 0;
  // A chosen gem keeps its gem look and gets a bright ring, so kids see what they picked.
  const gem = !stone && !burning ? GEM_LOOK[tile.kind] : null;
  const lightGem = gem && gem.rainbow;
  const bg = burning ? "linear-gradient(170deg,#FFE3B0 0%,#FFB067 60%,#FF7A2F 100%)" : stone ? "linear-gradient(170deg,#B5B2A8,#7A7C6E)" : gem ? gem.base : chosen ? T.blue : fire ? "linear-gradient(170deg,#FFD27A 0%,#FF7A2F 45%,#D7261E 100%)" : "linear-gradient(170deg,#FFF9EC,#EADFC4)";
  const ink = stone ? "#4D503F" : gem ? (lightGem ? "#0E3550" : "#FFFFFF") : chosen ? T.white : fire ? "#fff" : T.slate900;
  const border = stone ? "#5C5E50" : gem ? gem.border : chosen ? T.chromeBgDeep : fire ? "#9E1B14" : "#C9BB98";
  const shadow = danger || burning ? "0 0 0 3px rgba(239,68,68,0.6)"
    : gem && chosen ? `0 0 0 3px ${T.blue}, 0 3px 0 rgba(0,0,0,0.2)`
    : gem ? "0 3px 0 rgba(0,0,0,0.2), 0 0 8px rgba(255,255,255,0.35)"
    : "0 3px 0 rgba(0,0,0,0.15)";
  const textShadow = gem ? (lightGem ? "0 1px 0 #FFFFFF, 0 0 4px #FFFFFF" : "0 1px 2px rgba(0,0,0,0.7), 0 0 3px rgba(0,0,0,0.45)") : "none";
  return (
    <button
      type="button"
      onClick={onTap}
      disabled={stone}
      aria-label={`${tile.ch}${fire ? " fire" : GEM_LOOK[tile.kind] ? ` ${tile.kind}` : ""}${stone ? " stone" : ""}${burning ? " burning" : ""}`}
      style={{
        position: "absolute", left: left + 3, top: top + 3, width: size - 6, height: size - 6, padding: 0, cursor: stone ? "default" : "pointer",
        borderRadius: Math.round(size * 0.16), border: `2px solid ${border}`, background: bg, color: ink, overflow: "hidden",
        boxShadow: shadow, textShadow,
        transition: "top 0.25s ease-out, background 0.15s", fontFamily: "Georgia, 'Times New Roman', serif",
        animation: hinted ? "sqHint 0.6s ease-in-out infinite alternate" : tile.fresh ? "sqDrop 0.3s ease-out" : fire || burning ? "sqFlicker 0.9s ease-in-out infinite alternate" : "none",
      }}
    >
      {gem ? <GemCut gem={gem} id={tile.id || 0} /> : null}
      <span style={{ position: "relative", fontSize: Math.round(size * (tile.ch.length > 1 ? 0.4 : 0.5)), fontWeight: 700, lineHeight: 1 }}>{tile.ch === "QU" ? "Qu" : tile.ch}</span>
      <span style={{ position: "absolute", right: 5, bottom: 3, fontSize: Math.max(9, Math.round(size * 0.17)), opacity: gem ? 0.9 : 0.7 }}>
        {stone ? tile.stone : burning ? `🔥${tile.burn}` : tile.heat && GEM_TOUGH[tile.kind] ? `🛡${GEM_TOUGH[tile.kind] - tile.heat}` : (value ?? Math.round((VALUE[tile.ch] || 1) * 10))}
      </span>
      {chosen ? <span style={{ position: "absolute", left: 5, top: 3, fontSize: Math.max(9, Math.round(size * 0.19)), fontWeight: 700, opacity: gem ? 1 : 0.85 }}>{order + 1}</span> : null}
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
