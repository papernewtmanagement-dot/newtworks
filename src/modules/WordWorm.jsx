import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";
import { useDancers, CritterIcon, DoneDancerStyles } from "../components/Critters.jsx";

// =========================================================================
// WordWorm.jsx — Family game in the style of Bookworm. A board of letter tiles,
// 7 columns of 8, every other column set half a tile lower so each tile touches
// up to six others. Tap touching letters in order to spell a word (3 letters or
// more), then Go. Spelled tiles disappear and new ones drop in from the top.
// Scoring: each letter is worth more the rarer it is, longer words multiply the
// total, and gem tiles (earned by spelling 5, 6, 7+ letter words) add a bonus.
// Fire tiles: short words can drop a fire tile in. After every word each fire
// tile burns the tile under it and sinks one row; the game ends when fire
// reaches the bottom. Use a fire tile in a word to put it out.
// Dictionary: public/games/words.txt — about 72,000 everyday English words
// (SCOWL lists up to size 60, 3 to 12 letters), loaded once when the game opens.
// Spelling Quest (nav item of its own, <WordWorm quest />): the battle version, like
// Bookworm Adventures. Each player picks their hero from the family's dancing
// characters (dancers table); a kid starts on their own chore-chart animal. No fire. Each word hits the monster for a
// tenth of its points (CAT = 35 points = 4 damage). The monster hits back after every
// word that doesn't finish it. Beat it and the next, tougher one comes; you get some
// health back. The game ends when your health runs out.
// Bests saved per kid on family_kids.game_bests: bookworm (fire), bookworm_battle (battle).
// Guest games aren't saved.
// =========================================================================

const COLS = 7;
const ROWS = 8;

// How often each letter shows up (roughly English) and what it is worth.
const LETTERS = [
  ["E", 12, 1], ["A", 9, 1], ["I", 8, 1], ["O", 8, 1], ["N", 6, 1], ["R", 6, 1], ["T", 6, 1], ["S", 5, 1],
  ["L", 4, 1], ["U", 4, 1], ["D", 4, 1.25], ["G", 3, 1.25], ["B", 2, 1.5], ["C", 2, 1.5], ["M", 2, 1.5],
  ["P", 2, 1.5], ["F", 2, 1.75], ["H", 2, 1.75], ["V", 2, 1.75], ["W", 2, 1.75], ["Y", 2, 1.75],
  ["K", 1, 2.75], ["J", 1, 3], ["X", 1, 3], ["QU", 1, 3.5], ["Z", 1, 3.5],
];
const VALUE = Object.fromEntries(LETTERS.map(([ch, , v]) => [ch, v]));
const VOWELS = new Set(["A", "E", "I", "O", "U"]);
const TOTAL_WEIGHT = LETTERS.reduce((a, [, w]) => a + w, 0);
const LEN_MULT = { 3: 1, 4: 1.25, 5: 1.5, 6: 2, 7: 2.5, 8: 3, 9: 3.5 };
const GEM_FOR_LEN = len => (len >= 7 ? "diamond" : len === 6 ? "gold" : len === 5 ? "green" : null);
const GEM_BONUS = { green: 0.5, gold: 1, diamond: 2 };
const GEM_LOOK = {
  green:   { bg: "linear-gradient(160deg,#B9F2C8,#4CBF72)", border: "#2E8B57", ink: "#0F3D22", label: "+50%" },
  gold:    { bg: "linear-gradient(160deg,#FFE9A6,#E2B13C)", border: "#A8801F", ink: "#4A3500", label: "+100%" },
  diamond: { bg: "linear-gradient(160deg,#E3F6FF,#8CCFF2)", border: "#3F8DB8", ink: "#0E3550", label: "+200%" },
};
// Battle mode: the monsters in order. After the last one they come round again, 40% tougher each time.
const HERO_HP = 40;
const HEAL_ON_WIN = 12;
const MONSTERS = [
  { name: "Dust Bunny",    hp: 24,  hit: [2, 4],  body: "#C9C2B8", look: "ears" },
  { name: "Ink Blot",      hp: 32,  hit: [3, 5],  body: "#4A477E", look: "blob" },
  { name: "Paper Moth",    hp: 40,  hit: [3, 6],  body: "#D9C9A3", look: "wings" },
  { name: "Riddle Rat",    hp: 50,  hit: [4, 7],  body: "#8C7B6B", look: "ears" },
  { name: "Grumble Gnome", hp: 60,  hit: [5, 8],  body: "#6E8B4E", look: "hat" },
  { name: "Spell Slug",    hp: 72,  hit: [6, 9],  body: "#8DBA5E", look: "blob" },
  { name: "Shelf Troll",   hp: 86,  hit: [7, 11], body: "#7A6A8C", look: "horns" },
  { name: "Page Dragon",   hp: 100, hit: [8, 13], body: "#B8483A", look: "dragon" },
];
function monsterFor(stage) {
  const base = MONSTERS[(stage - 1) % MONSTERS.length];
  const round = Math.floor((stage - 1) / MONSTERS.length);
  const k = 1 + 0.4 * round;
  return {
    ...base,
    name: round ? `${base.name} ${round + 1}` : base.name,
    hp: Math.round(base.hp * k),
    hit: [Math.round(base.hit[0] * k), Math.round(base.hit[1] * k)],
  };
}
const ri = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
const damageFor = points => Math.max(1, Math.round(points / 10));
const freshBattle = () => { const m = monsterFor(1); return { stage: 1, monster: m, mhp: m.hp, hp: HERO_HP, beaten: 0, hurt: null }; };

