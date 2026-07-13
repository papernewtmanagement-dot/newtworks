import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// ─── Constants ─────────────────────────────────────────────────────

const TRAIT_LABELS = {
  deadline_motivation: "Deadline Motivation",
  recognition_drive:   "Recognition Drive",
  assertiveness:       "Assertiveness",
  independent_spirit:  "Independent Spirit",
  analytical:          "Analytical",
  compassion:          "Compassion",
  self_promotion:      "Self Promotion",
  belief_in_others:    "Belief in Others",
  optimism:            "Optimism",
};

// Returns "green" (ideal), "yellow" (watch), "red" (trigger), or "none" (missing)
const TRAIT_BAND = {
  deadline_motivation: (v) => v == null ? "none" : v >= 70 ? "green" : v >= 50 ? "yellow" : "red",
  recognition_drive:   (v) => v == null ? "none" : v >= 50 ? "green" : v >= 30 ? "yellow" : "red",
  assertiveness:       (v) => v == null ? "none" : v >= 50 ? "green" : v >= 30 ? "yellow" : "red",
  independent_spirit:  (v) => v == null ? "none" : v >= 50 ? "green" : v >= 30 ? "yellow" : "red",
  analytical:          (v) => v == null ? "none" : v <= 60 ? "green" : v <= 70 ? "yellow" : "red",
  compassion:          (v) => v == null ? "none" : (v >= 30 && v <= 70) ? "green" : (v >= 20 && v <= 80) ? "yellow" : "red",
  self_promotion:      (v) => v == null ? "none" : (v >= 10 && v <= 80) ? "green" : (v >= 5 && v <= 89) ? "yellow" : "red",
  belief_in_others:    (v) => v == null ? "none" : (v >= 20 && v <= 80) ? "green" : (v >= 10 && v <= 90) ? "yellow" : "red",
  optimism:            (v) => v == null ? "none" : (v >= 20 && v <= 80) ? "green" : (v >= 10 && v <= 90) ? "yellow" : "red",
};

// Maps a detected trigger to the manual section header text for question lookup.
// direction is "Low" or "High" based on which side of ideal range the score falls.
const triggerToHeader = (trait, value) => {
  if (trait === "deadline_motivation" && value < 70) return "Low Deadline Motivation";
  if (trait === "recognition_drive"   && value < 50) return "Low Recognition Drive";
  if (trait === "assertiveness"       && value < 50) return "Low Assertiveness";
  if (trait === "independent_spirit"  && value < 50) return "Low Independent Spirit";
  if (trait === "analytical"          && value > 60) return "High Analytical";
  if (trait === "compassion"          && value < 30) return "Low Compassion";
  if (trait === "compassion"          && value > 70) return "High Compassion";
  if (trait === "self_promotion"      && value < 10) return "Low Self-Promotion";
  if (trait === "self_promotion"      && value > 80) return "High Self-Promotion";
  if (trait === "belief_in_others"    && value < 20) return "Low Belief in Others";
  if (trait === "belief_in_others"    && value > 80) return "High Belief in Others";
  if (trait === "optimism"            && value < 20) return "Low Optimism";
  if (trait === "optimism"            && value > 80) return "High Optimism";
  if (trait === "lss_speed" || trait === "lss_accuracy") return "LSS Speed";
  return null;
};

// Extract a subsection from Final Interview manual markdown by its ### header.
// Returns the raw markdown text from that header to the next ### or ## (exclusive).
const extractSection = (markdown, headerText) => {
  if (!markdown || !headerText) return null;
  const lines = markdown.split("\n");
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("### ") && lines[i].includes(headerText)) {
      start = i;
      break;
    }
  }
  if (start === -1) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith("### ") || lines[i].startsWith("## ")) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
};

