import { useState, useEffect, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { mdToHtml } from "./Handbook.jsx";

// ============================================================
// Time Off & Remote Request Module
// Spec: persistent_memory id fcaa841a-68f0-481c-a348-9d07f1699a85
// Handbook: §02 Hours & Time Off (v25)
// ============================================================

const REQUEST_TYPES = [
  { id: "pto_full_day",       label: "PTO (full day)",          partial: false, location: false },
  { id: "pto_half_day",       label: "PTO (half day)",          partial: true,  location: false },
  { id: "sick",               label: "Sick",                    partial: false, location: false },
  { id: "remote_day",         label: "Remote (full day)",       partial: false, location: true  },
  { id: "remote_half_day",    label: "Remote (half day)",       partial: true,  location: true  },
  { id: "four_day_off_change",label: "Change my 4-day off day", partial: false, location: false }
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

// SUBMIT VIEW ================================================
function SubmitView({ me, onSubmitted }) {
  const [requestType, setRequestType] = useState("pto_full_day");
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
      const voteClosesAt = initialStatus === "voting" ? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString() : null;

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
      alert(initialStatus === "voting" ? "Submitted. Team has 24 hours to vote, then Peter decides." : "Submitted as case-by-case. Peter will review directly.");
    } catch (e) {
      setError(e?.message || "Failed to submit request");
    } finally {
      setSubmitting(false);
    }
  }

  const canSubmit = startDate && (isPartial || endDate || isChange) && !submitting;

  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 24 }}>
      <div>
        <h3 style={{ marginTop: 0 }}>New Request</h3>
        <label style={labelStyle}>Type</label>
        <select value={requestType} onChange={e => setRequestType(e.target.value)} style={inputStyle}>
          {REQUEST_TYPES.filter(t => t.id !== "sick").map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
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
        const typeLabel = REQUEST_TYPES.find(t => t.id === r.request_type)?.label || r.request_type;
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
              <div style={{ fontWeight: 600 }}>{REQUEST_TYPES.find(t => t.id === r.request_type)?.label || r.request_type}</div>
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

// INBOX VIEW (Owner only) ================================================
function LogTimeOffForm({ onLogged }) {
  const [team, setTeam] = useState([]);
  const [teamId, setTeamId] = useState("");
  const [type, setType] = useState("sick");           // sick | pto | remote
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
        .is("archived_at", null)
        .neq("is_test_user", true)
        .order("first_name");
      setTeam(Array.isArray(data) ? data : []);
    }
    loadTeam();
  }, []);

  function deriveRequestType(t, dp) {
    if (t === "sick") return "sick";
    if (t === "pto")    return dp === "none" ? "pto_full_day" : "pto_half_day";
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
        <span>📝 Log Time Off on Behalf of Team Member</span>
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

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginTop: 12 }}>
            <label style={lbl}>
              Type
              <select value={type} onChange={e => setType(e.target.value)} style={inp}>
                <option value="sick">Sick</option>
                <option value="pto">PTO</option>
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


function InboxView({ me, onDecided }) {
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);
  const [voteStatuses, setVoteStatuses] = useState({});
  const [deciding, setDeciding] = useState({});

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

  async function decide(reqId, decision, note) {
    if (!supabase || !me?.id) return;
    setDeciding(d => ({ ...d, [reqId]: true }));
    try {
      const { error } = await supabase.from("time_off_requests").update({
        status: decision,
        decided_by_team_id: me.id,
        decided_at: new Date().toISOString(),
        decision_note: note || null
      }).eq("id", reqId);
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
                  {REQUEST_TYPES.find(t => t.id === r.request_type)?.label || r.request_type} · {fmtDate(r.start_date)}{r.start_date !== r.end_date && ` → ${fmtDate(r.end_date)}`}
                </div>
              </div>
              <StatusBadge status={r.status} />
            </div>
            {r.notes && <div style={{ fontSize: 13, fontStyle: "italic", color: "#475569", marginBottom: 8 }}>"{r.notes}"</div>}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 8, marginBottom: 12 }}>
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
              <button onClick={() => decide(r.id, "approved", window.prompt("Approval note (optional):"))} disabled={deciding[r.id]} style={btnApprove}>Approve</button>
              <button onClick={() => decide(r.id, "denied", window.prompt("Denial reason (optional):"))} disabled={deciding[r.id]} style={btnDeny}>Deny</button>
              {r.status === "voting" && <button onClick={() => decide(r.id, "awaiting_decision", "Vote closed early by agent")} disabled={deciding[r.id]} style={btnAbstain}>Close voting now</button>}
            </div>
          </div>
        );
      })}
        </div>
      )}
    </div>
  );
}

// MAIN ================================================
export default function TimeOffRequests() {
  const [me, setMe] = useState(null);
  const [activeTab, setActiveTab] = useState("submit");
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
        const { data } = await supabase.from("handbook")
          .select("title, content, updated_at")
          .eq("agency_id", AGENCY_ID)
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

  if (loading) return <div style={{ padding: 40, color: "#64748b" }}>Loading…</div>;
  if (!me) return (
    <div style={{ padding: 40 }}>
      <h2>Time Off & Remote</h2>
      <p style={{ color: "#64748b" }}>You must be signed in with a linked team account to use this module.</p>
    </div>
  );

  const isOwner = me?.role_level === "Owner";
  const tabs = [
    { id: "submit", label: "Submit Request" },
    { id: "vote",   label: "Vote on Requests" },
    { id: "my",     label: "My Requests" }
  ];
  if (isOwner) tabs.push({ id: "inbox", label: "Inbox" });

  const bumpRefresh = () => setRefreshKey(k => k + 1);

  return (
    <div style={{ padding: 24, maxWidth: 1200, margin: "0 auto" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
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
                <div className="bcc-handbook-body" dangerouslySetInnerHTML={{ __html: policy.html }} />
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
        {activeTab === "inbox" && isOwner && <InboxView me={me} onDecided={bumpRefresh} />}
      </div>
    </div>
  );
}
