import { useCallback, useEffect, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";
import { OPS, MAX_LEVEL, ri, shuffle, fmt, tidy, makeProblem, makeMissing, choicesFor, ask, reveal, startLevelFor, defaultOpFor, caveStart, caveDrop, caveGaps } from "../lib/mathProblems.js";
import { PARTS, PART_LINES, CAVE_BLOCKERS, MISSION_WORLDS, missionStars } from "../lib/mathStory.js";
import { tone, noise, notes, playSound, gameBtn as btn, ReadAloud, stopSpeaking } from "../lib/gameKit.jsx";

// =========================================================================
// MathBlast.jsx — Family game, after Math Blaster ("In Search of Spot").
// Missions: Grumbolt the Junk King has taken Sprocket the robot pup. Each of
// eight worlds is a mission in four parts, with a read-aloud story between:
//   1 Asteroid Blast  — asteroids carry answers; blast the right one (10 to clear)
//   2 Fuel Recycler   — fill in the missing number, sign or pattern piece (8)
//   3 Cave Flight     — fly through the opening your number fits in; drips change
//                       your number; answer a problem for the tool past a blocker (8 walls)
//   4 Saucer Chase    — pick the right answer before time runs out (6 hits)
// Free play is the asteroid game alone, for as long as your shields last.
// Difficulty adjusts itself to keep a player getting about 85 of every 100 right,
// the rate at which practice builds skill fastest (Wilson et al. 2019, Nature
// Communications 10:4646). Each miss shows the right answer at once, since
// feedback right away is what fixes a wrong fact (Hattie & Timperley 2007).
// Each kid's level for each kind of problem, open worlds and stars are saved.
// Who sees it: parents and the family login (nav gate).
// =========================================================================

const LANES = 4;
const START_SHIELDS = 3;
const CAVE_BLOCK_AT = [2, 5]; // walls with something in the way

// Sounds (made up with WebAudio; muted by the same switch as the other games).
const SFX = {
  zap: (ctx, t) => tone(ctx, "square", 1200, 300, t, 0.15, 0.05),
  boom: (ctx, t) => { noise(ctx, t, 0.3, 1500, 120, 0.25); tone(ctx, "sine", 140, 40, t, 0.3, 0.2); },
  wrong: (ctx, t) => { tone(ctx, "sawtooth", 220, 110, t, 0.25, 0.07); },
  fuel: (ctx, t, n = 1) => { const f = 330 * 2 ** (Math.min(n, 10) * 2 / 12); notes(ctx, t, [f, f * 1.25], "sine", 0.06, 0.06); },
  whoosh: (ctx, t) => noise(ctx, t, 0.35, 400, 3000, 0.12),
  bump: (ctx, t) => { noise(ctx, t, 0.15, 600, 150, 0.25); tone(ctx, "sine", 120, 60, t, 0.2, 0.15); },
  win: (ctx, t) => notes(ctx, t, [523, 659, 784, 1047, 784, 1047], "triangle", 0.12, 0.08),
  lose: (ctx, t) => { tone(ctx, "sine", 392, 330, t, 0.2, 0.08); tone(ctx, "sine", 294, 196, t + 0.2, 0.4, 0.08); },
  tool: (ctx, t) => notes(ctx, t, [880, 1175, 1568], "triangle", 0.07, 0.06),
};
const sound = (name, arg) => playSound(SFX, name, arg);

// Seconds for an asteroid to fall the whole way. Bigger numbers get more time; it speeds up as you get them right.
function fallSecondsFor(level, correct, age) {
  const base = level <= 3 ? 11 : level <= 5 ? 12 : level <= 7 ? 14 : 16;
  const young = age != null && age < 7 ? 1.3 : 1;
  return base * young * Math.max(0.6, 1 - 0.015 * correct);
}
// Seconds to answer in the Saucer Chase.
const chaseSecondsFor = (level, age) => (level <= 3 ? 10 : level <= 6 ? 12 : 15) * (age != null && age < 7 ? 1.3 : 1);

// Fixed star field, drawn once.
const STARS = Array.from({ length: 60 }, (_, i) => ({ x: (i * 37.7) % 100, y: (i * 61.3) % 100, r: (i % 3) * 0.5 + 0.6, o: 0.35 + (i % 5) * 0.12 }));
const FREE_SKY = ["#2B3A67", "#0B0E1F"];

// Guest progress, kept until the page closes.
const GUEST = { unlocked: 1, stars: {} };

export default function MathBlast() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const { players, loading, error, reload } = useFamilyPlayers("mathblast");

  const [playerId, setPlayerId] = useState(null);
  const [op, setOp] = useState("add");
  const [screen, setScreen] = useState("setup"); // setup | map | story | blast | recycle | cave | boss | retry | over
  const [, setFrame] = useState(0);
  const [result, setResult] = useState(null);
  const [typed, setTyped] = useState("");
  const typedRef = useRef("");
  const [paused, setPaused] = useState(false);
  const [story, setStory] = useState(null);   // { title, text, button, next }
  const [step, setStep] = useState(null);     // the turn-by-turn parts: recycler, cave, chase
  const [guestTick, setGuestTick] = useState(0);
  const stepRef = useRef(null);
  stepRef.current = step;
  const g = useRef(null);       // the asteroid game
  const prog = useRef(null);    // level and score for this game: { level, topLevel, window, correct, answered, score, misses, age, kidId, op }
  const mission = useRef(null); // { world, part } while on a mission; null in free play
  const raf = useRef(0);
  const last = useRef(0);
  const timers = useRef([]);

  const player = players.find(p => p.id === playerId) || null;
  const unlocked = Math.min(MISSION_WORLDS.length, Math.max(1, Number(player ? player.bests?.unlocked?.mission : GUEST.unlocked) || 1));
  const starsOf = w => Number((player ? player.bests?.stars : GUEST.stars)?.[`m:${w + 1}`]) || 0;
  void guestTick;

  // Start on Guest; choosing a kid picks the kind of problem for their age.
  useEffect(() => { if (!loading && playerId === null) setPlayerId(""); }, [loading, playerId]);
  const choosePlayer = id => { setPlayerId(id); setOp(defaultOpFor(players.find(p => p.id === id))); };

  const later = (fn, ms) => { const t = setTimeout(fn, ms); timers.current.push(t); };
  const clearTimers = () => { timers.current.forEach(clearTimeout); timers.current = []; };
  const stopAll = () => { clearTimers(); cancelAnimationFrame(raf.current); if (g.current) g.current.over = true; };
  const rerender = () => setFrame(f => (f + 1) % 1000000);

  // One answer counted: adjust the level to hold about 85 of every 100 right.
  const tally = right => {
    const p = prog.current;
    p.answered += 1;
    if (right) p.correct += 1; else p.misses += 1;
    p.window.push(right ? 1 : 0);
    if (p.window.length > 8) p.window.shift();
    const got = p.window.reduce((a, b) => a + b, 0);
    let toast = null;
    if (p.window.length >= 8 && got >= 7 && p.level < MAX_LEVEL) {
      p.level += 1; p.topLevel = Math.max(p.topLevel, p.level); p.window = []; toast = `Level ${p.level}!`;
    } else if (p.window.length >= 6 && p.window.slice(-6).reduce((a, b) => a + b, 0) <= 3 && p.level > 1) {
      p.level -= 1; p.window = []; toast = "Slowing down a little";
    }
    if (toast && g.current && !g.current.over) g.current.toast = { text: toast, until: performance.now() + 1400 };
    return toast;
  };
  const points = (right, quick = 0) => {
    const p = prog.current;
    const base = 10 + 5 * (p.level - 1);
    return right ? base + Math.round(base * quick) : 0;
  };

  // ── Saving ────────────────────────────────────────────────────────────
  const save = async (extra) => {
    const p = prog.current;
    const detail = { op: p.op, level: p.level, correct: p.correct, answered: p.answered, top_level: p.topLevel, ...extra };
    if (!p.kidId) return { saved: null };
    const r = await recordFamilyGame(p.kidId, "mathblast", p.score, detail);
    reload();
    return r;
  };

  const finishFree = useCallback(async () => {
    const s = g.current; if (!s || s.over) return;
    stopAll();
    const p = prog.current;
    const summary = { free: true, score: p.score, correct: p.correct, answered: p.answered, topLevel: p.topLevel, op: p.op, saved: null, isBest: false };
    setResult(summary);
    setScreen("over");
    sound("lose");
    if (p.kidId) { const r = await save({}); setResult({ ...summary, saved: r.saved, isBest: r.isBest, best: r.bests?.best }); }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const finishMission = async () => {
    stopAll();
    const w = mission.current.world;
    const p = prog.current;
    const stars = missionStars(p.misses);
    const summary = { free: false, world: w, stars, score: p.score, correct: p.correct, answered: p.answered, misses: p.misses, topLevel: p.topLevel, op: p.op, saved: null };
    setResult(summary);
    sound("win");
    const nextOpen = Math.min(MISSION_WORLDS.length, w + 2);
    setStory({
      title: `World ${w + 1}: ${MISSION_WORLDS[w].name} · Mission complete`, world: w, kind: "outro",
      text: MISSION_WORLDS[w].outro, button: "See my stars", next: () => setScreen("over"),
    });
    setScreen("story");
    if (!p.kidId) {
      GUEST.unlocked = Math.max(GUEST.unlocked, nextOpen);
      GUEST.stars[`m:${w + 1}`] = Math.max(GUEST.stars[`m:${w + 1}`] || 0, stars);
      setGuestTick(t => t + 1);
      return;
    }
    const r = await save({ mission: w + 1, won: true, unlock_key: "mission", unlock: nextOpen, stars_key: `m:${w + 1}`, stars });
    setResult(x => ({ ...x, saved: r.saved, isBest: r.isBest }));
  };

  // ── Flow between parts ────────────────────────────────────────────────
  const newProg = () => {
    const lv = startLevelFor(player, op);
    prog.current = { op, level: lv, topLevel: lv, window: [], correct: 0, answered: 0, score: 0, misses: 0, age: player?.age ?? null, kidId: player?.id || null };
  };
  const startPart = part => {
    stopAll();
    setStep(null);
    mission.current.part = part;
    if (part === 0) startBlast(PARTS[0].goal);
    else if (part === 1) startRecycle();
    else if (part === 2) startCave();
    else startChase();
  };
  const partDone = () => {
    stopAll();
    const m = mission.current;
    if (!m) return;
    sound("win");
    if (m.part >= PARTS.length - 1) { finishMission(); return; }
    setStory({ title: `${PARTS[m.part].name} cleared! Next: ${PARTS[m.part + 1].name}`, world: m.world, kind: "part", text: PART_LINES[m.part], button: `Go to ${PARTS[m.part + 1].name}`, next: () => startPart(m.part + 1) });
    setScreen("story");
  };
  const partFailed = () => {
    stopAll();
    sound("lose");
    setScreen("retry");
  };
  const startMission = w => {
    newProg();
    mission.current = { world: w, part: 0 };
    setResult(null);
    const first = w === 0 && unlocked === 1;
    setStory({
      title: `World ${w + 1}: ${MISSION_WORLDS[w].name}`, world: w, kind: "intro",
      text: MISSION_WORLDS[w].intro, button: first ? "Start the mission" : "Launch", next: () => startPart(0),
    });
    setScreen("story");
  };
  const startFree = () => {
    newProg();
    mission.current = null;
    setResult(null);
    startBlast(0);
  };

  // ── Part 1: Asteroid Blast ────────────────────────────────────────────
  const nextRocks = useCallback(() => {
    const s = g.current; if (!s || s.over) return;
    const p = prog.current;
    const pr = makeProblem(p.op, p.level);
    const vals = choicesFor(pr, LANES);
    const stagger = shuffle([0, 0.05, 0.1, 0.15]);
    s.problem = pr;
    s.rocks = vals.map((v, i) => ({ id: `${s.total}-${i}`, value: v, lane: i, y: -0.12 - stagger[i], state: "fall", spin: ri(0, 359) }));
    s.locked = false;
    s.fallMs = fallSecondsFor(p.level, p.correct, p.age) * 1000;
    s.total += 1;
  }, []);

  const loseShield = (s) => {
    s.shields -= 1; s.streak = 0; s.shake = performance.now() + 350;
    sound("wrong");
    if (s.shields <= 0) later(() => (mission.current ? partFailed() : finishFree()), 1300);
  };
  const showRight = s => { s.flash = reveal(s.problem); };

  const fire = useCallback((rock) => {
    const s = g.current; if (!s || s.locked || s.over || s.paused || !rock || rock.state !== "fall") return;
    s.locked = true;
    s.laser = { lane: rock.lane, y: rock.y, until: performance.now() + 200 };
    sound("zap");
    if (tidy(rock.value) === tidy(s.problem.answer)) {
      rock.state = "hit";
      s.streak += 1; s.cleared += 1;
      const mult = Math.min(4, 1 + Math.floor(s.streak / 5));
      prog.current.score += points(true, Math.max(0, 1 - Math.max(0, rock.y))) * mult;
      later(() => sound("boom"), 90);
      if (s.streak % 10 === 0 && s.shields < START_SHIELDS) { s.shields += 1; s.toast = { text: "Shield back!", until: performance.now() + 1200 }; }
      tally(true);
      s.flash = null;
      if (s.goal && s.cleared >= s.goal) { later(partDone, 700); return; }
      later(nextRocks, 450);
    } else {
      rock.state = "wrong";
      s.rocks.forEach(r => { if (tidy(r.value) === tidy(s.problem.answer)) r.state = "show"; });
      showRight(s);
      tally(false);
      loseShield(s);
      if (s.shields > 0) later(() => { if (g.current) g.current.flash = null; nextRocks(); }, 1500);
    }
    typedRef.current = ""; setTyped("");
  }, [nextRocks]); // eslint-disable-line react-hooks/exhaustive-deps

  const loop = useCallback((now) => {
    const s = g.current; if (!s || s.over) return;
    const dt = Math.min(64, now - (last.current || now));
    last.current = now;
    if (!s.paused) {
      for (const r of s.rocks) {
        if (r.state === "fall" || r.state === "show") r.y += dt / s.fallMs;
      }
      if (!s.locked) {
        const right = s.rocks.find(r => tidy(r.value) === tidy(s.problem.answer));
        if (right && right.y >= 1) {
          s.locked = true;
          right.state = "show";
          showRight(s);
          tally(false);
          loseShield(s);
          if (s.shields > 0) later(() => { if (g.current) g.current.flash = null; nextRocks(); }, 1500);
        }
      }
    }
    rerender();
    raf.current = requestAnimationFrame(loop);
  }, [nextRocks]); // eslint-disable-line react-hooks/exhaustive-deps

  const startBlast = goal => {
    stopAll();
    const lv = prog.current.level;
    g.current = {
      goal, cleared: 0, shields: START_SHIELDS, streak: 0, total: 0,
      rocks: [], problem: null, locked: true, over: false, paused: false,
      flash: null, toast: { text: goal ? `Blast ${goal} asteroids!` : `Level ${lv}`, until: performance.now() + 1400 }, laser: null, shake: 0,
    };
    typedRef.current = ""; setTyped(""); setPaused(false);
    setScreen("blast");
    nextRocks();
    last.current = 0;
    raf.current = requestAnimationFrame(loop);
  };

  const togglePause = useCallback(() => {
    const s = g.current; if (!s || s.over) return;
    s.paused = !s.paused; setPaused(s.paused);
  }, []);

  // ── Part 2: Fuel Recycler ─────────────────────────────────────────────
  const recycleProblem = () => { const p = prog.current; const pr = makeMissing(p.op, p.level); return { problem: pr, choices: choicesFor(pr) }; };
  const startRecycle = () => {
    setStep({ kind: "recycle", filled: 0, ...recycleProblem(), picked: null });
    setScreen("recycle");
  };
  const pickRecycle = v => {
    if (!step || step.picked != null) return;
    const right = v === step.problem.answer || (typeof v === "number" && tidy(v) === tidy(step.problem.answer));
    tally(right);
    if (right) {
      prog.current.score += points(true, 0.5);
      const filled = step.filled + 1;
      sound("fuel", filled);
      setStep({ ...step, picked: v, right: true, filled });
      if (filled >= PARTS[1].goal) { later(partDone, 700); return; }
      later(() => setStep(st => ({ ...st, ...recycleProblem(), picked: null })), 600);
    } else {
      sound("wrong");
      setStep({ ...step, picked: v, right: false });
      later(() => setStep(st => ({ ...st, ...recycleProblem(), picked: null })), 1700);
    }
  };

  // ── Part 3: Cave Flight ───────────────────────────────────────────────
  const caveWall = (n, wall) => {
    const lv = Math.min(MAX_LEVEL, prog.current.level);
    const drop = wall > 0 && Math.random() < 0.6 ? caveDrop(n, lv) : null;
    const target = drop ? drop.value : n;
    const blocker = CAVE_BLOCK_AT.includes(wall) ? CAVE_BLOCKERS[(mission.current.world + CAVE_BLOCK_AT.indexOf(wall)) % CAVE_BLOCKERS.length] : null;
    const bp = blocker ? makeProblem(prog.current.op, prog.current.level) : null;
    return { n, wall, drop, target, ...caveGaps(target, lv), blocker, bp, bChoices: bp ? choicesFor(bp) : null, cleared: !blocker, picked: null };
  };
  const startCave = () => {
    const n = caveStart(Math.min(MAX_LEVEL, prog.current.level));
    setStep({ kind: "cave", shields: START_SHIELDS, ...caveWall(n, 0) });
    setScreen("cave");
  };
  const pickBlocker = v => {
    if (!step || step.cleared || step.picked != null) return;
    const right = tidy(v) === tidy(step.bp.answer);
    tally(right);
    if (right) { sound("tool"); prog.current.score += points(true, 0.5); setStep({ ...step, cleared: true, toolMsg: `You got the ${step.blocker.tool}! ${step.blocker.toolIcon}` }); return; }
    sound("wrong");
    setStep({ ...step, picked: v });
    later(() => setStep(st => { const bp = makeProblem(prog.current.op, prog.current.level); return { ...st, bp, bChoices: choicesFor(bp), picked: null }; }), 1700);
  };
  const pickGap = i => {
    if (!step || !step.cleared || step.picked != null) return;
    if (i === step.right) {
      sound("whoosh");
      prog.current.score += points(true, 0.3);
      prog.current.correct += 1; prog.current.answered += 1;
      const wall = step.wall + 1;
      setStep({ ...step, picked: i });
      if (wall >= PARTS[2].goal) { later(partDone, 600); return; }
      later(() => setStep(st => ({ kind: "cave", shields: st.shields, ...caveWall(st.target, wall) })), 550);
      return;
    }
    sound("bump");
    prog.current.misses += 1; prog.current.answered += 1;
    const shields = step.shields - 1;
    setStep({ ...step, picked: i, shields });
    if (shields <= 0) { later(partFailed, 1500); return; }
    later(() => setStep(st => ({ ...st, picked: null })), 1500);
  };

  // ── Part 4: Saucer Chase ──────────────────────────────────────────────
  const chaseProblem = () => {
    const p = prog.current;
    const pr = makeProblem(p.op, p.level);
    return { problem: pr, choices: choicesFor(pr), until: performance.now() + chaseSecondsFor(p.level, p.age) * 1000, picked: null };
  };
  const startChase = () => {
    setStep({ kind: "boss", shields: START_SHIELDS, hits: 0, ...chaseProblem() });
    setScreen("boss");
  };
  const chaseAnswer = (v, timeUp) => {
    const st = stepRef.current;
    if (!st || st.kind !== "boss" || st.picked != null) return;
    const right = !timeUp && tidy(v) === tidy(st.problem.answer);
    tally(right);
    let next;
    if (right) {
      sound("zap"); later(() => sound("boom"), 120);
      prog.current.score += points(true, Math.max(0, (st.until - performance.now()) / (chaseSecondsFor(prog.current.level, prog.current.age) * 1000))) * 2;
      next = { ...st, picked: v, right: true, hits: st.hits + 1 };
      if (next.hits >= PARTS[3].goal) later(partDone, 800);
      else later(() => setStep(s2 => ({ ...s2, ...chaseProblem() })), 650);
    } else {
      sound("wrong");
      next = { ...st, picked: timeUp ? "time" : v, right: false, shields: st.shields - 1 };
      if (next.shields <= 0) later(partFailed, 1600);
      else later(() => setStep(s2 => ({ ...s2, ...chaseProblem() })), 1600);
    }
    stepRef.current = next;
    setStep(next);
  };
  // The chase clock: time running out counts as a miss.
  useEffect(() => {
    if (screen !== "boss") return undefined;
    const id = setInterval(() => {
      const st = stepRef.current;
      if (st && st.kind === "boss" && st.picked == null && performance.now() >= st.until) chaseAnswer(null, true);
      rerender();
    }, 100);
    return () => clearInterval(id);
  }, [screen]); // eslint-disable-line react-hooks/exhaustive-deps

  // Stop on leaving the page; pause when the tab is hidden.
  useEffect(() => () => { cancelAnimationFrame(raf.current); clearTimers(); stopSpeaking(); }, []);
  useEffect(() => {
    const onVis = () => { const s = g.current; if (document.hidden && s && !s.over && !s.paused) { s.paused = true; setPaused(true); } };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

  // Typing: digits build an answer, Enter fires at the asteroid with that number.
  useEffect(() => {
    if (screen !== "blast") return undefined;
    const onKey = e => {
      const s = g.current; if (!s || s.over) return;
      if (e.key === "p" || e.key === "P" || e.key === "Escape") { togglePause(); return; }
      if (/^[0-9.]$/.test(e.key)) { typedRef.current = (typedRef.current + e.key).slice(0, 8); setTyped(typedRef.current); return; }
      if (e.key === "Backspace") { typedRef.current = typedRef.current.slice(0, -1); setTyped(typedRef.current); return; }
      if (e.key === "Enter" && typedRef.current) {
        const n = Number(typedRef.current);
        typedRef.current = ""; setTyped("");
        // A number on an asteroid fires at it; a number that isn't on any asteroid is ignored.
        const rock = s.rocks.find(r => r.state === "fall" && tidy(r.value) === tidy(n));
        if (rock) fire(rock);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [screen, fire, togglePause]);

  // ── Screens ───────────────────────────────────────────────────────────
  const page = children => <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>{children}</div>;
  const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 16 };
  const header = (
    <div style={{ marginBottom: 12 }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>Math Blast</div>
      <div style={{ fontSize: 13, color: T.slate500 }}>Rescue Sprocket the robot pup from Grumbolt the Junk King.</div>
    </div>
  );
  const opLabel = id => OPS.find(o => o.id === id)?.label || "";
  const who = (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, marginBottom: 10, flexWrap: "wrap" }}>
      <div style={{ fontSize: 14, color: T.slate700 }}><b>{player ? player.name : "Guest"}</b> · {opLabel(op)} · level {startLevelFor(player, op)}</div>
      <button type="button" onClick={() => setScreen("setup")} style={{ ...btn(T.slate400), padding: "6px 12px", fontSize: 13 }}>Change</button>
    </div>
  );

  if (screen === "setup") {
    return page(<>
      {header}
      {error ? <div style={{ color: T.red, fontSize: 13, marginBottom: 8 }}>{error}</div> : null}
      <div style={{ ...card, display: "grid", gap: 16 }}>
        <div>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>Who's playing?</div>
          {loading ? <div style={{ color: T.slate400, fontSize: 13 }}>Loading…</div> : <PlayerPicker players={players} value={playerId ?? ""} onChange={choosePlayer} />}
        </div>
        <div>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>What kind of math?</div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(96px, 1fr))", gap: 8 }}>
            {OPS.map(o => {
              const on = op === o.id;
              return (
                <button key={o.id} type="button" onClick={() => setOp(o.id)} style={{
                  padding: "10px 6px", borderRadius: 12, cursor: "pointer", fontFamily: "inherit",
                  border: `2px solid ${on ? T.purple : T.slate300}`, background: on ? T.purple : T.white, color: on ? T.white : T.slate800,
                }}>
                  <div style={{ fontSize: 22, fontWeight: 700, lineHeight: 1 }}>{o.sym}</div>
                  <div style={{ fontSize: 13, fontWeight: 600, marginTop: 4 }}>{o.label}</div>
                  <div style={{ fontSize: 11, opacity: 0.8 }}>Level {startLevelFor(player, o.id)}</div>
                </button>
              );
            })}
          </div>
        </div>
        <button type="button" onClick={() => setScreen("map")} style={{ ...btn(T.blue), padding: "14px 18px", fontSize: 18 }}>🚀 Missions</button>
        <button type="button" onClick={startFree} style={{ ...btn(T.slate600), padding: "10px 18px" }}>Free play · asteroids only</button>
      </div>
    </>);
  }

  if (screen === "map") {
    return page(<>
      {header}
      {who}
      <div style={{ display: "grid", gap: 8 }}>
        {MISSION_WORLDS.map((w, i) => {
          const open = i < unlocked;
          const st = starsOf(i);
          return (
            <button key={w.name} type="button" disabled={!open} onClick={() => startMission(i)} style={{
              display: "flex", alignItems: "center", gap: 12, padding: 10, borderRadius: 14, textAlign: "left", fontFamily: "inherit",
              cursor: open ? "pointer" : "default", border: `2px solid ${open ? (st ? T.green : T.blue) : T.slate200}`,
              background: open ? `linear-gradient(90deg, ${w.sky[0]}, ${w.sky[1]})` : T.slate100,
            }}>
              <svg viewBox="0 0 48 48" width="48" height="48" aria-hidden="true" style={{ flexShrink: 0, opacity: open ? 1 : 0.4 }}>
                <circle cx="24" cy="24" r="15" fill={open ? w.planet : T.slate300} />
                {w.ring ? <ellipse cx="24" cy="25" rx="22" ry="6" fill="none" stroke={open ? w.ring : T.slate300} strokeWidth="3" /> : null}
              </svg>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 15, fontWeight: 800, color: open ? "#fff" : T.slate400 }}>{open ? `${i + 1}. ${w.name}` : `${i + 1}. 🔒 Locked`}</div>
                {open ? <div style={{ fontSize: 14, color: "#FFE680", letterSpacing: 1 }}>{[0, 1, 2].map(k => (k < st ? "★" : "☆")).join("")}</div> : null}
              </div>
            </button>
          );
        })}
      </div>
    </>);
  }

  if (screen === "story" && story) {
    return page(<>
      {header}
      <div style={{ borderRadius: 16, overflow: "hidden", border: `1px solid ${T.slate200}`, background: T.white }}>
        <SpaceScene world={MISSION_WORLDS[story.world]} kind={story.kind} title={story.title} />
        <ReadAloud key={story.title} text={story.text} button={story.button} onDone={story.next} />
      </div>
    </>);
  }

  if (screen === "retry") {
    const m = mission.current;
    return page(<>
      {header}
      <div style={{ ...card, textAlign: "center", display: "grid", gap: 12 }}>
        <div style={{ fontSize: 40 }}>🛡️</div>
        <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Out of shields!</div>
        <div style={{ fontSize: 15, color: T.slate600 }}>Captain Vega patched up your ship. Try the {PARTS[m?.part || 0].name} again.</div>
        <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap" }}>
          <button type="button" onClick={() => startPart(m.part)} style={btn(T.blue)}>Try again</button>
          <button type="button" onClick={() => setScreen("map")} style={btn(T.slate600)}>Back to the map</button>
        </div>
      </div>
    </>);
  }

  if (screen === "over" && result) {
    return page(<>
      {header}
      <div style={{ ...card, padding: 20, textAlign: "center", display: "grid", gap: 10 }}>
        <div style={{ fontSize: 15, color: T.slate500 }}>{player ? player.name : "Guest"} · {opLabel(result.op)}{result.free ? " · free play" : ` · World ${result.world + 1}`}</div>
        {!result.free ? <div style={{ fontSize: 40, color: "#E2B13C", letterSpacing: 4 }}>{[0, 1, 2].map(k => (k < result.stars ? "★" : "☆")).join("")}</div> : null}
        <div style={{ fontSize: 44, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
        {result.isBest ? <div style={{ fontSize: 16, fontWeight: 700, color: T.gold }}>New best score!</div> : null}
        <div style={{ fontSize: 15, color: T.slate700 }}>{result.correct} right out of {result.answered} · reached level {result.topLevel}</div>
        {!result.free && result.stars < 3 ? <div style={{ fontSize: 13, color: T.slate500 }}>Fewer misses earn more stars: 2 or fewer for ★★★.</div> : null}
        {player && result.saved === false ? <div style={{ fontSize: 13, color: T.red }}>Couldn't save this game.</div> : null}
        {player && result.free && result.best != null && !result.isBest ? <div style={{ fontSize: 13, color: T.slate500 }}>Best: {Number(result.best).toLocaleString()}</div> : null}
        <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 6 }}>
          {result.free ? <button type="button" onClick={startFree} style={btn(T.blue)}>Play again</button> : null}
          {!result.free && result.world + 1 < MISSION_WORLDS.length ? <button type="button" onClick={() => startMission(result.world + 1)} style={btn(T.blue)}>Next mission</button> : null}
          {!result.free ? <button type="button" onClick={() => setScreen("map")} style={btn(T.teal)}>Map</button> : null}
          <button type="button" onClick={() => setScreen("setup")} style={btn(T.slate600)}>Change player</button>
        </div>
      </div>
    </>);
  }

  const p = prog.current;
  const m = mission.current;
  const sky = m ? MISSION_WORLDS[m.world].sky : FREE_SKY;
  const fieldH = _vp.isPhone ? 440 : 520;
  const now = performance.now();
  const topBar = (right) => (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 8 }}>
      <div style={{ fontSize: 15, fontWeight: 700, color: T.slate800 }}>{p ? p.score.toLocaleString() : 0} pts</div>
      <div style={{ fontSize: 13, color: T.slate600 }}>{m ? `World ${m.world + 1} · ${PARTS[m.part].name}` : "Free play"} · level {p?.level}</div>
      <div style={{ display: "flex", gap: 4, alignItems: "center" }}>{right}</div>
    </div>
  );
  const shieldsRow = n => Array.from({ length: START_SHIELDS }, (_, i) => <Shield key={i} on={i < n} />);
  const field = (children, extra = {}) => (
    <div style={{
      position: "relative", height: fieldH, borderRadius: 16, overflow: "hidden", userSelect: "none", touchAction: "manipulation",
      background: `radial-gradient(ellipse at 50% 120%, ${sky[0]} 0%, ${sky[1]} 70%)`, ...extra,
    }}>
      <svg width="100%" height="100%" style={{ position: "absolute", inset: 0 }} aria-hidden="true">
        {STARS.map((st, i) => <circle key={i} cx={`${st.x}%`} cy={`${st.y}%`} r={st.r} fill="#fff" opacity={st.o} />)}
      </svg>
      {children}
    </div>
  );
  const banner = text => (
    <div style={{ position: "absolute", top: 10, left: 8, right: 8, textAlign: "center", zIndex: 3, pointerEvents: "none" }}>
      <span style={{ display: "inline-block", padding: "8px 16px", borderRadius: 12, background: "rgba(255,255,255,0.94)", color: T.slate900, fontSize: _vp.isPhone ? 22 : 28, fontWeight: 800 }}>{text}</span>
    </div>
  );
  const goalBar = (n, goal, label) => (
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8, fontSize: 12, color: T.slate600 }}>
      <span style={{ flexShrink: 0 }}>{label}</span>
      <div style={{ flex: 1, height: 10, background: T.slate200, borderRadius: 999, overflow: "hidden" }}>
        <div style={{ width: `${Math.min(100, (n / goal) * 100)}%`, height: "100%", background: T.teal, transition: "width 0.3s" }} />
      </div>
      <span style={{ flexShrink: 0, fontWeight: 700 }}>{n}/{goal}</span>
    </div>
  );
  const answerButtons = (choices, onPick, picked, answer, right) => (
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
      {choices.map(v => {
        const isPicked = picked != null && picked === v;
        const isAnswer = picked != null && (v === answer || (typeof v === "number" && tidy(v) === tidy(answer)));
        const bg = isAnswer ? "#2E8B57" : isPicked && !right ? "#B84040" : "rgba(255,255,255,0.94)";
        return (
          <button key={String(v)} type="button" onClick={() => onPick(v)} disabled={picked != null} style={{
            padding: "14px 8px", borderRadius: 14, border: "none", fontFamily: "inherit", cursor: picked != null ? "default" : "pointer",
            background: bg, color: isAnswer || (isPicked && !right) ? "#fff" : T.slate900, fontSize: _vp.isPhone ? 24 : 28, fontWeight: 800,
          }}>{fmt(v)}</button>
        );
      })}
    </div>
  );

  // Part 2 screen
  if (screen === "recycle" && step?.kind === "recycle") {
    const pr = step.problem;
    return page(<>
      {topBar(null)}
      {goalBar(step.filled, PARTS[1].goal, "⛽ Fuel")}
      {field(<>
        {banner(ask(pr))}
        <FuelTank level={step.filled / PARTS[1].goal} />
        <div style={{ position: "absolute", left: 12, right: 12, bottom: 12, zIndex: 3 }}>
          {step.picked != null && !step.right ? <div style={{ textAlign: "center", marginBottom: 8 }}><span style={{ padding: "6px 12px", borderRadius: 10, background: "#FFF3CD", color: "#5B4300", fontWeight: 700 }}>{reveal(pr)}</span></div> : null}
          {answerButtons(step.choices, pickRecycle, step.picked, pr.answer, step.right)}
        </div>
      </>)}
      <div style={{ fontSize: 12, color: T.slate400, marginTop: 6, textAlign: "center" }}>{PARTS[1].tip}</div>
    </>);
  }

  // Part 3 screen
  if (screen === "cave" && step?.kind === "cave") {
    const blocked = !step.cleared;
    const order = [2, 1, 0]; // highest opening on top, like a number line going up
    return page(<>
      {topBar(shieldsRow(step.shields))}
      {goalBar(step.wall, PARTS[2].goal, "🕳️ Walls")}
      {field(<>
        <div style={{ position: "absolute", top: 10, left: 10, zIndex: 3, background: "rgba(255,255,255,0.94)", borderRadius: 12, padding: "8px 12px" }}>
          <div style={{ fontSize: 12, color: T.slate600 }}>Your number</div>
          <div style={{ fontSize: 30, fontWeight: 800, color: T.slate900 }}>{fmt(step.n)}{step.drop && !blocked ? <span style={{ fontSize: 18, color: "#3F8DB8" }}> 💧{step.drop.op}</span> : null}</div>
        </div>
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" width="100%" height="100%" style={{ position: "absolute", inset: 0 }} aria-hidden="true">
          <path d="M0 0 H100 V8 Q80 14 60 9 T20 12 T0 8 Z" fill="#4A3A2E" />
          <path d="M0 100 H100 V90 Q75 85 50 92 T0 88 Z" fill="#4A3A2E" />
          <rect x="62" y="12" width="12" height="78" fill="#5C4A3B" />
        </svg>
        {/* the ship */}
        <div style={{ position: "absolute", left: "12%", top: "48%", fontSize: 40, zIndex: 2, transform: step.picked != null && step.picked === step.right ? "translateX(260%)" : "none", transition: "transform 0.5s ease-in" }}>🚀</div>
        {blocked ? (
          <div style={{ position: "absolute", left: 10, right: 10, bottom: 12, zIndex: 3, display: "grid", gap: 8 }}>
            <div style={{ textAlign: "center", background: "rgba(255,255,255,0.94)", borderRadius: 12, padding: 10 }}>
              <div style={{ fontSize: 30 }}>{step.blocker.icon}</div>
              <div style={{ fontSize: 14, color: T.slate700 }}>{step.blocker.what}! Answer to get the {step.blocker.tool} {step.blocker.toolIcon}</div>
              <div style={{ fontSize: _vp.isPhone ? 22 : 26, fontWeight: 800, color: T.slate900 }}>{step.picked != null ? reveal(step.bp) : ask(step.bp)}</div>
            </div>
            {answerButtons(step.bChoices, pickBlocker, step.picked, step.bp.answer, false)}
          </div>
        ) : (
          <div style={{ position: "absolute", right: "18%", top: "14%", bottom: "12%", width: _vp.isPhone ? 130 : 160, zIndex: 3, display: "grid", gridTemplateRows: "1fr 1fr 1fr", gap: 10 }}>
            {order.map(i => {
              const gp = step.gaps[i];
              const isPicked = step.picked === i;
              const good = isPicked && i === step.right;
              const bad = isPicked && i !== step.right;
              return (
                <button key={i} type="button" onClick={() => pickGap(i)} disabled={step.picked != null} style={{
                  borderRadius: 999, border: `3px dashed ${good ? "#7CF5FF" : bad ? "#FF8A80" : "#E8D9B8"}`, fontFamily: "inherit",
                  background: good ? "rgba(124,245,255,0.3)" : bad ? "rgba(184,64,64,0.6)" : "rgba(10,10,10,0.55)", color: "#fff",
                  fontSize: _vp.isPhone ? 17 : 20, fontWeight: 800, cursor: step.picked != null ? "default" : "pointer",
                }}>{fmt(gp.lo)} to {fmt(gp.hi)}</button>
              );
            })}
          </div>
        )}
        {step.toolMsg && !blocked && step.picked == null ? (
          <div style={{ position: "absolute", left: 10, bottom: 12, zIndex: 3, color: "#FFE680", fontWeight: 800 }}>{step.toolMsg}</div>
        ) : null}
        {step.picked != null && step.picked !== step.right && step.cleared ? (
          <div style={{ position: "absolute", left: 10, right: 10, bottom: 12, zIndex: 4, textAlign: "center" }}>
            <span style={{ padding: "6px 12px", borderRadius: 10, background: "#FFF3CD", color: "#5B4300", fontWeight: 700 }}>
              {step.drop ? `${fmt(step.n)} ${step.drop.op} = ${fmt(step.target)}, ` : ""}{fmt(step.target)} fits between {fmt(step.gaps[step.right].lo)} and {fmt(step.gaps[step.right].hi)}
            </span>
          </div>
        ) : null}
      </>)}
      <div style={{ fontSize: 12, color: T.slate400, marginTop: 6, textAlign: "center" }}>{step.drop && !blocked ? "A drip changed your number! Work out your new number first. " : ""}{PARTS[2].tip}</div>
    </>);
  }

  // Part 4 screen
  if (screen === "boss" && step?.kind === "boss") {
    const total = chaseSecondsFor(p.level, p.age) * 1000;
    const left = step.picked == null ? Math.max(0, step.until - now) : 0;
    const pr = step.problem;
    return page(<>
      {topBar(shieldsRow(step.shields))}
      {goalBar(step.hits, PARTS[3].goal, "🛸 Hits")}
      {field(<>
        {banner(ask(pr))}
        <div style={{ position: "absolute", top: 70, left: 0, right: 0, display: "flex", justifyContent: "center", zIndex: 2 }}>
          <Saucer size={_vp.isPhone ? 120 : 150} hit={step.picked != null && step.right} />
        </div>
        <div style={{ position: "absolute", top: _vp.isPhone ? 190 : 225, left: 16, right: 16, height: 8, background: "rgba(255,255,255,0.2)", borderRadius: 999, zIndex: 2 }}>
          <div style={{ width: `${(left / total) * 100}%`, height: "100%", background: left / total < 0.3 ? "#FF8A80" : "#7CF5FF", borderRadius: 999 }} />
        </div>
        <div style={{ position: "absolute", left: 12, right: 12, bottom: 12, zIndex: 3 }}>
          {step.picked != null && !step.right ? <div style={{ textAlign: "center", marginBottom: 8 }}><span style={{ padding: "6px 12px", borderRadius: 10, background: "#FFF3CD", color: "#5B4300", fontWeight: 700 }}>{step.picked === "time" ? "Out of time! " : ""}{reveal(pr)}</span></div> : null}
          {answerButtons(step.choices, v => chaseAnswer(v, false), step.picked, pr.answer, step.right)}
        </div>
      </>)}
      <div style={{ fontSize: 12, color: T.slate400, marginTop: 6, textAlign: "center" }}>{PARTS[3].tip}</div>
    </>);
  }

  // Part 1 / free play screen
  const s = g.current;
  if (screen !== "blast" || !s) return null;
  const rockSize = _vp.isPhone ? 68 : 80;
  const showToast = s.toast && s.toast.until > now;
  const shaking = s.shake > now;
  const laserOn = s.laser && s.laser.until > now;
  const yPct = y => `${Math.max(-12, y * 74)}%`;
  return page(<>
    {topBar(<>
      {shieldsRow(s.shields)}
      <button type="button" onClick={togglePause} style={{ ...btn(T.slate600), padding: "6px 12px", fontSize: 13, marginLeft: 8 }}>{paused ? "Resume" : "Pause"}</button>
    </>)}
    {s.goal ? goalBar(s.cleared, s.goal, "☄️ Blasted") : null}
    {field(<>
      {laserOn ? (
        <svg width="100%" height="100%" style={{ position: "absolute", inset: 0, zIndex: 1 }} aria-hidden="true">
          <line x1="50%" y1="88%" x2={`${((s.laser.lane + 0.5) / LANES) * 100}%`} y2={`${Math.max(-12, s.laser.y * 74) + (rockSize / 2 / fieldH) * 100}%`}
            stroke="#7CF5FF" strokeWidth="4" strokeLinecap="round" />
        </svg>
      ) : null}
      {s.problem ? banner(ask(s.problem)) : null}
      {s.rocks.map(r => <Rock key={r.id} rock={r} lanes={LANES} top={yPct(r.y)} size={rockSize} onTap={() => fire(r)} />)}
      <svg viewBox="0 0 60 50" width="64" height="54" style={{ position: "absolute", left: "50%", bottom: 8, transform: "translateX(-50%)", zIndex: 2 }} aria-hidden="true">
        <path d="M30 2 L40 30 L54 40 L54 46 L36 42 L30 48 L24 42 L6 46 L6 40 L20 30 Z" fill="#DDE4F0" stroke="#8FA0BF" strokeWidth="2" />
        <circle cx="30" cy="22" r="6" fill="#7CF5FF" />
        <path d="M24 44 L30 50 L36 44" fill="#FFB347" />
      </svg>
      {s.flash ? (
        <div style={{ position: "absolute", left: 12, right: 12, bottom: 72, textAlign: "center", zIndex: 4, pointerEvents: "none" }}>
          <span style={{ display: "inline-block", padding: "8px 14px", borderRadius: 10, background: "#FFF3CD", color: "#5B4300", fontSize: 18, fontWeight: 700 }}>{s.flash}</span>
        </div>
      ) : null}
      {showToast ? (
        <div style={{ position: "absolute", top: "40%", left: 0, right: 0, textAlign: "center", zIndex: 4, pointerEvents: "none", color: "#FFE680", fontSize: 28, fontWeight: 800, textShadow: "0 2px 8px #000" }}>{s.toast.text}</div>
      ) : null}
      {paused ? (
        <div onClick={togglePause} style={{ position: "absolute", inset: 0, zIndex: 5, background: "rgba(10,12,30,0.7)", display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 26, fontWeight: 700, cursor: "pointer" }}>Paused · tap to go</div>
      ) : null}
      {typed ? <div style={{ position: "absolute", right: 12, bottom: 14, zIndex: 4, color: "#7CF5FF", fontSize: 22, fontWeight: 800 }}>{typed}</div> : null}
    </>, { transform: shaking ? `translateX(${(Math.random() - 0.5) * 10}px)` : "none" })}
    {!_vp.isPhone ? <div style={{ fontSize: 12, color: T.slate400, marginTop: 6, textAlign: "center" }}>Tap an asteroid, or type the answer and press Enter. P pauses.</div> : null}
  </>);
}

