// =========================================================================
// src/lib/cron.js
// =========================================================================
// Turns a cron expression into a sentence a person can read.
//
// Why this exists: the Automations page used to print recipe.cron_label,
// a column that does not exist on automation_recipes. Every live recipe
// showed an empty Trigger field. The expressions themselves are not
// readable either -- "59 8 * * *" tells you nothing at a glance.
//
// One function, one job. Anywhere a schedule needs to be shown to a
// person, call describeSchedule(recipe). Do not re-derive this anywhere
// else.
//
// Honest by design: the runner fires recipes at 59 minutes past the hour,
// so a recipe written as "59 8 * * *" really does run at 8:59 AM and that
// is what this prints. It does not round the minute away.
// =========================================================================

const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTH_NAMES = [
  null, "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

const TZ_LABELS = {
  "America/Chicago": "Central",
  UTC: "UTC",
};

// "a", "a and b", "a, b and c"
function joinList(parts) {
  const list = (parts || []).filter(Boolean);
  if (list.length === 0) return "";
  if (list.length === 1) return list[0];
  return `${list.slice(0, -1).join(", ")} and ${list[list.length - 1]}`;
}

// 0 -> "12:00 AM", 8 -> "8:00 AM", 20 -> "8:00 PM"
function clockTime(hour, minute) {
  const h24 = Number(hour);
  const m = Number(minute);
  if (!Number.isFinite(h24) || !Number.isFinite(m)) return "";
  const suffix = h24 < 12 ? "AM" : "PM";
  let h12 = h24 % 12;
  if (h12 === 0) h12 = 12;
  return `${h12}:${String(m).padStart(2, "0")} ${suffix}`;
}

// Reads one cron field. Returns { every: true } for "*",
// { step: n } for "*/n", or { values: [...] } for "3", "3,7", "8-16".
function readField(field, min, max) {
  const raw = String(field || "").trim();
  if (raw === "" || raw === "*") return { every: true };

  const stepMatch = raw.match(/^\*\/(\d+)$/);
  if (stepMatch) return { step: Number(stepMatch[1]) };

  const values = [];
  for (const part of raw.split(",")) {
    const range = part.match(/^(\d+)-(\d+)$/);
    if (range) {
      const from = Number(range[1]);
      const to = Number(range[2]);
      if (from <= to) for (let v = from; v <= to; v++) values.push(v);
      else { for (let v = from; v <= max; v++) values.push(v); for (let v = min; v <= to; v++) values.push(v); }
      continue;
    }
    const single = Number(part);
    if (Number.isFinite(single)) values.push(single);
  }
  if (values.length === 0) return { every: true };
  return { values, contiguous: /^\d+-\d+$/.test(raw) };
}

// "Weekdays", "Weekends", "Saturdays", "Sunday to Wednesday", or "" for daily.
function describeDays(dowField) {
  const dow = readField(dowField, 0, 6);
  if (dow.every || dow.step) return "";

  const days = [...new Set(dow.values.map((d) => (d === 7 ? 0 : d)))].sort((a, b) => a - b);
  if (days.length === 7) return "";

  const isWeekdays = days.length === 5 && days.every((d) => d >= 1 && d <= 5);
  if (isWeekdays) return "weekdays";

  const isWeekends = days.length === 2 && days.includes(0) && days.includes(6);
  if (isWeekends) return "weekends";

  if (days.length === 1) return `${DAY_NAMES[days[0]]}s`;

  if (dow.contiguous) return `${DAY_NAMES[days[0]]} to ${DAY_NAMES[days[days.length - 1]]}`;

  return joinList(days.map((d) => DAY_NAMES[d]));
}

// "November and December", or "" when it runs all year.
function describeMonths(monthField) {
  const months = readField(monthField, 1, 12);
  if (months.every || months.step) return "";
  const names = months.values.filter((m) => m >= 1 && m <= 12).map((m) => MONTH_NAMES[m]);
  if (names.length === 0 || names.length === 12) return "";
  return joinList(names);
}

// 1 -> "1st", 2 -> "2nd", 23 -> "23rd"
function ordinal(n) {
  const num = Number(n);
  if (!Number.isFinite(num)) return String(n);
  const tens = num % 100;
  if (tens >= 11 && tens <= 13) return `${num}th`;
  const ones = num % 10;
  if (ones === 1) return `${num}st`;
  if (ones === 2) return `${num}nd`;
  if (ones === 3) return `${num}rd`;
  return `${num}th`;
}

/**
 * Turn a five-field cron expression into a sentence.
 * Returns "" when the expression cannot be read, so callers can fall back.
 */
export function cronToPlainEnglish(expression, timezone) {
  const fields = String(expression || "").trim().split(/\s+/);
  if (fields.length < 5) return "";

  const [minField, hourField, domField, monthField, dowField] = fields;

  const minute = readField(minField, 0, 59);
  const hour = readField(hourField, 0, 23);
  const dom = readField(domField, 1, 31);

  // A single fixed minute is the only shape in use. Anything stranger is
  // better shown raw than described wrongly.
  if (minute.every || minute.step || minute.values.length !== 1) return "";
  const m = minute.values[0];

  const days = describeDays(dowField);
  const months = describeMonths(monthField);

  let core;

  if (hour.every) {
    core = m === 0 ? "Every hour" : `Every hour, at ${m} minutes past`;
  } else if (hour.step) {
    const pace = hour.step === 1 ? "Every hour" : `Every ${hour.step} hours`;
    core = m === 0 ? pace : `${pace}, at ${m} minutes past`;
  } else if (hour.contiguous && hour.values.length > 1) {
    const first = clockTime(hour.values[0], m);
    const last = clockTime(hour.values[hour.values.length - 1], m);
    core = `Hourly from ${first} to ${last}`;
  } else {
    const times = hour.values.map((h) => clockTime(h, m));
    core = `At ${joinList(times)}`;
  }

  // Day-of-month wins over day-of-week when it is set to a specific date.
  let whenPart = "";
  if (!dom.every && !dom.step && dom.values.length > 0) {
    whenPart = `the ${joinList(dom.values.map(ordinal))} of the month`;
  } else if (days) {
    whenPart = days;
  } else if (!hour.every && !hour.step) {
    whenPart = "daily";
  }

  let sentence = whenPart ? `${core}, ${whenPart}` : core;
  if (months) sentence += `, ${months} only`;

  const tz = TZ_LABELS[timezone] || (timezone ? String(timezone) : "");
  if (tz) sentence += ` (${tz})`;

  return sentence;
}

/**
 * What to show in a recipe's Trigger field. Handles non-cron recipes too.
 */
export function describeSchedule(recipe) {
  if (!recipe) return "Not scheduled";

  if (recipe.trigger_type && recipe.trigger_type !== "cron") {
    if (recipe.trigger_event) return `On ${String(recipe.trigger_event).replace(/_/g, " ")}`;
    return "Event triggered";
  }

  if (!recipe.cron_expression) return "Not scheduled";

  const plain = cronToPlainEnglish(recipe.cron_expression, recipe.timezone);
  return plain || recipe.cron_expression;
}
