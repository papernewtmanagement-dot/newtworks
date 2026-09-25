// ─── Weeks ────────────────────────────────────────────────────
// One place on the front end for "what week is it". The agency week runs
// Sunday to Saturday in Central, and it stays Central no matter where the
// browser is or what its own clock says. Anything that needs today, a week
// boundary, or a step of a few days works through here so no two screens can
// land on different weeks.
//
// Everything in and out is a plain ISO date string, YYYY-MM-DD. The arithmetic
// runs in UTC on purpose: a Date built at local midnight shifts a day when the
// browser sits east of UTC, which is the bug this file exists to end.

const CENTRAL = "America/Chicago";

function isValidISODate(s) {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

// Today's date in Central.
export function todayISOCentral() {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: CENTRAL,
    year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date());
  const get = (type) => parts.find((p) => p.type === type)?.value;
  return `${get("year")}-${get("month")}-${get("day")}`;
}

// Day of the week for an ISO date. 0 is Sunday, 6 is Saturday.
export function dayOfWeekISO(iso) {
  if (!isValidISODate(iso)) return null;
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

// A number of days on from an ISO date. Negative steps back.
export function addDaysISO(iso, days) {
  if (!isValidISODate(iso)) return null;
  const [y, m, d] = iso.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  t.setUTCDate(t.getUTCDate() + Number(days || 0));
  return t.toISOString().slice(0, 10);
}

// A number of whole months on from an ISO date. Pass a day and the result lands
// on that day of the target month instead of the start date's day. Either way a
// day past the end of a short month settles on its last day, so Jan 31 plus one
// month is Feb 28 (29 in a leap year). Negative months step back.
export function addMonthsISO(iso, months, day) {
  if (!isValidISODate(iso)) return null;
  const [y, m, d] = iso.split("-").map(Number);
  const idx = (m - 1) + Number(months || 0);
  const ty = y + Math.floor(idx / 12);
  const tm = ((idx % 12) + 12) % 12;
  const last = new Date(Date.UTC(ty, tm + 1, 0)).getUTCDate();
  const want = Math.min(Number(day) || d, last);
  return `${ty}-${String(tm + 1).padStart(2, "0")}-${String(want).padStart(2, "0")}`;
}

// The Saturday that ends the week the given ISO date falls in.
export function weekEndingSaturdayISO(iso) {
  const dow = dayOfWeekISO(iso);
  if (dow === null) return null;
  return addDaysISO(iso, 6 - dow);
}

// The Saturday that ends the current Central week.
export function currentWeekSaturdayCT() {
  return weekEndingSaturdayISO(todayISOCentral());
}
