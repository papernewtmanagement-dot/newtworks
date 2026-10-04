// =========================================================================
// airDancer.js — the inflatable tube dancer: how it moves and how it's drawn.
// Used by the Dancer game. No browser needed for the motion, so it
// can be tested in Node; drawDancer takes any canvas 2D context.
//
// How it moves: the tube is a chain of joints standing on a blower.
//   - Air pressure stiffens every joint and holds the tube straight up.
//   - With little air, weight wins: the tube sags and folds over.
//   - Air rushing up the tube makes it ripple; a puff of air (a tap, or a
//     beat in Watch mode) whips it upright with arms flung out.
// =========================================================================

const N = 12;          // body joints
const ARM_N = 4;       // joints per arm
const ARM_AT = 8;      // arms come out of joint 8 of 12
const FLOOR = -1.0;    // the ground, in segment lengths below the blower top (the tube can't go lower)
// Tempo. Air from a puff leaks out per beat, not per second, so on a fast song he
// sags in less time and you tap faster; on a slow song he holds up longer.
// d.beatSec is the song's seconds per beat (the game sets it; 0.6 = 100 a minute).
const AIR_LOSS_PER_BEAT = 0.5;
// While a puff's air is still in him, it holds his head up off the ground: fully at
// LIFT_FULL of puff air left, not at all at LIFT_NONE. Tapping every 4th beat he
// dips close to the ground by the 4th beat but never touches it, at any tempo; wait
// about 5 beats or more and he can hit it.
const LIFT_MAX = 2.2, LIFT_FULL = 0.1, LIFT_NONE = 0.03;

export function createDancer(seed = 1) {
  let s = seed >>> 0;
  const rnd = () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
  const ph = (k) => Array.from({ length: k }, () => rnd() * Math.PI * 2);
  return {
    th: new Float64Array(N), om: new Float64Array(N),
    arms: [-1, 1].map((side) => ({ side, th: new Float64Array(ARM_N), om: new Float64Array(ARM_N) })),
    base: 0.35,      // steady air from the blower, 0..1
    surge: 0,        // extra air from puffs, fades fast
    lean: 0,         // where the player is pushing it, -1..1
    t: 0,
    phA: ph(N), phB: ph(N), phArm: ph(ARM_N * 2),
    rnd,
    flash: 0,        // brief glow after a good hit
    hair: 0,
  };
}

// Air in the tube: the blower's steady push plus puffs. The first build's motion,
// loosened (softer tube, more ripple, less damping so he keeps moving between
// beats), with puff air timed in beats (see AIR_LOSS_PER_BEAT). Tapping every 4th
// beat he folds deep and nearly reaches the ground but stays off it.
export function pressure(d) {
  return Math.max(0, Math.min(1.15, d.base + d.surge));
}

// A puff of air. strength 0..1.5; dir -1 / 1 picks the side it whips toward (0 = random).
export function puff(d, strength = 1, dir = 0) {
  const side = dir || (d.rnd() < 0.5 ? -1 : 1);
  d.surge = Math.min(0.95, d.surge + 0.75 * strength);
  for (let i = 0; i < N; i++) {
    const wave = Math.sin((i / N) * Math.PI * 1.5 + d.rnd());
    d.om[i] += strength * (side * (1.2 + (i / N) * 2.5) * wave + (d.rnd() - 0.5) * 1.5);
  }
  for (const a of d.arms) for (let i = 0; i < ARM_N; i++) a.om[i] += strength * a.side * (3 + d.rnd() * 4) * (i === 0 ? 1.5 : 1);
}

