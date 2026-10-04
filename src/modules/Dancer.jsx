import { useCallback, useEffect, useRef, useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { PRACTICE_SONGS, renderSong } from "../lib/practiceSongs.js";
import { analyzeSong, gradeOffset, MAX_POINTS, MISS_AFTER, starsFor, createLiveBeat, secondsPerBeat } from "../lib/beat.js";
import { createDancer, stepDancer, puff, drawScene, drawDancer } from "../lib/airDancer.js";

// =========================================================================
// Dancer.jsx — test build of the air dancer game (Family area), "Dancer: dance
// with the air". The dancer's sag is timed in beats of the song
// playing (src/lib/airDancer.js), so fast songs need faster taps.
// Play: tap the screen on the beat; each tap is a puff of air. Every tap is
// graded against the nearest beat (Perfect / Good / OK), streaks raise a multiplier.
// Any pattern counts: every beat, every other beat, once a bar. Skipped beats are
// never a miss (dancers move at whatever beat level they feel; Drake, Jones & Baruch
// 2000, Cognition 77). What counts is each tap's timing and keeping the dancer going:
// stars = timing x the share of bars (4 beats) with at least one on-beat tap.
// Watch: the dancer dances to the music by itself, switching every few bars between
// puffing on every beat, every other beat, once a bar, double time, or resting.
// Music: three original practice songs (exact beats known), a song file from
// the phone (beat found by src/lib/beat.js), or Listen, which hears whatever is
// playing in the room through the microphone and follows its beat live.
// Nothing is saved to the database. Best scores and the timing adjustment are
// kept on the device only (browser storage).
// =========================================================================

const MODES = ["play", "watch"];
const MODE_LABEL = { play: "Play", watch: "Watch" };
const SYNC_KEY = "dancer.syncMs";
const bestKey = (id) => `dancer.best.${id}`;
const store = {
  get(k) { try { return window.localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { window.localStorage.setItem(k, v); } catch { /* private mode */ } },
};

const SONG_CACHE = new Map(); // practice songs, rendered once per visit

const btn = (kind = "soft") => ({
  border: `1px solid ${kind === "primary" ? T.blue : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : T.slate700,
  borderRadius: 10, padding: kind === "primary" ? "12px 18px" : "7px 12px",
  fontSize: kind === "primary" ? 16 : 13, fontWeight: 700, cursor: "pointer",
  fontFamily: "inherit", boxSizing: "border-box",
});
const chip = (on) => ({
  border: `1px solid ${on ? T.blue : T.slate200}`, background: on ? T.blueLt : T.white,
  color: on ? T.slate900 : T.slate700, borderRadius: 999, padding: "7px 12px",
  fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit", whiteSpace: "nowrap",
});

function newScore() {
  return {
    score: 0, streak: 0, bestStreak: 0, base: 0, judged: 0,
    counts: { Perfect: 0, Good: 0, OK: 0, Off: 0 }, claims: [], started: false,
    beatsPassed: 0, barHit: false, bars: 0, barsDanced: 0, quietBeats: 0,
  };
}

export default function Dancer() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [mode, setMode, modeHref] = useTabParam("mode", "play", MODES);
  const [source, setSource] = useState({ kind: "practice", id: PRACTICE_SONGS[0].id });
  const [fileSong, setFileSong] = useState(null); // { name, buffer, beats, loud, bpm }
  const [status, setStatus] = useState("");
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState(null);
  const [showSync, setShowSync] = useState(false);
  const [syncMs, setSyncMs] = useState(() => Number(store.get(SYNC_KEY)) || 0);

  const wrapRef = useRef(null);
  const canvasRef = useRef(null);
  const fileRef = useRef(null);
  const eng = useRef(null);
  const syncRef = useRef(syncMs);
  syncRef.current = syncMs;
  const modeRef = useRef(mode);
  modeRef.current = mode;

  if (!eng.current) {
    eng.current = { dancer: createDancer(Date.now() & 0xffff), ctx: null, src: null, mic: null, run: null, popups: [], glow: 0, last: 0 };
  }

  // ─── audio context (made on the first tap, as phones require) ─────────────
  const getCtx = useCallback(() => {
    const e = eng.current;
    if (!e.ctx) {
      try { if (navigator.audioSession) navigator.audioSession.type = "playback"; } catch { /* older Safari */ }
      const AC = window.AudioContext || window.webkitAudioContext;
      e.ctx = new AC({ latencyHint: "interactive" });
    }
    if (e.ctx.state === "suspended") e.ctx.resume();
    return e.ctx;
  }, []);

  // What the listener hears right now, in context seconds.
  const heardNow = () => {
    const ctx = eng.current.ctx;
    if (!ctx) return 0;
    const ts = ctx.getOutputTimestamp ? ctx.getOutputTimestamp() : null;
    if (ts && ts.performanceTime > 0) return ts.contextTime + (performance.now() - ts.performanceTime) / 1000;
    return ctx.currentTime - (ctx.outputLatency || ctx.baseLatency || 0);
  };
  // Song clock: seconds into the song, as heard.
  const songNow = () => {
    const r = eng.current.run;
    if (!r) return 0;
    if (r.kind === "mic") return performance.now() / 1000 - r.t0;
    return heardNow() - r.t0;
  };

  const beatsBetween = (a, b) => beatsIn(eng.current.run, a, b);

  // ─── a tap ────────────────────────────────────────────────────────────────
  const onTap = useCallback((ev) => {
    const e = eng.current, r = e.run;
    ev.preventDefault?.();
    if (!r || modeRef.current !== "play") {
      if (!r) puff(e.dancer, 0.8, 0);
      return;
    }
    const s = r.score;
    s.started = true;
    const ago = Math.max(0, (performance.now() - (ev.timeStamp || performance.now())) / 1000);
    const t = songNow() - ago - syncRef.current / 1000;
    const near = beatsBetween(t - 0.35, t + 0.35).filter((bt) => !claimed(s, bt));
    let best = null;
    for (const bt of near) if (best === null || Math.abs(bt - t) < Math.abs(best - t)) best = bt;
    const g = best === null ? null : gradeOffset(t - best);
    if (g) {
      s.claims.push(best);
      if (s.claims.length > 40) s.claims.shift();
      s.streak += 1;
      s.bestStreak = Math.max(s.bestStreak, s.streak);
      const mult = 1 + Math.min(3, Math.floor(s.streak / 8));
      s.score += g.points * mult;
      s.base += g.points;
      s.judged += 1;
      s.counts[g.label] += 1;
      puff(e.dancer, g.label === "Perfect" ? 1.15 : g.label === "Good" ? 0.95 : 0.75, 0);
      if (g.label === "Perfect") e.dancer.flash = 1;
      e.popups.push({ text: g.label === "Perfect" ? "Perfect!" : g.label, color: g.label === "Perfect" ? "#FFD23F" : g.label === "Good" ? "#7BE0A0" : "#FFFFFF", age: 0, ms: Math.round((t - best) * 1000) });
    } else {
      s.streak = 0;
      s.counts.Off += 1;
      puff(e.dancer, 0.5, 0);
      e.popups.push({ text: "Off beat", color: "#FFB4A8", age: 0 });
    }
  }, []);

  // ─── stop and score ───────────────────────────────────────────────────────
  const finish = useCallback((showResult = true) => {
    const e = eng.current, r = e.run;
    if (!r) return;
    e.run = null;
    try { e.src?.stop(); } catch { /* already stopped */ }
    e.src = null;
    if (e.mic) { e.mic.stream.getTracks().forEach((tr) => tr.stop()); try { e.mic.node.disconnect(); } catch { /* gone */ } e.mic = null; }
    setRunning(false);
    if (!showResult || r.mode !== "play") return;
    const s = r.score;
    const judged = s.judged + s.counts.Off;
    const accuracy = judged ? s.base / (judged * MAX_POINTS) : 0;
    const danced = s.bars ? s.barsDanced / s.bars : 0;
    const prevBest = Number(store.get(bestKey(r.id))) || 0;
    if (s.score > prevBest) store.set(bestKey(r.id), String(s.score));
    setResult({ title: r.title, score: s.score, accuracy, stars: starsFor(accuracy * danced), danced, bars: s.bars, barsDanced: s.barsDanced, counts: s.counts, bestStreak: s.bestStreak, best: Math.max(prevBest, s.score), newBest: s.score > prevBest && s.score > 0 });
  }, []);

  // ─── start ────────────────────────────────────────────────────────────────
  const start = useCallback(async () => {
    const e = eng.current;
    setResult(null);
    finish(false);
    const ctx = getCtx();
    const base = { mode: modeRef.current, score: newScore(), cursor: 0, missCheck: -1, passed: -1, watch: { pattern: null, beatsLeft: 0, count: 0, pending: [] } };
    if (source.kind === "mic") {
      setStatus("Asking for the microphone…");
      let stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
      } catch {
        setStatus("The microphone was not allowed. Turn it on for this site in the browser settings.");
        return;
      }
      const node = ctx.createMediaStreamSource(stream);
      const an = ctx.createAnalyser();
      an.fftSize = 1024; an.smoothingTimeConstant = 0;
      node.connect(an);
      e.mic = { stream, node, an, spec: new Float32Array(an.frequencyBinCount), prev: new Float32Array(an.frequencyBinCount).fill(-100), wave: new Float32Array(an.fftSize), peak: 0.02 };
      e.run = { ...base, kind: "mic", id: "listen", title: "Listening", t0: performance.now() / 1000, live: createLiveBeat(), loudNow: 0 };
      setStatus("Listening for the beat… play music near the phone.");
      setRunning(true);
      return;
    }
    let song;
    if (source.kind === "file") {
      if (!fileSong) { fileRef.current?.click(); return; }
      song = { id: `file:${fileSong.name}`, title: fileSong.name, buffer: fileSong.buffer, beats: fileSong.beats, downbeats: [], loud: fileSong.loud };
    } else {
      let cached = SONG_CACHE.get(source.id);
      if (!cached) {
        setStatus("Getting the song ready…");
        await new Promise((res) => setTimeout(res, 30));
        const rate = 22050;
        const r = renderSong(source.id, rate);
        const buf = ctx.createBuffer(2, r.left.length, rate);
        buf.getChannelData(0).set(r.left); buf.getChannelData(1).set(r.right);
        const hop = 0.05, lv = new Float32Array(Math.ceil(r.duration / hop));
        for (let i = 0; i < lv.length; i++) { let m = 0; const a = Math.floor(i * hop * rate), b = Math.min(r.left.length, a + Math.floor(hop * rate)); for (let j = a; j < b; j++) m = Math.max(m, Math.abs(r.left[j])); lv[i] = m; }
        cached = { buffer: buf, beats: r.beats, downbeats: r.downbeats, title: r.title, loud: { values: lv, hopSec: hop } };
        SONG_CACHE.set(source.id, cached);
      }
      song = { id: source.id, ...cached };
    }
    const src = ctx.createBufferSource();
    src.buffer = song.buffer;
    src.connect(ctx.destination);
    const startAt = ctx.currentTime + 0.25;
    src.start(startAt);
    src.onended = () => { if (eng.current.src === src) finish(true); };
    e.src = src;
    e.run = { ...base, kind: source.kind, id: song.id, title: song.title, t0: startAt, beats: song.beats, beatSec: secondsPerBeat(song.beats), downbeats: new Set(song.downbeats || []), loud: song.loud };
    setStatus("");
    setRunning(true);
  }, [source, fileSong, getCtx, finish]);

  // ─── pick a song file ─────────────────────────────────────────────────────
  const onFile = useCallback(async (ev) => {
    const f = ev.target.files?.[0];
    ev.target.value = "";
    if (!f) return;
    finish(false);
    setResult(null);
    setSource({ kind: "file" });
    setStatus("Opening the song…");
    try {
      const ctx = getCtx();
      const ab = await f.arrayBuffer();
      const buffer = await new Promise((res, rej) => ctx.decodeAudioData(ab, res, rej));
      setStatus("Finding the beat…");
      await new Promise((res) => setTimeout(res, 30));
      const chans = [];
      for (let c = 0; c < buffer.numberOfChannels; c++) chans.push(buffer.getChannelData(c));
      const a = analyzeSong(chans, buffer.sampleRate);
      if (!a.beats.length) { setStatus("Could not find a beat in that song. Try another one."); setFileSong(null); return; }
      setFileSong({ name: f.name.replace(/\.[^.]+$/, ""), buffer, beats: a.beats, loud: a.loud, bpm: a.bpm });
      setStatus(`Found the beat: about ${Math.round(a.bpm)} beats a minute. Press Start.`);
    } catch {
      setStatus("That file would not open. Songs from Apple Music or Spotify are copy-locked; use a song file you own.");
      setFileSong(null);
    }
  }, [getCtx, finish]);

  // ─── the frame loop ───────────────────────────────────────────────────────
  useEffect(() => {
    let raf = 0;
    const loop = (ms) => {
      raf = requestAnimationFrame(loop);
      const e = eng.current, cv = canvasRef.current, wrap = wrapRef.current;
      if (!cv || !wrap) return;
      const dt = e.last ? Math.min(0.05, (ms - e.last) / 1000) : 1 / 60;
      e.last = ms;
      const r = e.run, d = e.dancer;
      const now = r ? songNow() : 0;

      // music in, air out
      if (r) {
        if (r.kind === "mic" && e.mic) {
          const m = e.mic;
          m.an.getFloatFrequencyData(m.spec);
          const binHz = e.ctx.sampleRate / m.an.fftSize;
          let flux = 0, low = 0;
          for (let k = 1; k < m.spec.length && k * binHz < 5000; k++) {
            const v = Math.max(-100, m.spec[k]), up = Math.max(0, v - m.prev[k]);
            flux += up; if (k * binHz < 120) low += up;
            m.prev[k] = v;
          }
          r.live.push(now - 0.02, flux, low);
          m.an.getFloatTimeDomainData(m.wave);
          let rms = 0;
          for (let i = 0; i < m.wave.length; i++) rms += m.wave[i] * m.wave[i];
          rms = Math.sqrt(rms / m.wave.length);
          m.peak = Math.max(rms, m.peak * 0.999);
          r.loudNow = Math.min(1.2, rms / m.peak);
        } else if (r.loud) {
          const lv = r.loud.values;
          r.loudNow = lv[Math.max(0, Math.min(lv.length - 1, Math.floor(now / r.loud.hopSec)))] || 0;
        }
        while (r.kind !== "mic" && r.cursor < r.beats.length && r.beats[r.cursor] < now - 1.5) r.cursor++;
        // beats passing now: glow, and in Watch mode a puff
        for (const bt of beatsBetween(r.passed, now)) {
          e.glow = 1;
          if (r.mode === "watch") watchBeat(r, d, bt);
        }
        r.passed = now;
        // Watch mode's double-time puffs land half a beat after their beat
        while (r.mode === "watch" && r.watch.pending.length && r.watch.pending[0] <= now) {
          r.watch.pending.shift();
          puff(d, 0.45 + 0.3 * Math.random(), 0);
        }
        // beats now past tapping: count bars danced, and end a streak after two quiet bars
        if (r.mode === "play" && r.score.started) {
          const s = r.score;
          for (const bt of beatsBetween(r.missCheck, now - MISS_AFTER)) {
            const hit = claimed(s, bt);
            s.barHit = s.barHit || hit;
            s.quietBeats = hit ? 0 : s.quietBeats + 1;
            if (s.quietBeats === 8 && s.streak) s.streak = 0;
            s.beatsPassed += 1;
            if (s.beatsPassed % 4 === 0) { s.bars += 1; if (s.barHit) s.barsDanced += 1; s.barHit = false; }
          }
        }
        r.missCheck = now - MISS_AFTER;
        d.base = r.mode === "watch" ? 0.3 + 0.2 * Math.min(1, r.loudNow || 0) : 0.26;
        d.beatSec = r.kind === "mic" ? (r.live.period || d.beatSec || 0.6) : r.beatSec;
      } else {
        d.base = 0.5;
        d.beatSec = 0.6;
        if (Math.random() < dt * 0.5) puff(d, 0.4, 0);
      }
      stepDancer(d, dt);
      e.glow = Math.max(0, e.glow - dt * 4);

      // size
      const w = wrap.clientWidth;
      const h = Math.round(Math.min(Math.max(380, window.innerHeight * 0.62), 640));
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
        cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
        cv.style.width = `${w}px`; cv.style.height = `${h}px`;
      }
      const g = cv.getContext("2d");
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      const groundY = drawScene(g, w, h, { beatGlow: e.glow });
      drawDancer(g, d, w / 2, groundY, h * 0.6, { beatGlow: e.glow });
      drawHud(g, w, h, e, r, now, dt);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // leaving the page stops the music and the microphone
  useEffect(() => () => {
    const e = eng.current;
    try { e.src?.stop(); } catch { /* stopped */ }
    if (e.mic) e.mic.stream.getTracks().forEach((tr) => tr.stop());
    try { e.ctx?.close(); } catch { /* closed */ }
  }, []);

  const pick = (next) => {
    finish(false);
    setResult(null);
    setStatus("");
    if (next.kind === "file" && (!fileSong || source.kind === "file")) { fileRef.current?.click(); return; }
    setSource(next);
  };
  const isOn = (k, id) => source.kind === k && (k !== "practice" || source.id === id);

  return (
    <div style={{ padding: _pad, maxWidth: 760, margin: "0 auto", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 10 }}>
        <div>
          <div style={{ fontSize: 22, fontWeight: 800, color: T.slate900, lineHeight: 1.1 }}>Dancer</div>
          <div style={{ fontSize: 13, color: T.slate500, fontStyle: "italic" }}>Dance with the air</div>
        </div>
        <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap" }}>
          {MODES.map((m) => (
            <TabLink key={m} href={modeHref(m)} onSelect={() => { finish(false); setResult(null); setMode(m); }}
              style={{ ...chip(mode === m), flexShrink: 0 }}>{MODE_LABEL[m]}</TabLink>
          ))}
        </div>
      </div>

      <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 10 }}>
        {PRACTICE_SONGS.map((s) => (
          <button key={s.id} type="button" style={chip(isOn("practice", s.id))} onClick={() => pick({ kind: "practice", id: s.id })}>{s.title}</button>
        ))}
        <button type="button" style={chip(isOn("file"))} onClick={() => pick({ kind: "file" })}>
          {fileSong ? `🎵 ${fileSong.name.length > 18 ? fileSong.name.slice(0, 17) + "…" : fileSong.name}` : "🎵 Your song file"}
        </button>
        <button type="button" style={chip(isOn("mic"))} onClick={() => pick({ kind: "mic" })}>🎤 Listen</button>
        <input ref={fileRef} type="file" accept=".mp3,.m4a,.aac,.wav,.aif,.aiff,.flac,.ogg,.opus" style={{ display: "none" }} onChange={onFile} />
      </div>

      <div ref={wrapRef} style={{ position: "relative", borderRadius: 16, overflow: "hidden", border: `1px solid ${T.slate200}`, touchAction: "manipulation", userSelect: "none", WebkitUserSelect: "none" }}>
        <canvas ref={canvasRef} onPointerDown={onTap} style={{ display: "block", width: "100%", cursor: "pointer" }} />
        {result && (
          <div style={{ position: "absolute", inset: 0, background: "rgba(29,31,25,0.62)", display: "flex", alignItems: "center", justifyContent: "center", padding: 16, boxSizing: "border-box" }}>
            <div style={{ background: T.white, borderRadius: 16, padding: 20, width: "100%", maxWidth: 320, textAlign: "center", boxSizing: "border-box" }}>
              <div style={{ fontSize: 13, color: T.slate500, fontWeight: 700 }}>{result.title}</div>
              <div style={{ fontSize: 34, letterSpacing: 4, color: "#E8A21C", margin: "6px 0" }}>{"★".repeat(result.stars)}<span style={{ color: T.slate200 }}>{"★".repeat(3 - result.stars)}</span></div>
              <div style={{ fontSize: 32, fontWeight: 800, color: T.slate900 }}>{result.score.toLocaleString()}</div>
              <div style={{ fontSize: 14, color: T.slate700, marginBottom: 10 }}>
                {Math.round(result.accuracy * 100)}% on the beat{result.newBest ? " · new best!" : ` · best ${result.best.toLocaleString()}`}
              </div>
              <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
                Perfect {result.counts.Perfect} · Good {result.counts.Good} · OK {result.counts.OK}<br />
                Off beat {result.counts.Off} · Longest streak {result.bestStreak}<br />
                Danced {result.barsDanced} of {result.bars} bars
              </div>
              <button type="button" style={{ ...btn("primary"), width: "100%", marginTop: 14 }} onClick={start}>Play again</button>
            </div>
          </div>
        )}
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 10, flexWrap: "wrap" }}>
        {running
          ? <button type="button" style={{ ...btn("soft"), padding: "12px 18px", fontSize: 16, flex: "1 1 160px" }} onClick={() => finish(true)}>Stop</button>
          : <button type="button" style={{ ...btn("primary"), flex: "1 1 160px" }} onClick={start}>{source.kind === "file" && !fileSong ? "Pick a song file" : "Start"}</button>}
        {mode === "play" && (
          <button type="button" style={{ background: "none", border: "none", color: T.slate500, fontSize: 13, cursor: "pointer", fontFamily: "inherit", textDecoration: "underline" }} onClick={() => setShowSync((v) => !v)}>Timing</button>
        )}
      </div>
      {status && <div style={{ fontSize: 13, color: T.slate600, marginTop: 8 }}>{status}</div>}
      {!running && !status && (
        <div style={{ fontSize: 13, color: T.slate500, marginTop: 8 }}>
          {mode === "play" ? "Tap on the beat: every beat, every other beat, or once a bar. Each tap is a puff of air." : "Sit back. The dancer moves to the music on its own."}
        </div>
      )}
      {showSync && mode === "play" && (
        <div style={{ marginTop: 10, padding: 12, border: `1px solid ${T.slate200}`, borderRadius: 12, background: T.white }}>
          <div style={{ fontSize: 13, color: T.slate700, marginBottom: 6 }}>
            If taps right on the beat come up early or late (common with Bluetooth headphones), slide until they say Perfect. Now: {syncMs > 0 ? `${syncMs} ms later` : syncMs < 0 ? `${-syncMs} ms earlier` : "no change"}.
          </div>
          <input type="range" min={-300} max={300} step={10} value={syncMs} style={{ width: "100%" }}
            onChange={(ev) => { const v = Number(ev.target.value) || 0; setSyncMs(v); store.set(SYNC_KEY, String(v)); }} />
        </div>
      )}
    </div>
  );
}

// ─── the score, streak, beat lane and pop-ups, drawn on the canvas ─────────
function drawHud(g, w, h, e, r, now, dt) {
  g.textBaseline = "top";
  const shadow = (fn) => { g.save(); g.shadowColor = "rgba(0,0,0,0.45)"; g.shadowBlur = 6; fn(); g.restore(); };
  if (r && r.mode === "play") {
    const s = r.score;
    const mult = 1 + Math.min(3, Math.floor(s.streak / 8));
    shadow(() => {
      g.fillStyle = "#fff"; g.font = "800 26px system-ui, sans-serif"; g.textAlign = "left";
      g.fillText(s.score.toLocaleString(), 14, 12);
      g.textAlign = "right"; g.font = "700 16px system-ui, sans-serif";
      g.fillText(s.streak ? `${s.streak} in a row${mult > 1 ? `  ×${mult}` : ""}` : "", w - 14, 16);
    });
    // beat lane: dots slide left into the ring; tap when a dot reaches it
    const laneY = h - 34, ringX = w * 0.18, span = w * 0.72, ahead = 2;
    g.fillStyle = "rgba(0,0,0,0.35)";
    g.beginPath(); g.roundRect ? g.roundRect(10, laneY - 18, w - 20, 36, 18) : g.rect(10, laneY - 18, w - 20, 36); g.fill();
    g.strokeStyle = "#FFD23F"; g.lineWidth = 3;
    g.beginPath(); g.arc(ringX, laneY, 13 + e.glow * 4, 0, Math.PI * 2); g.stroke();
    const beats = beatsIn(r, now - 0.4, now + ahead);
    for (const bt of beats) {
      const x = ringX + ((bt - now) / ahead) * span;
      if (x < 14 || x > w - 14) continue;
      if (claimed(r.score, bt)) continue;
      g.fillStyle = bt < now - MISS_AFTER ? "rgba(255,255,255,0.3)" : r.downbeats?.has(bt) ? "#FFD23F" : "#fff";
      g.beginPath(); g.arc(x, laneY, r.downbeats?.has(bt) ? 9 : 7, 0, Math.PI * 2); g.fill();
    }
    if (r.kind === "mic" && !beats.length) {
      shadow(() => { g.fillStyle = "#fff"; g.font = "600 14px system-ui, sans-serif"; g.textAlign = "center"; g.fillText("Listening for the beat…", w / 2, laneY - 8); });
    }
  } else if (r) {
    shadow(() => {
      g.fillStyle = "#fff"; g.font = "700 16px system-ui, sans-serif"; g.textAlign = "left";
      g.fillText(r.kind === "mic" ? (r.live.bpm() ? `Dancing at ${Math.round(r.live.bpm())} beats a minute` : "Listening for the beat…") : r.title, 14, 14);
    });
  }
  // pop-ups float up from the lot, above the beat lane, and fade
  e.popups = e.popups.filter((p) => (p.age += dt) < 0.8);
  for (const p of e.popups) {
    g.globalAlpha = 1 - p.age / 0.8;
    shadow(() => {
      g.fillStyle = p.color; g.textAlign = "center";
      g.font = `800 ${p.text === "Perfect!" ? 30 : 24}px system-ui, sans-serif`;
      g.fillText(p.text, w / 2, h * 0.72 - p.age * 50);
    });
    g.globalAlpha = 1;
  }
}

// ─── Watch mode: how often the dancer puffs ───────────────────────────────
// A pattern is picked at random (weighted), held for 2 to 4 bars, then picked again.
const WATCH_PATTERNS = [
  { every: 1, weight: 3 },               // every beat
  { every: 2, weight: 3 },               // every other beat
  { every: 4, weight: 2 },               // once a bar
  { every: 1, double: true, weight: 1 }, // double time: on the beat and halfway between
  { every: 8, weight: 1 },               // a rest: one big puff every two bars
];
function pickWatchPattern() {
  const total = WATCH_PATTERNS.reduce((a, p) => a + p.weight, 0);
  let x = Math.random() * total;
  for (const p of WATCH_PATTERNS) { x -= p.weight; if (x < 0) return p; }
  return WATCH_PATTERNS[0];
}
function watchBeat(r, d, bt) {
  const w = r.watch;
  if (w.beatsLeft <= 0) { w.pattern = pickWatchPattern(); w.beatsLeft = 4 * (2 + Math.floor(Math.random() * 3)); w.count = 0; }
  if (w.count % w.pattern.every === 0) {
    const loud = Math.min(1, r.loudNow || 0);
    const big = w.pattern.every >= 4 ? 0.35 : 0; // fewer puffs, bigger ones
    puff(d, 0.5 + 0.35 * loud + 0.35 * Math.random() + big + (r.downbeats?.has(bt) ? 0.15 : 0), 0);
    if (w.pattern.double) {
      const gap = r.kind === "mic" ? r.live.period : (beatsIn(r, bt, bt + 2)[0] || bt + 0.5) - bt;
      if (gap > 0 && gap < 2) w.pending.push(bt + gap / 2);
    }
  }
  w.count += 1;
  w.beatsLeft -= 1;
}

// Has a tap already been scored on this beat?
function claimed(score, bt) {
  return score.claims.some((c) => Math.abs(c - bt) < 0.06);
}

// Beats with a < time <= b: from the song's list, or predicted live from the microphone.
function beatsIn(r, a, b) {
  if (!r) return [];
  const out = [];
  if (r.kind !== "mic") {
    for (let i = r.cursor; i < r.beats.length && r.beats[i] <= b; i++) if (r.beats[i] > a) out.push(r.beats[i]);
    return out;
  }
  let x = r.live.nextAfter(a);
  while (x !== null && x <= b && out.length < 64) { out.push(x); x = r.live.nextAfter(x + 1e-4); }
  return out;
}