function Shield({ on }) {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
      <path d="M12 2 L20 5 V11 C20 16 16.5 20 12 22 C7.5 20 4 16 4 11 V5 Z" fill={on ? "#4FB3D9" : "none"} stroke={on ? "#2A7FA3" : T.slate300} strokeWidth="2" />
    </svg>
  );
}

function Rock({ rock, lanes, top, size, onTap }) {
  const left = `calc(${((rock.lane + 0.5) / lanes) * 100}% - ${size / 2}px)`;
  const hit = rock.state === "hit";
  const wrong = rock.state === "wrong";
  const show = rock.state === "show";
  const label = fmt(rock.value);
  const digits = label.length;
  const fs = Math.round(size * (digits <= 2 ? 0.42 : digits === 3 ? 0.34 : digits === 4 ? 0.27 : 0.22));
  return (
    <button
      type="button"
      onPointerDown={e => { e.preventDefault(); onTap(); }}
      aria-label={`Answer ${label}`}
      style={{
        position: "absolute", top, left, width: size, height: size, padding: 0, border: "none", background: "none",
        cursor: "pointer", zIndex: 2, transition: hit ? "transform 0.35s, opacity 0.35s" : "none",
        transform: hit ? "scale(1.8)" : wrong ? "translateY(30px) scale(0.8)" : "none",
        opacity: hit ? 0 : wrong ? 0.35 : 1,
      }}
    >
      <svg viewBox="0 0 100 100" width={size} height={size} style={{ position: "absolute", inset: 0 }} aria-hidden="true">
        {show ? <circle cx="50" cy="50" r="49" fill="none" stroke="#FFE680" strokeWidth="5" /> : null}
        <g transform={`rotate(${rock.spin} 50 50)`}>
          <path d="M50 6 L74 12 L92 34 L94 60 L80 84 L54 94 L28 88 L10 68 L8 40 L24 16 Z"
            fill={hit ? "#FFB347" : wrong ? "#B84040" : "#7A6A5C"} stroke="#4E4237" strokeWidth="3" />
          <circle cx="32" cy="34" r="7" fill="#655548" />
          <circle cx="70" cy="66" r="9" fill="#655548" />
          <circle cx="66" cy="28" r="4" fill="#655548" />
        </g>
      </svg>
      <span style={{ position: "relative", color: "#fff", fontWeight: 800, fontSize: fs, textShadow: "0 1px 3px #000", fontFamily: "inherit" }}>{label}</span>
    </button>
  );
}