const levelAt = lv => 300 * (lv * (lv - 1)) / 2; // score where level lv starts: 0, 300, 900, 1800…

let DICT_PROMISE = null;
function loadDictionary() {
  if (!DICT_PROMISE) {
    const base = (import.meta.env && import.meta.env.BASE_URL) || "/";
    DICT_PROMISE = fetch(`${base}games/words.txt`)
      .then(r => { if (!r.ok) throw new Error(`Word list didn't load (${r.status})`); return r.text(); })
      .then(t => new Set(t.split("\n").map(w => w.trim()).filter(Boolean)))
      .catch(e => { DICT_PROMISE = null; throw e; });
  }
  return DICT_PROMISE;
}

let NEXT_ID = 1;
function randomLetter(board) {
  // Keep the board between about 30% and 50% vowels so there is always something to spell.
  let vowels = 0; let total = 0;
  for (const col of board || []) for (const t of col) { if (t.kind === "fire") continue; total += 1; if (VOWELS.has(t.ch)) vowels += 1; }
  const share = total ? vowels / total : 0.4;
  const want = share < 0.3 && Math.random() < 0.6 ? "vowel" : share > 0.5 && Math.random() < 0.6 ? "consonant" : null;
  for (;;) {
    let r = Math.random() * TOTAL_WEIGHT;
    let ch = "E";
    for (const [c, w] of LETTERS) { r -= w; if (r <= 0) { ch = c; break; } }
    if (want === "vowel" && !VOWELS.has(ch)) continue;
    if (want === "consonant" && VOWELS.has(ch)) continue;
    return ch;
  }
}
const newTile = (board, kind = "normal") => ({ id: NEXT_ID++, ch: randomLetter(board), kind, fresh: true });

