// src/lib/format.jsx
//
// Canonical money formatting for Newtworks. Accounting convention:
// negatives render as parentheses (never a leading minus) and, when the
// consuming surface renders JSX children, in red.
//
// Two exports:
//   fmtMoney(val, opts) — always returns a STRING. Safe in template
//                         literals, alert() text, subtitles that
//                         concatenate multiple values, etc.
//   fmtMoneyR(val, opts) — returns a STRING for positives / zero /
//                          invalid input, but a red-colored JSX <span>
//                          for negatives. Use in JSX-child positions
//                          where accounting-red is desired.
//
// opts:
//   decimals       — number of decimal places (default 0)
//   dashOnZero     — render "—" for zero (default false)
//   dashOnInvalid  — render "—" for null / undefined / "" / NaN
//                    (default true — most callers want this)
//
// Examples:
//   fmtMoney( 1234)                        → "$1,234"
//   fmtMoney(-1234)                        → "($1,234)"
//   fmtMoney( 1234.56, { decimals: 2 })    → "$1,234.56"
//   fmtMoney(-1234.56, { decimals: 2 })    → "($1,234.56)"
//   fmtMoney(0,       { dashOnZero: true }) → "—"
//   fmtMoney(null)                          → "—"
//   fmtMoney(null,    { dashOnInvalid: false, decimals: 2 }) → "$0.00"

import { T } from "./theme.js";

export function fmtMoney(val, opts = {}) {
  const {
    decimals = 0,
    dashOnZero = false,
    dashOnInvalid = true,
  } = opts;

  // Invalid input branch
  if (val === null || val === undefined || val === "") {
    return dashOnInvalid ? "—" : `$${(0).toFixed(decimals)}`;
  }
  const n = Number(val);
  if (!Number.isFinite(n)) {
    return dashOnInvalid ? "—" : `$${(0).toFixed(decimals)}`;
  }

  // Zero branch
  if (n === 0 && dashOnZero) return "—";

  // Formatted absolute value
  const abs = Math.abs(n).toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
  return n < 0 ? `($${abs})` : `$${abs}`;
}

export function fmtMoneyR(val, opts = {}) {
  const s = fmtMoney(val, opts);
  const n = Number(val);
  if (Number.isFinite(n) && n < 0) {
    return <span style={{ color: T.red }}>{s}</span>;
  }
  return s;
}
