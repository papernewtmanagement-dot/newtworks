import { useState, useEffect, useCallback, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { mdToHtml } from "../lib/markdown.js";

import { useTabParam } from "../lib/routing.jsx";
// ============================================================
// Time Off & Remote Request Module
// Spec: persistent_memory id fcaa841a-68f0-481c-a348-9d07f1699a85
// Handbook: §02 Hours & Time Off (v25)
// ============================================================

const REQUEST_TYPES = [
  { id: "time_off_full_day",             label: "Time off (full day)",              partial: false, location: false, submitViaDropdown: true  },
  { id: "time_off_half_day",             label: "Time off (half day)",              partial: true,  location: false, submitViaDropdown: true  },
  { id: "sick",                          label: "Sick",                             partial: false, location: false, submitViaDropdown: false },
  { id: "remote_day",                    label: "Remote (full day)",                partial: false, location: true,  submitViaDropdown: true  },
  { id: "remote_half_day",               label: "Remote (half day)",                partial: true,  location: true,  submitViaDropdown: true  },
  { id: "four_day_off_change",           label: "Change my 4-day off day (legacy)", partial: false, location: false, submitViaDropdown: false },
  { id: "standing_time_off_preference",  label: "WtW day off",                      partial: false, location: false, submitViaDropdown: false }
];

const STATUS_STYLES = {
  pending:              { bg: "#f1f5f9", fg: "#475569", label: "Pending" },
  voting:               { bg: "#dbeafe", fg: "#1e40af", label: "Voting" },
  awaiting_decision:    { bg: "#fef3c7", fg: "#92400e", label: "Awaiting Decision" },
  approved:             { bg: "#d1fae5", fg: "#065f46", label: "Approved" },
  denied:               { bg: "#fee2e2", fg: "#991b1b", label: "Denied" },
  expired:              { bg: "#f3f4f6", fg: "#6b7280", label: "Expired" },
  cancelled:            { bg: "#f3f4f6", fg: "#6b7280", label: "Cancelled" },
  flagged_case_by_case: { bg: "#fde68a", fg: "#78350f", label: "Case-by-Case" }
};

// Add N business days (Mon-Fri, local time) to a Date. Weekends are skipped, not counted.
// Team is CT-anchored so local weekday is the right anchor.
function addBusinessDays(from, days) {
  const result = new Date(from);
  let remaining = days;
  while (remaining > 0) {
    result.setDate(result.getDate() + 1);
    const dow = result.getDay(); // 0=Sun, 6=Sat
    if (dow !== 0 && dow !== 6) remaining -= 1;
  }
  return result;
}

// Human display label. Paid-time-off requests display as "PTO" only after approval
// with is_paid=true; unpaid or pre-decision reads generic "Time off".
function formatRequestLabel(request) {
  if (!request) return "";
  const t = request.request_type;
  const paid = request.is_paid === true;
  if (t === "time_off_full_day") return paid ? "PTO (full day)" : "Time off (full day)";
  if (t === "time_off_half_day") return paid ? "PTO (half day)" : "Time off (half day)";
  if (t === "standing_time_off_preference") return "WtW day off";
  const fallback = REQUEST_TYPES.find(x => x.id === t);
  return fallback ? fallback.label : (t || "");
}


const COVERAGE_STYLES = {
  green:  { bg: "#dcfce7", fg: "#166534", emoji: "🟢", label: "Clear" },
  yellow: { bg: "#fef9c3", fg: "#854d0e", emoji: "🟡", label: "Coverage concern" },
  red:    { bg: "#fee2e2", fg: "#991b1b", emoji: "🔴", label: "Coverage blocked" }
};

function StatusBadge({ status }) {
  const s = STATUS_STYLES[status] || STATUS_STYLES.pending;
  return (
    <span style={{ background: s.bg, color: s.fg, padding: "2px 10px", borderRadius: 12, fontSize: 11, fontWeight: 600, display: "inline-block" }}>
      {s.label}
    </span>
  );
}

function CoverageBadge({ severity, messages }) {
  const s = COVERAGE_STYLES[severity] || COVERAGE_STYLES.green;
  const msgList = Array.isArray(messages) ? messages : [];
  return (
    <div style={{ background: s.bg, color: s.fg, padding: 8, borderRadius: 6, fontSize: 12 }}>
      <div style={{ fontWeight: 600 }}>{s.emoji} {s.label}</div>
      {msgList.length > 0 && (
        <ul style={{ margin: "4px 0 0 16px", padding: 0 }}>
          {msgList.map((m, i) => <li key={i}>{m}</li>)}
        </ul>
      )}
    </div>
  );
}

function fmtDate(d) {
  if (!d) return "—";
  const dt = new Date(d + "T12:00:00");
  return dt.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", year: "numeric" });
}

function fmtDateTime(ts) {
  if (!ts) return "—";
  return new Date(ts).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

function CheckCard({ title, ok, warn, detail }) {
  const palette = ok
    ? { bg: "#dcfce7", fg: "#166534", emoji: "✅" }
    : warn
      ? { bg: "#fef9c3", fg: "#854d0e", emoji: "🟡" }
      : { bg: "#fee2e2", fg: "#991b1b", emoji: "⚠️" };
  return (
    <div style={{ background: palette.bg, color: palette.fg, padding: 8, borderRadius: 6, fontSize: 12 }}>
      <div style={{ fontWeight: 600 }}>{palette.emoji} {title}</div>
      <div style={{ marginTop: 2 }}>{detail}</div>
    </div>
  );
}

// Styles
const labelStyle = { display: "block", fontSize: 12, fontWeight: 600, color: "#475569", marginTop: 12, marginBottom: 4, textTransform: "uppercase", letterSpacing: 0.3 };
const inputStyle = { width: "100%", padding: "8px 10px", border: "1px solid #cbd5e1", borderRadius: 6, fontSize: 14, boxSizing: "border-box" };
const cardStyle = { background: "#fff", border: "1px solid #e2e8f0", borderRadius: 8, padding: 14 };
const btnBase = { padding: "8px 14px", border: "none", borderRadius: 6, cursor: "pointer", fontSize: 13, fontWeight: 600 };
const btnPrimary = { ...btnBase, background: "#2563eb", color: "#fff" };
const btnYes = { ...btnBase, background: "#16a34a", color: "#fff" };
const btnNo = { ...btnBase, background: "#dc2626", color: "#fff" };
const btnAbstain = { ...btnBase, background: "#e2e8f0", color: "#475569" };
const btnApprove = { ...btnBase, background: "#16a34a", color: "#fff" };
const btnDeny = { ...btnBase, background: "#dc2626", color: "#fff" };

// ============================================================
// STANDING TIME OFF PREFERENCE — components
// ============================================================
const DOW_LABELS = { monday: "Mon", tuesday: "Tue", wednesday: "Wed", thursday: "Thu", friday: "Fri" };
const DAY_PART_LABELS = { morning: "morning", afternoon: "afternoon", full: "full day" };
const PATTERN_LABELS = { off: "off", remote: "remote" };
const TRIGGER_LABELS = {
  wtw_won_prior_week: "WtW day off — applies only in weeks after we win Win the Week the prior week",
  always: "WtW day off — every week (grandfathered)"
};

function stopSummary(p) {
  // "Mon morning remote" / "Wed afternoon off" / "Fri full day off"
  const dow = DOW_LABELS[p.day_of_week] || p.day_of_week;
  const part = DAY_PART_LABELS[p.day_part] || p.day_part;
  const pat = PATTERN_LABELS[p.pattern] || p.pattern;
  return `${dow} ${part} ${pat}`;
}

function MyStandingPrefsPanel({ me }) {
  const [prefs, setPrefs] = useState([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    async function load() {
      if (!me?.id || !supabase) { setLoaded(true); return; }
      try {
        const { data } = await supabase
          .from("standing_time_off_preferences")
          .select("id, day_of_week, day_part, pattern, is_paid, trigger_type, effective_from, effective_until, notes")
          .eq("agency_id", AGENCY_ID)
          .eq("team_member_id", me.id)
          .is("archived_at", null);
        setPrefs(Array.isArray(data) ? data : []);
      } catch (e) { console.error("standing prefs load", e); }
      finally { setLoaded(true); }
    }
    load();
  }, [me?.id]);

  if (!loaded) return null;

  // Group by trigger for display
  const byTrigger = prefs.reduce((acc, p) => {
    (acc[p.trigger_type] = acc[p.trigger_type] || []).push(p);
    return acc;
  }, {});

  return (
    <div style={{ ...cardStyle, background: prefs.length ? "#f0f9ff" : "#f8fafc", borderColor: prefs.length ? "#bae6fd" : "#e2e8f0" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: prefs.length ? 10 : 0 }}>
        <div style={{ fontSize: 14, fontWeight: 700, color: "#0c4a6e" }}>My WtW Days Off</div>
        {prefs.length === 0 && <div style={{ fontSize: 12, color: "#64748b" }}>— none yet. Submit one below.</div>}
      </div>
      {Object.entries(byTrigger).map(([trigger, items]) => (
        <div key={trigger} style={{ marginBottom: 8 }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: "#0369a1", textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 4 }}>
            {TRIGGER_LABELS[trigger] || trigger}
          </div>
          <ul style={{ margin: 0, paddingLeft: 18, fontSize: 13, color: "#0f172a" }}>
            {items.map(p => (
              <li key={p.id}>
                {stopSummary(p)}{p.is_paid ? " (paid)" : " (unpaid)"}
              </li>
            ))}
          </ul>
        </div>
      ))}
      {prefs.length > 0 && (
        <div style={{ fontSize: 11, color: "#64748b", marginTop: 6 }}>
          These auto-generate as approved time-off entries each qualifying week.
        </div>
      )}
    </div>
  );
}

function StandingPrefBuilder({ me, onSubmitted }) {
  const [expanded, setExpanded] = useState(false);
  const [days, setDays] = useState([
    { day_of_week: "monday", day_part: "morning", pattern: "remote" }
  ]);
  const [trigger, setTrigger] = useState("wtw_won_prior_week");
  const [isPaid, setIsPaid] = useState(true);
  const [effectiveFrom, setEffectiveFrom] = useState("");
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);

  function addDay() {
    setDays([...days, { day_of_week: "monday", day_part: "morning", pattern: "off" }]);
  }
  function removeDay(idx) {
    setDays(days.filter((_, i) => i !== idx));
  }
  function updateDay(idx, field, value) {
    setDays(days.map((d, i) => (i === idx ? { ...d, [field]: value } : d)));
  }

  async function submit() {
    if (!me?.id || !supabase) return;
    if (days.length === 0) { setError("Add at least one day to the pattern."); return; }
    if (!effectiveFrom) { setError("Pick an effective-from date."); return; }
    setSubmitting(true);
    setError(null);
    try {
      const voteOpenedAt = new Date().toISOString();
      const voteClosesAt = addBusinessDays(new Date(), 2).toISOString();
      const { error: insErr } = await supabase.from("time_off_requests").insert({
        agency_id: AGENCY_ID,
        requester_team_id: me.id,
        request_type: "standing_time_off_preference",
        start_date: effectiveFrom,
        end_date: effectiveFrom,
        partial_day: "none",
        notes: notes || null,
        status: "voting",
        vote_opened_at: voteOpenedAt,
        vote_closes_at: voteClosesAt,
        standing_pref_days: days,
        standing_pref_trigger: trigger,
        standing_pref_is_paid: isPaid
      });
      if (insErr) throw insErr;
      setDays([{ day_of_week: "monday", day_part: "morning", pattern: "remote" }]);
      setNotes(""); setEffectiveFrom("");
      setExpanded(false);
      alert("WtW day off request submitted. Team has 2 weekdays to vote, then Peter decides.");
      if (typeof onSubmitted === "function") onSubmitted();
    } catch (e) {
      setError(e?.message || "Submit failed");
    } finally {
      setSubmitting(false);
    }
  }

  const dowOptions = [
    { v: "monday", l: "Monday" }, { v: "tuesday", l: "Tuesday" }, { v: "wednesday", l: "Wednesday" },
    { v: "thursday", l: "Thursday" }, { v: "friday", l: "Friday" }
  ];
  const dayPartOptions = [
    { v: "morning", l: "Morning (~8:30 AM – 1 PM CT)" },
    { v: "afternoon", l: "Afternoon (~1 PM – 5:30 PM CT)" },
    { v: "full", l: "Full workday" }
  ];
  const patternOptions = [
    { v: "off", l: "Off (not working)" },
    { v: "remote", l: "Remote (still working, from home)" }
  ];

  return (
    <div style={{ border: "1px solid #e2e8f0", borderRadius: 8, background: "#fff", overflow: "hidden" }}>
      <button
        type="button"
        onClick={() => setExpanded(v => !v)}
        style={{ width: "100%", padding: "12px 16px", background: "transparent", border: "none", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "space-between", fontSize: 14, fontWeight: 700, color: "#0f172a", textAlign: "left" }}
      >
        <span>➕ Request a WtW day off</span>
        <span style={{ transform: expanded ? "rotate(90deg)" : "rotate(0deg)", transition: "transform 0.15s", color: "#64748b", fontSize: 18, lineHeight: 1 }}>›</span>
      </button>
      {expanded && (
        <div style={{ padding: "12px 16px 16px", borderTop: "1px solid #e2e8f0" }}>
          <div style={{ fontSize: 12, color: "#64748b", marginBottom: 10, lineHeight: 1.5 }}>
            A WtW day off is a recurring weekly pattern earned through Win the Week: it only applies in weeks after we win the prior week. Once approved, each qualifying week auto-generates approved time-off entries on your calendar and shows up in coverage checks. Examples: Fridays off, Monday afternoon off, Tuesday and Thursday afternoons off.
          </div>

          <label style={labelStyle}>Pattern (add one row per day)</label>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {days.map((d, idx) => (
              <div key={idx} style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr auto", gap: 6, alignItems: "center" }}>
                <select value={d.day_of_week} onChange={e => updateDay(idx, "day_of_week", e.target.value)} style={inputStyle}>
                  {dowOptions.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
                </select>
                <select value={d.day_part} onChange={e => updateDay(idx, "day_part", e.target.value)} style={inputStyle}>
                  {dayPartOptions.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
                </select>
                <select value={d.pattern} onChange={e => updateDay(idx, "pattern", e.target.value)} style={inputStyle}>
                  {patternOptions.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
                </select>
                <button
                  type="button"
                  onClick={() => removeDay(idx)}
                  disabled={days.length <= 1}
                  style={{ padding: "6px 10px", background: "#fff", color: "#dc2626", border: "1px solid #fecaca", borderRadius: 6, cursor: days.length <= 1 ? "not-allowed" : "pointer", fontSize: 12, fontWeight: 600, opacity: days.length <= 1 ? 0.4 : 1 }}
                >Remove</button>
              </div>
            ))}
          </div>
          <button
            type="button"
            onClick={addDay}
            style={{ marginTop: 8, padding: "6px 12px", background: "#f1f5f9", color: "#0f172a", border: "1px solid #cbd5e1", borderRadius: 6, cursor: "pointer", fontSize: 12, fontWeight: 600 }}
          >+ Add another day</button>

          <div style={{ ...labelStyle, marginBottom: 4 }}>When this applies</div>
          <div style={{ padding: "8px 10px", background: "#fef3c7", border: "1px solid #f59e0b", borderRadius: 6, fontSize: 12, color: "#78350f" }}>
            Only in weeks after we win Win the Week the prior week.
          </div>

          <label style={labelStyle}>Pay treatment</label>
          <select value={isPaid ? "paid" : "unpaid"} onChange={e => setIsPaid(e.target.value === "paid")} style={inputStyle}>
            <option value="paid">Paid</option>
            <option value="unpaid">Unpaid</option>
          </select>

          <label style={labelStyle}>Effective from (first Monday the pattern should count)</label>
          <input type="date" value={effectiveFrom} onChange={e => setEffectiveFrom(e.target.value)} style={inputStyle} />

          <label style={labelStyle}>Notes / context (optional)</label>
          <textarea value={notes} onChange={e => setNotes(e.target.value)} style={{ ...inputStyle, minHeight: 60, fontFamily: "inherit" }} placeholder="Why this pattern, what it enables, etc." />

          {error && <div style={{ color: "#dc2626", marginTop: 8, fontSize: 13 }}>{error}</div>}

          <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 14 }}>
            <button
              onClick={submit}
              disabled={submitting}
              style={{ ...btnPrimary, opacity: submitting ? 0.5 : 1 }}
            >
              {submitting ? "Submitting…" : "Submit for team vote"}
            </button>
            <div style={{ fontSize: 12, color: "#94a3b8" }}>
              Voting: 2 weekdays. Peter decides after.
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// SUBMIT VIEW ================================================
function SubmitView({ me, onSubmitted }) {
  const [requestType, setRequestType] = useState("time_off_full_day");
  const [startDate, setStartDate] = useState("");
  const [endDate, setEndDate] = useState("");
  const [partialDay, setPartialDay] = useState("none");
  const [proposedDay, setProposedDay] = useState("");
  const [notes, setNotes] = useState("");
  const [checks, setChecks] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);

  const typeMeta = REQUEST_TYPES.find(t => t.id === requestType);
  const isPartial = typeMeta?.partial === true;
  const isChange = requestType === "four_day_off_change";

  useEffect(() => {
    if (isPartial && startDate) setEndDate(startDate);
  }, [isPartial, startDate]);

  const runChecks = useCallback(async () => {
    if (!supabase || !startDate) { setChecks(null); return; }
    const eff_end = isPartial ? startDate : (endDate || startDate);
    if (eff_end < startDate) { setError("End date can't be before start date."); return; }
    setError(null);
    try {
      const [noticeRes, eligRes, coverRes] = await Promise.all([
        supabase.rpc("time_off_check_notice", { p_request_type: requestType, p_submitted_at: new Date().toISOString(), p_start_date: startDate, p_end_date: eff_end }),
        supabase.rpc("time_off_check_eligibility", { p_requester_team_id: me?.id }),
        supabase.rpc("time_off_check_coverage", { p_agency_id: AGENCY_ID, p_start_date: startDate, p_end_date: eff_end, p_exclude_request_id: null, p_request_type: requestType, p_requester_team_id: me?.id })
      ]);
      setChecks({
        notice: noticeRes?.data || null,
        eligibility: eligRes?.data || null,
        coverage: coverRes?.data || null,
        notice_err: noticeRes?.error?.message,
        elig_err: eligRes?.error?.message,
        cover_err: coverRes?.error?.message
      });
    } catch (e) {
      setError(e?.message || "Failed to run pre-submit checks");
    }
  }, [requestType, startDate, endDate, me?.id, isPartial]);

  useEffect(() => { runChecks(); }, [runChecks]);

  async function submit() {
    if (!supabase || !me?.id || !startDate) return;
    const eff_end = isPartial ? startDate : (endDate || startDate);
    setSubmitting(true);
    setError(null);
    try {
      const noticePasses = checks?.notice?.passes === true;
      const coverageRed = checks?.coverage?.severity === "red";
      const eligStatus = checks?.eligibility?.overall_eligibility;
      const isCaseByCase = eligStatus === "pending_review" || coverageRed || !noticePasses;
      const initialStatus = isCaseByCase ? "flagged_case_by_case" : "voting";

      const voteOpenedAt = initialStatus === "voting" ? new Date().toISOString() : null;
      const voteClosesAt = initialStatus === "voting" ? addBusinessDays(new Date(), 2).toISOString() : null;

      const { error: insErr } = await supabase
        .from("time_off_requests")
        .insert({
          agency_id: AGENCY_ID,
          requester_team_id: me.id,
          request_type: requestType,
          start_date: startDate,
          end_date: eff_end,
          partial_day: isPartial ? (partialDay === "none" ? "morning" : partialDay) : "none",
          proposed_four_day_off_day: isChange ? (proposedDay || null) : null,
          notes: notes || null,
          status: initialStatus,
          notice_check_result: checks?.notice || null,
          eligibility_check_result: checks?.eligibility || null,
          coverage_check_result: checks?.coverage || null,
          vote_opened_at: voteOpenedAt,
          vote_closes_at: voteClosesAt
        });

      if (insErr) throw insErr;

      setStartDate(""); setEndDate(""); setNotes(""); setProposedDay(""); setChecks(null);
      if (typeof onSubmitted === "function") onSubmitted();
      alert(initialStatus === "voting" ? "Submitted. Team has 2 weekdays to vote, then Peter decides." : "Submitted as case-by-case. Peter will review directly.");
    } catch (e) {
      setError(e?.message || "Failed to submit request");
    } finally {
      setSubmitting(false);
    }
  }

  const canSubmit = startDate && (isPartial || endDate || isChange) && !submitting;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
      <MyStandingPrefsPanel me={me} />
      <StandingPrefBuilder me={me} onSubmitted={onSubmitted} />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 24 }}>
      <div>
        <h3 style={{ marginTop: 0 }}>New Request</h3>
        <label style={labelStyle}>Type</label>
        <select value={requestType} onChange={e => setRequestType(e.target.value)} style={inputStyle}>
          {REQUEST_TYPES.filter(t => t.submitViaDropdown).map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
        </select>
        {!isChange && (<>
          <label style={labelStyle}>Start date</label>
          <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} style={inputStyle} />
          {!isPartial && (<>
            <label style={labelStyle}>End date</label>
            <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} style={inputStyle} />
          </>)}
          {isPartial && (<>
            <label style={labelStyle}>Which half</label>
            <select value={partialDay} onChange={e => setPartialDay(e.target.value)} style={inputStyle}>
              <option value="morning">Morning</option>
              <option value="afternoon">Afternoon</option>
            </select>
          </>)}
        </>)}
        {isChange && (<>
          <label style={labelStyle}>Effective date (when new day starts)</label>
          <input type="date" value={startDate} onChange={e => { setStartDate(e.target.value); setEndDate(e.target.value); }} style={inputStyle} />
          <label style={labelStyle}>New off day</label>
          <select value={proposedDay} onChange={e => setProposedDay(e.target.value)} style={inputStyle}>
            <option value="">— select —</option>
            {["Monday","Tuesday","Wednesday","Thursday","Friday"].map(d => <option key={d} value={d}>{d}</option>)}
          </select>
          <div style={{ fontSize: 12, color: "#64748b", marginTop: 4 }}>Your current preset off day: {me?.four_day_off_day || "(not set)"}</div>
        </>)}
        <label style={labelStyle}>Notes (optional)</label>
        <textarea value={notes} onChange={e => setNotes(e.target.value)} style={{ ...inputStyle, minHeight: 80, fontFamily: "inherit" }} />
        {error && <div style={{ color: "#dc2626", marginTop: 8, fontSize: 13 }}>{error}</div>}
        <button onClick={submit} disabled={!canSubmit} style={{ ...btnPrimary, marginTop: 16, opacity: canSubmit ? 1 : 0.5 }}>
          {submitting ? "Submitting..." : "Submit Request"}
        </button>
      </div>
      <div>
        <h3 style={{ marginTop: 0 }}>Pre-Submit Checks</h3>
        {!checks && <div style={{ color: "#94a3b8", fontSize: 13 }}>Fill in dates to see checks…</div>}
        {checks && (
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <CheckCard title="Notice" ok={checks?.notice?.passes === true}
              detail={checks?.notice ? (checks.notice.passes ? `Required ${checks.notice.required_days} days · provided ${checks.notice.provided_days} days` : `Required ${checks.notice.required_days} days · provided ${checks.notice.provided_days} days · short ${checks.notice.shortfall_days} days`) : (checks?.notice_err || "—")} />
            <CheckCard title="Eligibility" ok={checks?.eligibility?.overall_eligibility === "eligible"} warn={checks?.eligibility?.overall_eligibility === "pending_review"}
              detail={checks?.eligibility ? `${checks.eligibility.overall_eligibility}${(checks.eligibility.reasons || []).length ? ' · ' + checks.eligibility.reasons.join('; ') : ''}` : (checks?.elig_err || "—")} />
            <div>
              <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>Coverage</div>
              {checks?.coverage ? <CoverageBadge severity={checks.coverage.severity} messages={checks.coverage.messages} /> : <div style={{ color: "#94a3b8", fontSize: 12 }}>{checks?.cover_err || "—"}</div>}
            </div>
          </div>
        )}
      </div>
      </div>
    </div>
  );
}

