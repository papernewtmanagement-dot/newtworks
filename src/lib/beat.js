// =========================================================================
// beat.js — finds the beat in a song, and grades a tap against it.
// Used by the Air Boogie game. Pure functions, no browser needed, so
// they can be tested in Node.
//
// Method: Ellis (2007), "Beat Tracking by Dynamic Programming",
// Journal of New Music Research 36(1). Three steps:
//   1. onsetEnvelope  — how strongly new sound starts at each moment
//                        (rises in loudness across frequency bands).
//   2. estimateTempo   — the repeat gap in that envelope, weighted toward the
//                        tempo people tap to most easily (about 120 a minute).
//   3. trackBeats      — picks beat times that land on strong starts while
//                        keeping the gaps even, by dynamic programming.
// =========================================================================

const TARGET_RATE = 11025; // work at about 11 kHz, enough for drums and bass
const FRAME = 512;         // 46 ms analysis window
const HOP = 64;            // 5.8 ms between frames
const BANDS = 32;

// ─── small FFT (radix 2, in place) ─────────────────────────────────────────
function makeFFT(n) {
  const levels = Math.log2(n) | 0;
  const cos = new Float64Array(n / 2), sin = new Float64Array(n / 2);
  for (let i = 0; i < n / 2; i++) { cos[i] = Math.cos((2 * Math.PI * i) / n); sin[i] = Math.sin((2 * Math.PI * i) / n); }
  const rev = new Uint32Array(n);
  for (let i = 0; i < n; i++) {
    let x = i, r = 0;
    for (let b = 0; b < levels; b++) { r = (r << 1) | (x & 1); x >>= 1; }
    rev[i] = r;
  }
  return (re, im) => {
    for (let i = 0; i < n; i++) {
      const j = rev[i];
      if (j > i) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (let size = 2; size <= n; size *= 2) {
      const half = size / 2, step = n / size;
      for (let i = 0; i < n; i += size) {
        for (let j = i, k = 0; j < i + half; j++, k += step) {
          const l = j + half;
          const tre = re[l] * cos[k] + im[l] * sin[k];
          const tim = -re[l] * sin[k] + im[l] * cos[k];
          re[l] = re[j] - tre; im[l] = im[j] - tim;
          re[j] += tre; im[j] += tim;
        }
      }
    }
  };
}

// Mix any number of channels down to one, at about 11 kHz.
export function downmix(channels, sampleRate) {
  const chans = (channels || []).filter(Boolean);
  if (!chans.length) return { samples: new Float32Array(0), rate: TARGET_RATE };
  const k = Math.max(1, Math.round(sampleRate / TARGET_RATE));
  const len = Math.floor(chans[0].length / k);
  const out = new Float32Array(len);
  const scale = 1 / (k * chans.length);
  for (let i = 0; i < len; i++) {
    let s = 0;
    const base = i * k;
    for (const c of chans) for (let j = 0; j < k; j++) s += c[base + j] || 0;
    out[i] = s * scale;
  }
  return { samples: out, rate: sampleRate / k };
}

// Step 1. How strongly new sound starts, about 172 times a second.
export function onsetEnvelope(samples, rate) {
  const fft = makeFFT(FRAME);
  const win = new Float64Array(FRAME);
  for (let i = 0; i < FRAME; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (FRAME - 1));
  // log-spaced bands from 30 Hz to 5 kHz
  const binHz = rate / FRAME;
  const edges = [];
  for (let b = 0; b <= BANDS; b++) edges.push(30 * Math.pow(5000 / 30, b / BANDS));
  const bandOf = new Int16Array(FRAME / 2).fill(-1);
  for (let k = 1; k < FRAME / 2; k++) {
    const hz = k * binHz;
    for (let b = 0; b < BANDS; b++) if (hz >= edges[b] && hz < edges[b + 1]) { bandOf[k] = b; break; }
  }
  const frames = Math.max(0, Math.floor((samples.length - FRAME) / HOP) + 1);
  const env = new Float32Array(frames);
  const low = new Float32Array(frames); // starts below about 120 Hz: mostly kick drums
  const re = new Float64Array(FRAME), im = new Float64Array(FRAME);
  const prev = new Float64Array(BANDS).fill(-80), cur = new Float64Array(BANDS);
  for (let f = 0; f < frames; f++) {
    const o = f * HOP;
    for (let i = 0; i < FRAME; i++) { re[i] = samples[o + i] * win[i]; im[i] = 0; }
    fft(re, im);
    cur.fill(0);
    for (let k = 1; k < FRAME / 2; k++) { const b = bandOf[k]; if (b >= 0) cur[b] += re[k] * re[k] + im[k] * im[k]; }
    let flux = 0, lowFlux = 0;
    for (let b = 0; b < BANDS; b++) {
      const db = Math.max(-80, 10 * Math.log10(cur[b] + 1e-10));
      if (f > 0) { const up = Math.max(0, db - prev[b]); flux += up; if (edges[b + 1] <= 120) lowFlux += up; }
      prev[b] = db;
    }
    env[f] = flux;
    low[f] = lowFlux;
  }
  // take away the slow drift (about a one second average), then scale to unit spread
  const fps = rate / HOP;
  const w = Math.max(1, Math.round(fps));
  const out = new Float32Array(frames);
  let sum = 0;
  const q = [];
  for (let f = 0; f < frames; f++) {
    sum += env[f]; q.push(env[f]);
    if (q.length > w) sum -= q.shift();
    out[f] = env[f] - sum / q.length;
  }
  let m = 0, v = 0;
  for (let f = 0; f < frames; f++) m += out[f];
  m /= frames || 1;
  for (let f = 0; f < frames; f++) v += (out[f] - m) ** 2;
  const sd = Math.sqrt(v / (frames || 1)) || 1;
  for (let f = 0; f < frames; f++) out[f] = out[f] / sd;
  return { env: out, fps, low };
}

// Step 2. The beat gap, in frames. Weighted toward about 120 beats a minute
// (people tap there most easily; Ellis uses a log-normal weight 1.4 octaves wide),
// and boosted where the double gap also repeats, which settles half/double mistakes.
export function estimateTempo(env, fps) {
  const n = Math.min(env.length, Math.round(fps * 90)); // up to 90 s from the middle
  const start = Math.max(0, Math.floor((env.length - n) / 2));
  const lo = Math.floor((fps * 60) / 220), hi = Math.ceil((fps * 60) / 45);
  const r = new Float64Array(2 * hi + 2);
  for (let l = 1; l < r.length; l++) {
    let s = 0;
    for (let t = start + l; t < start + n; t++) s += env[t] * env[t - l];
    r[l] = s / n;
  }
  const l0 = (fps * 60) / 120;
  const w = (l) => Math.exp(-0.5 * Math.pow(Math.log2(l / l0) / 1.4, 2));
  const tps = (l) => (l >= 1 && l < r.length ? w(l) * r[l] : 0);
  let best = lo, bestScore = -Infinity;
  for (let l = lo; l <= hi; l++) {
    const s = tps(l) + 0.5 * tps(2 * l) + 0.25 * tps(2 * l - 1) + 0.25 * tps(2 * l + 1);
    if (s > bestScore) { bestScore = s; best = l; }
  }
  // fine-tune between frames
  const a = tps(best - 1), b = tps(best), c = tps(best + 1);
  const den = a - 2 * b + c;
  const shift = den !== 0 ? Math.max(-0.5, Math.min(0.5, (0.5 * (a - c)) / den)) : 0;
  const period = best + shift;
  return { periodFrames: period, bpm: (60 * fps) / period };
}

// Step 3. Beat times in seconds. alpha = how hard the gaps are held even (Ellis: 100).
export function trackBeats(env, fps, periodFrames, alpha = 100) {
  const n = env.length;
  if (!n || !(periodFrames > 1)) return [];
  const p = periodFrames;
  const score = new Float64Array(n), back = new Int32Array(n).fill(-1);
  const from = Math.round(2 * p), to = Math.max(1, Math.round(p / 2));
  for (let t = 0; t < n; t++) {
    let best = 0, arg = -1;
    for (let tau = t - from; tau <= t - to; tau++) {
      if (tau < 0) continue;
      const d = Math.log((t - tau) / p);
      const s = score[tau] - alpha * d * d;
      if (arg < 0 || s > best) { best = s; arg = tau; }
    }
    score[t] = env[t] + (arg >= 0 ? Math.max(0, best) : 0);
    back[t] = arg >= 0 && best > 0 ? arg : -1;
  }
  // best ending inside the last beat gap
  let end = n - 1, top = -Infinity;
  for (let t = Math.max(0, n - Math.round(p)); t < n; t++) if (score[t] > top) { top = score[t]; end = t; }
  const beats = [];
  for (let t = end; t >= 0; t = back[t]) { beats.push(t); if (back[t] < 0) break; }
  beats.reverse();
  // the first analysis frame is centered half a window in
  return beats;
}

// Frames to seconds. The window is centered half a frame in; the extra 15 ms
// is the measured lead of the onset envelope over the true hit (tested on the
// practice songs, whose beat times are exact).
export function framesToSeconds(frames, fps) {
  const offset = FRAME / 2 / (fps * HOP) + 0.015;
  return frames.map((f) => f / fps + offset);
}

// Popular music puts the kick drum on the beat. If the low end hits harder
// half a beat later, the tracker locked onto the off-beat: move it over.
export function fixOffbeat(beatFrames, low, periodFrames) {
  if (!beatFrames.length || !low) return beatFrames;
  const at = (f) => {
    const i = Math.round(f);
    let m = 0;
    for (let j = i - 2; j <= i + 2; j++) if (j >= 0 && j < low.length) m = Math.max(m, low[j]);
    return m;
  };
  const half = periodFrames / 2;
  let on = 0, off = 0;
  for (const f of beatFrames) { on += at(f); off += at(f + half); }
  if (off > on * 1.3) return beatFrames.map((f) => f + half).filter((f) => f < low.length);
  return beatFrames;
}

// Loudness every hopSec seconds, scaled so the loud parts of this song sit near 1.
export function loudness(samples, rate, hopSec = 0.05) {
  const hop = Math.max(1, Math.round(rate * hopSec));
  const out = new Float32Array(Math.ceil(samples.length / hop));
  for (let i = 0; i < out.length; i++) {
    let s = 0;
    const o = i * hop, e = Math.min(samples.length, o + hop);
    for (let j = o; j < e; j++) s += samples[j] * samples[j];
    out[i] = Math.sqrt(s / Math.max(1, e - o));
  }
  const sorted = Array.from(out).sort((a, b) => a - b);
  const p90 = sorted[Math.floor(sorted.length * 0.9)] || 1;
  for (let i = 0; i < out.length; i++) out[i] = Math.min(1.5, out[i] / p90);
  return { values: out, hopSec };
}

// Drop beats in silence at the start and end.
export function trimToMusic(beats, loud) {
  const at = (t) => loud.values[Math.min(loud.values.length - 1, Math.max(0, Math.floor(t / loud.hopSec)))] || 0;
  let a = 0, b = beats.length - 1;
  while (a <= b && at(beats[a]) < 0.08) a++;
  while (b >= a && at(beats[b]) < 0.08) b--;
  return beats.slice(a, b + 1);
}

// Whole song in, beats out. channels = Float32Array per channel.
export function analyzeSong(channels, sampleRate) {
  const { samples, rate } = downmix(channels, sampleRate);
  const { env, fps, low } = onsetEnvelope(samples, rate);
  const { periodFrames, bpm } = estimateTempo(env, fps);
  const loud = loudness(samples, rate);
  const frames = fixOffbeat(trackBeats(env, fps, periodFrames), low, periodFrames);
  const beats = trimToMusic(framesToSeconds(frames, fps), loud);
  return { beats, bpm, loud };
}

// ─── grading a tap ─────────────────────────────────────────────────────────
// Windows are wider than arcade rhythm games because phone screens add their
// own touch delay; skilled tappers land within about 30–50 ms of a steady beat
// (Repp 2005, "Sensorimotor synchronization: a review", Psychonomic Bulletin & Review).
export const GRADES = [
  { label: "Perfect", window: 0.05, points: 300 },
  { label: "Good", window: 0.1, points: 150 },
  { label: "OK", window: 0.15, points: 50 },
];
export const MAX_POINTS = GRADES[0].points;
export const MISS_AFTER = GRADES[GRADES.length - 1].window;

export function gradeOffset(offsetSec) {
  const a = Math.abs(offsetSec);
  for (const g of GRADES) if (a <= g.window) return g;
  return null;
}

// Find the nearest beat not yet used. Returns its index, or -1.
export function nearestOpenBeat(beats, used, t, from = 0) {
  let best = -1, bestD = Infinity;
  for (let i = Math.max(0, from - 2); i < beats.length; i++) {
    const d = Math.abs(beats[i] - t);
    if (beats[i] - t > 1) break;
    if (!used[i] && d < bestD) { bestD = d; best = i; }
  }
  return best;
}

export function starsFor(accuracy) {
  return accuracy >= 0.9 ? 3 : accuracy >= 0.7 ? 2 : accuracy >= 0.4 ? 1 : 0;
}

// ─── live beat, for the microphone ────────────────────────────────────────
// Feed it a start strength once per screen frame; it keeps the last 8 seconds,
// re-finds the tempo and the phase every half second, and predicts the next beats.
// Same tempo weighting as estimateTempo.
export function createLiveBeat() {
  const RATE = 50; // grid, beats per second resolution 20 ms
  const SPAN = 8;
  return {
    points: [], period: 0, phaseT: 0, confidence: 0, lastFit: 0, pending: null,
    push(t, v, low = 0) {
      this.points.push([t, Math.max(0, v), Math.max(0, low)]);
      while (this.points.length && this.points[0][0] < t - SPAN) this.points.shift();
      if (t - this.lastFit >= 0.5) { this.lastFit = t; this.fit(t); }
    },
    fit(now) {
      const n = SPAN * RATE;
      const grid = new Float64Array(n), lowGrid = new Float64Array(n);
      const t0 = now - SPAN;
      for (const [t, v, lo] of this.points) {
        const i = Math.floor((t - t0) * RATE);
        if (i >= 0 && i < n) { grid[i] = Math.max(grid[i], v); lowGrid[i] = Math.max(lowGrid[i], lo); }
      }
      // remove the average so steady noise does not look like a beat
      let mean = 0;
      for (let i = 0; i < n; i++) mean += grid[i];
      mean /= n;
      for (let i = 0; i < n; i++) grid[i] = Math.max(0, grid[i] - mean);
      const lo = Math.floor((RATE * 60) / 200), hi = Math.ceil((RATE * 60) / 50);
      const r = new Float64Array(2 * hi + 2);
      let zero = 0;
      for (let i = 0; i < n; i++) zero += grid[i] * grid[i];
      if (zero <= 1e-9) { this.confidence = 0; return; }
      for (let l = 1; l < r.length; l++) { let s = 0; for (let i = l; i < n; i++) s += grid[i] * grid[i - l]; r[l] = s / zero; }
      const l0 = (RATE * 60) / 120;
      const w = (l) => Math.exp(-0.5 * Math.pow(Math.log2(l / l0) / 1.4, 2));
      const tps = (l) => (l >= 1 && l < r.length ? w(l) * r[l] : 0);
      let best = lo, bs = -Infinity;
      for (let l = lo; l <= hi; l++) {
        const s = tps(l) + 0.5 * tps(2 * l) + 0.25 * tps(2 * l - 1) + 0.25 * tps(2 * l + 1);
        if (s > bs) { bs = s; best = l; }
      }
      const a = tps(best - 1), b = tps(best), c = tps(best + 1), den = a - 2 * b + c;
      const lag = best + (den !== 0 ? Math.max(-0.5, Math.min(0.5, (0.5 * (a - c)) / den)) : 0);
      let period = lag / RATE;
      // hold steady through small wobbles
      if (this.period && Math.abs(period / this.period - 1) < 0.06) period = 0.7 * this.period + 0.3 * period;
      // phase: the offset whose comb of beats collects the most onset
      let bestPh = 0, bestSum = -Infinity;
      const steps = Math.max(1, Math.round(period * RATE));
      for (let k = 0; k < steps; k++) {
        let s = 0;
        for (let m = 0; ; m++) {
          const idx = n - 1 - k - Math.round(m * period * RATE);
          if (idx < 0) break;
          s += grid[idx] + 0.5 * ((grid[idx - 1] || 0) + (grid[idx + 1] || 0));
        }
        if (s > bestSum) { bestSum = s; bestPh = k; }
      }
      // kick drums mark the beat: if the low end hits harder half a beat over, move over
      const comb = (k, g) => {
        let sum = 0;
        for (let m = 0; ; m++) {
          const idx = n - 1 - Math.round(k) - Math.round(m * period * RATE);
          if (idx < 1) break;
          sum += Math.max(g[idx], g[idx - 1], g[idx + 1] || 0);
        }
        return sum;
      };
      const halfSteps = (period * RATE) / 2;
      const onLow = comb(bestPh, lowGrid), offLow = comb(bestPh + halfSteps, lowGrid);
      if (offLow > onLow * 1.3) bestPh = bestPh + halfSteps;
      const phaseT = t0 + (n - 1 - bestPh) / RATE; // a recent beat time
      this.confidence = r[best];
      if (!(this.period > 0)) { this.period = period; this.phaseT = phaseT; return; }
      // Small change: ease toward it. Big change: only after two fits in a row agree,
      // so one noisy half second can't throw the beat off.
      const cur = this.nextAfter(now, true), cand = phaseT + Math.ceil((now - phaseT) / period) * period;
      let diff = cand - cur;
      if (Math.abs(diff) > this.period / 2) diff -= Math.sign(diff) * this.period;
      if (Math.abs(diff) < 0.07 && Math.abs(period / this.period - 1) < 0.06) {
        this.period = period;
        this.phaseT = cur + 0.4 * diff;
        this.pending = null;
      } else if (this.pending && Math.abs(this.pending.period / period - 1) < 0.04 && Math.abs(((cand - this.pending.next(now)) % period + period * 1.5) % period - period / 2) < 0.05) {
        this.period = period; this.phaseT = phaseT; this.pending = null;
      } else {
        this.pending = { period, phaseT, next: (t) => phaseT + Math.ceil((t - phaseT) / period) * period };
      }
    },
    // next beat time strictly after t (or null while still listening)
    nextAfter(t, ignoreConfidence = false) {
      if (!(this.period > 0) || (!ignoreConfidence && this.confidence < 0.15)) return null;
      const k = Math.floor((t - this.phaseT) / this.period) + 1;
      return this.phaseT + k * this.period;
    },
    bpm() { return this.period > 0 ? 60 / this.period : 0; },
  };
}