function newBoard() {
  const b = [];
  for (let c = 0; c < COLS; c++) { b.push([]); for (let r = 0; r < ROWS; r++) b[c].push(newTile(b)); }
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

export default function WordWorm({ quest = false }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const mode = quest ? "battle" : "fire";
  const { all: heroes, ready: heroesReady } = useDancers();
  const [heroKey, setHeroKey] = useState(null);
  const gameKey = mode === "battle" ? "bookworm_battle" : "bookworm";
  const { players, loading, error, reload } = useFamilyPlayers(gameKey);
  const [battle, setBattle] = useState(null);

  const [dict, setDict] = useState(null);
  const [dictError, setDictError] = useState(null);
  const [playerId, setPlayerId] = useState("");
  const [screen, setScreen] = useState("setup"); // setup | play | over
  const [board, setBoard] = useState(null);
  const [sel, setSel] = useState([]); // tile ids in spelling order
  const [score, setScore] = useState(0);
  const [words, setWords] = useState([]); // [{word, points}]
  const [message, setMessage] = useState(null);
  const [result, setResult] = useState(null);
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

  const player = players.find(p => p.id === playerId) || null;
  // A kid's hero starts as their own chore-chart animal; Guest starts on the first character.
  const choosePlayer = id => {
    setPlayerId(id);
    const kid = players.find(p => p.id === id);
    if (kid?.animal) setHeroKey(kid.animal);
  };
  const hero = heroes.find(h => h.key === heroKey) || heroes[0] || null;
  const level = useMemo(() => { let lv = 1; while (score >= levelAt(lv + 1)) lv += 1; return lv; }, [score]);

  const selTiles = useMemo(() => {
    if (!board) return [];
    return sel.map(id => { const at = findTile(board, id); return at ? board[at.c][at.r] : null; }).filter(Boolean);
  }, [board, sel]);
  const word = selTiles.map(t => t.ch).join("").toLowerCase();
  const letterCount = word.length;
  const valid = !!dict && letterCount >= 3 && dict.has(word);
  const preview = valid ? scoreWord(selTiles) : 0;

  const say = (text, tone = "info") => {
    clearTimeout(msgTimer.current);
    setMessage({ text, tone });
    msgTimer.current = setTimeout(() => setMessage(null), 2200);
  };

  const start = () => {
    NEXT_ID = 1;
    setBoard(newBoard()); setSel([]); setScore(0); setWords([]); setResult(null); setMessage(null);
    setBattle(mode === "battle" ? freshBattle() : null);
    setScreen("play");
  };

  // fight = { beaten, monster } in battle mode, null in the fire game.
  const finish = useCallback(async (finalScore, finalWords, fight) => {
    const best = [...finalWords].sort((a, b) => b.points - a.points)[0] || null;
    const longest = [...finalWords].sort((a, b) => b.word.length - a.word.length)[0] || null;
    const summary = { score: finalScore, count: finalWords.length, best, longest, fight: fight || null, saved: null, isBest: false };
    setResult(summary);
    setScreen("over");
    if (player) {
      const r = await recordFamilyGame(player.id, gameKey, finalScore, {
        words: finalWords.length, best_word: best?.word || null, best_word_points: best?.points || 0, longest_word: longest?.word || null,
        ...(fight ? { beaten: fight.beaten, hero: fight.hero || null } : {}),
      });
      setResult({ ...summary, saved: r.saved, isBest: r.isBest, bestScore: r.bests?.best });
      reload();
    }
  }, [player, reload, gameKey]);

  const tap = (tile) => {
    if (!board) return;
    const idx = sel.indexOf(tile.id);
    if (idx >= 0) { setSel(sel.slice(0, idx)); return; } // tap a chosen letter: back up to before it
    const at = findTile(board, tile.id);
    const lastAt = sel.length ? findTile(board, sel[sel.length - 1]) : null;
    if (!lastAt || touching(lastAt, at)) setSel([...sel, tile.id]);
    else setSel([tile.id]); // not touching: start a new word here
  };

  const submit = () => {
    if (!board || !valid) return;
    const points = preview;
    const used = new Set(sel);
    const putOut = selTiles.filter(t => t.kind === "fire").length;
    const gemKind = GEM_FOR_LEN(letterCount);
    const lv = level;
    const fireChance = mode === "battle" ? 0 : letterCount <= 3 ? Math.min(0.7, 0.25 + 0.05 * lv) : letterCount === 4 ? Math.min(0.4, 0.05 * lv) : 0;
    const addFire = Math.random() < fireChance;

    // 1. Take out the spelled tiles and drop new ones in from the top.
    let b = cloneBoard(board).map(col => col.filter(t => !used.has(t.id)));
    const spawn = [];
    for (let c = 0; c < COLS; c++) {
      while (b[c].length < ROWS) { const t = newTile(b); b[c].unshift(t); spawn.push(t); }
    }
    if (gemKind && spawn.length) pick(spawn).kind = gemKind;
    const plain = spawn.filter(t => t.kind === "normal");
    if (addFire && plain.length) pick(plain).kind = "fire";

    // 2. Fires that were already on the board burn the tile under them and sink a row.
    // Lowest fire first, looked up fresh each time because each burn shifts the column.
    let lost = false;
    for (let c = 0; c < COLS && mode !== "battle"; c++) {
      const fires = b[c].filter(t => t.kind === "fire" && !t.fresh).map(t => t.id).reverse();
      for (const id of fires) {
        const r = b[c].findIndex(t => t.id === id);
        if (r === ROWS - 1) { lost = true; continue; }
        if (b[c][r + 1].kind === "fire") continue; // a fire never burns another fire; it waits on top
        b[c].splice(r + 1, 1);
        b[c].unshift(newTile(b));
      }
    }

    let newScore = score + points;
    const newWords = [{ word, points }, ...words];

    if (mode === "battle" && battle) {
      const dmg = damageFor(points);
      const mhp = battle.mhp - dmg;
      if (mhp <= 0) {
        const bonus = 100 * battle.stage;
        newScore += bonus;
        const next = monsterFor(battle.stage + 1);
        setBattle({ stage: battle.stage + 1, monster: next, mhp: next.hp, hp: Math.min(HERO_HP, battle.hp + HEAL_ON_WIN), beaten: battle.beaten + 1, hurt: null });
        setBoard(b); setSel([]); setScore(newScore); setWords(newWords);
        say(`${word.toUpperCase()} beat ${battle.monster.name}! +${bonus} · here comes ${next.name}`, "good");
        return;
      }
      const hit = ri(battle.monster.hit[0], battle.monster.hit[1]);
      const hp = battle.hp - hit;
      setBattle({ ...battle, mhp, hp: Math.max(0, hp), hurt: "both" });
      setBoard(b); setSel([]); setScore(newScore); setWords(newWords);
      if (hp <= 0) { finish(newScore, newWords, { beaten: battle.beaten, monster: battle.monster.name, hero: hero?.key }); return; }
      say(`${word.toUpperCase()} hits for ${dmg} · ${battle.monster.name} hits you for ${hit}`, "warn");
      return;
    }

    setBoard(b); setSel([]); setScore(newScore); setWords(newWords);
    if (lost) { finish(newScore, newWords); return; }
    const bits = [`${word.toUpperCase()} +${points}`];
    if (putOut) bits.push("fire out!");
    if (gemKind) bits.push(`${gemKind} tile earned`);
    if (addFire) bits.push("a fire dropped in");
    say(bits.join(" · "), addFire ? "warn" : "good");
  };

  const scramble = () => {
    if (!board) return;
    const b = cloneBoard(board);
    for (const col of b) for (const t of col) if (t.kind === "normal") t.ch = randomLetter(b);
    if (mode === "battle" && battle) {
      // In battle a shuffle costs a turn: the monster hits you.
      const hit = ri(battle.monster.hit[0], battle.monster.hit[1]);
      const hp = battle.hp - hit;
      setBoard(b); setSel([]);
      setBattle({ ...battle, hp: Math.max(0, hp), hurt: "you" });
      if (hp <= 0) { finish(score, words, { beaten: battle.beaten, monster: battle.monster.name, hero: hero?.key }); return; }
      say(`Shuffled · ${battle.monster.name} hits you for ${hit}`, "warn");
      return;
    }
    const top = [];
    for (let c = 0; c < COLS; c++) if (b[c][0].kind === "normal") top.push(b[c][0]);
    if (top.length) { const t = pick(top); t.kind = "fire"; t.fresh = true; }
    setBoard(b); setSel([]);
    say("Shuffled · it cost a fire tile", "warn");
  };

  const header = (
    <div style={{ marginBottom: 12 }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>{quest ? "Spelling Quest" : "Word Worm"}</div>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        {mode === "battle" ? "Spell words with touching letters to beat the monsters." : "Spell words with touching letters. Keep the fire off the bottom row."}
      </div>
    </div>
  );

  if (screen === "setup") {
    return (
      <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>
        {header}
        {error ? <div style={{ color: T.red, fontSize: 13, marginBottom: 8 }}>{error}</div> : null}
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 16, display: "grid", gap: 16 }}>
          <div>
            <div style={{ fontSize: 13, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>Who's playing?</div>
            {loading ? <div style={{ color: T.slate400, fontSize: 13 }}>Loading…</div> : <PlayerPicker players={players} value={playerId} onChange={choosePlayer} accent={T.teal} />}
          </div>
          {quest ? (
            <div>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>
                Pick your hero{hero ? <span style={{ fontWeight: 500, color: T.slate500 }}> · {hero.label}</span> : null}
              </div>
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
          {player?.bests?.best_detail?.best_word ? (
            <div style={{ fontSize: 13, color: T.slate600 }}>
              {player.name}'s best word: <b>{String(player.bests.best_detail.best_word).toUpperCase()}</b> ({Number(player.bests.best_detail.best_word_points || 0).toLocaleString()} pts)
            </div>
          ) : null}
          {dictError ? <div style={{ color: T.red, fontSize: 13 }}>{dictError}</div> : null}
          <button type="button" onClick={start} disabled={!dict} style={{
            padding: "14px 18px", borderRadius: 12, border: "none", background: dict ? T.teal : T.slate300, color: T.white,
            fontSize: 18, fontWeight: 700, cursor: dict ? "pointer" : "default", fontFamily: "inherit",
          }}>{dict ? "Start" : "Loading words…"}</button>
        </div>
      </div>
    );
  }

  if (screen === "over" && result) {
    return (
      <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>
        {header}
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 20, textAlign: "center", display: "grid", gap: 10 }}>
          <div style={{ fontSize: 15, color: T.slate500 }}>
            {result.fight ? `${result.fight.monster} won this time` : "The fire reached the bottom"} · {player ? player.name : "Guest"}
          </div>
          <div style={{ fontSize: 44, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
          {result.isBest ? <div style={{ fontSize: 16, fontWeight: 700, color: T.gold }}>New best score!</div> : null}
          <div style={{ fontSize: 15, color: T.slate700 }}>
            {result.count} words{result.fight ? ` · beat ${result.fight.beaten} monster${result.fight.beaten === 1 ? "" : "s"}` : ""}
          </div>
          {result.best ? <div style={{ fontSize: 15, color: T.slate700 }}>Best word: <b>{result.best.word.toUpperCase()}</b> ({result.best.points.toLocaleString()} pts)</div> : null}
          {result.longest && result.longest.word !== result.best?.word ? <div style={{ fontSize: 15, color: T.slate700 }}>Longest: <b>{result.longest.word.toUpperCase()}</b></div> : null}
          {player && result.saved === false ? <div style={{ fontSize: 13, color: T.red }}>Couldn't save this score.</div> : null}
          {player && result.bestScore != null && !result.isBest ? <div style={{ fontSize: 13, color: T.slate500 }}>Best: {Number(result.bestScore).toLocaleString()}</div> : null}
          <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 6 }}>
            <button type="button" onClick={start} style={btn(T.teal)}>Play again</button>
            <button type="button" onClick={() => setScreen("setup")} style={btn(T.slate600)}>Change player</button>
          </div>
        </div>
      </div>
    );
  }

  if (!board) return null;
  const S = Math.max(40, Math.min(64, Math.floor(boxW / (COLS + 0.15))));
  const boardW = S * COLS;
  const boardH = S * (ROWS + 0.5);
  const nextAt = levelAt(level + 1);

  return (
    <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", flexWrap: "wrap", gap: 8, marginBottom: 8 }}>
        <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>{score.toLocaleString()} pts</div>
        <div style={{ fontSize: 13, color: T.slate600 }}>
          {battle ? `Monster ${battle.stage} · beaten ${battle.beaten}` : `Level ${level} · next at ${nextAt.toLocaleString()}`}
        </div>
      </div>

      {battle ? <BattleBar battle={battle} hero={hero} /> : null}

      {/* Word being spelled */}
      <div style={{
        display: "flex", alignItems: "center", gap: 8, padding: "8px 10px", marginBottom: 10, borderRadius: 12, minHeight: 52,
        background: T.white, border: `2px solid ${valid ? T.green : T.slate200}`, flexWrap: "wrap",
      }}>
        <div style={{ flex: "1 1 160px", fontSize: 24, fontWeight: 800, letterSpacing: 2, color: valid ? T.slate900 : T.slate500, minWidth: 0, overflowWrap: "anywhere" }}>
          {word ? word.toUpperCase() : <span style={{ fontSize: 14, fontWeight: 500, letterSpacing: 0, color: T.slate400 }}>Tap touching letters</span>}
        </div>
        {valid ? <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>+{preview}{battle ? ` · ${damageFor(preview)} dmg` : ""}</div> : null}
        <button type="button" onClick={() => setSel([])} disabled={!sel.length} style={{ ...btn(T.slate400), padding: "8px 12px", opacity: sel.length ? 1 : 0.5 }}>Clear</button>
        <button type="button" onClick={submit} disabled={!valid} style={{ ...btn(T.teal), opacity: valid ? 1 : 0.4 }}>Go</button>
      </div>

      <div ref={boxRef} style={{ width: "100%" }}>
        <div style={{ position: "relative", width: boardW, height: boardH, margin: "0 auto", userSelect: "none", touchAction: "manipulation" }}>
          <style>{"@keyframes wwDrop{from{transform:translateY(-14px);opacity:0}to{transform:none;opacity:1}}@keyframes wwFlicker{from{filter:brightness(1)}to{filter:brightness(1.18)}}"}</style>
          {board.map((col, c) => col.map((t, r) => {
            const order = sel.indexOf(t.id);
            return (
              <Tile key={t.id} tile={t} size={S} left={c * S} top={(r + (c % 2 ? 0.5 : 0)) * S}
                order={order} danger={t.kind === "fire" && r >= ROWS - 2} onTap={() => tap(t)} />
            );
          }))}
        </div>
      </div>

      {message ? (
        <div style={{
          marginTop: 10, padding: "8px 12px", borderRadius: 10, fontSize: 14, fontWeight: 600, textAlign: "center",
          background: message.tone === "warn" ? T.amberLt : T.greenLt, color: message.tone === "warn" ? "#7A4B00" : "#0F5132",
        }}>{message.text}</div>
      ) : null}

      <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 12 }}>
        <button type="button" onClick={scramble} style={{ ...btn(T.amber), padding: "8px 14px", fontSize: 14 }}>{battle ? "Shuffle (monster gets a turn)" : "Shuffle (adds fire)"}</button>
        <button type="button" onClick={() => finish(score, words)} style={{ ...btn(T.slate400), padding: "8px 14px", fontSize: 14 }}>End game</button>
      </div>

      {words.length ? (
        <div style={{ marginTop: 14, fontSize: 13, color: T.slate600, textAlign: "center" }}>
          {words.slice(0, 6).map((w, i) => (
            <span key={i} style={{ display: "inline-block", margin: "2px 6px" }}><b>{w.word.toUpperCase()}</b> {w.points}</span>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

function btn(bg) {
  return { padding: "10px 18px", borderRadius: 10, border: "none", background: bg, color: T.white, fontSize: 15, fontWeight: 700, cursor: "pointer", fontFamily: "inherit" };
}

function Tile({ tile, size, left, top, order, danger, onTap }) {
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
        animation: tile.fresh ? "wwDrop 0.3s ease-out" : fire ? "wwFlicker 0.9s ease-in-out infinite alternate" : "none",
      }}
    >
      <span style={{ fontSize: Math.round(size * (tile.ch.length > 1 ? 0.4 : 0.5)), fontWeight: 700, lineHeight: 1 }}>
        {tile.ch === "QU" ? "Qu" : tile.ch}
      </span>
      <span style={{ position: "absolute", right: 4, bottom: 2, fontSize: Math.max(9, Math.round(size * 0.18)), fontFamily: "inherit", opacity: 0.7 }}>
        {Math.round(value * 10) / 10}
      </span>
      {chosen ? (
        <span style={{ position: "absolute", left: 4, top: 2, fontSize: Math.max(9, Math.round(size * 0.2)), fontWeight: 700, opacity: 0.85 }}>{order + 1}</span>
      ) : null}
    </button>
  );
}

function Bar({ value, max, color, label }) {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, fontWeight: 600, color: T.slate700, marginBottom: 2 }}>
        <span>{label}</span><span>{Math.max(0, value)} / {max}</span>
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
    <div style={{ display: "flex", gap: 10, alignItems: "center", padding: 10, marginBottom: 10, borderRadius: 12, background: T.white, border: `1px solid ${T.slate200}` }}>
      <DoneDancerStyles />
      {hero ? (
        <div key={`h-${battle.hp}`} style={{ flexShrink: 0, animation: battle.hurt ? "wwHit 0.35s" : "none" }}>
          <span className="nw-bop" style={{ display: "inline-block", lineHeight: 0 }}><CritterIcon which={hero.key} size={64} /></span>
        </div>
      ) : null}
      <style>{"@keyframes wwHit{0%{transform:translateX(0)}25%{transform:translateX(-6px)}50%{transform:translateX(6px)}75%{transform:translateX(-3px)}100%{transform:none}}"}</style>
      <div key={`${battle.stage}-${battle.mhp}`} style={{ flexShrink: 0, animation: battle.mhp < m.hp ? "wwHit 0.35s" : "none" }}>
        <Monster m={m} size={72} />
      </div>
      <div style={{ flex: 1, minWidth: 0, display: "grid", gap: 8 }}>
        <Bar value={battle.mhp} max={m.hp} color={T.red} label={m.name} />
        <div key={`hp-${battle.hp}`} style={{ animation: battle.hurt ? "wwHit 0.35s" : "none" }}>
          <Bar value={battle.hp} max={HERO_HP} color={T.green} label={hero ? `You · ${hero.label}` : "You"} />
        </div>
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
        <g fill={c} opacity="0.75" stroke="#2D2F26" strokeWidth="2">
          <path d="M28 50 L4 26 L10 58 Z" /><path d="M72 50 L96 26 L90 58 Z" />
        </g>
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
