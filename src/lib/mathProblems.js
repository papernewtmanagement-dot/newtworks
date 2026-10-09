// =========================================================================
// mathProblems.js — every math problem Math Blast asks, by kind and level (1-10).
// Kinds: add, subtract, multiply, divide, mix (those four), number patterns,
// estimating, and fractions/decimals/percents (with everyday money problems at
// the top levels). Each problem is { text, answer, choices-maker hints }; answers
// are numbers, except "which sign" problems in the Fuel Recycler (answer is the sign).
// =========================================================================

export const OPS = [
  { id: "add",      label: "Add",           sym: "+" },
  { id: "sub",      label: "Subtract",      sym: "−" },
  { id: "mult",     label: "Multiply",      sym: "×" },
  { id: "div",      label: "Divide",        sym: "÷" },
  { id: "mix",      label: "Mix",           sym: "?" },
  { id: "pattern",  label: "Patterns",      sym: "⋯" },
  { id: "estimate", label: "Estimate",      sym: "≈" },
  { id: "fraction", label: "Fractions & %", sym: "%" },
];
export const MAX_LEVEL = 10;

export const ri = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
export const pick = arr => arr[Math.floor(Math.random() * arr.length)];
export const shuffle = arr => { const a = [...arr]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
// Two decimal places at most, so 0.1 + 0.2 shows as 0.3.
export const tidy = n => (typeof n === "number" ? Math.round(n * 100) / 100 : n);
// How a number shows on screen: commas for big whole numbers, decimals as written.
export const fmt = v => (typeof v !== "number" ? v : Number.isInteger(v) ? v.toLocaleString() : String(tidy(v)));
const money = v => `$${Number.isInteger(v) ? v : tidy(v).toFixed(2)}`;
const roundTo = (n, to) => Math.round(n / to) * to;

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

function arithmetic(kind, lv) {
  let a, b, answer, sym;
  if (kind === "add") { [a, b] = addPair(lv); answer = a + b; sym = "+"; }
  else if (kind === "sub") { const [x, y] = addPair(lv); a = x + y; b = y; answer = x; sym = "−"; }
  else if (kind === "mult") { [a, b] = multPair(lv); answer = a * b; sym = "×"; }
  else { let [x, y] = multPair(lv); if (x === 0) x = 1; a = x * y; b = x; answer = y; sym = "÷"; }
  return { kind, a, b, sym, answer, text: `${a.toLocaleString()} ${sym} ${b.toLocaleString()}` };
}

// Number patterns: what comes next.
function pattern(lv) {
  let seq;
  const build = (start, next, n = 5) => { const out = [start]; while (out.length < n) out.push(next(out[out.length - 1], out.length, out)); return out; };
  switch (lv) {
    case 1: { const st = ri(1, 2); seq = build(ri(0, 10), x => x + st); break; }
    case 2: { const st = pick([5, 10]); seq = build(st * ri(0, 6), x => x + st); break; }
    case 3: { const st = ri(1, 3); seq = build(ri(20, 40), x => x - st); break; }
    case 4: { const st = ri(3, 9); seq = build(ri(0, 20), x => x + st); break; }
    case 5: seq = build(ri(1, 5), x => x * 2); break;
    case 6: { const st = pick([1, 2]); seq = build(ri(1, 10), (x, i) => x + st * i); break; }
    case 7: seq = Math.random() < 0.5 ? build(ri(1, 3), x => x * 3) : build(ri(1, 6) * 32, x => x / 2); break;
    case 8: { const up = ri(4, 9); const down = ri(1, up - 1); seq = build(ri(1, 10), (x, i) => (i % 2 ? x + up : x - down), 6); break; }
    case 9: { const n0 = ri(1, 6); seq = build(n0 * n0, (x, i) => (n0 + i) * (n0 + i)); break; }
    default: seq = Math.random() < 0.5 ? build(ri(1, 4), x => x * 2 + 1) : (() => { const s = [ri(1, 4), ri(1, 4)]; while (s.length < 6) s.push(s[s.length - 1] + s[s.length - 2]); return s; })();
  }
  const answer = seq[seq.length - 1];
  const shown = seq.slice(0, -1);
  const step = shown[shown.length - 1] - shown[shown.length - 2];
  return { kind: "pattern", seq, answer, text: `${shown.map(fmt).join(", ")}, ?`, wrong: [answer + 1, answer - 1, shown[shown.length - 1] + step + 2, shown[shown.length - 1], answer + step] };
}

// Estimating: round, or round first and then work it out.
function estimate(lv) {
  const near = (ans, to) => [ans + to, ans - to, ans + 2 * to, ans - 2 * to];
  switch (lv) {
    case 1: { const n = ri(11, 99); const a = roundTo(n, 10); return { kind: "estimate", answer: a, text: `Round ${n} to the nearest 10`, wrong: [...near(a, 10), n] }; }
    case 2: { const n = ri(101, 999); const a = roundTo(n, 10); return { kind: "estimate", answer: a, text: `Round ${n} to the nearest 10`, wrong: [...near(a, 10), roundTo(n, 100)] }; }
    case 3: { const n = ri(101, 999); const a = roundTo(n, 100); return { kind: "estimate", answer: a, text: `Round ${n} to the nearest 100`, wrong: [...near(a, 100), roundTo(n, 10)] }; }
    case 4: { const x = ri(11, 89); const y = ri(11, 89); const a = roundTo(x, 10) + roundTo(y, 10); return { kind: "estimate", answer: a, text: `${x} + ${y} ≈ ? (round to tens)`, wrong: [...near(a, 10), x + y] }; }
    case 5: { const x = ri(51, 99); const y = ri(11, 49); const a = roundTo(x, 10) - roundTo(y, 10); return { kind: "estimate", answer: a, text: `${x} − ${y} ≈ ? (round to tens)`, wrong: [...near(a, 10), x - y] }; }
    case 6: { const x = ri(101, 899); const y = ri(101, 899); const a = roundTo(x, 100) + roundTo(y, 100); return { kind: "estimate", answer: a, text: `${x} + ${y} ≈ ? (round to hundreds)`, wrong: [...near(a, 100), x + y] }; }
    case 7: { const x = ri(12, 89); const y = ri(3, 9); const a = roundTo(x, 10) * y; return { kind: "estimate", answer: a, text: `${x} × ${y} ≈ ? (round ${x} to tens)`, wrong: [...near(a, y * 10), x * y] }; }
    case 8: { const x = ri(12, 89); const y = ri(12, 89); const a = roundTo(x, 10) * roundTo(y, 10); return { kind: "estimate", answer: a, text: `${x} × ${y} ≈ ? (round to tens)`, wrong: [...near(a, 100), a + 1000, x * y] }; }
    case 9: { const n = ri(1001, 9999); const a = roundTo(n, 1000); return { kind: "estimate", answer: a, text: `Round ${n.toLocaleString()} to the nearest 1,000`, wrong: [...near(a, 1000), roundTo(n, 100)] }; }
    default: {
      const x = ri(105, 995) / 100; const y = ri(105, 995) / 100; const a = Math.round(x) + Math.round(y);
      return { kind: "estimate", answer: a, text: `${money(x)} + ${money(y)} ≈ ? (round to dollars)`, wrong: [a + 1, a - 1, a + 2, tidy(x + y)] };
    }
  }
}

// Fractions, decimals and percents, ending with everyday money: sales, tips and tax.
function fraction(lv) {
  switch (lv) {
    case 1: { const n = 2 * ri(1, 10); return { kind: "fraction", answer: n / 2, text: `1/2 of ${n}`, wrong: [n, n / 2 + 1, n / 2 - 1, n * 2] }; }
    case 2: { const d = pick([2, 3, 4, 5, 10]); const n = d * ri(1, 10); return { kind: "fraction", answer: n / d, text: `1/${d} of ${n}`, wrong: [n / d + 1, n / d - 1, n - d, n / d + d] }; }
    case 3: { const d = pick([3, 4, 5, 8, 10]); const k = ri(2, d - 1); const n = d * ri(1, 10); const a = (n / d) * k; return { kind: "fraction", answer: a, text: `${k}/${d} of ${n}`, wrong: [n / d, a + n / d, a - 1, a + 1] }; }
    case 4: { const x = ri(1, 8); const y = ri(1, 9 - x); return { kind: "fraction", answer: tidy((x + y) / 10), text: `0.${x} + 0.${y}`, wrong: [tidy((x + y) / 100), x + y, tidy((x + y) / 10 + 0.1), tidy((x + y) / 10 - 0.1)] }; }
    case 5: { const p = pick([10, 25, 50, 100]); const n = (100 / p) * ri(1, 12) * (p === 10 ? 1 : 2); const a = (n * p) / 100; return { kind: "fraction", answer: a, text: `${p}% of ${n}`, wrong: [a * 2, a + p / 10, Math.max(0, a - 1), n - a] }; }
    case 6: { const [k, d] = pick([[1, 2], [1, 4], [3, 4], [1, 5], [2, 5], [3, 5], [1, 10], [3, 10], [7, 10]]); const a = (k / d) * 100; return { kind: "fraction", answer: a, text: `${k}/${d} = ?%`, wrong: [k * 10 + d, a + 5, a - 5, a + 10] }; }
    case 7: {
      const [m, step] = pick([[0.5, 2], [0.25, 4], [0.1, 10]]); const n = step * ri(1, 12); const a = tidy(m * n);
      return { kind: "fraction", answer: a, text: `${m} × ${n}`, wrong: [n, tidy(a * 10), a + 1, tidy(n / 10)] };
    }
    case 8: { const x = ri(1, 8) + pick([0.25, 0.5, 0.75]); const y = pick([0.25, 0.5, 0.75, 1.5]); const a = tidy(x + y); return { kind: "fraction", answer: a, text: `${money(x)} + ${money(y)}`, wrong: [tidy(a + 1), tidy(a - 0.25), tidy(a + 0.25), tidy(a - 1)] }; }
    case 9: {
      const p = pick([10, 20, 25, 50]); const price = (100 / p) * ri(2, 10);
      const off = (price * p) / 100; const a = price - off;
      return { kind: "fraction", answer: a, text: `${money(price)} item, ${p}% off. New price?`, wrong: [off, price + off, a + 5, a - 5] };
    }
    default: {
      if (Math.random() < 0.5) { const p = pick([15, 20]); const bill = 20 * ri(1, 6); const a = (bill * p) / 100; return { kind: "fraction", answer: a, text: `${p}% tip on a ${money(bill)} meal`, wrong: [a + 2, a * 2, bill / 10, a - 1] }; }
      const t = pick([5, 10]); const price = 20 * ri(1, 10); const a = price + (price * t) / 100;
      return { kind: "fraction", answer: a, text: `${money(price)} plus ${t}% tax. Total?`, wrong: [(price * t) / 100, price + t, a + 10, a - 1] };
    }
  }
}

export function makeProblem(op, level) {
  const kind = op === "mix" ? pick(["add", "sub", "mult", "div"]) : op;
  if (kind === "pattern") return pattern(level);
  if (kind === "estimate") return estimate(level);
  if (kind === "fraction") return fraction(level);
  // In Mix, adding and subtracting run two levels ahead of times and divide.
  const lv = op === "mix" && (kind === "add" || kind === "sub") ? Math.min(MAX_LEVEL, level + 2) : level;
  return arithmetic(kind, lv);
}

// Fuel Recycler: the same problem with one piece missing (a number, the sign, or a pattern term).
export function makeMissing(op, level) {
  const p = makeProblem(op, level);
  if (p.seq) {
    const i = ri(1, p.seq.length - 2);
    return { ...p, answer: p.seq[i], text: p.seq.map((v, j) => (j === i ? "?" : fmt(v))).join(", "), wrong: [p.seq[i] + 1, p.seq[i] - 1, p.seq[i + 1], p.seq[i - 1]] };
  }
  if (!p.sym) return p;
  const whole = p.kind === "add" ? p.a + p.b : p.kind === "sub" ? p.a - p.b : p.kind === "mult" ? p.a * p.b : p.a / p.b;
  const roll = Math.random();
  // Which sign? Only when exactly one sign makes it true.
  if (roll < 0.25 && level >= 2) {
    const works = ["+", "−", "×", "÷"].filter(sg => {
      const v = sg === "+" ? p.a + p.b : sg === "−" ? p.a - p.b : sg === "×" ? p.a * p.b : p.b ? p.a / p.b : NaN;
      return v === whole;
    });
    if (works.length === 1) return { ...p, answer: p.sym, signs: true, text: `${fmt(p.a)} ? ${fmt(p.b)} = ${fmt(whole)}` };
  }
  if (roll < 0.6) return { ...p, answer: p.a, text: `? ${p.sym} ${fmt(p.b)} = ${fmt(whole)}`, wrong: null };
  return { ...p, answer: p.b, text: `${fmt(p.a)} ${p.sym} ? = ${fmt(whole)}`, wrong: null };
}

// How a problem is asked on screen, and how it reads with the answer filled in.
const SLOT = /(^|[\s,])\?(?=%|[\s,]|$)/;
export const ask = p => (SLOT.test(p.text) || p.text.endsWith("?") ? p.text : `${p.text} = ?`);
export const reveal = p => (SLOT.test(p.text) ? p.text.replace(SLOT, `$1${fmt(p.answer)}`) : p.text.endsWith("?") ? `${p.text} ${fmt(p.answer)}` : `${p.text} = ${fmt(p.answer)}`);

// Four choices: the answer plus wrong answers close enough to tempt.
export function choicesFor(p, count = 4) {
  if (p.signs) return ["+", "−", "×", "÷"];
  const ans = p.answer;
  let near;
  if (p.wrong) near = [...p.wrong];
  else {
    near = [ans + 1, ans - 1, ans + 2, ans - 2];
    if (ans >= 10) near.push(ans + 10, ans - 10);
    const s = String(ans);
    if (s.length >= 2 && Number.isInteger(ans)) near.push(Number(s.slice(0, -2) + s.slice(-1) + s.slice(-2, -1)));
    if (p.sym === "+") near.push(Math.abs(p.a - p.b));
    if (p.sym === "×") near.push(p.a + p.b, ans + p.a, ans - p.a);
    if (p.sym === "−") near.push(p.a + p.b);
    if (p.sym === "÷") near.push(p.a - p.b, ans * 2);
  }
  const pool = shuffle([...new Set(near.map(tidy))].filter(n => Number.isFinite(n) && n >= 0 && n !== tidy(ans)));
  const out = pool.slice(0, count - 1);
  let k = 3;
  const stepUp = Number.isInteger(ans) ? 1 : 0.1;
  while (out.length < count - 1) { const n = tidy(ans + k * stepUp); if (!out.includes(n)) out.push(n); k += 1; }
  return shuffle([tidy(ans), ...out]);
}

// Where a kid starts: their saved level for that kind, else a level for their age.
export function startLevelFor(player, op) {
  const saved = Number(player?.bests?.levels?.[op]);
  if (Number.isFinite(saved) && saved >= 1) return Math.min(MAX_LEVEL, saved);
  const age = player?.age;
  if (age == null) return 3;
  if (op === "add" || op === "sub") return age <= 6 ? 1 : age === 7 ? 3 : age <= 9 ? 4 : 6;
  if (op === "mult" || op === "div") return age <= 8 ? 1 : age <= 10 ? 3 : 4;
  if (op === "pattern") return age <= 7 ? 1 : age <= 9 ? 3 : age <= 12 ? 5 : 7;
  if (op === "estimate") return age <= 8 ? 1 : age <= 10 ? 3 : age <= 12 ? 5 : 7;
  if (op === "fraction") return age <= 8 ? 1 : age <= 10 ? 2 : age <= 12 ? 4 : 6;
  return age <= 10 ? 2 : age <= 13 ? 4 : 6;
}
export function defaultOpFor(player) {
  const age = player?.age;
  if (age == null) return "add";
  if (age < 9) return "add";
  if (age < 13) return "mult";
  return "mix";
}

// Cave Flight: your number must fit between the two numbers on one of three openings.
// Water drops change your number on the way. Numbers grow with the level.
export function caveStart(level) {
  return level <= 3 ? ri(3, 15) : level <= 6 ? ri(20, 80) : ri(100, 600);
}
export function caveDrop(n, level) {
  const ops = level <= 3
    ? [["+", ri(1, 5)], ["−", ri(1, Math.min(4, n - 1))]]
    : level <= 6
      ? [["+", ri(5, 20)], ["−", ri(5, Math.min(20, n - 5))], ["×", 2]]
      : [["+", ri(20, 120)], ["−", ri(20, Math.min(150, n - 20))], ["×", 2], ...(n % 2 === 0 ? [["÷", 2]] : [])];
  const valid = ops.filter(([, v]) => v > 0);
  const [sg, v] = pick(valid);
  const out = sg === "+" ? n + v : sg === "−" ? n - v : sg === "×" ? n * v : n / v;
  if (out > (level <= 3 ? 40 : level <= 6 ? 200 : 2000) || out < 1) return { op: `+ ${level <= 3 ? 1 : 10}`, value: n + (level <= 3 ? 1 : 10) };
  return { op: `${sg} ${v}`, value: out };
}
// Three openings, lowest to highest; exactly one has n strictly inside.
export function caveGaps(n, level) {
  const span = level <= 3 ? 4 : level <= 6 ? 15 : 80;
  const lo = n - ri(1, Math.min(span, n));
  const hi = n + ri(1, span);
  const w1 = ri(2, span * 2); const w2 = ri(2, span * 2);
  // No numbers below zero: the opening can only sit higher up when there's room under it.
  const at = pick([0, ...(lo - w1 >= 0 ? [1] : []), ...(lo - w1 - w2 >= 0 ? [2] : [])]);
  let edges;
  if (at === 0) edges = [lo, hi, hi + w1, hi + w1 + w2];
  else if (at === 1) edges = [lo - w1, lo, hi, hi + w2];
  else edges = [lo - w1 - w2, lo - w1, lo, hi];
  return { gaps: [0, 1, 2].map(i => ({ lo: edges[i], hi: edges[i + 1] })), right: at };
}