// Sprocket the robot pup.
function Sprocket({ size = 56 }) {
  return (
    <svg viewBox="0 0 60 60" width={size} height={size} aria-hidden="true">
      <rect x="14" y="22" width="32" height="24" rx="6" fill="#C9D3E3" stroke="#6C7A93" strokeWidth="2" />
      <rect x="18" y="8" width="24" height="18" rx="5" fill="#DDE4F0" stroke="#6C7A93" strokeWidth="2" />
      <path d="M18 10 L12 2 L22 8 Z M42 10 L48 2 L38 8 Z" fill="#8FA0BF" />
      <circle cx="25" cy="16" r="3" fill="#2D2F26" /><circle cx="35" cy="16" r="3" fill="#2D2F26" />
      <circle cx="26" cy="15" r="1" fill="#fff" /><circle cx="36" cy="15" r="1" fill="#fff" />
      <rect x="27" y="20" width="6" height="3" rx="1.5" fill="#FF8A80" />
      <rect x="17" y="44" width="6" height="10" rx="2" fill="#8FA0BF" /><rect x="37" y="44" width="6" height="10" rx="2" fill="#8FA0BF" />
      <path d="M46 30 Q56 24 54 14" fill="none" stroke="#8FA0BF" strokeWidth="3" strokeLinecap="round" />
      <circle cx="54" cy="13" r="3" fill="#7CF5FF" />
    </svg>
  );
}