export function stepDancer(d, dt) {
  dt = Math.min(dt, 1 / 30);
  const sub = 4, h = dt / sub;
  for (let k = 0; k < sub; k++) {
    d.t += h;
    d.surge *= Math.exp(-h * AIR_LOSS_PER_BEAT / (d.beatSec || 0.6));
    const liftT = Math.max(0, Math.min(1, (d.surge - LIFT_NONE) / (LIFT_FULL - LIFT_NONE)));
    const lift = LIFT_MAX * liftT * liftT * (3 - 2 * liftT);
    const P = pressure(d);
    const stiff = 2.5 + 36 * P * P;
    const damp = 1.8 + 3.5 * P;
    const grav = 34 * Math.pow(Math.max(0, 1 - P), 2);
    const gust = 4 + 4.8 * Math.min(1, P);
    // heights of each point, in segment lengths above the blower top
    let phi = 0, ht = 0;
    const phis = d._phis || (d._phis = new Float64Array(N));
    const floorPush = d._fp || (d._fp = new Float64Array(N));
    floorPush.fill(0);
    for (let i = 0; i < N; i++) { phi += d.th[i]; phis[i] = phi; ht += Math.cos(phi); const fl = FLOOR + lift * ((i + 1) / N); if (ht < fl) { const pen = fl - ht; for (let j = 0; j <= i; j++) floorPush[j] -= 70 * pen * Math.sign(phis[i]) * (0.4 + 0.6 * (j / (i + 1))); } }
    phi = 0;
    for (let i = 0; i < N; i++) {
      phi += d.th[i];
      const above = (N - i) / N;
      // air rushing up the tube: a ripple travelling upward
      const turb = gust * (Math.sin(d.t * 3.1 - i * 0.55 + d.phA[i]) + 0.6 * Math.sin(d.t * 5.3 - i * 0.9 + d.phB[i])) * (0.4 + 0.6 * (i / N));
      let tq = -stiff * d.th[i] - damp * d.om[i] + grav * above * Math.sin(phi) + turb + floorPush[i];
      if (i < 3) tq += 18 * P * (d.lean * 0.35 - phi) * (i === 0 ? 1 : 0.5);
      d.om[i] += tq * h;
    }
    phi = 0; ht = 0;
    for (let i = 0; i < N; i++) {
      d.th[i] += d.om[i] * h;
      if (d.th[i] > 1.4) { d.th[i] = 1.4; d.om[i] *= -0.3; }
      if (d.th[i] < -1.4) { d.th[i] = -1.4; d.om[i] *= -0.3; }
      phi += d.th[i];
      // can't go through the ground: limit how far this segment can point down
      const need = FLOOR + lift * ((i + 1) / N) - ht; // lowest cos(phi) that keeps the next point above the ground (or above the lift)
      const maxAbs = need <= -1 ? Math.PI : need >= 1 ? 0 : Math.acos(need);
      if (Math.abs(phi) > maxAbs) { const over = phi - Math.sign(phi) * maxAbs; d.th[i] -= over; phi -= over; d.om[i] *= -0.2; }
      ht += Math.cos(phi);
    }
    // arms: point up and out with air, hang down without it
    for (const a of d.arms) {
      const rest = a.side * (2.7 - 1.85 * Math.min(1, P)); // angle from the body's "up"
      const aStiff = 3 + 45 * P * P, aDamp = 2 + 3 * P;
      for (let i = 0; i < ARM_N; i++) {
        const target = i === 0 ? rest : 0;
        const turb = 2.5 * (0.4 + P) * Math.sin(d.t * (4 + i) + d.phArm[i + (a.side > 0 ? ARM_N : 0)]);
        const tq = -aStiff * (a.th[i] - target) - aDamp * a.om[i] + turb;
        a.om[i] += tq * h;
        a.th[i] += a.om[i] * h;
        const lim = i === 0 ? 3.1 : 1.3;
        if (a.th[i] > lim) { a.th[i] = lim; a.om[i] *= -0.3; }
        if (a.th[i] < -lim) { a.th[i] = -lim; a.om[i] *= -0.3; }
      }
    }
  }
  d.flash = Math.max(0, d.flash - dt * 2.5);
  d.hair += dt * (6 + 10 * pressure(d));
}

// ─── drawing ───────────────────────────────────────────────────────────────
// Original look: a red-orange tube with a yellow stripe, cartoon eyes and an
// open grin, standing on a grey blower in a sunny lot. No brand designs.
const COLOR = { body: "#E8452C", bodyDark: "#A82A16", stripe: "#FFD23F", light: "#FF8A6B" };

function points(d, x0, y0, len) {
  const pts = [[x0, y0]];
  const ang = [];
  let phi = 0, x = x0, y = y0;
  for (let i = 0; i < N; i++) {
    phi += d.th[i];
    x += Math.sin(phi) * len; y -= Math.cos(phi) * len;
    pts.push([x, y]); ang.push(phi);
  }
  return { pts, ang };
}

