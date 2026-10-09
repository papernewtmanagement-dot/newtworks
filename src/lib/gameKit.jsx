import { useEffect, useState } from "react";
import { T } from "./theme.js";

// =========================================================================
// gameKit.jsx — pieces the Family games share: the read-aloud voice, the
// made-up sounds (WebAudio, no files), one mute switch for every game, the
// game button style, and the read-aloud story text (each word lit up as it's
// spoken). Spelling Quest and Math Blast both use these; nothing here is game-specific.
// =========================================================================

// ── Mute: one switch for all the games, remembered on this device.
export const SOUND = { muted: false, ctx: null };
try { SOUND.muted = window.localStorage.getItem("sq_muted") === "1"; } catch { SOUND.muted = false; }
export function setMuted(m) {
  SOUND.muted = !!m;
  try { window.localStorage.setItem("sq_muted", m ? "1" : "0"); } catch { /* fine */ }
}

// ── Sound building blocks.
export function audioCtx() {
  if (SOUND.muted || typeof window === "undefined") return null;
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return null;
  const ctx = SOUND.ctx || (SOUND.ctx = new AC());
  if (ctx.state === "suspended") ctx.resume();
  return ctx;
}
export function tone(ctx, type, f1, f2, at, len, vol = 0.08) {
  const o = ctx.createOscillator(); const g = ctx.createGain();
  o.type = type; o.frequency.setValueAtTime(f1, at); o.frequency.exponentialRampToValueAtTime(Math.max(20, f2), at + len);
  g.gain.setValueAtTime(vol, at); g.gain.exponentialRampToValueAtTime(0.001, at + len);
  o.connect(g); g.connect(ctx.destination); o.start(at); o.stop(at + len + 0.02);
}
export function noise(ctx, at, len, f1, f2, vol = 0.15) {
  const n = Math.floor(ctx.sampleRate * len);
  const buf = ctx.createBuffer(1, n, ctx.sampleRate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1;
  const src = ctx.createBufferSource(); src.buffer = buf;
  const f = ctx.createBiquadFilter(); f.type = "bandpass"; f.Q.value = 1.2;
  f.frequency.setValueAtTime(f1, at); f.frequency.exponentialRampToValueAtTime(f2, at + len);
  const g = ctx.createGain(); g.gain.setValueAtTime(vol, at); g.gain.exponentialRampToValueAtTime(0.001, at + len);
  src.connect(f); f.connect(g); g.connect(ctx.destination); src.start(at); src.stop(at + len);
}
export const notes = (ctx, t, list, type = "triangle", len = 0.1, vol = 0.07) => list.forEach((f, i) => tone(ctx, type, f, f, t + i * len, len * 1.4, vol));
// Play one sound from a game's own sound list. Quiet when muted or when the device has no sound.
export function playSound(list, name, arg) {
  try { const ctx = audioCtx(); if (ctx && list[name]) list[name](ctx, ctx.currentTime, arg); } catch { /* no sound on this device */ }
}

// ── Read aloud: the browser's own voice. onWord gets the index of the word being spoken.
export function speak(text, onWord, onEnd, opts = {}) {
  try {
    const synth = window.speechSynthesis;
    if (!synth || typeof SpeechSynthesisUtterance === "undefined") return false;
    synth.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.rate = opts.rate || 0.9; u.pitch = opts.pitch || 1.05;
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
export function stopSpeaking() { try { if (window.speechSynthesis) window.speechSynthesis.cancel(); } catch { /* fine */ } }

// ── The games' button look.
export function gameBtn(bg) {
  return { padding: "10px 18px", borderRadius: 10, border: "none", background: bg, color: T.white, fontSize: 15, fontWeight: 700, cursor: "pointer", fontFamily: "inherit" };
}

// ── Story text read aloud: starts reading on its own (unless muted), each word lit up as it's said,
// a Read / Stop button, and the game's own button to go on.
export function ReadAloud({ text, button, onDone, color = T.teal }) {
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
    <div style={{ padding: 16, display: "grid", gap: 14 }}>
      <div style={{ fontSize: 20, lineHeight: 1.6, color: T.slate900, fontFamily: "Georgia, 'Times New Roman', serif" }}>
        {words.map((w, i) => (
          <span key={i} style={{ background: i === at ? "#FFE680" : "transparent", borderRadius: 4, transition: "background 0.1s" }}>{w}{i < words.length - 1 ? " " : ""}</span>
        ))}
      </div>
      <div style={{ display: "flex", gap: 10, justifyContent: "center", flexWrap: "wrap" }}>
        {canSpeak ? <button type="button" onClick={read} style={gameBtn(T.blue)}>{reading ? "⏹ Stop reading" : "🔊 Read to me"}</button> : null}
        <button type="button" onClick={() => { stopSpeaking(); onDone(); }} style={gameBtn(color)}>{button}</button>
      </div>
    </div>
  );
}