// Grumbolt's saucer.
function Saucer({ size = 140, hit = false }) {
  return (
    <svg viewBox="0 0 140 80" width={size} height={size * 0.57} aria-hidden="true" style={{ transition: "transform 0.2s", transform: hit ? "rotate(-12deg) scale(0.92)" : "none", animation: "mbBob 1.6s ease-in-out infinite alternate" }}>
      <style>{"@keyframes mbBob { from { transform: translateY(0) } to { transform: translateY(6px) } }"}</style>
      <ellipse cx="70" cy="34" rx="28" ry="22" fill="#9FE3C7" opacity="0.85" stroke="#4F8C70" strokeWidth="2" />
      <circle cx="62" cy="30" r="5" fill="#2D2F26" /><circle cx="78" cy="30" r="5" fill="#2D2F26" />
      <path d="M60 22 L64 16 L68 22 L72 15 L76 22 L80 16" fill="none" stroke="#E2B13C" strokeWidth="3" />
      <ellipse cx="70" cy="50" rx="66" ry="16" fill="#8A8F7A" stroke="#4E523F" strokeWidth="3" />
      <path d="M20 48 L30 52 M50 44 L52 56 M88 44 L90 56 M118 48 L108 52" stroke="#5C604E" strokeWidth="3" />
      {[18, 46, 70, 94, 122].map(x => <circle key={x} cx={x} cy="56" r="4" fill={hit ? "#FF8A80" : "#FFE680"} />)}
      {hit ? <text x="112" y="20" fontSize="22">💥</text> : null}
    </svg>
  );
}