// VOTE VIEW ================================================
function VoteView({ me }) {
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);
  const [voting, setVoting] = useState({});

  const load = useCallback(async () => {
    if (!supabase || !me?.id) return;
    setLoading(true);
    try {
      const { data } = await supabase.from("v_time_off_pending_votes").select("*").eq("agency_id", AGENCY_ID).eq("voter_team_id", me.id);
      setRequests(Array.isArray(data) ? data : []);
    } catch (e) { console.error("Vote load error", e); }
    finally { setLoading(false); }
  }, [me?.id]);

  useEffect(() => { load(); }, [load]);

  async function castVote(reqId, vote, reason) {
    if (!supabase || !me?.id) return;
    setVoting(v => ({ ...v, [reqId]: true }));
    try {
      const { error } = await supabase.from("time_off_votes").upsert({ request_id: reqId, voter_team_id: me.id, vote, reason: reason || null }, { onConflict: "request_id,voter_team_id" });
      if (error) throw error;
      await load();
    } catch (e) { alert("Vote failed: " + (e?.message || "unknown")); }
    finally { setVoting(v => ({ ...v, [reqId]: false })); }
  }

  if (loading) return <div style={{ color: "#64748b" }}>Loading…</div>;
  if (!requests.length) return <div style={{ color: "#64748b", padding: 24, textAlign: "center" }}>No pending votes. 🎉</div>;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      {requests.map(r => {
        const typeLabel = formatRequestLabel(r);
        const closesIn = r.vote_closes_at ? Math.max(0, Math.round((new Date(r.vote_closes_at) - Date.now()) / (60 * 60 * 1000))) : null;
        return (
          <div key={r.request_id} style={cardStyle}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
              <div>
                <div style={{ fontWeight: 700, fontSize: 16 }}>{r.requester_name}</div>
                <div style={{ color: "#64748b", fontSize: 13 }}>{typeLabel} · {fmtDate(r.start_date)}{r.start_date !== r.end_date && ` → ${fmtDate(r.end_date)}`}</div>
              </div>
              {closesIn !== null && <div style={{ fontSize: 12, color: closesIn <= 4 ? "#dc2626" : "#64748b" }}>Closes in {closesIn}h</div>}
            </div>
            {r.notes && <div style={{ marginTop: 8, fontSize: 13, fontStyle: "italic", color: "#475569" }}>"{r.notes}"</div>}
            {r.coverage_check_result && <div style={{ marginTop: 8 }}><CoverageBadge severity={r?.coverage_check_result?.severity} messages={r?.coverage_check_result?.messages} /></div>}
            {r.already_voted ? (
              <div style={{ marginTop: 12, color: "#16a34a", fontSize: 13, fontWeight: 600 }}>✓ You've voted</div>
            ) : (
              <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
                <button onClick={() => castVote(r.request_id, "yes")} disabled={voting[r.request_id]} style={btnYes}>👍 Yes</button>
                <button onClick={() => { const reason = window.prompt("Reason for no (optional):"); castVote(r.request_id, "no", reason); }} disabled={voting[r.request_id]} style={btnNo}>👎 No</button>
                <button onClick={() => castVote(r.request_id, "abstain")} disabled={voting[r.request_id]} style={btnAbstain}>Abstain</button>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// MY REQUESTS VIEW ================================================
function MyRequestsView({ me }) {
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      if (!supabase || !me?.id) return;
      try {
        const { data } = await supabase.from("time_off_requests").select("*").eq("agency_id", AGENCY_ID).eq("requester_team_id", me.id).order("submitted_at", { ascending: false }).limit(50);
        setRequests(Array.isArray(data) ? data : []);
      } catch (e) { console.error(e); }
      finally { setLoading(false); }
    }
    load();
  }, [me?.id]);

  if (loading) return <div style={{ color: "#64748b" }}>Loading…</div>;
  if (!requests.length) return <div style={{ color: "#64748b", padding: 24, textAlign: "center" }}>No requests yet.</div>;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      {requests.map(r => (
        <div key={r.id} style={cardStyle}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <div>
              <div style={{ fontWeight: 600 }}>{formatRequestLabel(r)}</div>
              <div style={{ fontSize: 13, color: "#64748b" }}>
                {fmtDate(r.start_date)}{r.start_date !== r.end_date && ` → ${fmtDate(r.end_date)}`}
                {" · submitted "}{fmtDateTime(r.submitted_at)}
              </div>
            </div>
            <StatusBadge status={r.status} />
          </div>
          {r.notes && <div style={{ marginTop: 6, fontSize: 13, color: "#475569" }}>{r.notes}</div>}
          {r.decision_note && <div style={{ marginTop: 6, fontSize: 13, color: "#1e40af" }}>Decision note: {r.decision_note}</div>}
        </div>
      ))}
    </div>
  );
}

// HISTORY VIEW (Everyone reads; Owner edits) ===================
function HistoryEditModal({ request, team, onClose, onSaved, onDeleted }) {
  const [requestType, setRequestType] = useState(request.request_type);
  const [partialDay, setPartialDay] = useState(request.partial_day || "none");
  const [startDate, setStartDate] = useState(request.start_date);
  const [endDate, setEndDate] = useState(request.end_date);
  const [status, setStatus] = useState(request.status);
  const [isPaid, setIsPaid] = useState(request.is_paid !== false);
  const [isPlanned, setIsPlanned] = useState(!!request.is_planned);
  const [notes, setNotes] = useState(request.notes || "");
  const [decisionNote, setDecisionNote] = useState(request.decision_note || "");
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);

  async function save() {
    if (!startDate) { alert("Start date required"); return; }
    setSaving(true);
    try {
      const { data, error } = await supabase
        .from("time_off_requests")
        .update({
          request_type: requestType,
          partial_day: partialDay,
          start_date: startDate,
          end_date: endDate || startDate,
          status,
          is_paid: isPaid,
          is_planned: isPlanned,
          notes: notes || null,
          decision_note: decisionNote || null,
          updated_at: new Date().toISOString()
        })
        .eq("id", request.id)
        .select("id");
      if (error) throw error;
      if (!data || data.length === 0) {
        alert("Save returned 0 rows. RLS may have blocked the update.");
        return;
      }
      if (typeof onSaved === "function") onSaved();
      onClose();
    } catch (e) {
      alert("Save failed: " + (e?.message || "unknown"));
    } finally {
      setSaving(false);
    }
  }

  async function destroy() {
    if (!confirm("Delete this time off record? This cannot be undone.")) return;
    setDeleting(true);
    try {
      const { data, error } = await supabase
        .from("time_off_requests")
        .delete()
        .eq("id", request.id)
        .select("id");
      if (error) throw error;
      if (!data || data.length === 0) {
        alert("Delete returned 0 rows. RLS may have blocked the delete.");
        return;
      }
      if (typeof onDeleted === "function") onDeleted();
      onClose();
    } catch (e) {
      alert("Delete failed: " + (e?.message || "unknown"));
    } finally {
      setDeleting(false);
    }
  }

  const inp = { padding: "8px 10px", border: "1px solid #cbd5e1", borderRadius: 6, fontSize: 14, marginTop: 4, width: "100%", boxSizing: "border-box" };
  const lbl = { fontSize: 12, fontWeight: 600, color: "#475569", display: "block" };
  const requesterName = (team.find(t => t.id === request.requester_team_id) || {});
  const reqLabel = `${requesterName.first_name || "?"} ${requesterName.last_name || ""}`.trim();

  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)", display: "flex", alignItems: "center", justifyContent: "center", padding: 20, zIndex: 1000 }} onClick={onClose}>
      <div style={{ background: "#fff", borderRadius: 10, padding: 20, width: "min(560px, 100%)", maxHeight: "92vh", overflow: "auto" }} onClick={e => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
          <h3 style={{ margin: 0, fontSize: 18 }}>Edit time off record</h3>
          <button onClick={onClose} style={{ background: "transparent", border: "none", fontSize: 22, cursor: "pointer", color: "#64748b", lineHeight: 1 }}>×</button>
        </div>
        <div style={{ fontSize: 13, color: "#64748b", marginBottom: 12 }}>{reqLabel} · submitted {fmtDateTime(request.submitted_at)}</div>

        <label style={lbl}>
          Type
          <select value={requestType} onChange={e => setRequestType(e.target.value)} style={inp}>
            {REQUEST_TYPES.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
          </select>
        </label>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 12, marginTop: 12 }}>
          <label style={lbl}>
            Day part
            <select value={partialDay} onChange={e => setPartialDay(e.target.value)} style={inp}>
              <option value="none">Full day</option>
              <option value="morning">Morning</option>
              <option value="afternoon">Afternoon</option>
            </select>
          </label>
          <label style={lbl}>
            Status
            <select value={status} onChange={e => setStatus(e.target.value)} style={inp}>
              <option value="approved">Approved</option>
              <option value="denied">Denied</option>
              <option value="cancelled">Cancelled</option>
              <option value="expired">Expired</option>
              <option value="voting">Voting</option>
              <option value="awaiting_decision">Awaiting Decision</option>
              <option value="flagged_case_by_case">Case-by-Case</option>
              <option value="pending">Pending</option>
            </select>
          </label>
          <label style={lbl}>
            Start date
            <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} style={inp} />
          </label>
          <label style={lbl}>
            End date
            <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} style={inp} />
          </label>
          <label style={lbl}>
            Pay
            <select value={isPaid ? "paid" : "unpaid"} onChange={e => setIsPaid(e.target.value === "paid")} style={inp}>
              <option value="paid">Paid</option>
              <option value="unpaid">Unpaid</option>
            </select>
          </label>
          <label style={lbl}>
            Planning
            <select value={isPlanned ? "planned" : "unplanned"} onChange={e => setIsPlanned(e.target.value === "planned")} style={inp}>
              <option value="unplanned">Unplanned</option>
              <option value="planned">Planned</option>
            </select>
          </label>
        </div>

        <label style={{ ...lbl, marginTop: 12 }}>
          Notes
          <input type="text" value={notes} onChange={e => setNotes(e.target.value)} placeholder="Original notes from requester" style={inp} />
        </label>
        <label style={{ ...lbl, marginTop: 12 }}>
          Decision note
          <input type="text" value={decisionNote} onChange={e => setDecisionNote(e.target.value)} placeholder="Owner note attached to decision" style={inp} />
        </label>

        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 18 }}>
          <button onClick={destroy} disabled={deleting || saving} style={{ ...btnBase, background: "#fee2e2", color: "#991b1b", border: "1px solid #fecaca" }}>
            {deleting ? "Deleting…" : "Delete record"}
          </button>
          <div style={{ display: "flex", gap: 8 }}>
            <button onClick={onClose} style={btnAbstain}>Cancel</button>
            <button onClick={save} disabled={saving || deleting} style={{ ...btnPrimary, opacity: saving ? 0.6 : 1 }}>
              {saving ? "Saving…" : "Save changes"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ============================================================
// TEAM CALENDAR VIEW (replaces the old request-list history)
// ============================================================
function startOfWeekMondayLocal(d) {
  const day = d.getDay(); // 0=Sun, 1=Mon...6=Sat
  const diff = day === 0 ? -6 : 1 - day;
  const nd = new Date(d);
  nd.setDate(d.getDate() + diff);
  nd.setHours(0, 0, 0, 0);
  return nd;
}
function addDaysLocal(d, n) {
  const nd = new Date(d);
  nd.setDate(d.getDate() + n);
  return nd;
}
function isoDayLocal(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}
function dayShortLabel(d) { return d.toLocaleDateString(undefined, { weekday: "short" }); }
function dayMonthShort(d) { return d.toLocaleDateString(undefined, { month: "short", day: "numeric" }); }

const CALENDAR_PENDING_STATUSES = new Set(["voting","awaiting_decision","flagged_case_by_case","pending"]);

function categorizeRequestForCalendar(r) {
  const t = r.request_type || "";
  if (t === "sick") return "sick";
  if (t.startsWith("remote")) return "remote";
  return "off"; // time_off_full_day, time_off_half_day, four_day_off_change
}

const CALENDAR_KIND_COLORS = {
  off:    { bg: "#fecaca", border: "#f87171" },
  sick:   { bg: "#fed7aa", border: "#fb923c" },
  remote: { bg: "#bfdbfe", border: "#60a5fa" }
};
const CALENDAR_STANDING_BG = "#fef3c7";       // amber-100
const CALENDAR_STANDING_BORDER = "#f59e0b";   // amber-500 (used for legend swatch)
const CAL_ICON_PAID_OK = "#059669";           // green-600
const CAL_ICON_BAD     = "#dc2626";           // red-600

function calendarBlockStyle(seg, isStanding) {
  if (!seg) return { background: "transparent" };
  const c = CALENDAR_KIND_COLORS[seg.kind] || CALENDAR_KIND_COLORS.off;
  if (seg.pending) {
    return { background: "transparent", border: `2px dashed ${c.border}`, borderRadius: 3, boxSizing: "border-box" };
  }
  const bg = isStanding ? CALENDAR_STANDING_BG : c.bg;
  return { background: bg, borderLeft: `3px solid ${c.border}` };
}

function SegmentBlock({ seg, isSplit }) {
  if (!seg) {
    // empty placeholder to keep flex layout stable when only morning or only afternoon is populated
    return <div style={{ flex: isSplit ? 1 : undefined, height: isSplit ? undefined : "100%", background: "transparent", borderRadius: 3 }} />;
  }
  const isStanding = !!seg.r.derived_from_standing_pref_id;
  const style = calendarBlockStyle(seg, isStanding);
  const showIcons = !seg.pending;
  const paid    = seg.r.is_paid    !== false;
  const planned = seg.r.is_planned !== false;
  const iconFontSize = isSplit ? 10 : 13;
  return (
    <div style={{
      ...style,
      flex: isSplit ? 1 : undefined,
      height: isSplit ? undefined : "100%",
      borderRadius: 3,
      position: "relative"
    }}>
      {showIcons && (
        <div style={{
          position: "absolute",
          top: 1, right: 3,
          display: "flex", gap: 3,
          fontSize: iconFontSize, lineHeight: 1, fontWeight: 700,
          fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
          pointerEvents: "none"
        }}>
          <span style={{ color: paid    ? CAL_ICON_PAID_OK : CAL_ICON_BAD }} title={paid    ? "Paid"    : "Unpaid"}>$</span>
          <span style={{ color: planned ? CAL_ICON_PAID_OK : CAL_ICON_BAD }} title={planned ? "Planned" : "Unplanned"}>{planned ? "✓" : "!"}</span>
        </div>
      )}
    </div>
  );
}

function CellBlocks({ requests }) {
  if (!requests || requests.length === 0) return null;
  const segments = { morning: null, afternoon: null, full: null };
  for (const r of requests) {
    const isPending = CALENDAR_PENDING_STATUSES.has(r.status);
    const kind = categorizeRequestForCalendar(r);
    const part = r.partial_day && r.partial_day !== "none" ? r.partial_day : "full";
    const existing = segments[part];
    if (!existing || (existing.pending && !isPending)) {
      segments[part] = { kind, pending: isPending, r };
    }
  }
  if (segments.full) {
    return (
      <div style={{ height: "100%", minHeight: 42 }}>
        <SegmentBlock seg={segments.full} isSplit={false} />
      </div>
    );
  }
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", minHeight: 42, gap: 2 }}>
      <SegmentBlock seg={segments.morning}   isSplit={true} />
      <SegmentBlock seg={segments.afternoon} isSplit={true} />
    </div>
  );
}