function smoothPath(ctx, pts) {
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length - 1; i++) {
    const mx = (pts[i][0] + pts[i + 1][0]) / 2, my = (pts[i][1] + pts[i + 1][1]) / 2;
    ctx.quadraticCurveTo(pts[i][0], pts[i][1], mx, my);
  }
  const last = pts[pts.length - 1];
  ctx.lineTo(last[0], last[1]);
}

function tube(ctx, pts, width, main, dark, light) {
  ctx.lineCap = "round"; ctx.lineJoin = "round";
  smoothPath(ctx, pts); ctx.strokeStyle = dark; ctx.lineWidth = width + 4; ctx.stroke();
  smoothPath(ctx, pts); ctx.strokeStyle = main; ctx.lineWidth = width; ctx.stroke();
  // shine down one side
  const shine = pts.map(([x, y], i) => {
    const j = Math.min(pts.length - 1, i + 1), k = Math.max(0, i - 1);
    const dx = pts[j][0] - pts[k][0], dy = pts[j][1] - pts[k][1];
    const l = Math.hypot(dx, dy) || 1;
    return [x - (dy / l) * width * 0.22, y + (dx / l) * width * 0.22];
  });
  smoothPath(ctx, shine); ctx.strokeStyle = light; ctx.globalAlpha = 0.55; ctx.lineWidth = width * 0.18; ctx.stroke();
  ctx.globalAlpha = 1;
}

export function drawScene(ctx, w, h, opts = {}) {
  // sky and lot
  const g = ctx.createLinearGradient(0, 0, 0, h);
  g.addColorStop(0, "#9ED8F2"); g.addColorStop(0.7, "#E9F6F8"); g.addColorStop(0.71, "#5B5F63"); g.addColorStop(1, "#45484B");
  ctx.fillStyle = g; ctx.fillRect(0, 0, w, h);
  const groundY = h * 0.84;
  ctx.fillStyle = "#5B5F63"; ctx.fillRect(0, groundY, w, h - groundY);
  ctx.strokeStyle = "rgba(255,255,255,0.55)"; ctx.lineWidth = 3;
  for (let x = w * 0.08; x < w; x += w * 0.22) { ctx.beginPath(); ctx.moveTo(x, groundY + 6); ctx.lineTo(x - 18, h); ctx.stroke(); }
  // sun
  ctx.fillStyle = "rgba(255,226,120,0.9)"; ctx.beginPath(); ctx.arc(w * 0.85, h * 0.13, Math.min(w, h) * 0.06, 0, Math.PI * 2); ctx.fill();
  // string of pennants that bob with the beat
  const bob = opts.beatGlow || 0;
  const cols = ["#FFD23F", "#3FA7D6", "#59CD90", "#EE6352", "#FAC05E"];
  ctx.strokeStyle = "#555"; ctx.lineWidth = 1.5;
  const py = h * 0.2;
  ctx.beginPath(); ctx.moveTo(0, py); ctx.quadraticCurveTo(w / 2, py + 26, w, py); ctx.stroke();
  for (let i = 0; i < 11; i++) {
    const x = (i + 0.5) * (w / 11);
    const tt = x / w;
    const y = (1 - tt) * (1 - tt) * py + 2 * (1 - tt) * tt * (py + 26) + tt * tt * py;
    ctx.fillStyle = cols[i % cols.length];
    ctx.beginPath(); ctx.moveTo(x - 9, y); ctx.lineTo(x + 9, y); ctx.lineTo(x + Math.sin(i + bob * 3) * 3, y + 20 + bob * 6); ctx.closePath(); ctx.fill();
  }
  return groundY;
}