// Story picture: the world's planet in space, with Sprocket or the saucer.
function SpaceScene({ world, kind, title }) {
  return (
    <div style={{ position: "relative", height: 170, background: `linear-gradient(180deg, ${world.sky[1]}, ${world.sky[0]})`, overflow: "hidden" }}>
      <svg width="100%" height="100%" style={{ position: "absolute", inset: 0 }} aria-hidden="true">
        {STARS.slice(0, 40).map((st, i) => <circle key={i} cx={`${st.x}%`} cy={`${st.y}%`} r={st.r} fill="#fff" opacity={st.o} />)}
      </svg>
      <svg viewBox="0 0 120 120" width="130" height="130" style={{ position: "absolute", left: 14, bottom: -24 }} aria-hidden="true">
        <circle cx="60" cy="60" r="44" fill={world.planet} />
        <circle cx="44" cy="46" r="8" fill="#000" opacity="0.12" /><circle cx="74" cy="72" r="11" fill="#000" opacity="0.12" />
        {world.ring ? <ellipse cx="60" cy="62" rx="58" ry="14" fill="none" stroke={world.ring} strokeWidth="5" opacity="0.9" /> : null}
      </svg>
      <div style={{ position: "absolute", right: 18, top: 40 }}>
        {kind === "outro" ? <Sprocket size={84} /> : <Saucer size={150} />}
      </div>
      <div style={{ position: "absolute", left: 12, top: 10, background: "rgba(255,255,255,0.88)", borderRadius: 10, padding: "4px 10px", fontSize: 13, fontWeight: 800, color: T.slate800, maxWidth: "70%" }}>{title}</div>
    </div>
  );
}

// The recycler's fuel tank, filling as you go.
function FuelTank({ level }) {
  return (
    <svg viewBox="0 0 100 100" width="100%" height="58%" preserveAspectRatio="xMidYMid meet" style={{ position: "absolute", left: 0, right: 0, top: 70 }} aria-hidden="true">
      <rect x="34" y="8" width="32" height="70" rx="8" fill="rgba(255,255,255,0.12)" stroke="#DDE4F0" strokeWidth="2" />
      <rect x="36" y={10 + 66 * (1 - level)} width="28" height={66 * level} rx="6" fill="#4FD39B" style={{ transition: "all 0.4s" }} />
      <path d="M44 4 H56 V8 H44 Z" fill="#DDE4F0" />
      {[0.25, 0.5, 0.75].map(f => <line key={f} x1="34" x2="40" y1={10 + 66 * f} y2={10 + 66 * f} stroke="#DDE4F0" strokeWidth="1.5" />)}
      <text x="50" y="92" textAnchor="middle" fontSize="8" fill="#DDE4F0">FUEL</text>
    </svg>
  );
}
