// =========================================================================
// practiceSongs.js — three original songs for Private Dancer, made from math.
// No recordings, so nothing to license. Each song knows its exact beat
// times, so the game never has to guess the beat for these.
// renderSong(id, sampleRate) → { left, right, beats, downbeats, duration, bpm }
// =========================================================================

export const PRACTICE_SONGS = [
  { id: "warmup", title: "Warm Up", bpm: 92, bars: 24, key: 57, prog: [0, 5, 3, 4], feel: "easy" },
  { id: "carlot", title: "Car Lot", bpm: 112, bars: 32, key: 55, prog: [0, 3, 4, 3], feel: "funk" },
  { id: "blowout", title: "Blowout Sale", bpm: 126, bars: 40, key: 60, prog: [0, 4, 5, 3], feel: "dance" },
];

const MAJOR = [0, 2, 4, 5, 7, 9, 11];
const hz = (midi) => 440 * Math.pow(2, (midi - 69) / 12);

// small deterministic random so every play sounds the same
function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

export function renderSong(id, sampleRate = 44100) {
  const song = PRACTICE_SONGS.find((s) => s.id === id) || PRACTICE_SONGS[0];
  const spb = 60 / song.bpm;
  const lead = 0.5; // half a second of quiet before bar 1
  const totalBeats = song.bars * 4;
  const duration = lead + totalBeats * spb + 1.5;
  const n = Math.ceil(duration * sampleRate);
  const L = new Float32Array(n), R = new Float32Array(n);
  const rand = rng(song.bpm * 7919);

  const add = (start, len, fn, gainL = 1, gainR = 1) => {
    const a = Math.max(0, Math.floor(start * sampleRate));
    const b = Math.min(n, a + Math.floor(len * sampleRate));
    for (let i = a; i < b; i++) {
      const v = fn((i - a) / sampleRate);
      L[i] += v * gainL; R[i] += v * gainR;
    }
  };

  const kick = (t0, g = 1) => add(t0, 0.35, (t) => {
    const f = 45 + 110 * Math.exp(-t * 28);
    return Math.sin(2 * Math.PI * f * t) * Math.exp(-t * 9) * 0.9 * g;
  });
  const snare = (t0, g = 1) => {
    let lp = 0;
    add(t0, 0.22, (t) => {
      const noise = rand() * 2 - 1;
      lp += 0.35 * (noise - lp);
      const hp = noise - lp;
      return (hp * 0.55 * Math.exp(-t * 18) + Math.sin(2 * Math.PI * 190 * t) * 0.3 * Math.exp(-t * 25)) * g;
    });
  };
  const hat = (t0, g = 1, open = false) => {
    let lp = 0;
    add(t0, open ? 0.25 : 0.06, (t) => {
      const noise = rand() * 2 - 1;
      lp += 0.6 * (noise - lp);
      return (noise - lp) * 0.22 * Math.exp(-t * (open ? 12 : 60)) * g;
    }, 0.8, 1.1);
  };
  const clap = (t0) => {
    let lp = 0;
    add(t0, 0.2, (t) => {
      const noise = rand() * 2 - 1;
      lp += 0.3 * (noise - lp);
      const burst = t < 0.03 ? (Math.floor(t / 0.01) % 2 === 0 ? 1 : 0.3) : Math.exp(-(t - 0.03) * 20);
      return (noise - lp) * 0.4 * burst;
    }, 1.1, 0.8);
  };
  const bass = (t0, len, midi, g = 1) => {
    const f = hz(midi);
    let lp = 0;
    add(t0, len, (t) => {
      const ph = (f * t) % 1;
      const saw = 2 * ph - 1;
      lp += 0.08 * (saw - lp);
      const envA = Math.min(1, t / 0.005) * Math.exp(-t * 2.5) * Math.min(1, (len - t) / 0.02);
      return (lp * 0.9 + Math.sin(2 * Math.PI * f * t) * 0.35) * envA * 0.55 * g;
    });
  };
  const pad = (t0, len, midis, g = 1) => add(t0, len, (t) => {
    let s = 0;
    for (const m of midis) {
      const f = hz(m);
      const ph = (f * t) % 1;
      s += (ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph) * 0.5 + Math.sin(2 * Math.PI * f * 1.003 * t) * 0.3;
    }
    const envA = Math.min(1, t / 0.08) * Math.min(1, (len - t) / 0.15);
    return (s / midis.length) * envA * 0.16 * g;
  }, 0.9, 1.1);
  const pluck = (t0, len, midi, g = 1) => {
    const f = hz(midi);
    add(t0, len, (t) => {
      const ph = (f * t) % 1;
      const sq = (ph < 0.5 ? 1 : -1) * 0.4 + Math.sin(2 * Math.PI * f * t) * 0.6;
      return sq * Math.exp(-t * 5) * Math.min(1, t / 0.004) * Math.min(1, (len - t) / 0.02) * 0.2 * g;
    }, 1.1, 0.9);
  };

  const scale = (deg, oct = 0) => song.key + MAJOR[((deg % 7) + 7) % 7] + 12 * (Math.floor(deg / 7) + oct);
  const beats = [], downbeats = [];
  // melody: a simple motif that walks the chord, varied per section
  const motifs = [[0, 2, 4, 2], [4, 2, 0, -1], [0, 4, 5, 4], [2, 0, 2, 4]];

  for (let bar = 0; bar < song.bars; bar++) {
    const section = Math.floor(bar / 8); // 8-bar sections
    const intro = bar < 4;
    const outro = bar >= song.bars - 2;
    const chordDeg = song.prog[bar % song.prog.length];
    const root = scale(chordDeg, -2);
    const triad = [scale(chordDeg, 0), scale(chordDeg + 2, 0), scale(chordDeg + 4, 0)];
    const barT = lead + bar * 4 * spb;

    pad(barT, 4 * spb, triad, intro ? 0.7 : 1);
    for (let b = 0; b < 4; b++) {
      const t = barT + b * spb;
      beats.push(t);
      if (b === 0) downbeats.push(t);
      // drums
      if (!intro || b % 2 === 0) kick(t, b === 0 ? 1 : 0.85);
      if (song.feel === "dance" && !intro) kick(t, 0.9);
      if (!intro && (b === 1 || b === 3)) { snare(t); if (section % 2 === 1) clap(t); }
      hat(t + spb / 2, 0.9, song.feel === "dance" && !intro);
      if (song.feel !== "easy") hat(t, 0.5);
      if (song.feel === "funk" && !intro) hat(t + (3 * spb) / 4, 0.4);
      // bass
      if (song.feel === "funk") {
        bass(t, spb * 0.45, root + (b === 2 ? 7 : 0));
        if (b === 3) bass(t + spb * 0.5, spb * 0.4, root + 12, 0.7);
      } else if (song.feel === "dance") {
        bass(t + spb / 2, spb * 0.45, root + 12);
        bass(t, spb * 0.3, root, 0.6);
      } else {
        if (b % 2 === 0) bass(t, spb * 1.8, root);
      }
    }
    // melody after the intro, rests in the last two bars of each section
    if (!intro && !outro && bar % 8 < 6) {
      const motif = motifs[(section + bar) % motifs.length];
      for (let i = 0; i < 4; i++) {
        const step = song.feel === "easy" ? 1 : 0.5;
        const t = barT + i * spb * (song.feel === "easy" ? 1 : 0.5) + (song.feel === "easy" ? 0 : (bar % 2) * 2 * spb);
        pluck(t, spb * step * 0.95, scale(chordDeg + motif[i], 1));
      }
    }
  }
  // closing hit
  const endT = lead + totalBeats * spb;
  kick(endT); pad(endT, 1.2, [scale(0, 0), scale(2, 0), scale(4, 0)]);

  // soft limit and normalize
  let peak = 0;
  for (let i = 0; i < n; i++) { L[i] = Math.tanh(L[i] * 1.2); R[i] = Math.tanh(R[i] * 1.2); peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i])); }
  const g = peak > 0 ? 0.89 / peak : 1;
  for (let i = 0; i < n; i++) { L[i] *= g; R[i] *= g; }
  return { left: L, right: R, beats, downbeats, duration, bpm: song.bpm, title: song.title };
}
