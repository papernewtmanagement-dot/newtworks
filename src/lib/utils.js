/**
 * fmt — null-safe currency formatter
 * fmt(1234.5) → "$1,234.50"
 * fmt(null) → "$0.00"
 * fmt(undefined) → "$0.00"
 */
export function fmt(val) {
  const n = parseFloat(val);
  if (isNaN(n)) return "$0.00";
  return "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/**
 * pct — null-safe percentage calculator
 * pct(75, 100) → "75.0"
 */
export function pct(val, max) {
  const v = parseFloat(val) || 0;
  const m = parseFloat(max) || 1;
  return ((v / m) * 100).toFixed(1);
}

/**
 * parseLocalDate — parse a date value without UTC-shifting bare YYYY-MM-DD strings.
 * Postgres `date` columns arrive as bare "YYYY-MM-DD"; `new Date("YYYY-MM-DD")` treats
 * that as UTC midnight, which renders as the *previous* day in Central Time. Append
 * "T00:00:00" so JS parses it as local midnight instead. Full ISO timestamps and Date
 * objects pass through unchanged.
 */
export function parseLocalDate(val) {
  if (val instanceof Date) return val;
  if (typeof val === "string" && /^\d{4}-\d{2}-\d{2}$/.test(val)) {
    return new Date(val + "T00:00:00");
  }
  return new Date(val);
}

/**
 * fmtDate — format a date string for display
 * fmtDate("2026-04-15") → "Apr 15, 2026"
 */
export function fmtDate(dateStr) {
  if (!dateStr) return "—";
  try {
    return parseLocalDate(dateStr).toLocaleDateString("en-US", {
      month: "short", day: "numeric", year: "numeric"
    });
  } catch {
    return dateStr;
  }
}

/**
 * fmtDateShort — short date format
 * fmtDateShort("2026-04-15") → "Apr 15"
 */
export function fmtDateShort(dateStr) {
  if (!dateStr) return "—";
  try {
    return parseLocalDate(dateStr).toLocaleDateString("en-US", {
      month: "short", day: "numeric"
    });
  } catch {
    return dateStr;
  }
}

/**
 * todayLabel — returns today as "Mon D" matching content_calendar format
 * todayLabel() → "Apr 28"
 */
export function todayLabel() {
  return new Date().toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

/**
 * safeArr — ensure value is always an array
 */
export function safeArr(val) {
  if (Array.isArray(val)) return val;
  return [];
}

/**
 * safeNum — ensure value is always a number
 */
export function safeNum(val) {
  const n = parseFloat(val);
  return isNaN(n) ? 0 : n;
}