// Minimal markdown → JSX: **bold**, *italic*, bullets, headers.
const renderMarkdown = (text) => {
  if (!text) return null;
  const lines = text.split("\n");
  return lines.map((ln, idx) => {
    if (ln.startsWith("### ")) {
      return <div key={idx} style={{ fontWeight: 700, fontSize: 14, color: T.slate800, marginTop: 8, marginBottom: 4 }}>{ln.slice(4).replace(/[()<>0-9]/g, m => m).trim()}</div>;
    }
    if (ln.startsWith("- ")) {
      let body = ln.slice(2);
      // Detect and strip *(optional) ... * pattern common in Final Interview manual
      const isOptional = /^\*\s*\(optional\)/i.test(body);
      if (isOptional) {
        // Strip leading "*(optional) " and trailing "*"
        body = body.replace(/^\*\s*\(optional\)\s*/i, "").replace(/\*\s*$/, "");
      }
      return (
        <div key={idx} style={{ marginLeft: 12, marginBottom: 3, fontSize: 12, color: isOptional ? T.slate500 : T.slate800, fontStyle: isOptional ? "italic" : "normal", lineHeight: 1.5 }}>
          <span style={{ marginRight: 4, opacity: 0.6 }}>{isOptional ? "○" : "•"}</span>{renderInline(body)}
        </div>
      );
    }
    if (ln.startsWith("**") && ln.endsWith("**")) {
      return <div key={idx} style={{ fontSize: 12, fontWeight: 700, color: T.slate700, marginTop: 6 }}>{ln.replace(/\*\*/g, "")}</div>;
    }
    if (ln.trim() === "") {
      return <div key={idx} style={{ height: 4 }} />;
    }
    return <div key={idx} style={{ fontSize: 12, color: T.slate700, marginBottom: 3 }}>{renderInline(ln)}</div>;
  });
};

// Inline markdown for a single line: **bold** and *italic*
const renderInline = (text) => {
  const parts = [];
  let remaining = text;
  let key = 0;
  while (remaining.length > 0) {
    // **bold**
    const boldMatch = remaining.match(/^\*\*(.+?)\*\*/);
    if (boldMatch) {
      parts.push(<strong key={key++}>{boldMatch[1]}</strong>);
      remaining = remaining.slice(boldMatch[0].length);
      continue;
    }
    // *italic*
    const italMatch = remaining.match(/^\*([^*]+)\*/);
    if (italMatch) {
      parts.push(<em key={key++} style={{ color: T.slate500 }}>{italMatch[1]}</em>);
      remaining = remaining.slice(italMatch[0].length);
      continue;
    }
    // Plain text up to next markdown marker
    const next = remaining.search(/\*/);
    if (next === -1) {
      parts.push(<span key={key++}>{remaining}</span>);
      break;
    }
    parts.push(<span key={key++}>{remaining.slice(0, next)}</span>);
    remaining = remaining.slice(next);
  }
  return parts;
};

const STAGE_LABELS = {
  assessed:        "Assessed",
  email_screen:    "Email Screen",
  interview:       "Interview",
  reference_check: "Ref Check",
  offer:           "Offer",
  hired:           "Hired",
  archived:        "Archived",
};

const SCORECARD_FIELDS = [
  { key: "personal_presence",           label: "Personal Presence",           type: "num" },
  { key: "resume_quality",              label: "Resume Quality",              type: "num" },
  { key: "honesty",                     label: "Honesty",                     type: "num", character: true },
  { key: "hard_work_ethic",             label: "Hard Work Ethic",             type: "num", character: true },
  { key: "personally_responsible",      label: "Personally Responsible",      type: "num", character: true },
  { key: "concern_for_others",          label: "Concern for Others",          type: "num", character: true },
  { key: "attitude_toward_sales",       label: "Attitude Toward Sales",       type: "num" },
  { key: "willingness_to_own_products", label: "Willingness to Own Products", type: "num" },
  { key: "motivation_type",             label: "Motivation Type",             type: "enum", options: [
    { v: "competitive", l: "Competitive" },
    { v: "income",      l: "Income" },
    { v: "duty",        l: "Duty" },
    { v: "recognition", l: "Recognition" },
  ]},
  { key: "motivation_level",            label: "Motivation Level",            type: "num" },
  { key: "recommendation",              label: "Overall Recommendation",      type: "enum", options: [
    { v: "great_fit",  l: "Great Fit" },
    { v: "good_fit",   l: "Good Fit" },
    { v: "not_a_fit",  l: "Not a Fit" },
  ]},
];

