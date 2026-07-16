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

// Validity bands — reliability higher-is-better, distortion lower-is-better.
// Values are text: 'very_low' | 'low' | 'moderate' | 'high' | 'very_high'.
const RELIABILITY_BAND = (v) => {
  if (v == null) return "none";
  if (v === "very_high" || v === "high") return "green";
  if (v === "moderate") return "yellow";
  return "red"; // low, very_low
};
const DISTORTION_BAND = (v) => {
  if (v == null) return "none";
  if (v === "very_low" || v === "low") return "green";
  if (v === "moderate") return "yellow";
  return "red"; // high, very_high
};

// Competency band — green ≥ 50, yellow 40–49, red < 40. Same threshold across
// all four role fits (per Peter directive 2026-07-16).
const competencyBand = (v) => {
  if (v == null) return "none";
  if (v >= 50) return "green";
  if (v >= 40) return "yellow";
  return "red";
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

// Single horizontal row inside the Assessment top box. Left-aligned label,
// right-aligned value + optional smaller extra (units, secondary metric, or
// warning glyph). Optional `band` drives left-border color and value tint
// via bandColor(); pass "none" for a neutral grey stripe, null for no band.
const AssessRow = ({ label, value, extra, band }) => {
  const colors = band ? bandColor(band) : null;
  const bg = colors ? colors.bg : T.slate50;
  const stripe = colors ? colors.fg : T.slate200;
  const valueColor = colors && (band === "green" || band === "yellow" || band === "red") ? colors.fg : T.slate900;
  return (
    <div style={{
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      padding: "6px 10px",
      background: bg,
      borderRadius: 6,
      borderLeft: `3px solid ${stripe}`,
      boxSizing: "border-box",
      gap: 8,
    }}>
      <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>{label}</span>
      <span style={{ fontSize: 14, fontWeight: 700, color: valueColor, whiteSpace: "nowrap" }}>
        {value ?? "—"}
        {extra != null && extra !== "" && (
          <span style={{ fontSize: 10, color: T.slate500, fontWeight: 400, marginLeft: 4 }}>{extra}</span>
        )}
      </span>
    </div>
  );
};

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

      {/* Assessment — top box merging LSS breakdown, validity, drive/empathy,
          traits (left column) with all competencies + role fit + best fit
          (right column). Timing flag now sits at the TOP of the left column
          as a fully colored row (per Peter 2026-07-16). CTS label dropped
          from all headings. */}
      <Section title="Assessment">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 16 }}>

          {/* LEFT COLUMN */}
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            {/* Timing flag — row background colored by cts_timing_assessment
                overall_flag (red / yellow / green). Consolidates former
                footer chip (label + pill) into a single colored strip. */}
            {timing != null && timing?.overall_flag !== "no_data" && (() => {
              const flag = String(timing.overall_flag || "green").toLowerCase();
              const bg = flag === "red" ? T.redLt : flag === "yellow" ? T.amberLt : T.greenLt;
              const fg = flag === "red" ? T.red   : flag === "yellow" ? T.amber  : T.green;
              return (
                <div style={{
                  padding: "8px 10px",
                  background: bg,
                  borderRadius: 6,
                  borderLeft: `3px solid ${fg}`,
                  boxSizing: "border-box",
                }}>
                  <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                    <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>Timing</span>
                    <span style={{ fontSize: 12, fontWeight: 700, color: fg, whiteSpace: "nowrap" }}>
                      {timing.total_min}m
                      <span style={{ fontSize: 10, color: T.slate600, fontWeight: 400, marginLeft: 6 }}>
                        total · Traits {timing.cts_min}m · LSS {timing.lss_min}m · VCT {timing.vct_min}m
                      </span>
                    </span>
                  </div>
                  {Array.isArray(timing.reasons) && timing.reasons.length > 0 && (
                    <div style={{ fontSize: 11, color: T.slate600, marginTop: 4 }}>
                      {timing.reasons.map((r, i) => <div key={i}>• {r}</div>)}
                    </div>
                  )}
                </div>
              );
            })()}
            <AssessRow
              label="LSS Math"
              value={detail?.lss_math_accuracy}
              extra={detail?.lss_math_speed_seconds != null ? `${detail.lss_math_speed_seconds}s/item` : null}
            />
            <AssessRow
              label="LSS Verbal"
              value={detail?.lss_verbal_accuracy}
              extra={detail?.lss_verbal_speed_seconds != null ? `${detail.lss_verbal_speed_seconds}s/item` : null}
            />
            <AssessRow
              label="LSS Problem Solving"
              value={detail?.lss_problem_solving_accuracy}
              extra={detail?.lss_problem_solving_speed_seconds != null ? `${detail.lss_problem_solving_speed_seconds}s/item` : null}
            />
            <AssessRow
              label="LSS Total"
              value={detail?.lss_total_accuracy}
              extra={detail?.lss_total_accuracy != null ? "/35" : null}
              band={
                detail?.lss_total_accuracy == null ? "none"
                : detail.lss_total_accuracy >= 30 ? "green"
                : detail.lss_total_accuracy >= 25 ? "yellow"
                : "red"
              }
            />
            <AssessRow
              label="LSS Speed"
              value={(() => {
                const m = Number(detail?.lss_math_speed_seconds);
                const v = Number(detail?.lss_verbal_speed_seconds);
                const p = Number(detail?.lss_problem_solving_speed_seconds);
                if (!Number.isFinite(m) || !Number.isFinite(v) || !Number.isFinite(p)) return null;
                return Math.round((m + v + p) / 3);
              })()}
              extra="s/item avg"
              band={(() => {
                const maxSpeed = Math.max(
                  Number(detail?.lss_math_speed_seconds) || 0,
                  Number(detail?.lss_verbal_speed_seconds) || 0,
                  Number(detail?.lss_problem_solving_speed_seconds) || 0
                );
                if (!maxSpeed) return "none";
                return maxSpeed > 60 ? "red" : maxSpeed > 40 ? "yellow" : "green";
              })()}
            />
            <AssessRow
              label="Reliability"
              value={detail?.reliability}
              band={RELIABILITY_BAND(detail?.reliability)}
            />
            <AssessRow
              label="Distortion"
              value={detail?.response_distortion}
              band={DISTORTION_BAND(detail?.response_distortion)}
            />
            <AssessRow label="Drive" value={detail?.ego_drive_score} />
            <AssessRow label="Empathy" value={detail?.empathy_score} />

            {/* Horizontal divider between validity/drive/empathy block and traits */}
            <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />

            {/* 9 traits, one row each with band coloring */}
            {Object.entries(TRAIT_LABELS).map(([trait, label]) => {
              const value = detail?.[trait];
              const band = TRAIT_BAND[trait](value);
              return <AssessRow key={trait} label={label} value={value} band={band} />;
            })}
          </div>

          {/* RIGHT COLUMN */}
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            {(() => {
              // Union of all four role competencies. Shared names have the
              // same underlying value (formulas produce identical results),
              // so a simple first-wins merge keeps every distinct competency
              // once. Sorted alphabetically by canonical snake_case key so
              // ordering is stable across candidates.
              const all = {};
              if (competencies && typeof competencies === "object") {
                ["sales", "service", "service_sales", "aspirant"].forEach((role) => {
                  const roleC = competencies[role] || {};
                  Object.entries(roleC).forEach(([k, v]) => {
                    if (!(k in all)) all[k] = v;
                  });
                });
              }
              const entries = Object.entries(all).sort(([a], [b]) => a.localeCompare(b));
              const formatCompLabel = (k) =>
                k.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
              if (entries.length === 0) {
                return (
                  <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
                    Competencies computed at runtime from traits.
                  </div>
                );
              }
              return entries.map(([k, v]) => {
                const band = competencyBand(v);
                return <AssessRow key={k} label={formatCompLabel(k)} value={v} band={band} />;
              });
            })()}

            {/* Divider before role fit block */}
            <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />

            {/* Role fit scores + best fit indicator */}
            {(() => {
              const bf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
              if (!bf) {
                return (
                  <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
                    Best-fit role computes from traits — awaiting assessment.
                  </div>
                );
              }
              const ROLE_LABELS = {
                sales:         "Sales",
                service:       "Service",
                service_sales: "Service Sales",
                aspirant:      "Aspirant",
              };
              const roleRows = [
                { key: "sales",         os: bf.sales_os },
                { key: "service",       os: bf.service_os },
                { key: "service_sales", os: bf.service_sales_os },
                { key: "aspirant",      os: bf.aspirant_os },
              ];
              const bestKey = bf.best_role;
              return (
                <>
                  {roleRows.map((r) => (
                    <AssessRow
                      key={r.key}
                      label={`${ROLE_LABELS[r.key] || r.key} Fit`}
                      value={r.os}
                      extra="OS"
                      band={r.key === bestKey ? "green" : null}
                    />
                  ))}
                  <div style={{
                    marginTop: 6,
                    padding: "8px 10px",
                    background: T.greenLt,
                    borderRadius: 6,
                    borderLeft: `3px solid ${T.green}`,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                  }}>
                    <span style={{ fontSize: 10, textTransform: "uppercase", color: T.slate600, fontWeight: 700, letterSpacing: 0.3 }}>
                      Best Fit
                    </span>
                    <span style={{ fontSize: 14, fontWeight: 700, color: T.green }}>
                      ★ {ROLE_LABELS[bestKey] || bestKey}
                    </span>
                  </div>
                </>
              );
            })()}
          </div>
        </div>

        {/* Timing flag moved to top of left column above (Peter 2026-07-16). */}
      </Section>

      {/* Analysis */}
      <Section title="Analysis" tone={T.slate50}>
        {/* Profile validity — only surface when non-valid. Reliability +
            Distortion cells above already carry the underlying reads via
            band coloring; showing the raw jsonb here added noise, so we
            only render an actionable banner when the validity function
            flags questionable/unknown. Warning text comes from the RPC. */}
        {(() => {
          const v0 = Array.isArray(validity) && validity.length > 0 ? validity[0] : null;
          if (!v0) return null;
          const status = v0.validity_status;
          if (status === "valid") return null;
          const isUnknown = status === "unknown";
          const bg = isUnknown ? T.slate100 : T.redLt;
          const fg = isUnknown ? T.slate500 : T.red;
          const msg = v0.warning
            || (isUnknown ? "Assessment scores not yet available — validity cannot be evaluated."
                          : "Profile flagged as questionable. Review Reliability + Distortion above before weighing scores.");
          return (
            <div style={{
              marginBottom: 10,
              padding: "8px 10px",
              background: bg,
              borderRadius: 6,
              borderLeft: `3px solid ${fg}`,
              boxSizing: "border-box",
              fontSize: 12,
              color: T.slate700,
            }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: fg, textTransform: "uppercase", letterSpacing: 0.3, marginBottom: 2 }}>
                Profile validity — {status}
              </div>
              {msg}
            </div>
          );
        })()}
        {detail?.claude_summary && (
          <div style={{ padding: 10, background: T.white, borderRadius: 7, fontSize: 12, marginBottom: 10, color: T.slate700 }}>
            <div style={{ fontSize: 10, fontWeight: 700, color: T.slate500, textTransform: "uppercase", marginBottom: 4 }}>Claude Summary</div>
            {detail.claude_summary}
          </div>
        )}
        <div>
          <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>Trait triggers detected:</div>
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
              ? "No trait data yet — framework read waits for assessment scores."
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