export function drawDancer(ctx, d, x0, groundY, height, opts = {}) {
  const P = Math.min(1, pressure(d));
  const len = (height / N) * (0.6 + 0.4 * P); // a soft tube crumples shorter
  const width = (height / N) * (1.55 + 0.45 * P);
  // ground shadow and beat ring
  ctx.fillStyle = "rgba(0,0,0,0.25)";
  ctx.beginPath(); ctx.ellipse(x0, groundY + 4, width * 1.6, 9, 0, 0, Math.PI * 2); ctx.fill();
  if (opts.beatGlow > 0) {
    ctx.strokeStyle = `rgba(255,210,63,${opts.beatGlow * 0.9})`; ctx.lineWidth = 4;
    ctx.beginPath(); ctx.ellipse(x0, groundY + 4, width * (1.7 + (1 - opts.beatGlow) * 1.4), 12 + (1 - opts.beatGlow) * 10, 0, 0, Math.PI * 2); ctx.stroke();
  }
  const blowerH = Math.max(22, (height / N) * 1.3);
  const y0 = groundY - blowerH;
  const { pts, ang } = points(d, x0, y0, len);

  // glow behind the body after a perfect hit
  if (d.flash > 0) { smoothPath(ctx, pts); ctx.strokeStyle = `rgba(255,230,120,${d.flash * 0.8})`; ctx.lineWidth = width + 22; ctx.lineCap = "round"; ctx.stroke(); }
  // arms behind the body
  for (const a of d.arms) {
    const [ax, ay] = pts[ARM_AT];
    let phi = ang[ARM_AT - 1] + a.th[0];
    const ap = [[ax, ay]];
    let x = ax, y = ay;
    const al = len * 0.95;
    for (let i = 0; i < ARM_N; i++) {
      if (i > 0) phi += a.th[i];
      x += Math.sin(phi) * al; y -= Math.cos(phi) * al;
      ap.push([x, y]);
    }
    tube(ctx, ap, width * 0.52, COLOR.body, COLOR.bodyDark, COLOR.light);
  }
  // body
  tube(ctx, pts, width, COLOR.body, COLOR.bodyDark, COLOR.light);
  // yellow stripe near the bottom
  const stripe = pts.slice(1, 4);
  smoothPath(ctx, stripe); ctx.strokeStyle = COLOR.stripe; ctx.lineWidth = width * 0.98; ctx.lineCap = "butt"; ctx.stroke();
  ctx.lineCap = "round";

  // face on the top segment
  const top = pts[N], below = pts[N - 2];
  const a = Math.atan2(top[0] - below[0], -(top[1] - below[1]));
  ctx.save();
  ctx.translate(top[0], top[1]);
  ctx.rotate(a);
  const fy = len * 0.9; // face center, down from the top
  // hair: streamers blown out of the top
  for (let i = -2; i <= 2; i++) {
    const wave = Math.sin(d.hair + i * 1.3) * width * 0.25;
    ctx.strokeStyle = i % 2 ? COLOR.stripe : COLOR.body; ctx.lineWidth = 4;
    ctx.beginPath(); ctx.moveTo(i * width * 0.12, -2);
    ctx.quadraticCurveTo(i * width * 0.2 + wave, -width * 0.35, i * width * 0.3 + wave * 1.4, -width * (0.45 + 0.25 * P));
    ctx.stroke();
  }
  const eyeR = width * 0.17;
  const look = Math.max(-1, Math.min(1, (d.om[N - 1] || 0) * 0.15));
  for (const sx of [-1, 1]) {
    ctx.fillStyle = "#fff"; ctx.strokeStyle = "#222"; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.ellipse(sx * width * 0.2, fy, eyeR, eyeR * (0.75 + 0.4 * P), 0, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    ctx.fillStyle = "#222";
    ctx.beginPath(); ctx.arc(sx * width * 0.2 + look * eyeR * 0.45, fy + eyeR * 0.15, eyeR * 0.45, 0, Math.PI * 2); ctx.fill();
  }
  // grin: wider and more open with more air
  const mw = width * 0.32, mh = width * (0.06 + 0.2 * P);
  ctx.fillStyle = "#3A0D08";
  ctx.beginPath(); ctx.ellipse(0, fy + eyeR * 1.9, mw, mh, 0, 0, Math.PI); ctx.fill();
  ctx.restore();

  // blower box
  const bw = width * 2.2;
  ctx.fillStyle = "#3D4247"; ctx.strokeStyle = "#202326"; ctx.lineWidth = 2;
  roundRect(ctx, x0 - bw / 2, y0 - 2, bw, blowerH + 2, 6); ctx.fill(); ctx.stroke();
  ctx.strokeStyle = "#5C6369"; ctx.lineWidth = 2;
  for (let i = 1; i < 4; i++) { const yy = y0 + (blowerH * i) / 4; ctx.beginPath(); ctx.moveTo(x0 - bw / 2 + 6, yy); ctx.lineTo(x0 + bw / 2 - 6, yy); ctx.stroke(); }
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y); ctx.lineTo(x + w - r, y); ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r); ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h); ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r); ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
}
