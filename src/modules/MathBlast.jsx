import { useCallback, useEffect, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useFamilyPlayers, recordFamilyGame, PlayerPicker } from "../lib/familyGames.jsx";

// =========================================================================
// MathBlast.jsx — Family game. A math problem sits at the top; four asteroids
// carrying answers fall toward your ship. Tap (or type) the right one to blast it.
// A wrong tap, or the right asteroid reaching the ship, costs a shield; three
// shields, and every 10 in a row earns one back.
// Difficulty adjusts itself to keep a player getting about 85 of every 100 right,
// the rate at which practice builds skill fastest (Wilson et al. 2019, Nature
// Communications 10:4646). Each miss shows the right answer at once, since
// feedback right away is what fixes a wrong fact (Hattie & Timperley 2007).
// Each kid's level for each kind of problem is saved, so the next game starts
// where they left off. Who sees it: parents and the family login (nav gate).
// =========================================================================

const OPS = [
  { id: "add",  label: "Add",      sym: "+" },
  { id: "sub",  label: "Subtract", sym: "−" },
  { id: "mult", label: "Multiply", sym: "×" },
  { id: "div",  label: "Divide",   sym: "÷" },
  { id: "mix",  label: "Mix",      sym: "?" },
];
const MAX_LEVEL = 10;
const LANES = 4;
const START_SHIELDS = 3;

const ri = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
const pick = arr => arr[Math.floor(Math.random() * arr.length)];
const shuffle = arr => { const a = [...arr]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };

// Addition pairs by level. Subtraction runs the same pair backwards, so answers never go below zero.
function addPair(level) {
  switch (level) {
    case 1: return [ri(0, 5), ri(0, 5)];
    case 2: { const a = ri(0, 10); return [a, ri(0, 10 - a)]; }
    case 3: return [ri(2, 12), ri(2, 9)];
    case 4: { const a = ri(10, 89); return [a, ri(1, Math.max(1, 9 - (a % 10)))]; }
    case 5: return [ri(10, 89), ri(2, 9)];
    case 6: { const a = ri(10, 79); return [a, ri(10, 99 - a)]; }
    case 7: return [ri(15, 99), ri(15, 99)];
    case 8: return [ri(100, 899), ri(10, 99)];
    case 9: return [ri(100, 899), ri(100, 899)];
    default: return [ri(1000, 8999), ri(100, 999)];
  }
}
// Multiplication pairs by level. Division runs the same pair backwards (never by zero).
function multPair(level) {
  switch (level) {
    case 1: return [ri(0, 2), ri(0, 10)];
    case 2: return [pick([2, 3, 4, 5, 10]), ri(0, 10)];
    case 3: return [ri(0, 10), ri(0, 10)];
    case 4: return [ri(2, 12), ri(2, 12)];
    case 5: return [ri(6, 12), ri(6, 12)];
    case 6: return [ri(11, 30), ri(2, 9)];
    case 7: return [ri(11, 99), ri(2, 9)];
    case 8: return [ri(11, 25), ri(11, 19)];
    case 9: return [ri(11, 50), ri(11, 50)];
    default: return [ri(100, 999), ri(2, 12)];
  }
}

function makeProblem(op, level) {
  const kind = op === "mix" ? pick(["add", "sub", "mult", "div"]) : op;
  // In Mix, adding and subtracting run two levels ahead of times and divide.
  const lv = op === "mix" && (kind === "add" || kind === "sub") ? Math.min(MAX_LEVEL, level + 2) : level;
  let a, b, answer, sym;
  if (kind === "add") { [a, b] = addPair(lv); answer = a + b; sym = "+"; }
  else if (kind === "sub") { const [x, y] = addPair(lv); a = x + y; b = y; answer = x; sym = "−"; }
  else if (kind === "mult") { [a, b] = multPair(lv); answer = a * b; sym = "×"; }
  else { let [x, y] = multPair(lv); if (x === 0) x = 1; a = x * y; b = x; answer = y; sym = "÷"; }
  return { a, b, sym, answer, text: `${a.toLocaleString()} ${sym} ${b.toLocaleString()}` };
}

