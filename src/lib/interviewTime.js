import { T } from "./theme.js";

// One place that turns a candidate's interview fields into the short line
// shown on the pipeline card and the candidate detail page. Reads
// hiring_candidates columns: interview_scheduled_start, interview_booked_at,
// interview_invite_sent_at, interview_reminder_response.
// Returns null when there is nothing to say (no invite sent yet).
export const INTERVIEW_TIME_COLS = "interview_scheduled_start, interview_booked_at, interview_invite_sent_at, interview_reminder_response";

const fmt = (iso) => {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return null;
  const day = d.toLocaleDateString("en-US", { timeZone: "America/Chicago", weekday: "short", month: "short", day: "numeric" });
  const time = d.toLocaleTimeString("en-US", { timeZone: "America/Chicago", hour: "numeric", minute: "2-digit" });
  return `${day} · ${time}`;
};

export function interviewTimeLine(c) {
  if (!c) return null;
  if (c.interview_booked_at && c.interview_scheduled_start) {
    const when = fmt(c.interview_scheduled_start);
    if (!when) return null;
    const past = new Date(c.interview_scheduled_start).getTime() < Date.now();
    return { text: past ? `Interviewed ${when}` : `Interview ${when}`, color: past ? T.slate500 : T.blue };
  }
  if (c.interview_reminder_response === "reschedule") {
    return { text: "Asked for a new time — not rebooked yet", color: T.amber };
  }
  if (c.interview_invite_sent_at) {
    return { text: "Invite sent — no time picked yet", color: T.amber };
  }
  return null;
}
