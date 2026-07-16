import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// ─── Constants ─────────────────────────────────────────────────────

const DECLINE_REASON_LABEL = {
  active_applicant: "Active — declined",
  offer_rescinded:  "Offer rescinded",
  calibration_only: "Calibration",
  former_team:      "Former team",
};

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

// Rules from hiregauge_evaluate_candidate get bucketed by cross-referencing
// their short_label against the arrays returned by
// hiregauge_composite_recommendation. Order in UI: failed floors first
// (most decision-relevant), then decline / consider / hire, then informational.
const BUCKET_CONFIG = {
  failed_floor:  { title: "Character floors failed", tone: "red" },
  soft_decline:  { title: "Decline signals",         tone: "red" },
  consider:      { title: "Consider signals",        tone: "amber" },
  hire:          { title: "Hire signals",            tone: "green" },
  informational: { title: "Informational",           tone: "slate" },
};

// Candidate.status → which hiring_stage rules are most relevant right now.
// Used only for a small chip that highlights stage-relevant rules; nothing
// is hidden — the framework read is comprehensive by design.
const STAGE_TO_RELEVANT_RULE_STAGES = {
  assessed:        ["assessment_review", "resume_review"],
  email_screen:    ["assessment_review", "interview"],
  interview:       ["interview", "reference_check"],
  reference_check: ["reference_check", "interview"],
  offer:           ["reference_check", "onboarding"],
  hired:           ["onboarding", "retention"],
  declined:        [],
  archived:        [],
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
  const [probesGenerating, setProbesGenerating] = useState(false);
  const [probesError, setProbesError] = useState(null);
  const [composite, setComposite] = useState(null);
  const [frameworkRules, setFrameworkRules] = useState([]);
  const [competencies, setCompetencies] = useState(null);

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
    // Competencies for all four role fits (single RPC returning JSONB keyed by role)
    supabase.rpc("cts_all_competencies", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!error) setCompetencies(data); })
      .catch(() => {});
    // HireGauge framework read — composite verdict + all matched rules.
    // Both RPCs are read-only, IMMUTABLE per candidate, safe to call every mount.
    supabase.rpc("hiregauge_composite_recommendation", { p_assessment_id: detail.id })
      .then(({ data, error }) => {
        if (!error && Array.isArray(data) && data[0]) setComposite(data[0]);
      })
      .catch(() => {});
    supabase.rpc("hiregauge_evaluate_candidate", { p_assessment_id: detail.id })
      .then(({ data, error }) => {
        if (!error && Array.isArray(data)) setFrameworkRules(data);
      })
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

  // Bucket evaluate_candidate rows by verdict impact using composite's signal
  // arrays as the routing table. Composite's decline_signals annotate unverified
  // floors with " (unverified)" suffix — strip before matching. Rules with no
  // match land in "informational" as a safe default.
  const rulesByImpact = useMemo(() => {
    const buckets = { failed_floor: [], soft_decline: [], consider: [], hire: [], informational: [] };
    if (!composite) return buckets;
    const strip = (s) => (s || "").replace(/\s*\(unverified\)\s*$/, "").trim();
    const declineSet  = new Set((composite.decline_signals  || []).map(strip));
    const considerSet = new Set(composite.consider_signals || []);
    const hireSet     = new Set(composite.hire_signals     || []);
    const infoSet     = new Set(composite.informational_signals || []);
    (frameworkRules || []).forEach((r) => {
      const label = r.out_short_label;
      if (r.out_match_confidence === "floor_failed") {
        buckets.failed_floor.push(r);
      } else if (hireSet.has(label)) {
        buckets.hire.push(r);
      } else if (declineSet.has(label)) {
        buckets.soft_decline.push(r);
      } else if (considerSet.has(label)) {
        buckets.consider.push(r);
      } else if (infoSet.has(label)) {
        buckets.informational.push(r);
      } else {
        buckets.informational.push(r);
      }
    });
    return buckets;
  }, [composite, frameworkRules]);

  // Which hiring stages are most relevant given candidate's current status.
  // Rules whose out_hiring_stage intersects this list get a subtle highlight.
  const relevantRuleStages = useMemo(
    () => new Set(STAGE_TO_RELEVANT_RULE_STAGES[detail?.status] || []),
    [detail?.status]
  );

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

  // Invoke edge fn generate-custom-probes; refresh the row on success.
  const generateCustomProbes = async () => {
    if (!detail?.id || !supabase) return;
    setProbesGenerating(true);
    setProbesError(null);
    try {
      const { data, error } = await supabase.functions.invoke("generate-custom-probes", {
        body: { assessment_id: detail.id },
      });
      if (error) throw new Error(error.message || String(error));
      if (data?.error) throw new Error(data.error);
      const { data: refreshed } = await supabase
        .from("team_assessments")
        .select("*")
        .eq("id", detail.id)
        .maybeSingle();
      if (refreshed) setDetail(refreshed);
    } catch (e) {
      setProbesError(e?.message || String(e));
    } finally {
      setProbesGenerating(false);
    }
  };

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
        {(detail?.decline_reason || detail?.assessment_date) && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
            {detail?.decline_reason && (<>Declined: {DECLINE_REASON_LABEL[detail.decline_reason] || detail.decline_reason} · </>)}
            Assessed {detail?.assessment_date || "—"}
          </div>
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

      {/* Role Fit & Competencies — best-fit role, per-role OS scores, and
          competency detail for the best-fit role. Replaces the old raw-JSON
          "Best-fit role" line. Falls back gracefully when CTS unassessed. */}
      <Section title="Role Fit & Competencies">
        {(() => {
          const bf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
          if (!bf) {
            return (
              <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
                Best-fit role computes from CTS traits — awaiting assessment.
              </div>
            );
          }
          const ROLE_LABELS = {
            sales: "Sales",
            service: "Service",
            service_sales: "Service Sales",
            aspirant: "Aspirant",
          };
          const roleTiles = [
            { key: "sales", os: bf.sales_os },
            { key: "service", os: bf.service_os },
            { key: "service_sales", os: bf.service_sales_os },
            { key: "aspirant", os: bf.aspirant_os },
          ];
          const bestKey = bf.best_role;
          const bestComp = competencies?.[bestKey] || null;
          const formatCompLabel = (k) => k.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
          return (
            <>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8, marginBottom: 14 }}>
                {roleTiles.map((r) => {
                  const isBest = r.key === bestKey;
                  return (
                    <div key={r.key} style={{
                      padding: 10, borderRadius: 7,
                      background: isBest ? T.greenLt : T.slate50,
                      border: isBest ? `2px solid ${T.green}` : `1px solid ${T.slate200}`,
                    }}>
                      <div style={{ fontSize: 9, textTransform: "uppercase", color: T.slate500, fontWeight: 600, letterSpacing: 0.3 }}>
                        {ROLE_LABELS[r.key] || r.key}
                        {isBest && <span style={{ marginLeft: 6, color: T.green, fontWeight: 700 }}>★ BEST FIT</span>}
                      </div>
                      <div style={{ fontSize: 22, fontWeight: 700, color: isBest ? T.green : T.slate900, marginTop: 2 }}>
                        {r.os ?? "—"}
                        <span style={{ fontSize: 11, fontWeight: 400, color: T.slate500, marginLeft: 4 }}>OS</span>
                      </div>
                    </div>
                  );
                })}
              </div>
              {bestComp ? (
                <>
                  <div style={{ fontSize: 11, color: T.slate600, marginBottom: 8 }}>
                    <strong>Competencies for {ROLE_LABELS[bestKey] || bestKey}:</strong>
                  </div>
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 6 }}>
                    {Object.entries(bestComp).map(([k, v]) => {
                      const band = v == null ? "none" : v >= 70 ? "green" : v >= 50 ? "yellow" : "red";
                      const colors = bandColor(band);
                      return (
                        <div key={k} style={{ padding: 8, background: colors.bg, borderRadius: 6, borderLeft: `3px solid ${colors.fg}` }}>
                          <div style={{ fontSize: 10, color: T.slate600, fontWeight: 600 }}>{formatCompLabel(k)}</div>
                          <div style={{ fontSize: 16, fontWeight: 700, color: colors.fg }}>{v ?? "—"}</div>
                        </div>
                      );
                    })}
                  </div>
                </>
              ) : (
                <div style={{ fontSize: 11, color: T.slate500, fontStyle: "italic" }}>
                  Competencies computed at runtime from CTS traits.
                </div>
              )}
            </>
          );
        })()}
      </Section>

      {/* Analysis */}
      <Section title="Analysis" tone={T.slate50}>
        <div style={{ marginBottom: 10 }}>
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

      {/* HireGauge Framework Read — auto-computed verdict + every matched
          rule from hiregauge_evaluate_candidate. Bucketed by verdict impact
          via hiregauge_composite_recommendation's signal arrays. This is the
          raw framework read; Customized Interview Probes below is the
          LLM-crafted, candidate-specific probe list built from this same input. */}
      <Section title="HireGauge Framework Read">
        {!composite ? (
          <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
            {frameworkRules?.length === 0
              ? "No trait data yet — framework read waits for CTS scores."
              : "Loading framework read..."}
          </div>
        ) : (
          <>
            {/* Verdict banner */}
            {(() => {
              const v = composite.verdict;
              const ctx = composite.retrospective_context;
              const isRetro = v === "retrospective_read";
              const bg = isRetro ? T.blueLt : v === "decline" ? T.redLt : v === "hire" ? T.greenLt : T.amberLt;
              const fg = isRetro ? T.blue   : v === "decline" ? T.red   : v === "hire" ? T.green   : T.amber;
              const label = isRetro ? "RETROSPECTIVE READ" : (v || "unknown");
              return (
                <div style={{ padding: "10px 14px", marginBottom: 12, borderRadius: 8, background: bg, borderLeft: `4px solid ${fg}` }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 4 }}>
                    <span style={{ padding: "3px 10px", borderRadius: 4, fontSize: 11, fontWeight: 700, color: T.white, background: fg, textTransform: "uppercase", letterSpacing: 0.5 }}>
                      {label}
                    </span>
                    {ctx === "former_team" && (
                      <span style={{ padding: "2px 8px", borderRadius: 4, fontSize: 10, fontWeight: 600, color: T.slate700, background: T.slate100, textTransform: "uppercase", letterSpacing: 0.3 }}>
                        Former team
                      </span>
                    )}
                    <span style={{ fontSize: 11, color: T.slate600 }}>
                      {composite.matched_rules_count ?? 0} rules matched · {composite.floor_failures_count ?? 0} floor failure(s)
                    </span>
                  </div>
                  {composite.primary_reason && (
                    <div style={{ fontSize: 12, color: T.slate800, lineHeight: 1.5 }}>{composite.primary_reason}</div>
                  )}
                </div>
              );
            })()}

            {/* Signal counts row */}
            <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 12, fontSize: 11 }}>
              {[
                { label: "Floors failed",       count: composite.character_floors_failed?.length || 0, fg: T.red },
                { label: "Decline signals",     count: composite.decline_signals?.length || 0,        fg: T.red },
                { label: "Consider signals",    count: composite.consider_signals?.length || 0,       fg: T.amber },
                { label: "Hire signals",        count: composite.hire_signals?.length || 0,           fg: T.green },
                { label: "Informational",       count: composite.informational_signals?.length || 0,  fg: T.slate500 },
              ].filter((s) => s.count > 0).map((s) => (
                <span key={s.label} style={{
                  padding: "3px 8px", borderRadius: 4, background: T.white,
                  border: `1px solid ${s.fg}`, color: s.fg, fontWeight: 600,
                }}>
                  {s.count} × {s.label}
                </span>
              ))}
            </div>

            {/* Rules by bucket */}
            {["failed_floor", "soft_decline", "consider", "hire", "informational"].map((bucketKey) => {
              const rules = rulesByImpact[bucketKey] || [];
              if (rules.length === 0) return null;
              const cfg = BUCKET_CONFIG[bucketKey];
              const bucketFg = cfg.tone === "red" ? T.red : cfg.tone === "amber" ? T.amber : cfg.tone === "green" ? T.green : T.slate500;
              return (
                <div key={bucketKey} style={{ marginBottom: 12 }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: bucketFg, textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 6 }}>
                    {cfg.title} ({rules.length})
                  </div>
                  {rules.map((r) => {
                    const stageMatch = Array.isArray(r.out_hiring_stage)
                      && r.out_hiring_stage.some((s) => relevantRuleStages.has(s));
                    return (
                      <div key={r.out_rule_id} style={{
                        padding: 10, marginBottom: 6, background: T.white, borderRadius: 7,
                        borderLeft: `3px solid ${bucketFg}`,
                        boxShadow: stageMatch ? `0 0 0 1px ${bucketFg}22` : "none",
                      }}>
                        <div style={{ display: "flex", justifyContent: "space-between", gap: 10, flexWrap: "wrap", marginBottom: 4 }}>
                          <div style={{ flex: 1, minWidth: 220 }}>
                            <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900 }}>
                              {r.out_short_label ? <>{r.out_short_label} · </> : null}{r.out_rule_name}
                            </div>
                            <div style={{ fontSize: 10, color: T.slate500, marginTop: 2 }}>
                              {(r.out_rule_type || "").replace(/_/g, " ")}
                              {r.out_calibration_status ? ` · ${r.out_calibration_status.replace(/_/g, " ")}` : ""}
                              {r.out_n_count > 0 ? ` · n=${r.out_n_count}` : ""}
                              {Array.isArray(r.out_hiring_stage) && r.out_hiring_stage.length > 0
                                ? ` · stage: ${r.out_hiring_stage.join(", ")}`
                                : ""}
                              {stageMatch ? " · relevant now" : ""}
                            </div>
                          </div>
                          {r.out_match_confidence && (
                            <span style={{ fontSize: 10, color: T.slate500, fontFamily: "monospace" }}>{r.out_match_confidence}</span>
                          )}
                        </div>
                        {r.out_description && (
                          <div style={{ fontSize: 11, color: T.slate700, marginTop: 4, lineHeight: 1.5 }}>{r.out_description}</div>
                        )}
                        {r.out_recommendation && (
                          <div style={{ fontSize: 11, color: T.slate800, marginTop: 6, lineHeight: 1.5 }}>
                            <strong>Recommendation: </strong>{r.out_recommendation}
                          </div>
                        )}
                        {r.out_diagnostic_action && (
                          <div style={{ fontSize: 11, color: T.slate700, marginTop: 4, lineHeight: 1.5 }}>
                            <strong>Diagnostic: </strong>{r.out_diagnostic_action}
                          </div>
                        )}
                        {r.out_interview_probe && (
                          <div style={{ fontSize: 11, color: T.slate700, marginTop: 4, lineHeight: 1.5 }}>
                            <strong>Interview probe: </strong>{r.out_interview_probe}
                          </div>
                        )}
                        {r.out_coaching_prescription && (
                          <div style={{ fontSize: 11, color: T.slate700, marginTop: 4, lineHeight: 1.5 }}>
                            <strong>Coaching: </strong>{r.out_coaching_prescription}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              );
            })}

            {(!rulesByImpact.failed_floor.length && !rulesByImpact.soft_decline.length
              && !rulesByImpact.consider.length && !rulesByImpact.hire.length
              && !rulesByImpact.informational.length) && (
              <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
                No framework rules matched this candidate's profile.
              </div>
            )}
          </>
        )}
      </Section>

      {/* Customized Interview Probes — LLM-generated per candidate.
          Complements the Triggered Follow-Up Questions below (which is a raw
          manual-section pull based on trait triggers). Runs the whole framework
          picture through the LLM for candidate-specific probes with listen_for
          and concern annotations. */}
      <Section title="Customized Interview Probes" tone={T.blueLt}>
        {(!detail?.custom_probes || !Array.isArray(detail?.custom_probes?.sections) || detail.custom_probes.sections.length === 0) ? (
          <div style={{ fontSize: 12, color: T.slate700 }}>
            No custom probes generated yet for this candidate.
            <div style={{ marginTop: 8 }}>
              <button
                onClick={generateCustomProbes}
                disabled={probesGenerating}
                style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: probesGenerating ? "wait" : "pointer" }}
              >
                {probesGenerating ? "Generating... (may take ~30s)" : "Generate custom probes"}
              </button>
            </div>
          </div>
        ) : (
          <>
            <div style={{ fontSize: 10, color: T.slate500, marginBottom: 12 }}>
              Generated {detail?.custom_probes_generated_at ? new Date(detail.custom_probes_generated_at).toLocaleString() : "—"}
              {detail.custom_probes?.model ? ` · ${detail.custom_probes.model}` : ""}
              {detail.custom_probes?.framework_matches_n != null ? ` · ${detail.custom_probes.framework_matches_n} framework matches` : ""}
              {detail.custom_probes?.resume_analyzed
                ? ` · resume read (${detail.custom_probes.resume_length_chars || 0} chars, ${detail.custom_probes.resume_source || "?"})`
                : detail.custom_probes?.resume_source
                  ? ` · resume not read (${detail.custom_probes.resume_source})`
                  : ""}
              {detail.custom_probes?.notes ? ` · ${detail.custom_probes.notes}` : ""}
            </div>
            {detail.custom_probes.sections.map((sec, si) => (
              <div key={si} style={{ marginBottom: 14 }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: T.slate800, marginBottom: 6, textTransform: "uppercase", letterSpacing: 0.3 }}>{sec?.focus || "Section"}</div>
                {(Array.isArray(sec?.probes) ? sec.probes : []).map((p, pi) => (
                  <div key={pi} style={{ padding: 10, background: T.white, borderRadius: 7, marginBottom: 6, borderLeft: `3px solid ${T.blue}` }}>
                    <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, marginBottom: 4 }}>Q: {p?.question}</div>
                    {p?.listen_for && (
                      <div style={{ fontSize: 11, color: T.slate700, marginBottom: 3 }}>
                        <strong style={{ color: T.green }}>Listen for:</strong> {p.listen_for}
                      </div>
                    )}
                    {p?.concern && (
                      <div style={{ fontSize: 11, color: T.slate700, marginBottom: 3 }}>
                        <strong style={{ color: T.red }}>Concern:</strong> {p.concern}
                      </div>
                    )}
                    {p?.source && (
                      <div style={{ fontSize: 10, color: T.slate500, fontFamily: "monospace", marginTop: 3 }}>{p.source}</div>
                    )}
                  </div>
                ))}
              </div>
            ))}
            <div style={{ marginTop: 8 }}>
              <button
                onClick={generateCustomProbes}
                disabled={probesGenerating}
                style={{ padding: "6px 12px", fontSize: 11, fontWeight: 600, color: T.slate700, background: T.slate100, border: "none", borderRadius: 7, cursor: probesGenerating ? "wait" : "pointer" }}
              >
                {probesGenerating ? "Regenerating..." : "🔄 Regenerate probes"}
              </button>
            </div>
          </>
        )}
        {probesError && (
          <div style={{ marginTop: 8, padding: 8, background: T.redLt, borderRadius: 6, color: T.red, fontSize: 11 }}>
            {probesError}
          </div>
        )}
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