// ─── Helpers ───────────────────────────────────────────────────────

const bandColor = (band) => {
  if (band === "green")  return { bg: T.greenLt, fg: T.green };
  if (band === "yellow") return { bg: T.amberLt, fg: T.amber };
  if (band === "red")    return { bg: T.redLt,   fg: T.red };
  return { bg: T.slate100, fg: T.slate500 };
};

const detectTriggers = (detail) => {
  const triggers = [];
  Object.entries(TRAIT_BAND).forEach(([trait, evaluator]) => {
    const value = detail?.[trait];
    const band = evaluator(value);
    if (band === "red" || band === "yellow") {
      triggers.push({ trait, label: TRAIT_LABELS[trait], value, severity: band });
    }
  });
  // LSS triggers
  const maxSpeed = Math.max(
    Number(detail?.lss_math_speed_seconds) || 0,
    Number(detail?.lss_verbal_speed_seconds) || 0,
    Number(detail?.lss_problem_solving_speed_seconds) || 0
  );
  if (maxSpeed > 60) {
    triggers.push({ trait: "lss_speed", label: "LSS Speed", value: `${maxSpeed}s`, severity: "red" });
  }
  const acc = detail?.lss_total_accuracy;
  if (Number.isFinite(acc) && acc < 25) {
    triggers.push({ trait: "lss_accuracy", label: "LSS Accuracy", value: `${acc}/35`, severity: "red" });
  } else if (Number.isFinite(acc) && acc < 35) {
    triggers.push({ trait: "lss_accuracy", label: "LSS Accuracy", value: `${acc}/35`, severity: "yellow" });
  }
  return triggers;
};

const characterFloorPassed = (detail, prefix) => {
  const scores = [
    detail?.[`${prefix}honesty`],
    detail?.[`${prefix}hard_work_ethic`],
    detail?.[`${prefix}personally_responsible`],
    detail?.[`${prefix}concern_for_others`],
  ];
  if (scores.some(s => s == null)) return null; // incomplete
  return scores.every(s => Number(s) >= 7);
};

// ─── Sub-components ────────────────────────────────────────────────

const Section = ({ title, children, tone }) => (
  <div style={{ marginBottom: 20, padding: 14, background: tone || T.white, border: `1px solid ${T.slate200}`, borderRadius: 10 }}>
    <div style={{ fontSize: 11, textTransform: "uppercase", letterSpacing: 0.5, fontWeight: 700, color: T.slate600, marginBottom: 10 }}>{title}</div>
    {children}
  </div>
);

const MetricBox = ({ label, value, extra }) => (
  <div style={{ padding: 8, background: T.slate50, borderRadius: 7 }}>
    <div style={{ fontSize: 9, textTransform: "uppercase", color: T.slate500, fontWeight: 600 }}>{label}</div>
    <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{value ?? "—"} <span style={{ fontSize: 11, color: T.slate500, fontWeight: 400 }}>{extra}</span></div>
  </div>
);