function CalendarDetailModal({ mode, teamId, dateISO, team, cellIndex, isOwner, onEdit, onClose }) {
  let title; let listReqs = [];
  const nameById = {};
  for (const t of team) nameById[t.id] = `${t.first_name || ""} ${t.last_name || ""}`.trim();
  const displayDate = new Date(dateISO + "T12:00:00").toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  if (mode === "cell") {
    title = `${nameById[teamId] || "—"} · ${displayDate}`;
    listReqs = cellIndex[`${teamId}|${dateISO}`] || [];
  } else {
    title = displayDate;
    for (const [key, arr] of Object.entries(cellIndex)) {
      if (key.endsWith(`|${dateISO}`)) listReqs.push(...arr);
    }
  }
  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)", display: "flex", alignItems: "center", justifyContent: "center", padding: 20, zIndex: 1000 }} onClick={onClose}>
      <div style={{ background: "#fff", borderRadius: 10, padding: 20, width: "min(560px, 100%)", maxHeight: "92vh", overflow: "auto" }} onClick={e => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
          <h3 style={{ margin: 0, fontSize: 16 }}>{title}</h3>
          <button onClick={onClose} style={{ background: "transparent", border: "none", fontSize: 22, cursor: "pointer", color: "#64748b", lineHeight: 1 }}>×</button>
        </div>
        {listReqs.length === 0 ? (
          <div style={{ color: "#64748b", padding: 20, textAlign: "center" }}>No time off recorded.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {listReqs.map(r => (
              <div key={r.id} style={{ border: "1px solid #e2e8f0", borderRadius: 8, padding: 10, background: "#fff" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10 }}>
                  <div style={{ flex: 1 }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                      {mode === "day" && <div style={{ fontWeight: 600 }}>{nameById[r.requester_team_id] || "Unknown"}</div>}
                      <StatusBadge status={r.status} />
                      {r.is_paid === false && <span style={{ fontSize: 11, color: "#7c2d12", background: "#ffedd5", padding: "2px 8px", borderRadius: 10 }}>Unpaid</span>}
                      {r.derived_from_standing_pref_id && <span style={{ fontSize: 11, color: "#0369a1", background: "#e0f2fe", padding: "2px 8px", borderRadius: 10 }}>WtW</span>}
                    </div>
                    <div style={{ fontSize: 13, color: "#475569", marginTop: 4 }}>
                      {formatRequestLabel(r)}{r.partial_day && r.partial_day !== "none" ? ` (${r.partial_day})` : ""}
                      {" · "}
                      {fmtDate(r.start_date)}{r.start_date !== r.end_date && ` → ${fmtDate(r.end_date)}`}
                    </div>
                    {r.notes && <div style={{ fontSize: 12, color: "#64748b", marginTop: 4 }}><span style={{ color: "#94a3b8" }}>Notes:</span> {r.notes}</div>}
                    {r.decision_note && <div style={{ fontSize: 12, color: "#1e40af", marginTop: 2 }}><span style={{ color: "#94a3b8" }}>Decision note:</span> {r.decision_note}</div>}
                  </div>
                  {isOwner && (
                    <button onClick={() => onEdit(r)} style={{ padding: "6px 10px", background: "#f1f5f9", color: "#1e40af", border: "1px solid #cbd5e1", borderRadius: 6, fontSize: 12, fontWeight: 600, cursor: "pointer" }}>Edit</button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function HistoryView({ me }) {
  // Team roster + weekly time-off calendar. Replaces the prior stack-of-requests list view.
  const [weekStart, setWeekStart] = useState(() => startOfWeekMondayLocal(new Date()));
  const [team, setTeam] = useState([]);
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(null); // {mode:'cell'|'day', teamId?, dateISO}
  const [editing, setEditing] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const isOwner = me?.role_level === "Owner";

  const days = useMemo(() => [0,1,2,3,4].map(i => addDaysLocal(weekStart, i)), [weekStart]);
  const weekStartIso = isoDayLocal(weekStart);
  const weekEndIso = isoDayLocal(days[4]);

  useEffect(() => {
    async function loadTeam() {
      if (!supabase) return;
      const { data } = await supabase.from("team")
        .select("id, first_name, last_name, role_level")
        .eq("agency_id", AGENCY_ID)
        .eq("category", "agency")
        .eq("is_admin_backoffice", false)
        .is("archived_at", null)
        .order("first_name");
      setTeam(Array.isArray(data) ? data : []);
    }
    loadTeam();
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!supabase) return;
      setLoading(true);
      try {
        const { data } = await supabase.from("time_off_requests")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .lte("start_date", weekEndIso)
          .gte("end_date", weekStartIso)
          .neq("request_type", "standing_time_off_preference")
          .in("status", ["approved","voting","awaiting_decision","flagged_case_by_case","pending"]);
        if (!cancelled) setRequests(Array.isArray(data) ? data : []);
      } catch (e) { console.error("Calendar load failed", e); }
      finally { if (!cancelled) setLoading(false); }
    }
    load();
    return () => { cancelled = true; };
  }, [weekStartIso, weekEndIso, refreshKey]);

  const cellIndex = useMemo(() => {
    const idx = {};
    for (const r of requests) {
      const s = new Date(r.start_date + "T12:00:00");
      const e = new Date(r.end_date + "T12:00:00");
      for (let d = new Date(s); d <= e; d = addDaysLocal(d, 1)) {
        const dow = d.getDay();
        if (dow === 0 || dow === 6) continue; // weekend
        const key = `${r.requester_team_id}|${isoDayLocal(d)}`;
        (idx[key] = idx[key] || []).push(r);
      }
    }
    return idx;
  }, [requests]);

  const todayIso = isoDayLocal(new Date());
  const isCurrentWeek = weekStartIso === isoDayLocal(startOfWeekMondayLocal(new Date()));

  const weekBtn = { padding: "6px 12px", background: "#fff", border: "1px solid #cbd5e1", borderRadius: 6, cursor: "pointer", fontSize: 13, fontWeight: 600, color: "#0f172a" };
  const thNameStyle = { padding: "8px 10px", background: "#f8fafc", borderBottom: "1px solid #e2e8f0", borderRight: "1px solid #e2e8f0", textAlign: "left", fontSize: 12, fontWeight: 600, color: "#475569", minWidth: 110, position: "sticky", left: 0, zIndex: 1 };
  const thDayStyle  = (isToday) => ({ padding: "6px 6px", background: isToday ? "#eff6ff" : "#f8fafc", borderBottom: "1px solid #e2e8f0", borderRight: "1px solid #e2e8f0", textAlign: "center", fontSize: 12, fontWeight: 600, color: isToday ? "#1e40af" : "#475569", cursor: "pointer", userSelect: "none" });
  const tdNameStyle = { padding: "8px 10px", borderBottom: "1px solid #f1f5f9", borderRight: "1px solid #e2e8f0", verticalAlign: "middle", background: "#fafafa", position: "sticky", left: 0, zIndex: 1 };
  const tdCellStyle = (isToday, hasReqs) => ({ padding: 3, borderBottom: "1px solid #f1f5f9", borderRight: "1px solid #f1f5f9", height: 48, minWidth: 88, background: isToday ? "#f0f9ff" : "#fff", cursor: hasReqs ? "pointer" : "default" });

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 12, gap: 8, flexWrap: "wrap" }}>
        <div style={{ display: "flex", gap: 6 }}>
          <button onClick={() => setWeekStart(addDaysLocal(weekStart, -7))} style={weekBtn}>← Prev</button>
          <button onClick={() => setWeekStart(startOfWeekMondayLocal(new Date()))} style={{ ...weekBtn, background: isCurrentWeek ? "#eff6ff" : "#fff", color: isCurrentWeek ? "#1e40af" : "#0f172a" }}>Today</button>
          <button onClick={() => setWeekStart(addDaysLocal(weekStart, 7))} style={weekBtn}>Next →</button>
        </div>
        <div style={{ fontSize: 15, fontWeight: 600, color: "#0f172a" }}>
          Week of {dayMonthShort(weekStart)} – {dayMonthShort(days[4])}, {weekStart.getFullYear()}
        </div>
      </div>

      {loading ? (
        <div style={{ color: "#64748b", padding: 20 }}>Loading…</div>
      ) : (
        <div style={{ overflowX: "auto", border: "1px solid #e2e8f0", borderRadius: 8, background: "#fff" }}>
          <table style={{ borderCollapse: "collapse", width: "100%", minWidth: 640 }}>
            <thead>
              <tr>
                <th style={thNameStyle}>Teammate</th>
                {days.map(d => {
                  const iso = isoDayLocal(d);
                  const isToday = iso === todayIso;
                  return (
                    <th key={iso}
                        style={thDayStyle(isToday)}
                        onClick={() => setExpanded({ mode: "day", dateISO: iso })}
                        title="Click to see everyone on this day">
                      <div>{dayShortLabel(d)}</div>
                      <div style={{ fontSize: 11, color: isToday ? "#3b82f6" : "#94a3b8", fontWeight: 400, marginTop: 1 }}>{dayMonthShort(d)}</div>
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {team.length === 0 ? (
                <tr><td colSpan={6} style={{ padding: 20, textAlign: "center", color: "#94a3b8" }}>No active team members.</td></tr>
              ) : team.map(t => (
                <tr key={t.id}>
                  <td style={tdNameStyle}>
                    <div style={{ fontWeight: 600, fontSize: 13 }}>{t.first_name}</div>
                    <div style={{ fontSize: 11, color: "#94a3b8" }}>{t.last_name}</div>
                  </td>
                  {days.map(d => {
                    const iso = isoDayLocal(d);
                    const isToday = iso === todayIso;
                    const key = `${t.id}|${iso}`;
                    const cellReqs = cellIndex[key] || [];
                    const hasReqs = cellReqs.length > 0;
                    return (
                      <td
                        key={key}
                        onClick={() => hasReqs && setExpanded({ mode: "cell", teamId: t.id, dateISO: iso })}
                        style={tdCellStyle(isToday, hasReqs)}
                      >
                        <CellBlocks requests={cellReqs} />
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, marginTop: 10, fontSize: 11, color: "#64748b", alignItems: "center" }}>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}><span style={{ display: "inline-block", width: 14, height: 14, background: "#fecaca", borderLeft: "3px solid #f87171", borderRadius: 2 }} /> Off / PTO</span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}><span style={{ display: "inline-block", width: 14, height: 14, background: "#fed7aa", borderLeft: "3px solid #fb923c", borderRadius: 2 }} /> Sick</span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}><span style={{ display: "inline-block", width: 14, height: 14, background: "#bfdbfe", borderLeft: "3px solid #60a5fa", borderRadius: 2 }} /> Remote</span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}><span style={{ display: "inline-block", width: 14, height: 14, background: "#fef3c7", borderLeft: "3px solid #f59e0b", borderRadius: 2 }} /> WtW day off</span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}><span style={{ display: "inline-block", width: 14, height: 14, border: "2px dashed #94a3b8", borderRadius: 2 }} /> Pending vote</span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
          <span style={{ fontFamily: "ui-monospace, monospace", fontWeight: 700, color: "#059669" }}>$</span>paid /
          <span style={{ fontFamily: "ui-monospace, monospace", fontWeight: 700, color: "#dc2626" }}>$</span>unpaid
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
          <span style={{ fontFamily: "ui-monospace, monospace", fontWeight: 700, color: "#059669" }}>✓</span>planned /
          <span style={{ fontFamily: "ui-monospace, monospace", fontWeight: 700, color: "#dc2626" }}>!</span>unplanned
        </span>
        <span style={{ color: "#94a3b8" }}>· split cell = half-day (top=morning · bottom=afternoon) · click any cell for detail</span>
      </div>

      {expanded && (
        <CalendarDetailModal
          mode={expanded.mode}
          teamId={expanded.teamId}
          dateISO={expanded.dateISO}
          team={team}
          cellIndex={cellIndex}
          isOwner={isOwner}
          onEdit={r => { setEditing(r); setExpanded(null); }}
          onClose={() => setExpanded(null)}
        />
      )}

      {editing && isOwner && (
        <HistoryEditModal
          request={editing}
          team={team}
          onClose={() => setEditing(null)}
          onSaved={() => { setRefreshKey(k => k + 1); setEditing(null); }}
          onDeleted={() => { setRefreshKey(k => k + 1); setEditing(null); }}
        />
      )}
    </div>
  );
}

// INBOX VIEW (Owner only) ================================================
function LogTimeOffForm({ onLogged }) {
  const [team, setTeam] = useState([]);
  const [teamId, setTeamId] = useState("");
  const [type, setType] = useState("sick");           // sick | time_off | remote
  const [dayPart, setDayPart] = useState("none");     // none | morning | afternoon
  const [isPaid, setIsPaid] = useState(true);
  const [isPlanned, setIsPlanned] = useState(false);
  const [startDate, setStartDate] = useState("");
  const [endDate, setEndDate] = useState("");
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [expanded, setExpanded] = useState(false);

  useEffect(() => {
    async function loadTeam() {
      if (!supabase) return;
      const { data } = await supabase.from("team")
        .select("id, first_name, last_name")
        .eq("agency_id", AGENCY_ID)
        .eq("category", "agency")
        .eq("is_admin_backoffice", false)
        .is("archived_at", null)
        .neq("is_test_user", true)
        .order("first_name");
      setTeam(Array.isArray(data) ? data : []);
    }
    loadTeam();
  }, []);

  function deriveRequestType(t, dp) {
    if (t === "sick") return "sick";
    if (t === "time_off") return dp === "none" ? "time_off_full_day" : "time_off_half_day";
    if (t === "remote") return dp === "none" ? "remote_day"   : "remote_half_day";
    return "sick";
  }

  async function submit() {
    if (!teamId || !startDate) { alert("Team member and start date are required"); return; }
    const requestType = deriveRequestType(type, dayPart);
    setSubmitting(true);
    try {
      const { error } = await supabase.rpc("log_time_off_for", {
        p_team_member_id: teamId,
        p_request_type:   requestType,
        p_start_date:     startDate,
        p_end_date:       endDate || startDate,
        p_partial_day:    dayPart,
        p_is_paid:        isPaid,
        p_is_planned:     isPlanned,
        p_notes:          notes || null
      });
      if (error) throw error;
      setTeamId(""); setStartDate(""); setEndDate("");
      setType("sick"); setDayPart("none"); setIsPaid(true); setIsPlanned(false);
      setNotes(""); setExpanded(false);
      alert("Time off logged. Calendar event will appear within 5 minutes.");
      if (typeof onLogged === "function") onLogged();
    } catch (e) {
      alert("Log failed: " + (e?.message || "unknown"));
    } finally {
      setSubmitting(false);
    }
  }

  const inp = { padding: "8px 10px", border: "1px solid #cbd5e1", borderRadius: 6, fontSize: 14, marginTop: 4, width: "100%", boxSizing: "border-box" };
  const lbl = { fontSize: 12, fontWeight: 600, color: "#475569", display: "block" };

  return (
    <div style={{ border: "1px solid #e2e8f0", borderRadius: 8, background: "#fff", overflow: "hidden", marginBottom: 4 }}>
      <button
        type="button"
        onClick={() => setExpanded(v => !v)}
        style={{ width: "100%", padding: "12px 16px", background: "transparent", border: "none", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "space-between", fontSize: 14, fontWeight: 600, color: "#0f172a", textAlign: "left" }}
      >
        <span>Log Time for Team</span>
        <span style={{ transform: expanded ? "rotate(90deg)" : "rotate(0deg)", transition: "transform 0.15s", color: "#64748b", fontSize: 18, lineHeight: 1 }}>›</span>
      </button>
      {expanded && (
        <div style={{ padding: "12px 16px 16px", borderTop: "1px solid #e2e8f0" }}>
          <label style={lbl}>
            Team Member
            <select value={teamId} onChange={e => setTeamId(e.target.value)} style={inp}>
              <option value="">— select —</option>
              {team.map(t => <option key={t.id} value={t.id}>{t.first_name} {t.last_name}</option>)}
            </select>
          </label>

          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 12, marginTop: 12 }}>
            <label style={lbl}>
              Type
              <select value={type} onChange={e => setType(e.target.value)} style={inp}>
                <option value="sick">Sick</option>
                <option value="time_off">Time off</option>
                <option value="remote">Remote</option>
              </select>
            </label>
            <label style={lbl}>
              Day Part
              <select value={dayPart} onChange={e => setDayPart(e.target.value)} style={inp}>
                <option value="none">Full day</option>
                <option value="morning">Morning only</option>
                <option value="afternoon">Afternoon only</option>
              </select>
            </label>
            <label style={lbl}>
              Pay
              <select value={isPaid ? "paid" : "unpaid"} onChange={e => setIsPaid(e.target.value === "paid")} style={inp}>
                <option value="paid">Paid</option>
                <option value="unpaid">Unpaid</option>
              </select>
            </label>
            <label style={lbl}>
              Planning
              <select value={isPlanned ? "planned" : "unplanned"} onChange={e => setIsPlanned(e.target.value === "planned")} style={inp}>
                <option value="unplanned">Unplanned</option>
                <option value="planned">Planned</option>
              </select>
            </label>
            <label style={lbl}>
              Start Date
              <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} style={inp} />
            </label>
            <label style={lbl}>
              End Date (optional)
              <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} style={inp} />
            </label>
          </div>

          <label style={{ ...lbl, marginTop: 12 }}>
            Notes (optional)
            <input type="text" value={notes} onChange={e => setNotes(e.target.value)} placeholder="e.g. 'flu, out for the day'" style={inp} />
          </label>

          <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 12 }}>
            <button onClick={submit} disabled={submitting} style={{ padding: "8px 14px", background: "#16a34a", color: "#fff", border: "none", borderRadius: 6, fontSize: 14, fontWeight: 600, cursor: submitting ? "wait" : "pointer", opacity: submitting ? 0.6 : 1 }}>
              {submitting ? "Logging…" : "Log Time Off"}
            </button>
            <div style={{ fontSize: 12, color: "#94a3b8" }}>
              Skips vote. Status = approved. Calendar event auto-creates. No email sent.
            </div>
          </div>
        </div>
      )}
    </div>
  );
}


// Approval defaults — follow the rules:
// - PTO: eligibility=eligible → paid; not_eligible → unpaid; pending_review → paid (data gap, benefit of doubt)
// - Sick: paid by default (handbook policy)
// - Remote / 4-day off-day change: paid (still working, just different location/schedule)
function computeDefaultPaid(req) {
  if (!req) return false;
  const t = req.request_type || "";
  const e = req.eligibility_check_result || {};
  // Still working that day — paid
  if (t.startsWith("remote")) return true;
  if (t === "four_day_off_change") return true;
  if (t === "sick") return true;
  // PTO — handbook §02 v25 rules
  if (t.startsWith("time_off")) {
    // Owner — own rules
    if (e.is_owner) return true;
    // Account Associate (= Account Representative in handbook) — accrued PTO ONLY.
    // 0 days year 1, 5 days year 2, 10 days year 3+. Default UNPAID; Peter
    // verifies YTD balance against accrual_cap in the modal before marking paid.
    if (e.is_account_associate) return false;
    // Account Manager and above — unlimited PTO subject to Sales Points Good+
    if (e.is_manager_tier) {
      const o = e.overall_eligibility;
      if (o === "eligible") return true;
      if (o === "ineligible") return false;
      return true; // pending_review — data gap, benefit of doubt for AMs
    }
    return false;
  }
  return false;
}

function computeDefaultPaidReason(req) {
  if (!req) return "";
  const t = req.request_type || "";
  const e = req.eligibility_check_result || {};
  if (t.startsWith("remote")) return "Working remotely — still paid.";
  if (t === "four_day_off_change") return "4-day off-day change — still paid.";
  if (t === "sick") return "Sick day — paid by default.";
  if (t.startsWith("time_off")) {
    if (e.is_owner) return "Owner — sets own rules.";
    if (e.is_account_associate) {
      const cap = e.aa_pto_days_per_year ?? 0;
      const band = e.aa_year_band;
      if (band === "year_1") return "Account Associate, year 1 — no PTO accrued yet (handbook §02).";
      if (band === "year_2") return `Account Associate, year 2 — ${cap} days/year accrued. Verify YTD balance before marking paid.`;
      if (band === "year_3_plus") return `Account Associate, year 3+ — ${cap} days/year accrued. Verify YTD balance before marking paid.`;
      return "Account Associate — accrued PTO only (handbook §02). Verify balance.";
    }
    if (e.is_manager_tier) {
      const o = e.overall_eligibility;
      if (o === "eligible") return "Account Manager, Sales Points Good+ — unlimited PTO is paid.";
      if (o === "ineligible") return "Account Manager, Sales Points below Good — unpaid by policy.";
      if (o === "pending_review") return "Account Manager, eligibility pending review — defaulting to paid.";
      return "";
    }
    return "Role not mapped to PTO eligibility — verify manually.";
  }
  return "";
}

// Sum approved+paid PTO days for a requester in the requested calendar year.
// Half-day partial = 0.5; full day = 1; multi-day span = (end - start + 1) * dayVal.
async function fetchYtdPaidPtoDays(requesterTeamId, year) {
  if (!supabase || !requesterTeamId) return 0;
  const { data, error } = await supabase
    .from("time_off_requests")
    .select("start_date, end_date, partial_day, request_type, is_paid, status")
    .eq("agency_id", AGENCY_ID)
    .eq("requester_team_id", requesterTeamId)
    .like("request_type", "pto%")
    .eq("status", "approved")
    .eq("is_paid", true)
    .gte("start_date", `${year}-01-01`)
    .lte("end_date", `${year}-12-31`);
  if (error) { console.error(error); return 0; }
  let used = 0;
  for (const r of (data || [])) {
    const s = new Date(r.start_date);
    const e = new Date(r.end_date);
    const span = Math.round((e - s) / 86400000) + 1;
    const dayVal = r.partial_day && r.partial_day !== "none" ? 0.5 : 1;
    used += span * dayVal;
  }
  return used;
}

// Day-count for the request being approved (so we can compare requested vs remaining)
function ptoDaysForRequest(req) {
  if (!req) return 0;
  if (!(req.request_type || "").startsWith("time_off")) return 0;
  const s = new Date(req.start_date);
  const e = new Date(req.end_date);
  const span = Math.round((e - s) / 86400000) + 1;
  const dayVal = req.partial_day && req.partial_day !== "none" ? 0.5 : 1;
  return span * dayVal;
}

function ApproveModal({ request, onCancel, onConfirm }) {
  const defaultPaid = computeDefaultPaid(request);
  const defaultReason = computeDefaultPaidReason(request);
  const [isPaid, setIsPaid] = useState(defaultPaid);
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [aaBalance, setAaBalance] = useState(null); // { cap, used, remaining, requested }

  const elig = request?.eligibility_check_result || {};
  const isAa = !!elig.is_account_associate;

  // For AAs: fetch YTD used + show balance context. Auto-bump default to PAID if
  // (a) we haven't taken a user override, AND (b) balance remaining covers this request.
  useEffect(() => {
    let cancelled = false;
    async function loadBalance() {
      if (!request || !isAa) { setAaBalance(null); return; }
      const cap = elig.aa_pto_days_per_year ?? 0;
      const year = new Date(request.start_date).getFullYear();
      const used = await fetchYtdPaidPtoDays(request.requester_team_id, year);
      const requested = ptoDaysForRequest(request);
      const remaining = Math.max(cap - used, 0);
      if (cancelled) return;
      setAaBalance({ cap, used, remaining, requested });
      // Smart-default: if AA has remaining balance >= requested, default PAID
      // (still safer to UNPAID for year 1 where cap=0 — remaining will be 0)
      if (remaining >= requested && requested > 0) setIsPaid(true);
    }
    loadBalance();
    return () => { cancelled = true; };
  }, [request?.id, isAa]);

  if (!request) return null;

  const reqLabel = (REQUEST_TYPES.find(t => t.id === request.request_type)?.label) || request.request_type;
  const lbl = { fontSize: 12, fontWeight: 600, color: "#475569", display: "block", marginBottom: 4 };
  const radioRow = (val, label, isDefault) => (
    <label style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 10px", border: isPaid === val ? "2px solid #2563eb" : "1px solid #cbd5e1", borderRadius: 6, cursor: "pointer", background: isPaid === val ? "#eff6ff" : "#fff" }}>
      <input type="radio" checked={isPaid === val} onChange={() => setIsPaid(val)} />
      <div style={{ display: "flex", flexDirection: "column" }}>
        <span style={{ fontWeight: 600, fontSize: 14 }}>{label}</span>
        {isDefault && <span style={{ fontSize: 11, color: "#64748b" }}>Default — {defaultReason}</span>}
      </div>
    </label>
  );

  async function confirm() {
    setSubmitting(true);
    try {
      await onConfirm(note.trim() || null, isPaid);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)", display: "flex", alignItems: "center", justifyContent: "center", padding: 20, zIndex: 1000 }} onClick={onCancel}>
      <div style={{ background: "#fff", borderRadius: 10, padding: 20, width: "min(480px, 100%)", maxHeight: "92vh", overflow: "auto" }} onClick={e => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
          <h3 style={{ margin: 0, fontSize: 18 }}>Approve {reqLabel}</h3>
          <button onClick={onCancel} style={{ background: "transparent", border: "none", fontSize: 22, cursor: "pointer", color: "#64748b" }}>×</button>
        </div>

        {isAa && aaBalance && (
          <div style={{ background: aaBalance.remaining >= aaBalance.requested ? "#ecfdf5" : "#fef2f2", border: `1px solid ${aaBalance.remaining >= aaBalance.requested ? "#a7f3d0" : "#fecaca"}`, borderRadius: 6, padding: 10, marginBottom: 12, fontSize: 13 }}>
            <div style={{ fontWeight: 600, marginBottom: 2 }}>Account Associate accrual (handbook §02)</div>
            <div>
              {aaBalance.cap === 0
                ? `Year 1 — no PTO accrued yet (0 days/year).`
                : `${aaBalance.cap} days/year accrued · ${aaBalance.used} used YTD · ${aaBalance.remaining} remaining · this request = ${aaBalance.requested} day(s)`}
            </div>
            {aaBalance.cap > 0 && aaBalance.remaining < aaBalance.requested && (
              <div style={{ color: "#991b1b", marginTop: 4, fontWeight: 600 }}>
                ⚠ Insufficient balance for paid PTO ({aaBalance.requested} requested vs {aaBalance.remaining} remaining)
              </div>
            )}
          </div>
        )}

        <div style={{ display: "grid", gap: 8, marginBottom: 16 }}>
          <div style={lbl}>Paid or unpaid?</div>
          {radioRow(true,  "Paid",   defaultPaid === true)}
          {radioRow(false, "Unpaid", defaultPaid === false)}
        </div>

        <label style={lbl}>
          Note to requester (optional)
          <textarea value={note} onChange={e => setNote(e.target.value)} rows={3} style={{ padding: "8px 10px", border: "1px solid #cbd5e1", borderRadius: 6, fontSize: 14, marginTop: 4, width: "100%", boxSizing: "border-box", resize: "vertical" }} placeholder="e.g. 'have a great trip'" />
        </label>

        <div style={{ display: "flex", justifyContent: "flex-end", gap: 8, marginTop: 14 }}>
          <button onClick={onCancel} disabled={submitting} style={{ padding: "8px 14px", background: "#fff", color: "#475569", border: "1px solid #cbd5e1", borderRadius: 6, fontSize: 14, fontWeight: 600, cursor: submitting ? "wait" : "pointer" }}>Cancel</button>
          <button onClick={confirm} disabled={submitting} style={{ padding: "8px 14px", background: "#16a34a", color: "#fff", border: "none", borderRadius: 6, fontSize: 14, fontWeight: 600, cursor: submitting ? "wait" : "pointer", opacity: submitting ? 0.6 : 1 }}>
            {submitting ? "Approving…" : `Approve as ${isPaid ? "PAID" : "UNPAID"}`}
          </button>
        </div>
      </div>
    </div>
  );
}

function InboxView({ me, onDecided }) {
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);
  const [voteStatuses, setVoteStatuses] = useState({});
  const [deciding, setDeciding] = useState({});
  const [approving, setApproving] = useState(null);

  const load = useCallback(async () => {
    if (!supabase || !me?.id) return;
    setLoading(true);
    try {
      const { data } = await supabase
        .from("time_off_requests")
        .select("*, requester:team!time_off_requests_requester_team_id_fkey(first_name, last_name, role_level)")
        .eq("agency_id", AGENCY_ID)
        .in("status", ["voting", "awaiting_decision", "flagged_case_by_case"])
        .order("submitted_at", { ascending: true });
      setRequests(Array.isArray(data) ? data : []);
      const statuses = {};
      for (const r of (data || [])) {
        const { data: vs } = await supabase.rpc("time_off_vote_status", { p_request_id: r.id });
        statuses[r.id] = vs;
      }
      setVoteStatuses(statuses);
    } catch (e) { console.error(e); }
    finally { setLoading(false); }
  }, [me?.id]);

  useEffect(() => { load(); }, [load]);

  async function decide(reqId, decision, note, isPaid) {
    if (!supabase || !me?.id) return;
    setDeciding(d => ({ ...d, [reqId]: true }));
    try {
      const update = {
        status: decision,
        decided_by_team_id: me.id,
        decided_at: new Date().toISOString(),
        decision_note: note || null
      };
      if (decision === "approved" && typeof isPaid === "boolean") {
        update.is_paid = isPaid;
      }
      const { error } = await supabase.from("time_off_requests").update(update).eq("id", reqId);
      if (error) throw error;
      await load();
      if (typeof onDecided === "function") onDecided();
    } catch (e) { alert("Decision failed: " + (e?.message || "unknown")); }
    finally { setDeciding(d => ({ ...d, [reqId]: false })); }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      <LogTimeOffForm onLogged={load} />
      {loading ? (
        <div style={{ color: "#64748b" }}>Loading…</div>
      ) : !requests.length ? (
        <div style={{ color: "#64748b", padding: 24, textAlign: "center", border: "1px dashed #e2e8f0", borderRadius: 8 }}>Inbox empty.</div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {requests.map(r => {
        const vs = voteStatuses[r.id];
        const elig = r.eligibility_check_result;
        const cov = r.coverage_check_result;
        const notice = r.notice_check_result;
        const requesterName = r?.requester?.first_name ? `${r.requester.first_name} ${r.requester.last_name}` : "—";
        return (
          <div key={r.id} style={cardStyle}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 8 }}>
              <div>
                <div style={{ fontWeight: 700, fontSize: 16 }}>{requesterName}</div>
                <div style={{ fontSize: 13, color: "#64748b" }}>
                  {formatRequestLabel(r)} · {fmtDate(r.start_date)}{r.start_date !== r.end_date && ` → ${fmtDate(r.end_date)}`}
                </div>
              </div>
              <StatusBadge status={r.status} />
            </div>
            {r.notes && <div style={{ fontSize: 13, fontStyle: "italic", color: "#475569", marginBottom: 8 }}>"{r.notes}"</div>}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8, marginBottom: 12 }}>
              <CheckCard title="Notice" ok={notice?.passes === true} detail={notice ? `${notice.provided_days}/${notice.required_days} days` : "—"} />
              <CheckCard title="Eligibility" ok={elig?.overall_eligibility === "eligible"} warn={elig?.overall_eligibility === "pending_review"} detail={elig?.overall_eligibility || "—"} />
              <div>{cov ? <CoverageBadge severity={cov.severity} messages={cov.messages} /> : <div style={{ fontSize: 12, color: "#94a3b8" }}>—</div>}</div>
            </div>
            {vs && (
              <div style={{ background: "#f8fafc", padding: 10, borderRadius: 6, fontSize: 13, marginBottom: 12 }}>
                <div style={{ fontWeight: 600, marginBottom: 4 }}>Team vote</div>
                <div>👍 {vs.yes_count || 0} · 👎 {vs.no_count || 0} · — {vs.abstain_count || 0} · ⏸ {vs.non_responder_count || 0} (no response)</div>
                <div style={{ marginTop: 4, color: "#475569" }}>
                  Quorum: {vs.quorum_met ? "met" : "not met"} ({vs.votes_cast}/{vs.quorum_threshold} required)
                  · Recommendation: <strong>{(vs.recommendation || "").replace(/_/g, " ")}</strong>
                </div>
                {(elig?.reasons || []).length > 0 && <div style={{ marginTop: 6, color: "#854d0e", fontSize: 12 }}>⚠ {(elig.reasons || []).join("; ")}</div>}
              </div>
            )}
            <div style={{ display: "flex", gap: 8 }}>
              <button onClick={() => setApproving(r)} disabled={deciding[r.id]} style={btnApprove}>Approve</button>
              <button onClick={() => decide(r.id, "denied", window.prompt("Denial reason (optional):"))} disabled={deciding[r.id]} style={btnDeny}>Deny</button>
              {r.status === "voting" && <button onClick={() => decide(r.id, "awaiting_decision", "Vote closed early by agent")} disabled={deciding[r.id]} style={btnAbstain}>Close voting now</button>}
            </div>
          </div>
        );
      })}
        </div>
      )}
      {approving && (
        <ApproveModal
          request={approving}
          onCancel={() => setApproving(null)}
          onConfirm={async (note, isPaid) => {
            const req = approving;
            setApproving(null);
            await decide(req.id, "approved", note, isPaid);
          }}
        />
      )}
    </div>
  );
}

