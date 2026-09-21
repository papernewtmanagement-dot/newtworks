// ─── Kickoff cycle: today's week and day ──────────────────────
// The Daily Kickoff runs a 13-week cycle that restarts the first Monday of
// every quarter. Worked out in Central time. Saturday and Sunday point at the
// coming Monday, since that is the next kickoff. A quarter with a 14th week
// stays on week 13. Shared by the Kickoff page (Manual.jsx) and the Checklist
// tab on the Dashboard (ActivityLog.jsx), so both land on the same week.
export function kickoffToday() {
  const DAY = 86400000;
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago", year: "numeric", month: "numeric", day: "numeric",
  }).formatToParts(new Date());
  const get = (t) => Number((parts.find((p) => p.type === t) || {}).value);
  let d = new Date(Date.UTC(get("year"), get("month") - 1, get("day")));
  const dow = d.getUTCDay();
  if (dow === 6) d = new Date(d.getTime() + 2 * DAY);
  if (dow === 0) d = new Date(d.getTime() + DAY);
  const firstMonday = (y, q) => {
    const first = new Date(Date.UTC(y, q * 3, 1));
    return new Date(first.getTime() + ((8 - first.getUTCDay()) % 7) * DAY);
  };
  let y = d.getUTCFullYear();
  let q = Math.floor(d.getUTCMonth() / 3);
  let start = firstMonday(y, q);
  if (d < start) {
    q -= 1;
    if (q < 0) { q = 3; y -= 1; }
    start = firstMonday(y, q);
  }
  const week = Math.min(13, Math.floor((d.getTime() - start.getTime()) / (7 * DAY)) + 1);
  const day = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][d.getUTCDay()];
  return { week: String(week), day };
}

// Which week (or day) a page shows: the one picked in its dropdown, else
// today's, else the first the page has. list is scanSelector's weeks or days.
export function pickCycleValue(list, picked, todayValue) {
  if (!Array.isArray(list) || !list.length) return null;
  return (list.find((x) => x.value === picked) || list.find((x) => x.value === todayValue) || list[0]).value;
}
