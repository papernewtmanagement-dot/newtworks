import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// Meet & greet scheduler. Opens when a candidate is moved to the Meet & Greet
// stage.
//
// The interview before it lets the candidate pick their own time from slots the
// scheduler worked out. This stage deliberately does not: Peter picks the time
// himself (his ruling, 2026-08-21), because the meeting has to suit two or
// three teammates as well as him. So this form is a time picker, not a booking
// link — and it has to be filled in before the stage actually moves, because
// there is no meet & greet without a time on the calendar.
//
// Everything else the form asks is a real fork rather than a preference:
//   - in the office or on video, which changes both the calendar entry and
//     what the candidate's email tells them to do
//   - which teammates come, read live from the team list so a page left open
//     since last week cannot invite someone who has left
//   - work or personal addresses for those teammates, because a Google Meet
//     invite behaves differently arriving at a Google account than at a work
//     mailbox, and which one is better is a live question
//
// The writing all happens server-side in the hiring-interview-scheduler edge
// function (mode=schedule_meet_greet): the calendar credentials must never
// reach the browser. That function creates the event, moves the stage, and
// emails the candidate.

const TZ = "America/Chicago";

// How far Central sat from UTC at a given instant, in minutes.
function centralOffsetMinutes(utcDate) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const p = dtf.formatToParts(utcDate).reduce((a, x) => { a[x.type] = x.value; return a; }, {});
  const asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, p.hour === "24" ? 0 : +p.hour, +p.minute, +p.second);
  return (utcDate.getTime() - asUtc) / 60000;
}

// Turn the typed date + time into the exact moment that clock reading happens
// in Central. Typing 10:00 has to mean 10:00 in San Antonio even if the laptop
// is in another time zone, so the offset is looked up for that particular date
// rather than taken from the browser.
function centralIso(dateStr, timeStr) {
  if (!dateStr || !timeStr) return null;
  const [y, m, d] = dateStr.split("-").map(Number);
  const [hh, mm] = timeStr.split(":").map(Number);
  if (![y, m, d, hh, mm].every(Number.isFinite)) return null;
  const guess = Date.UTC(y, m - 1, d, hh, mm, 0);
  return new Date(guess + centralOffsetMinutes(new Date(guess)) * 60000).toISOString();
}

const isoDate = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

// Tomorrow, rolled forward off a weekend.
function defaultDate() {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  while (d.getDay() === 0 || d.getDay() === 6) d.setDate(d.getDate() + 1);
  return isoDate(d);
}

function displayWhen(iso, minutes) {
  if (!iso) return "—";
  const start = new Date(iso);
  if (Number.isNaN(start.getTime())) return "—";
  const day = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, weekday: "long", month: "long", day: "numeric",
    hour: "numeric", minute: "2-digit",
  }).format(start);
  const end = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, hour: "numeric", minute: "2-digit",
  }).format(new Date(start.getTime() + minutes * 60000));
  return `${day} – ${end} Central`;
}

const teamName = (m) => `${m.nickname || m.first_name || ""} ${m.last_name || ""}`.trim();