const ScorecardForm = ({ title, prefix, detail, onFieldChange, onSave, saving, tone }) => {
  const charFloorPassed = characterFloorPassed(detail, prefix);
  return (
    <Section title={title} tone={tone}>
      {charFloorPassed !== null && (
        <div style={{ fontSize: 11, marginBottom: 10, color: charFloorPassed ? T.green : T.red, fontWeight: 600 }}>
          Character floor (≥7 across all 4 traits): {charFloorPassed ? "✓ Passed" : "✗ FAILED"}
        </div>
      )}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(2, 1fr)", gap: 8 }}>
        {SCORECARD_FIELDS.map(f => {
          const fieldKey = `${prefix}${f.key}`;
          const val = detail?.[fieldKey] ?? "";
          if (f.type === "num") {
            return (
              <div key={f.key}>
                <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 }}>{f.label} {f.character && <span style={{ color: T.red }}>*</span>}</label>
                <input
                  type="number" min={1} max={10}
                  value={val}
                  onChange={(e) => {
                    const n = e.target.value === "" ? null : Number(e.target.value);
                    onFieldChange(fieldKey, n);
                  }}
                  style={{ width: "100%", padding: 6, fontSize: 12, borderRadius: 5, border: `1px solid ${T.slate200}` }}
                  placeholder="1-10"
                />
              </div>
            );
          }
          if (f.type === "enum") {
            return (
              <div key={f.key}>
                <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 }}>{f.label}</label>
                <select
                  value={val || ""}
                  onChange={(e) => onFieldChange(fieldKey, e.target.value || null)}
                  style={{ width: "100%", padding: 6, fontSize: 12, borderRadius: 5, border: `1px solid ${T.slate200}` }}
                >
                  <option value="">—</option>
                  {f.options.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
                </select>
              </div>
            );
          }
          return null;
        })}
      </div>
      <div style={{ marginTop: 10 }}>
        <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 }}>Notes</label>
        <textarea
          value={detail?.[`${prefix}notes`] || ""}
          onChange={(e) => onFieldChange(`${prefix}notes`, e.target.value)}
          rows={3}
          style={{ width: "100%", padding: 6, fontSize: 12, borderRadius: 5, border: `1px solid ${T.slate200}` }}
        />
      </div>
      <button onClick={onSave} disabled={saving} style={{ marginTop: 10, padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: saving ? "wait" : "pointer" }}>
        {saving ? "Saving..." : `Save ${title}`}
      </button>
      {detail?.[`${prefix}scored_at`] && (
        <span style={{ marginLeft: 10, fontSize: 10, color: T.slate500 }}>
          Last saved {new Date(detail[`${prefix}scored_at`]).toLocaleString()}
        </span>
      )}
    </Section>
  );
};

// ─── Main component ────────────────────────────────────────────────