// Wrong answers close enough to tempt: off by one or two, off by ten, a digit swap, the other operation.
function choicesFor(p) {
  const ans = p.answer;
  const near = [ans + 1, ans - 1, ans + 2, ans - 2];
  if (ans >= 10) near.push(ans + 10, ans - 10);
  const s = String(ans);
  if (s.length >= 2) near.push(Number(s.slice(0, -2) + s.slice(-1) + s.slice(-2, -1)));
  if (p.sym === "+") near.push(Math.abs(p.a - p.b));
  if (p.sym === "×") near.push(p.a + p.b, ans + p.a, ans - p.a);
  if (p.sym === "−") near.push(p.a + p.b);
  if (p.sym === "÷") near.push(p.a - p.b, ans * 2);
  const pool = shuffle([...new Set(near)].filter(n => Number.isFinite(n) && n >= 0 && n !== ans));
  const out = pool.slice(0, LANES - 1);
  let k = 3;
  while (out.length < LANES - 1) { const n = ans + k; if (!out.includes(n)) out.push(n); k += 1; }
  return shuffle([ans, ...out]);
}

function startLevelFor(player, op) {
  const saved = Number(player?.bests?.levels?.[op]);
  if (Number.isFinite(saved) && saved >= 1) return Math.min(MAX_LEVEL, saved);
  const age = player?.age;
  if (age == null) return 3;
  if (op === "add" || op === "sub") return age <= 6 ? 1 : age === 7 ? 3 : age <= 9 ? 4 : 6;
  if (op === "mult" || op === "div") return age <= 8 ? 1 : age <= 10 ? 3 : 4;
  return age <= 10 ? 2 : age <= 13 ? 4 : 6;
}
function defaultOpFor(player) {
  const age = player?.age;
  if (age == null) return "add";
  if (age < 9) return "add";
  if (age < 13) return "mult";
  return "mix";
}
// Seconds for an asteroid to fall the whole way. Bigger numbers get more time; it speeds up as you get them right.
function fallSecondsFor(level, correct, age) {
  const base = level <= 3 ? 11 : level <= 5 ? 12 : level <= 7 ? 14 : 16;
  const young = age != null && age < 7 ? 1.3 : 1;
  return base * young * Math.max(0.6, 1 - 0.015 * correct);
}

// Fixed star field, drawn once.
const STARS = Array.from({ length: 60 }, (_, i) => ({ x: (i * 37.7) % 100, y: (i * 61.3) % 100, r: (i % 3) * 0.5 + 0.6, o: 0.35 + (i % 5) * 0.12 }));