export default function MeetGreetModal({ candidate, onClose, onSaved }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "14px" : "20px 24px";

  const [team, setTeam] = useState([]);
  const [picked, setPicked] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);

  const [date, setDate] = useState(defaultDate());
  const [time, setTime] = useState("10:00");
  const [duration, setDuration] = useState(30);
  const [meetingKind, setMeetingKind] = useState("office");
  const [emailKind, setEmailKind] = useState("work");
  const [note, setNote] = useState("");

  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  const [result, setResult] = useState(null);

  const fullName = [candidate?.first_name, candidate?.last_name].filter(Boolean).join(" ")
    || candidate?.candidate_name || "";

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error } = await supabase
        .from("team")
        .select("id, first_name, last_name, nickname, role, role_level, email_sf, email_personal")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true)
        .order("first_name");
      if (cancelled) return;
      if (error) {
        setLoadError(error.message);
        setLoading(false);
        return;
      }
      // The owner runs the meeting and already gets a copy through the
      // forwarding address the scheduler adds, so he is not in the pick list.
      const rows = (data || []).filter((m) => m.role_level !== "Owner" && teamName(m));
      setTeam(rows);
      setPicked(rows.filter((m) => m.role_level === "Unit Manager").map((m) => m.id));
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, []);

  const startIso = useMemo(() => centralIso(date, time), [date, time]);
  const emailFor = (m) => (emailKind === "personal"
    ? (m.email_personal || m.email_sf)
    : (m.email_sf || m.email_personal));

  const toggle = (id) =>
    setPicked((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));

  const inThePast = startIso ? new Date(startIso).getTime() < Date.now() : false;
  const canSave = Boolean(candidate?.id) && Boolean(startIso) && !inThePast && !saving;

  const schedule = async () => {
    if (!canSave) return;
    setSaving(true);
    setSaveError(null);
    try {
      const { data, error: fnErr } = await supabase.functions.invoke("hiring-interview-scheduler", {
        body: {
          mode: "schedule_meet_greet",
          agency_id: AGENCY_ID,
          candidate_id: candidate.id,
          start: startIso,
          duration_minutes: Number(duration),
          meeting_kind: meetingKind,
          team_email_kind: emailKind,
          team_ids: picked,
          note,
        },
      });
      if (fnErr) {
        // A non-2xx reply arrives as an error with the response hanging off it;
        // the body says far more than the status line does.
        let detail = fnErr.message || String(fnErr);
        try {
          const body = await fnErr.context?.json?.();
          if (body?.error) detail = body.detail ? `${body.error} — ${body.detail}` : body.error;
        } catch { /* body already read, or not JSON — keep the status message */ }
        throw new Error(detail);
      }
      if (!data?.ok) {
        throw new Error(data?.detail ? `${data.error} — ${data.detail}` : (data?.error || "the scheduler returned no result"));
      }
      setResult(data);
    } catch (e) {
      setSaveError(e?.message || String(e));
    } finally {
      setSaving(false);
    }
  };

  const label = { fontSize: 11, fontWeight: 700, color: T.slate600, marginBottom: 4, display: "block" };
  const input = {
    width: "100%", boxSizing: "border-box", padding: "8px 10px", fontSize: 13,
    border: `1px solid ${T.slate200}`, borderRadius: 8, color: T.slate900, background: T.white,
  };
  const pill = (on) => ({
    flex: 1, minWidth: 110, boxSizing: "border-box", padding: "9px 10px", fontSize: 12,
    fontWeight: 700, borderRadius: 9, cursor: "pointer",
    border: `1px solid ${on ? T.teal : T.slate200}`,
    background: on ? T.tealLt : T.white,
    color: on ? T.teal : T.slate600,
  });

  return (
    <div
      onClick={onClose}
      style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.5)", display: "flex",
               alignItems: "center", justifyContent: "center", zIndex: 1000, padding: _vp.isPhone ? 8 : 20 }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{ background: T.white, borderRadius: 14, padding: _pad, width: "100%", maxWidth: 640,
                 maxHeight: "92vh", overflowY: "auto", boxSizing: "border-box",
                 boxShadow: "0 20px 60px rgba(0,0,0,0.3)" }}
      >
        <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between",
                      gap: 10, flexWrap: "wrap", marginBottom: 4 }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.01em" }}>
              Meet &amp; greet
            </div>
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
              {fullName || "Candidate"} · you pick the time
            </div>
          </div>
          <button onClick={onClose} style={{ background: "none", border: "none", fontSize: 20,
                                             color: T.slate400, cursor: "pointer", lineHeight: 1 }}>×</button>
        </div>

        {/* ---------- booked ---------- */}
        {result && (
          <div style={{ marginTop: 16 }}>
            <div style={{ background: T.greenLt, border: `1px solid ${T.green}`, borderRadius: 10,
                          padding: "12px 14px", boxSizing: "border-box" }}>
              <div style={{ fontSize: 13, fontWeight: 800, color: T.green }}>On the calendar</div>
              <div style={{ fontSize: 13, color: T.slate800, marginTop: 6 }}>{result.scheduled_display}</div>
              <div style={{ fontSize: 12, color: T.slate700, marginTop: 4 }}>{result.location}</div>
              {result.meet_url && (
                <div style={{ fontSize: 12, marginTop: 6, wordBreak: "break-all" }}>
                  <a href={result.meet_url} target="_blank" rel="noreferrer" style={{ color: T.blue }}>
                    {result.meet_url}
                  </a>
                </div>
              )}
              {Array.isArray(result.attendees) && result.attendees.length > 0 && (
                <div style={{ fontSize: 12, color: T.slate600, marginTop: 6 }}>
                  Invited: {result.attendees.map((a) => a.name).filter(Boolean).join(", ")}
                </div>
              )}
              <div style={{ fontSize: 12, color: T.slate600, marginTop: 6 }}>
                {result.emailed
                  ? "The candidate has been emailed and is on the calendar invite."
                  : "The candidate is on the calendar invite, but the email did not go out."}
              </div>
            </div>

            {result.calendar_conflict && (
              <div style={{ marginTop: 10, background: T.amberLt, border: `1px solid ${T.amber}`,
                            borderRadius: 10, padding: "10px 12px", fontSize: 12, color: T.slate800,
                            boxSizing: "border-box" }}>
                Something else is already on the calendar at that time. The meet &amp; greet was still
                booked — move it if that clash matters.
              </div>
            )}

            {!result.emailed && result.email_error && (
              <div style={{ marginTop: 10, background: T.redLt, border: `1px solid ${T.red}`,
                            borderRadius: 10, padding: "10px 12px", fontSize: 12, color: T.slate800,
                            boxSizing: "border-box" }}>
                Email did not send: {result.email_error}
              </div>
            )}

            <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 16 }}>
              <button
                onClick={() => { if (typeof onSaved === "function") onSaved(); }}
                style={{ padding: "10px 18px", fontSize: 13, fontWeight: 700, borderRadius: 9,
                         border: "none", background: T.blue, color: T.white, cursor: "pointer" }}
              >
                Done
              </button>
            </div>
          </div>
        )}

        {/* ---------- form ---------- */}
        {!result && (
          <>
            {loadError && (
              <div style={{ fontSize: 12, color: T.red, background: T.redLt, borderRadius: 8,
                            padding: "8px 10px", margin: "10px 0" }}>
                Could not load the team list: {loadError}
              </div>
            )}

            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))",
                          gap: 10, marginTop: 14 }}>
              <div>
                <label style={label}>Date</label>
                <input type="date" style={input} value={date} onChange={(e) => setDate(e.target.value)} />
              </div>
              <div>
                <label style={label}>Start time (Central)</label>
                <input type="time" style={input} value={time} onChange={(e) => setTime(e.target.value)} />
              </div>
              <div>
                <label style={label}>How long</label>
                <select style={input} value={duration} onChange={(e) => setDuration(Number(e.target.value))}>
                  <option value={30}>30 minutes</option>
                  <option value={45}>45 minutes</option>
                  <option value={60}>1 hour</option>
                </select>
              </div>
            </div>

            <div style={{ fontSize: 12, color: inThePast ? T.red : T.slate600, marginTop: 8 }}>
              {inThePast ? "That time has already passed." : displayWhen(startIso, Number(duration))}
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={label}>Where</label>
              <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                <button style={pill(meetingKind === "office")} onClick={() => setMeetingKind("office")}>
                  In the office
                </button>
                <button style={pill(meetingKind === "video")} onClick={() => setMeetingKind("video")}>
                  Google Meet
                </button>
              </div>
              <div style={{ fontSize: 11, color: T.slate500, marginTop: 5 }}>
                {meetingKind === "office"
                  ? "The office address goes on the invite and in the candidate's email."
                  : "A fresh Meet link is created with the event and sent to everyone on it."}
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between",
                            gap: 8, flexWrap: "wrap" }}>
                <label style={{ ...label, marginBottom: 0 }}>Who else is coming</label>
                <div style={{ display: "flex", gap: 6 }}>
                  <button
                    onClick={() => setEmailKind("work")}
                    style={{ padding: "3px 9px", fontSize: 10, fontWeight: 700, borderRadius: 20,
                             border: `1px solid ${emailKind === "work" ? T.blue : T.slate200}`,
                             background: emailKind === "work" ? T.blueLt : T.white,
                             color: emailKind === "work" ? T.blue : T.slate500, cursor: "pointer" }}
                  >
                    Work email
                  </button>
                  <button
                    onClick={() => setEmailKind("personal")}
                    style={{ padding: "3px 9px", fontSize: 10, fontWeight: 700, borderRadius: 20,
                             border: `1px solid ${emailKind === "personal" ? T.blue : T.slate200}`,
                             background: emailKind === "personal" ? T.blueLt : T.white,
                             color: emailKind === "personal" ? T.blue : T.slate500, cursor: "pointer" }}
                  >
                    Personal email
                  </button>
                </div>
              </div>

              {loading && (
                <div style={{ fontSize: 12, color: T.slate500, padding: "10px 0" }}>Loading the team…</div>
              )}

              {!loading && team.length === 0 && (
                <div style={{ fontSize: 12, color: T.slate500, padding: "10px 0" }}>
                  No active teammates to invite. The meeting will be you and the candidate.
                </div>
              )}

              {!loading && team.length > 0 && (
                <div style={{ marginTop: 8, border: `1px solid ${T.slate200}`, borderRadius: 10,
                              overflow: "hidden", boxSizing: "border-box" }}>
                  {team.map((m, i) => {
                    const addr = emailFor(m);
                    const on = picked.includes(m.id);
                    return (
                      <label
                        key={m.id}
                        style={{ display: "flex", alignItems: "center", gap: 10, padding: "9px 12px",
                                 boxSizing: "border-box",
                                 borderTop: i === 0 ? "none" : `1px solid ${T.slate100}`,
                                 background: on ? T.tealLt : T.white,
                                 cursor: addr ? "pointer" : "not-allowed", opacity: addr ? 1 : 0.55 }}
                      >
                        <input
                          type="checkbox"
                          checked={on}
                          disabled={!addr}
                          onChange={() => toggle(m.id)}
                          style={{ width: 16, height: 16, flexShrink: 0, accentColor: T.teal }}
                        />
                        <span style={{ minWidth: 0 }}>
                          <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>
                            {teamName(m)}
                          </span>
                          {m.role_level && (
                            <span style={{ fontSize: 11, color: T.slate500 }}> · {m.role_level}</span>
                          )}
                          <span style={{ display: "block", fontSize: 11, color: addr ? T.slate500 : T.red,
                                         wordBreak: "break-all" }}>
                            {addr || "no email on file"}
                          </span>
                        </span>
                      </label>
                    );
                  })}
                </div>
              )}
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={label}>Anything to add to the candidate's email (optional)</label>
              <textarea
                style={{ ...input, minHeight: 70, resize: "vertical", fontFamily: "inherit" }}
                value={note}
                onChange={(e) => setNote(e.target.value)}
                placeholder="Parking is behind the building — come to suite 125 and ask for me."
              />
            </div>

            {saveError && (
              <div style={{ fontSize: 12, color: T.red, background: T.redLt, borderRadius: 8,
                            padding: "8px 10px", marginTop: 12, boxSizing: "border-box" }}>
                {saveError}
              </div>
            )}

            <div style={{ display: "flex", justifyContent: "flex-end", gap: 8, marginTop: 18,
                          flexWrap: "wrap" }}>
              <button
                onClick={onClose}
                style={{ padding: "10px 16px", fontSize: 13, fontWeight: 700, borderRadius: 9,
                         border: `1px solid ${T.slate200}`, background: T.white, color: T.slate600,
                         cursor: "pointer" }}
              >
                Cancel
              </button>
              <button
                onClick={schedule}
                disabled={!canSave}
                style={{ padding: "10px 18px", fontSize: 13, fontWeight: 700, borderRadius: 9,
                         border: "none", background: canSave ? T.teal : T.slate300, color: T.white,
                         cursor: canSave ? "pointer" : "not-allowed" }}
              >
                {saving ? "Booking…" : "Book it and email them"}
              </button>
            </div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 6, textAlign: "right" }}>
              This creates the calendar invite, emails the candidate, and moves them to Meet &amp; Greet.
            </div>
          </>
        )}
      </div>
    </div>
  );
}