// MAIN ================================================
export default function TimeOffRequests() {
  const [me, setMe] = useState(null);
  const [activeTab, setActiveTab] = useTabParam("subtab", "submit", ["submit","history","inbox","my","vote"]);
  const [loading, setLoading] = useState(true);
  const [refreshKey, setRefreshKey] = useState(0);
  const [policyOpen, setPolicyOpen] = useState(false);
  const [policy, setPolicy] = useState(null); // { title, html, updated_at }

  useEffect(() => {
    async function loadMe() {
      try {
        if (!supabase) { setLoading(false); return; }
        const { data: sessionData } = await supabase.auth.getUser();
        const authUser = sessionData?.user;
        if (!authUser) { setLoading(false); return; }
        // Resolve auth.users.id -> public.users row -> public.team row
        // (team.user_id holds public.users.id, NOT auth.users.id, so we must
        // route through the users table by auth_user_id.)
        const { data: userRow } = await supabase.from("users")
          .select("team_member_id")
          .eq("agency_id", AGENCY_ID).eq("auth_user_id", authUser.id).maybeSingle();
        if (!userRow?.team_member_id) { setLoading(false); return; }
        const { data: teamRow } = await supabase.from("team")
          .select("id, first_name, last_name, role, role_level, work_location, four_day_off_day, category")
          .eq("id", userRow.team_member_id).maybeSingle();
        setMe(teamRow);
      } catch (e) { console.error("Time Off — auth load error", e); }
      finally { setLoading(false); }
    }
    loadMe();
  }, []);

  // Load the "02 Hours & Time Off" handbook page live so the policy below
  // always reflects the current handbook (no duplication). Re-renders on
  // next page load whenever the handbook row is updated.
  useEffect(() => {
    async function loadPolicy() {
      try {
        if (!supabase) return;
        const { data } = await supabase.from("manuals")
          .select("title, content, updated_at")
          .eq("agency_id", AGENCY_ID)
          .eq("manual_type", "handbook")
          .eq("title", "02 Hours & Time Off")
          .eq("is_active", true)
          .maybeSingle();
        if (data) {
          setPolicy({
            title: data.title,
            html: mdToHtml(data.content),
            updated_at: data.updated_at
          });
        }
      } catch (e) { console.error("Time Off — policy load error", e); }
    }
    loadPolicy();
  }, []);

  // Hooks must run on every render — declare BEFORE any early returns.
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : 24;

  if (loading) return <div style={{ padding: 40, color: "#64748b" }}>Loading…</div>;
  if (!me) return (
    <div style={{ padding: 40 }}>
      <h2>Time Off & Remote</h2>
      <p style={{ color: "#64748b" }}>You must be signed in with a linked team account to use this module.</p>
    </div>
  );

  const isOwner = me?.role_level === "Owner";
  const tabs = [
    { id: "submit",  label: "Submit Request" },
    { id: "vote",    label: "Vote on Requests" },
    { id: "my",      label: "My Requests" },
    { id: "history", label: "Team Calendar" }
  ];
  if (isOwner) tabs.push({ id: "inbox", label: "Inbox" });

  const bumpRefresh = () => setRefreshKey(k => k + 1);

  return (
    <div style={{ padding: _pad, maxWidth: 1200, margin: "0 auto" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16, flexWrap: "wrap", gap: 8 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>Time Off & Remote</h1>
        <div style={{ fontSize: 13, color: "#64748b" }}>{me?.first_name} {me?.last_name} · {me?.role_level || "—"}</div>
      </div>

      {/* Handbook policy reference — reads live from public.handbook (single source of truth). */}
      <div style={{ marginBottom: 16, border: "1px solid #e2e8f0", borderRadius: 8, background: "#f8fafc", overflow: "hidden" }}>
        <button
          onClick={() => setPolicyOpen(!policyOpen)}
          type="button"
          style={{ width: "100%", padding: "12px 16px", background: "transparent", border: "none", display: "flex", alignItems: "center", justifyContent: "space-between", cursor: "pointer", fontSize: 14, fontWeight: 600, color: "#0f172a", textAlign: "left" }}
        >
          <span>📖 Hours & Time Off — Policy (from handbook)</span>
          <span style={{ transform: policyOpen ? "rotate(90deg)" : "rotate(0deg)", transition: "transform 0.15s", fontSize: 18, color: "#64748b", lineHeight: 1 }}>›</span>
        </button>
        {policyOpen && (
          <div style={{ padding: "12px 20px 16px", borderTop: "1px solid #e2e8f0", background: "#fff", fontSize: 14, lineHeight: 1.55 }}>
            {policy ? (
              <>
                <div className="newtworks-handbook-body" dangerouslySetInnerHTML={{ __html: policy.html }} />
                <div style={{ marginTop: 16, paddingTop: 12, borderTop: "1px solid #f1f5f9", fontSize: 12, color: "#94a3b8" }}>
                  From handbook · last updated {new Date(policy.updated_at).toLocaleDateString()}
                </div>
              </>
            ) : (
              <div style={{ color: "#94a3b8" }}>Loading policy…</div>
            )}
          </div>
        )}
      </div>

      <div style={{ display: "flex", gap: 4, borderBottom: "1px solid #e2e8f0", marginBottom: 20 }}>
        {tabs.map(tab => (
          <button key={tab.id} onClick={() => setActiveTab(tab.id)}
            style={{
              padding: "10px 16px", border: "none",
              borderBottom: activeTab === tab.id ? "2px solid #2563eb" : "2px solid transparent",
              background: "transparent", cursor: "pointer",
              fontWeight: activeTab === tab.id ? 600 : 500,
              color: activeTab === tab.id ? "#1e40af" : "#475569"
            }}>{tab.label}</button>
        ))}
      </div>
      <div key={refreshKey}>
        {activeTab === "submit" && <SubmitView me={me} onSubmitted={bumpRefresh} />}
        {activeTab === "vote" && <VoteView me={me} />}
        {activeTab === "my" && <MyRequestsView me={me} />}
        {activeTab === "history" && <HistoryView me={me} />}
        {activeTab === "inbox" && isOwner && <InboxView me={me} onDecided={bumpRefresh} />}
      </div>
    </div>
  );
}