export default function MathBlast() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const { players, loading, error, reload } = useFamilyPlayers("mathblast");

  const [playerId, setPlayerId] = useState(null);
  const [op, setOp] = useState("add");
  const [screen, setScreen] = useState("setup"); // setup | play | over
  const [, setFrame] = useState(0);
  const [result, setResult] = useState(null);
  const [typed, setTyped] = useState("");
  const typedRef = useRef("");
  const [paused, setPaused] = useState(false);
  const g = useRef(null);
  const raf = useRef(0);
  const last = useRef(0);
  const timers = useRef([]);

  const player = players.find(p => p.id === playerId) || null;

  // Start on Guest; choosing a kid picks the kind of problem for their age.
  useEffect(() => { if (!loading && playerId === null) setPlayerId(""); }, [loading, playerId]);
  const choosePlayer = id => { setPlayerId(id); setOp(defaultOpFor(players.find(p => p.id === id))); };

  const later = (fn, ms) => { const t = setTimeout(fn, ms); timers.current.push(t); };
  const clearTimers = () => { timers.current.forEach(clearTimeout); timers.current = []; };

  const nextProblem = useCallback(() => {
    const s = g.current; if (!s || s.over) return;
    const p = makeProblem(s.op, s.level);
    const vals = choicesFor(p);
    const stagger = shuffle([0, 0.05, 0.1, 0.15]);
    s.problem = p;
    s.rocks = vals.map((v, i) => ({ id: `${s.total}-${i}`, value: v, lane: i, y: -0.12 - stagger[i], state: "fall", spin: ri(0, 359) }));
    s.locked = false;
    s.fallMs = fallSecondsFor(s.level, s.correct, s.age) * 1000;
    s.total += 1;
  }, []);

  const finish = useCallback(async () => {
    const s = g.current; if (!s || s.over) return;
    s.over = true;
    cancelAnimationFrame(raf.current);
    clearTimers();
    const detail = { op: s.op, level: s.level, correct: s.correct, answered: s.answered, top_level: s.topLevel };
    const summary = { score: s.score, correct: s.correct, answered: s.answered, level: s.level, topLevel: s.topLevel, op: s.op, saved: null, isBest: false };
    setResult(summary);
    setScreen("over");
    if (s.kidId) {
      const r = await recordFamilyGame(s.kidId, "mathblast", s.score, detail);
      setResult({ ...summary, saved: r.saved, isBest: r.isBest, best: r.bests?.best });
      reload();
    }
  }, [reload]);

  // One answer counted: adjust the level to hold about 85 of every 100 right.
  const tally = (s, right) => {
    s.answered += 1;
    s.window.push(right ? 1 : 0);
    if (s.window.length > 8) s.window.shift();
    const got = s.window.reduce((a, b) => a + b, 0);
    if (s.window.length >= 8 && got >= 7 && s.level < MAX_LEVEL) {
      s.level += 1; s.topLevel = Math.max(s.topLevel, s.level); s.window = []; s.toast = { text: `Level ${s.level}!`, until: performance.now() + 1400 };
    } else if (s.window.length >= 6 && s.window.slice(-6).reduce((a, b) => a + b, 0) <= 3 && s.level > 1) {
      s.level -= 1; s.window = []; s.toast = { text: "Slowing down a little", until: performance.now() + 1400 };
    }
  };

  const loseShield = (s) => {
    s.shields -= 1; s.streak = 0; s.shake = performance.now() + 350;
    if (s.shields <= 0) later(finish, 1300);
  };

  const fire = useCallback((rock) => {
    const s = g.current; if (!s || s.locked || s.over || s.paused || !rock || rock.state !== "fall") return;
    s.locked = true;
    s.laser = { lane: rock.lane, y: rock.y, until: performance.now() + 200 };
    if (rock.value === s.problem.answer) {
      rock.state = "hit";
      s.streak += 1; s.correct += 1;
      const base = 10 + 5 * (s.level - 1);
      const quick = Math.round(base * Math.max(0, 1 - Math.max(0, rock.y)));
      const mult = Math.min(4, 1 + Math.floor(s.streak / 5));
      s.score += (base + quick) * mult;
      if (s.streak % 10 === 0 && s.shields < START_SHIELDS) { s.shields += 1; s.toast = { text: "Shield back!", until: performance.now() + 1200 }; }
      tally(s, true);
      s.flash = null;
      later(nextProblem, 450);
    } else {
      rock.state = "wrong";
      s.rocks.forEach(r => { if (r.value === s.problem.answer) r.state = "show"; });
      s.flash = `${s.problem.text} = ${s.problem.answer.toLocaleString()}`;
      tally(s, false);
      loseShield(s);
      if (s.shields > 0) later(() => { if (g.current) g.current.flash = null; nextProblem(); }, 1500);
    }
    typedRef.current = ""; setTyped("");
  }, [nextProblem]); // eslint-disable-line react-hooks/exhaustive-deps

  const loop = useCallback((now) => {
    const s = g.current; if (!s || s.over) return;
    const dt = Math.min(64, now - (last.current || now));
    last.current = now;
    if (!s.paused) {
      for (const r of s.rocks) {
        if (r.state === "fall" || r.state === "show") r.y += dt / s.fallMs;
      }
      if (!s.locked) {
        const right = s.rocks.find(r => r.value === s.problem.answer);
        if (right && right.y >= 1) {
          s.locked = true;
          right.state = "show";
          s.flash = `${s.problem.text} = ${s.problem.answer.toLocaleString()}`;
          tally(s, false);
          loseShield(s);
          if (s.shields > 0) later(() => { if (g.current) g.current.flash = null; nextProblem(); }, 1500);
        }
      }
    }
    setFrame(f => (f + 1) % 1000000);
    raf.current = requestAnimationFrame(loop);
  }, [nextProblem]); // eslint-disable-line react-hooks/exhaustive-deps

  const start = () => {
    clearTimers();
    cancelAnimationFrame(raf.current);
    const lv = startLevelFor(player, op);
    g.current = {
      op, level: lv, topLevel: lv, age: player?.age ?? null, kidId: player?.id || null,
      score: 0, shields: START_SHIELDS, streak: 0, correct: 0, answered: 0, total: 0,
      window: [], rocks: [], problem: null, locked: true, over: false, paused: false,
      flash: null, toast: { text: `Level ${lv}`, until: performance.now() + 1200 }, laser: null, shake: 0,
    };
    setResult(null); typedRef.current = ""; setTyped(""); setPaused(false);
    setScreen("play");
    nextProblem();
    last.current = 0;
    raf.current = requestAnimationFrame(loop);
  };

  const togglePause = useCallback(() => {
    const s = g.current; if (!s || s.over) return;
    s.paused = !s.paused; setPaused(s.paused);
  }, []);

  // Stop on leaving the page; pause when the tab is hidden.
  useEffect(() => () => { cancelAnimationFrame(raf.current); clearTimers(); }, []);
  useEffect(() => {
    const onVis = () => { const s = g.current; if (document.hidden && s && !s.over && !s.paused) { s.paused = true; setPaused(true); } };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

  // Typing: digits build an answer, Enter fires at the asteroid with that number.
  useEffect(() => {
    if (screen !== "play") return undefined;
    const onKey = e => {
      const s = g.current; if (!s || s.over) return;
      if (e.key === "p" || e.key === "P" || e.key === "Escape") { togglePause(); return; }
      if (/^[0-9]$/.test(e.key)) { typedRef.current = (typedRef.current + e.key).slice(0, 6); setTyped(typedRef.current); return; }
      if (e.key === "Backspace") { typedRef.current = typedRef.current.slice(0, -1); setTyped(typedRef.current); return; }
      if (e.key === "Enter" && typedRef.current) {
        const n = Number(typedRef.current);
        typedRef.current = ""; setTyped("");
        // A number on an asteroid fires at it; a number that isn't on any asteroid is ignored.
        const rock = s.rocks.find(r => r.state === "fall" && r.value === n);
        if (rock) fire(rock);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [screen, fire, togglePause]);

  const s = g.current;
  const now = performance.now();
  const fieldH = _vp.isPhone ? 440 : 520;
  const rockSize = _vp.isPhone ? 68 : 80;

  const header = (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 12 }}>
      <div>
        <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>Math Blast</div>
        <div style={{ fontSize: 13, color: T.slate500 }}>Blast the asteroid with the right answer.</div>
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
            {loading ? <div style={{ color: T.slate400, fontSize: 13 }}>Loading…</div> : <PlayerPicker players={players} value={playerId ?? ""} onChange={choosePlayer} />}
          </div>
          <div>
            <div style={{ fontSize: 13, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>What kind of math?</div>
            <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              {OPS.map(o => {
                const on = op === o.id;
                const lv = startLevelFor(player, o.id);
                return (
                  <button key={o.id} type="button" onClick={() => setOp(o.id)} style={{
                    minWidth: 92, padding: "10px 12px", borderRadius: 12, cursor: "pointer", fontFamily: "inherit",
                    border: `2px solid ${on ? T.purple : T.slate300}`, background: on ? T.purple : T.white, color: on ? T.white : T.slate800,
                  }}>
                    <div style={{ fontSize: 22, fontWeight: 700, lineHeight: 1 }}>{o.sym}</div>
                    <div style={{ fontSize: 13, fontWeight: 600, marginTop: 4 }}>{o.label}</div>
                    <div style={{ fontSize: 11, opacity: 0.8 }}>Level {lv}</div>
                  </button>
                );
              })}
            </div>
          </div>
          <button type="button" onClick={start} style={{
            padding: "14px 18px", borderRadius: 12, border: "none", background: T.blue, color: T.white,
            fontSize: 18, fontWeight: 700, cursor: "pointer", fontFamily: "inherit",
          }}>Launch</button>
        </div>
      </div>
    );
  }

  if (screen === "over" && result) {
    const opLabel = OPS.find(o => o.id === result.op)?.label || "";
    return (
      <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>
        {header}
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 20, textAlign: "center", display: "grid", gap: 10 }}>
          <div style={{ fontSize: 15, color: T.slate500 }}>{player ? player.name : "Guest"} · {opLabel}</div>
          <div style={{ fontSize: 44, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
          {result.isBest ? <div style={{ fontSize: 16, fontWeight: 700, color: T.gold }}>New best score!</div> : null}
          <div style={{ fontSize: 15, color: T.slate700 }}>{result.correct} right out of {result.answered} · reached level {result.topLevel}</div>
          {player && result.saved === false ? <div style={{ fontSize: 13, color: T.red }}>Couldn't save this score.</div> : null}
          {player && result.best != null && !result.isBest ? <div style={{ fontSize: 13, color: T.slate500 }}>Best: {Number(result.best).toLocaleString()}</div> : null}
          <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap", marginTop: 6 }}>
            <button type="button" onClick={start} style={btn(T.blue)}>Play again</button>
            <button type="button" onClick={() => setScreen("setup")} style={btn(T.slate600)}>Change player</button>
          </div>
        </div>
      </div>
    );
  }

  if (!s) return null;
  const showToast = s.toast && s.toast.until > now;
  const shaking = s.shake > now;
  const laserOn = s.laser && s.laser.until > now;
  const yPct = y => `${Math.max(-12, y * 74)}%`;

  return (
    <div style={{ padding: _pad, maxWidth: 640, margin: "0 auto" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 8 }}>
        <div style={{ fontSize: 15, fontWeight: 700, color: T.slate800 }}>{s.score.toLocaleString()} pts</div>
        <div style={{ fontSize: 13, color: T.slate600 }}>Level {s.level}{s.streak >= 5 ? ` · ${Math.min(4, 1 + Math.floor(s.streak / 5))}× streak` : ""}</div>
        <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
          {Array.from({ length: START_SHIELDS }, (_, i) => <Shield key={i} on={i < s.shields} />)}
          <button type="button" onClick={togglePause} style={{ ...btn(T.slate600), padding: "6px 12px", fontSize: 13, marginLeft: 8 }}>{paused ? "Resume" : "Pause"}</button>
        </div>
      </div>

      <div style={{
        position: "relative", height: fieldH, borderRadius: 16, overflow: "hidden", userSelect: "none", touchAction: "manipulation",
        background: "radial-gradient(ellipse at 50% 120%, #2B3A67 0%, #141A33 55%, #0B0E1F 100%)",
        transform: shaking ? `translateX(${(Math.random() - 0.5) * 10}px)` : "none",
      }}>
        <svg width="100%" height="100%" style={{ position: "absolute", inset: 0 }} aria-hidden="true">
          {STARS.map((st, i) => <circle key={i} cx={`${st.x}%`} cy={`${st.y}%`} r={st.r} fill="#fff" opacity={st.o} />)}
          {laserOn ? (
            <line x1="50%" y1="88%" x2={`${((s.laser.lane + 0.5) / LANES) * 100}%`} y2={`${Math.max(-12, s.laser.y * 74) + (rockSize / 2 / fieldH) * 100}%`}
              stroke="#7CF5FF" strokeWidth="4" strokeLinecap="round" />
          ) : null}
        </svg>

        {/* The problem */}
        <div style={{ position: "absolute", top: 10, left: 0, right: 0, textAlign: "center", pointerEvents: "none", zIndex: 3 }}>
          <span style={{
            display: "inline-block", padding: "8px 18px", borderRadius: 12, background: "rgba(255,255,255,0.92)",
            color: T.slate900, fontSize: _vp.isPhone ? 26 : 32, fontWeight: 800, letterSpacing: 1,
          }}>{s.problem?.text} = ?</span>
        </div>

        {s.rocks.map(r => (
          <Rock key={r.id} rock={r} lanes={LANES} top={yPct(r.y)} size={rockSize} onTap={() => fire(r)} />
        ))}

        {/* Ship */}
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
        {typed ? (
          <div style={{ position: "absolute", right: 12, bottom: 14, zIndex: 4, color: "#7CF5FF", fontSize: 22, fontWeight: 800 }}>{typed}</div>
        ) : null}
      </div>
      {!_vp.isPhone ? <div style={{ fontSize: 12, color: T.slate400, marginTop: 6, textAlign: "center" }}>Tap an asteroid, or type the answer and press Enter. P pauses.</div> : null}
    </div>
  );
}

function btn(bg) {
  return { padding: "10px 18px", borderRadius: 10, border: "none", background: bg, color: T.white, fontSize: 15, fontWeight: 700, cursor: "pointer", fontFamily: "inherit" };
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
  const digits = String(rock.value).length;
  const fs = Math.round(size * (digits <= 2 ? 0.42 : digits === 3 ? 0.34 : digits === 4 ? 0.27 : 0.22));
  return (
    <button
      type="button"
      onPointerDown={e => { e.preventDefault(); onTap(); }}
      aria-label={`Answer ${rock.value}`}
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
      <span style={{ position: "relative", color: "#fff", fontWeight: 800, fontSize: fs, textShadow: "0 1px 3px #000", fontFamily: "inherit" }}>
        {rock.value.toLocaleString()}
      </span>
    </button>
  );
}