export default function CandidateDetail({ candidate, onBack, onUpdate }) {
  const [detail, setDetail] = useState(candidate || {});
  const [savingSection, setSavingSection] = useState(null);
  const [bestFit, setBestFit] = useState(null);
  const [validity, setValidity] = useState(null);
  const [timing, setTiming] = useState(null);
  const [manualMarkdown, setManualMarkdown] = useState("");

  // Fetch full row on mount
  useEffect(() => {
    if (!candidate?.id || !supabase) return;
    let cancelled = false;
    supabase
      .from("team_assessments")
      .select("*")
      .eq("id", candidate.id)
      .maybeSingle()
      .then(({ data, error }) => {
        if (cancelled || error || !data) return;
        setDetail(data);
      });
    return () => { cancelled = true; };
  }, [candidate?.id]);

  // Best-fit role + validity via RPC (graceful fallback if functions missing)
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    supabase.rpc("cts_best_fit_role", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!error) setBestFit(data); })
      .catch(() => {});
    supabase.rpc("cts_profile_validity", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!error) setValidity(data); })
      .catch(() => {});
    supabase.rpc("cts_timing_assessment", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!error) setTiming(data); })
      .catch(() => {});
  }, [detail?.id]);

  // Fetch Final Interview manual page for triggered follow-up questions
  useEffect(() => {
    if (!supabase) return;
    let cancelled = false;
    supabase
      .from("manuals")
      .select("content")
      .eq("id", "d83be3b8-55c9-4d60-9303-13a1f84141a8")  // Final Interview page
      .maybeSingle()
      .then(({ data, error }) => {
        if (cancelled || error || !data) return;
        setManualMarkdown(data.content || "");
      });
    return () => { cancelled = true; };
  }, []);

  const triggers = useMemo(() => detectTriggers(detail), [detail]);

  const updateField = (field, value) => {
    setDetail(prev => ({ ...prev, [field]: value }));
  };

  const saveFields = async (fields, sectionKey) => {
    if (!detail?.id) return;
    setSavingSection(sectionKey);
    const updates = {};
    fields.forEach(f => { updates[f] = detail[f] ?? null; });
    // Timestamp bookkeeping
    if (sectionKey === "va") updates.va_scored_at = new Date().toISOString();
    if (sectionKey === "fi") updates.fi_scored_at = new Date().toISOString();
    if (sectionKey === "rc" && detail.rc_notes) updates.rc_completed_at = new Date().toISOString();
    if (sectionKey === "decision" && detail.final_decision) updates.decision_at = new Date().toISOString();

    const { error, data } = await supabase
      .from("team_assessments")
      .update(updates)
      .eq("id", detail.id)
      .select()
      .maybeSingle();
    setSavingSection(null);
    if (error) {
      alert("Save failed: " + error.message);
      return;
    }
    if (data) setDetail(data);
  };

  const saveVA = () => saveFields(
    SCORECARD_FIELDS.map(f => `va_${f.key}`).concat(["va_notes"]),
    "va"
  );
  const saveFI = () => saveFields(
    SCORECARD_FIELDS.map(f => `fi_${f.key}`).concat(["fi_notes"]),
    "fi"
  );
  const saveRC = () => saveFields(["rc_notes"], "rc");
  const saveDecision = () => saveFields(["final_decision", "decision_notes"], "decision");

  const displayName = [detail?.first_name, detail?.last_name].filter(Boolean).join(" ") || detail?.candidate_name || "Unknown Candidate";

  return (
    <div>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 16, gap: 12, flexWrap: "wrap" }}>
        <button onClick={onBack} style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.slate700, background: T.slate100, border: "none", borderRadius: 7, cursor: "pointer" }}>← Back to Pipeline</button>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          {detail?.resume_url && (
            <a href={detail.resume_url} target="_blank" rel="noreferrer" style={{ padding: "7px 14px", fontSize: 12, color: T.blue, background: T.blueLt, textDecoration: "none", borderRadius: 7 }}>📄 Resume</a>
          )}
          <div style={{ padding: "5px 12px", fontSize: 11, fontWeight: 600, color: T.slate700, background: T.slate100, borderRadius: 12 }}>
            {STAGE_LABELS[detail?.status] || detail?.status || "—"}
          </div>
        </div>
      </div>

      {/* Identity */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>{displayName}</div>
        <div style={{ fontSize: 13, color: T.slate600, marginTop: 2 }}>
          {[detail?.position, detail?.email, detail?.phone].filter(Boolean).join(" · ") || "No contact info on file"}
        </div>
        {detail?.source && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>Source: {detail.source} · Assessed {detail?.assessment_date || "—"}</div>
        )}
      </div>

      {/* CTS Score Panel */}
      <Section title="CTS Assessment — Traits">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10 }}>
          {Object.entries(TRAIT_LABELS).map(([trait, label]) => {
            const value = detail?.[trait];
            const band = TRAIT_BAND[trait](value);
            const colors = bandColor(band);
            return (
              <div key={trait} style={{ background: colors.bg, padding: 10, borderRadius: 7, borderLeft: `3px solid ${colors.fg}` }}>
                <div style={{ fontSize: 10, textTransform: "uppercase", color: T.slate600, fontWeight: 600 }}>{label}</div>
                <div style={{ fontSize: 22, fontWeight: 700, color: colors.fg, marginTop: 2 }}>{value ?? "—"}</div>
              </div>
            );
          })}
        </div>
      </Section>

      <Section title="CTS Assessment — Other Metrics">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8 }}>
          <MetricBox label="Overall Score" value={detail?.overall_score} extra={detail?.overall_score_band ? `(${detail.overall_score_band})` : ""} />
          <MetricBox label="LSS Accuracy" value={detail?.lss_total_accuracy} extra={detail?.lss_total_accuracy != null ? "/35" : ""} />
          <MetricBox label="Reliability" value={detail?.reliability} extra={detail?.reliability != null && detail.reliability < 50 ? "⚠️" : ""} />
          <MetricBox label="Distortion" value={detail?.response_distortion} extra={detail?.response_distortion != null && detail.response_distortion > 60 ? "⚠️ high" : ""} />
          <MetricBox label="Ego Drive" value={detail?.ego_drive_score} />
          <MetricBox label="Empathy" value={detail?.empathy_score} />
        </div>
        {timing != null && timing?.overall_flag !== "no_data" && (
          <div style={{ marginTop: 10, padding: 10, background: T.slate50, borderRadius: 7 }}>
            <div style={{ fontSize: 9, textTransform: "uppercase", color: T.slate500, fontWeight: 600, marginBottom: 4 }}>Timing flag</div>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span style={{
                padding: "2px 8px",
                borderRadius: 4,
                fontWeight: 700,
                fontSize: 12,
                background: timing.overall_flag === "red" ? "#fee2e2" : timing.overall_flag === "yellow" ? "#fef3c7" : "#d1fae5",
                color: timing.overall_flag === "red" ? "#991b1b" : timing.overall_flag === "yellow" ? "#92400e" : "#065f46",
              }}>
                {timing.overall_flag === "red" ? "🔴" : timing.overall_flag === "yellow" ? "🟡" : "🟢"} {String(timing.overall_flag).toUpperCase()}
              </span>
              <span style={{ color: T.slate500, fontSize: 12 }}>
                total {timing.total_min}m · CTS {timing.cts_min}m · LSS {timing.lss_min}m · VCT {timing.vct_min}m
              </span>
            </div>
            {Array.isArray(timing.reasons) && timing.reasons.length > 0 && (
              <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
                {timing.reasons.map((r, i) => <div key={i}>• {r}</div>)}
              </div>
            )}
          </div>
        )}
      </Section>

      {/* Analysis */}
      <Section title="Analysis" tone={T.slate50}>
        <div style={{ marginBottom: 10 }}>
          <div style={{ fontSize: 12, marginBottom: 4 }}><strong>Best-fit role:</strong> {bestFit ? JSON.stringify(bestFit) : "Not computed"}</div>
          {validity != null && (
            <div style={{ fontSize: 12, marginBottom: 4 }}><strong>Profile validity:</strong> {typeof validity === "string" ? validity : JSON.stringify(validity)}</div>
          )}
        </div>
        {detail?.claude_summary && (
          <div style={{ padding: 10, background: T.white, borderRadius: 7, fontSize: 12, marginBottom: 10, color: T.slate700 }}>
            <div style={{ fontSize: 10, fontWeight: 700, color: T.slate500, textTransform: "uppercase", marginBottom: 4 }}>Claude Summary</div>
            {detail.claude_summary}
          </div>
        )}
        <div>
          <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>CTS triggers detected:</div>
          {triggers.length === 0 ? (
            <div style={{ fontSize: 12, color: T.green }}>None — all traits in ideal range ✓</div>
          ) : (
            <ul style={{ margin: "4px 0 0 0", paddingLeft: 18, fontSize: 12 }}>
              {triggers.map((t, i) => (
                <li key={i} style={{ color: t.severity === "red" ? T.red : T.amber, marginBottom: 2 }}>
                  <strong>{t.label}:</strong> {t.value} <em>({t.severity === "red" ? "trigger" : "watch"})</em>
                </li>
              ))}
            </ul>
          )}
        </div>
      </Section>

      {/* Triggered Follow-Up Questions — parsed from Final Interview manual page at runtime */}
      <Section title="Triggered Follow-Up Questions" tone={T.blueLt}>
        {triggers.length === 0 ? (
          <div style={{ fontSize: 12, color: T.slate700 }}>
            No triggers — all traits in ideal range. Run only the baseline questions in the Final Interview manual page.
          </div>
        ) : (
          <>
            <div style={{ fontSize: 12, color: T.slate700, marginBottom: 12 }}>
              <strong>{triggers.filter(t => t.severity === "red").length}</strong> red trigger(s) · <strong>{triggers.filter(t => t.severity === "yellow").length}</strong> watch trigger(s). Ask the core questions for each; use optionals if the picture is still unclear.
            </div>
            {!manualMarkdown ? (
              <div style={{ fontSize: 11, color: T.slate500, fontStyle: "italic" }}>Loading manual...</div>
            ) : (
              triggers.map((t, i) => {
                const header = triggerToHeader(t.trait, Number(t.value)) || t.label;
                const section = extractSection(manualMarkdown, header);
                return (
                  <div key={i} style={{ marginBottom: 14, padding: 10, background: T.white, borderRadius: 7, borderLeft: `3px solid ${t.severity === "red" ? T.red : T.amber}` }}>
                    {section ? (
                      renderMarkdown(section)
                    ) : (
                      <div style={{ fontSize: 11, color: T.slate500, fontStyle: "italic" }}>
                        No matching section found in the Final Interview manual for &quot;{header}&quot;. (Check the manual page structure.)
                      </div>
                    )}
                  </div>
                );
              })
            )}
          </>
        )}
      </Section>

      {/* Video AMA Scorecard */}
      <ScorecardForm
        title="Video AMA Scorecard"
        prefix="va_"
        detail={detail}
        onFieldChange={updateField}
        onSave={saveVA}
        saving={savingSection === "va"}
      />

      {/* Final Interview Scorecard */}
      <ScorecardForm
        title="Final Interview Scorecard"
        prefix="fi_"
        detail={detail}
        onFieldChange={updateField}
        onSave={saveFI}
        saving={savingSection === "fi"}
      />

      {/* Reference Check */}
      <Section title="Reference Check Notes">
        <textarea
          value={detail?.rc_notes || ""}
          onChange={(e) => updateField("rc_notes", e.target.value)}
          placeholder="Notes from 2-3 reference calls (script on Reference Check manual page)"
          rows={6}
          style={{ width: "100%", padding: 8, fontSize: 12, borderRadius: 7, border: `1px solid ${T.slate200}` }}
        />
        <div style={{ marginTop: 8, display: "flex", alignItems: "center", gap: 10 }}>
          <button onClick={saveRC} disabled={savingSection === "rc"} style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: savingSection === "rc" ? "wait" : "pointer" }}>
            {savingSection === "rc" ? "Saving..." : "Save Reference Notes"}
          </button>
          {detail?.rc_completed_at && (
            <span style={{ fontSize: 10, color: T.slate500 }}>Refs completed {new Date(detail.rc_completed_at).toLocaleString()}</span>
          )}
        </div>
      </Section>

      {/* Final Decision */}
      <Section title="Final Decision" tone={T.amberLt}>
        <div style={{ marginBottom: 8 }}>
          <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 }}>Decision</label>
          <select
            value={detail?.final_decision || ""}
            onChange={(e) => updateField("final_decision", e.target.value || null)}
            style={{ padding: 6, fontSize: 13, borderRadius: 5, border: `1px solid ${T.slate200}`, minWidth: 180 }}
          >
            <option value="">Pending</option>
            <option value="hire">Hire</option>
            <option value="no_hire">No Hire</option>
            <option value="pending">Pending Review</option>
          </select>
        </div>
        <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 }}>Reasoning (document before offer letter — see Team & People Decisions principle)</label>
        <textarea
          value={detail?.decision_notes || ""}
          onChange={(e) => updateField("decision_notes", e.target.value)}
          rows={4}
          style={{ width: "100%", padding: 8, fontSize: 12, borderRadius: 7, border: `1px solid ${T.slate200}` }}
        />
        <div style={{ marginTop: 8, display: "flex", alignItems: "center", gap: 10 }}>
          <button onClick={saveDecision} disabled={savingSection === "decision"} style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: savingSection === "decision" ? "wait" : "pointer" }}>
            {savingSection === "decision" ? "Saving..." : "Save Decision"}
          </button>
          {detail?.decision_at && (
            <span style={{ fontSize: 10, color: T.slate500 }}>Decided {new Date(detail.decision_at).toLocaleString()}</span>
          )}
        </div>
      </Section>
    </div>
  );
}
