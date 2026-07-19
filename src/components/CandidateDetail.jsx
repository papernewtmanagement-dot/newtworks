import { useState, useEffect, useMemo, Fragment } from "react";
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

// Role display labels — shared between Results matrix, Assessment layer expansion,
// and Competencies section. Keys match hiring_candidates.assessment_target_role CHECK.
const ROLE_LABELS = {
  sales_outbound:       "Sales - Outbound",
  sales_inbound:        "Sales - Inbound",
  sales_in_book:        "Sales - In-Book",
  retention_reception:  "Retention - Reception",
  retention_escalation: "Retention - Escalation",
  retention_support:    "Retention - Support",
  aspirant:             "Aspirant",
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

// Parse a probe.source string into a colored pill origin. Five origin families
// observed in generate-custom-probes v9.0+ output:
//   manual:{Trait Direction}                      — trait-triggered manual injection (red)
//   trait:{trait}={value}(band)                   — trait-flag-driven LLM probe (red|amber)
//   character_floor:{Trait}[=failed|=v(low)]      — character floor gate (red)
//   resume:{keyword}                              — resume-driven (slate, informational)
//   behavioral_tell:{Tell}=match                  — behavioral tell (amber)
// tone maps into bandColor for pill colors.
const parseProbeOrigin = (source) => {
  if (!source) return null;
  const s = String(source);

  if (s.startsWith("manual:")) {
    return { kind: "manual", label: "Trait Trigger", detail: s.slice(7).trim(), tone: "red" };
  }
  if (s.startsWith("trait:")) {
    const m = s.match(/^trait:([a-z_]+)=([0-9.]+)\(([a-z]+)\)/i);
    if (m) {
      const traitLabel = TRAIT_LABELS[m[1]] || m[1];
      const value = m[2];
      const band = m[3].toLowerCase();
      const tone = (band === "moderate" || band === "watch") ? "amber" : "red";
      const dir = band === "low" ? "Low" : band === "high" ? "High" : band[0].toUpperCase() + band.slice(1);
      return { kind: "trait", label: "Trait Trigger", detail: `${dir} ${traitLabel} (${value})`, tone };
    }
    return { kind: "trait", label: "Trait Trigger", detail: s.slice(6), tone: "red" };
  }
  if (s.startsWith("character_floor:")) {
    const rest = s.slice(16).replace(/=failed$/, "").replace(/=[0-9.]+\([a-z]+\)$/i, "").trim();
    return { kind: "character_floor", label: "Character Floor", detail: rest, tone: "red" };
  }
  if (s.startsWith("resume:")) {
    return { kind: "resume", label: "Resume", detail: s.slice(7).replace(/_/g, " "), tone: "slate" };
  }
  if (s.startsWith("behavioral_tell:")) {
    const rest = s.slice(16);
    const m = rest.match(/^([^=]+)=(.+)$/);
    return { kind: "behavioral_tell", label: "Behavioral Tell", detail: m ? m[1] : rest, tone: "amber" };
  }
  return { kind: "other", label: "Custom", detail: s, tone: "slate" };
};

const originPillColors = (tone) => {
  if (tone === "red")   return { bg: T.redLt,    fg: T.red };
  if (tone === "amber") return { bg: T.amberLt,  fg: T.amber };
  return                       { bg: T.slate100, fg: T.slate600 };
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
    {title && (
      <div style={{ fontSize: 11, textTransform: "uppercase", letterSpacing: 0.5, fontWeight: 700, color: T.slate600, marginBottom: 10 }}>{title}</div>
    )}
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
const AssessRow = ({ label, value, extra, band, subline }) => {
  const colors = band ? bandColor(band) : null;
  const bg = colors ? colors.bg : T.slate50;
  const stripe = colors ? colors.fg : T.slate200;
  const valueColor = colors && (band === "green" || band === "yellow" || band === "red") ? colors.fg : T.slate900;
  return (
    <div style={{
      display: "flex",
      flexDirection: "column",
      padding: "6px 10px",
      background: bg,
      borderRadius: 6,
      borderLeft: `3px solid ${stripe}`,
      boxSizing: "border-box",
      gap: 2,
    }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
        <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>{label}</span>
        <span style={{ fontSize: 14, fontWeight: 700, color: valueColor, whiteSpace: "nowrap" }}>
          {value ?? "—"}
          {extra != null && extra !== "" && (
            <span style={{ fontSize: 10, color: T.slate500, fontWeight: 400, marginLeft: 4 }}>{extra}</span>
          )}
        </span>
      </div>
      {subline && (
        <div style={{ fontSize: 10, color: T.slate500, fontWeight: 400 }}>{subline}</div>
      )}
    </div>
  );
};


// Resume layer expansion body — plain-text extracted resume, scrollable.
// Falls back to a hint when no extraction exists (usually because
// document-processor hasn't parsed the file yet).
// Resume layer expansion body — shows HOW the resume score was arrived at.
// Renders (when present): composite + verdict pill, Nature/Nurture/Drivers
// construct rollups with sub-signals grouped underneath (11 total: 3 Nature,
// 4 Nurture, 4 Drivers), fired resume-tell rule chips (res_rules_fired), and
// a collapsible extracted-text pane. Sub-signal scores + reasoning read from
// first-class res_<slug>_score / res_<slug>_reason columns on hiring_candidates
// (migration 20260718230100 — was res_subsignals JSONB). Falls back to plain
// text display when no score has been written yet. All scores render on the
// 0-100 whole-number scale (bands: ≥75 green / ≥60 amber / <60 red).
function renderResumeLayer(detail, T) {
  const text = detail?.resume_extracted_text;
  const composite = detail?.res_composite;
  const rulesFired = detail?.res_rules_fired;
  const scoredAt = detail?.res_scored_at;
  const scoredModel = detail?.res_scored_model;
  const nature = detail?.res_nature;
  const nurture = detail?.res_nurture;
  const drivers = detail?.res_drivers;

  // Sub-signal → construct mapping. Canonical from hiregauge_rules.resume_score_rubric.
  //   Nature  = mean(Autonomy, Leadership Emergence, Interpersonal Substrate)
  //   Nurture = mean(Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility)
  //   Drivers = mean(Trajectory Direction, Coherent Pursuit, Follow-Through, Goal Orientation)
  // Each sub-signal reads from res_<slug>_score + res_<slug>_reason columns on
  // hiring_candidates (first-class columns as of migration 20260718230100).
  const CONSTRUCTS = [
    { key: "nature",  label: "Nature",  score: nature,  signals: [
      { label: "Autonomy",                scoreKey: "res_autonomy_score",                reasonKey: "res_autonomy_reason" },
      { label: "Leadership Emergence",    scoreKey: "res_leadership_emergence_score",    reasonKey: "res_leadership_emergence_reason" },
      { label: "Interpersonal Substrate", scoreKey: "res_interpersonal_substrate_score", reasonKey: "res_interpersonal_substrate_reason" },
    ]},
    { key: "nurture", label: "Nurture", score: nurture, signals: [
      { label: "Honesty",                 scoreKey: "res_honesty_score",                 reasonKey: "res_honesty_reason" },
      { label: "Concern for Others",      scoreKey: "res_concern_for_others_score",      reasonKey: "res_concern_for_others_reason" },
      { label: "Hard Work Ethic",         scoreKey: "res_hard_work_ethic_score",         reasonKey: "res_hard_work_ethic_reason" },
      { label: "Personal Responsibility", scoreKey: "res_personal_responsibility_score", reasonKey: "res_personal_responsibility_reason" },
    ]},
    { key: "drivers", label: "Drivers", score: drivers, signals: [
      { label: "Trajectory Direction",    scoreKey: "res_trajectory_direction_score",    reasonKey: "res_trajectory_direction_reason" },
      { label: "Coherent Pursuit",        scoreKey: "res_coherent_pursuit_score",        reasonKey: "res_coherent_pursuit_reason" },
      { label: "Follow-Through",          scoreKey: "res_follow_through_score",          reasonKey: "res_follow_through_reason" },
      { label: "Goal Orientation",        scoreKey: "res_goal_orientation_score",        reasonKey: "res_goal_orientation_reason" },
    ]},
  ];

  const anySubSignalScored = CONSTRUCTS.some((c) =>
    c.signals.some((s) => detail?.[s.scoreKey] != null || detail?.[s.reasonKey])
  );

  const hasText = text && String(text).trim().length > 0;
  const hasScore = composite != null || anySubSignalScored;

  if (!hasScore && !hasText) {
    return (
      <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
        No extracted resume text on file. If a PDF is attached, the document processor may not have parsed it yet — check the Resume link at the top of the page for the raw file.
      </div>
    );
  }

  // Coloring thresholds aligned with verdict thresholds (70 pass / 50 consider). 0-100 scale.
  const scoreBg = (v) => v == null ? T.slate50 : v >= 70 ? T.greenLt : v >= 50 ? T.amberLt : T.redLt;
  const scoreFg = (v) => v == null ? T.slate500 : v >= 70 ? T.green   : v >= 50 ? T.amber   : T.red;

  // Round to whole number for display. Rubric scores stored on 0-100 scale.
  const pct = (v) => v == null ? null : Math.round(Number(v));

  // Verdict hardcoded on 0-100 scale. Computed from composite at view time — NOT
  // stored on the row (per Peter directive 2026-07-18: derived data drifts when stored).
  //   composite >= 70 -> pass
  //   composite 50-69 -> consider
  //   composite  < 50 -> decline
  const verdict = composite == null ? null
                : Number(composite) >= 70 ? "pass"
                : Number(composite) >= 50 ? "consider"
                :                           "decline";

  const verdictColor = verdict === "pass"     ? T.green
                     : verdict === "consider" ? T.amber
                     : verdict === "decline"  ? T.red
                     :                          T.slate500;

  return (
    <div>
      {/* Score header — composite + verdict + sub-construct rollups + scored metadata */}
      {hasScore ? (
        <div style={{
          padding: "12px 14px", background: scoreBg(pct(composite)),
          borderRadius: 8, borderLeft: `3px solid ${scoreFg(pct(composite))}`,
          marginBottom: 12,
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 6 }}>
            <span style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>
              {composite != null ? pct(composite) : "—"}
            </span>
            {verdict && (
              <span style={{
                padding: "3px 10px", borderRadius: 4, fontSize: 10, fontWeight: 700,
                color: T.white, background: verdictColor,
                textTransform: "uppercase", letterSpacing: 0.5,
              }}>
                {verdict}
              </span>
            )}
            <span style={{ fontSize: 10, color: T.slate600 }}>resume-only read</span>
          </div>
          {(scoredAt || scoredModel) && (
            <div style={{ fontSize: 10, color: T.slate500, marginTop: 6, fontFamily: "monospace" }}>
              {scoredAt && String(scoredAt).slice(0, 10)}
              {scoredAt && scoredModel && " · "}
              {scoredModel}
            </div>
          )}
        </div>
      ) : hasText ? (
        <div style={{
          padding: "8px 10px", background: T.slate50,
          borderRadius: 6, borderLeft: `3px solid ${T.slate300}`,
          fontSize: 11, color: T.slate600, fontStyle: "italic", marginBottom: 12,
        }}>
          Not yet scored. Extracted resume text below awaits resume-rubric or in-chat Opus scoring.
        </div>
      ) : null}

      {/* Construct rollups — what went into Nature / Nurture / Drivers.
          Each construct score is the mean of its sub-signals; sub-signals
          nested under their construct heading with reasoning text.
          All scores displayed as whole numbers on the 0-100 scale.
          Sub-signal values read from first-class res_<slug>_score /
          res_<slug>_reason columns (migration 20260718230100). */}
      {(nature != null || nurture != null || drivers != null || anySubSignalScored) && (
        <div style={{ marginBottom: 12 }}>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 8 }}>
            How we got here — construct rollups
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
            {CONSTRUCTS.map((c) => {
              const cpct = pct(c.score);
              const scoredSignals = c.signals.filter(
                (sig) => detail?.[sig.scoreKey] != null || detail?.[sig.reasonKey]
              );
              return (
                <div key={c.key}>
                  <div style={{
                    display: "flex", alignItems: "baseline", gap: 10, flexWrap: "wrap",
                    padding: "6px 10px", background: scoreBg(cpct),
                    borderLeft: `3px solid ${scoreFg(cpct)}`, borderRadius: 4,
                    marginBottom: 6,
                  }}>
                    <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{c.label}</span>
                    <span style={{ fontSize: 16, fontWeight: 800, color: T.slate900 }}>
                      {cpct != null ? cpct : "—"}
                    </span>
                    <span style={{ fontSize: 10, color: T.slate600 }}>
                      mean of {c.signals.length} sub-signals
                    </span>
                  </div>
                  {scoredSignals.length > 0 && (
                    <div style={{ display: "flex", flexDirection: "column", gap: 6, marginLeft: 6 }}>
                      {scoredSignals.map((sig) => {
                        const s = detail[sig.scoreKey];
                        const r = detail[sig.reasonKey];
                        const spct = pct(s);
                        return (
                          <div key={sig.label} style={{
                            display: "flex", gap: 10, alignItems: "flex-start",
                            padding: "8px 10px", background: T.white,
                            borderRadius: 6, border: `1px solid ${T.slate200}`,
                          }}>
                            <div style={{
                              minWidth: 52, textAlign: "center", padding: "4px 6px",
                              background: scoreBg(spct), borderRadius: 4,
                              fontWeight: 700, fontSize: 14, color: T.slate900,
                              borderLeft: `3px solid ${scoreFg(spct)}`,
                            }}>
                              {spct != null ? spct : "—"}
                            </div>
                            <div style={{ flex: 1, minWidth: 0 }}>
                              <div style={{ fontSize: 12, fontWeight: 700, color: T.slate800, marginBottom: 2 }}>{sig.label}</div>
                              {r && <div style={{ fontSize: 11, color: T.slate600, lineHeight: 1.5 }}>{r}</div>}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Fired resume-tell rules — chips (self-superiority language, buzzword grid,
          scaffolded career only, career-pivot velocity, metric-perfect-clinical, etc). */}
      {Array.isArray(rulesFired) && rulesFired.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 6 }}>
            Resume-tell rules fired ({rulesFired.length})
          </div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {rulesFired.map((r, i) => (
              <span key={i} style={{
                padding: "3px 8px", borderRadius: 4, background: T.amberLt,
                border: `1px solid ${T.amber}`, color: T.amber, fontSize: 11, fontWeight: 600,
              }}>
                {String(r)}
              </span>
            ))}
          </div>
        </div>
      )}

      {/* Extracted resume text — collapsed when a score exists (score is the
          primary content); expanded inline when no score yet (matches prior UX). */}
      {hasText && (hasScore ? (
        <details style={{ marginTop: 8 }}>
          <summary style={{
            fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4,
            fontWeight: 700, color: T.slate600, cursor: "pointer", userSelect: "none",
            padding: "6px 0",
          }}>
            Extracted resume text
          </summary>
          <div style={{
            fontSize: 12.5,
            lineHeight: 1.55,
            color: T.slate800,
            background: T.white,
            border: `1px solid ${T.slate200}`,
            borderRadius: 6,
            padding: "12px 14px",
            maxHeight: 480,
            overflowY: "auto",
            whiteSpace: "pre-wrap",
            wordBreak: "break-word",
            marginTop: 8,
            fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
          }}>
            {text}
          </div>
        </details>
      ) : (
        <div style={{
          fontSize: 12.5,
          lineHeight: 1.55,
          color: T.slate800,
          background: T.white,
          border: `1px solid ${T.slate200}`,
          borderRadius: 6,
          padding: "12px 14px",
          maxHeight: 480,
          overflowY: "auto",
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
          fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        }}>
          {text}
        </div>
      ))}
    </div>
  );
}

// Assessment layer expansion body — the full LSS / validity / drive & empathy
// / traits view on the left; role-fit selector + competencies for the
// currently-selected role on the right. Moved here from the standalone
// top-of-page Assessment section per Peter directive 2026-07-17.
function renderAssessmentLayer({ detail, timing, validity, competencies, bestFit, selectedRole, setSelectedRole, T }) {
  return (
    <div>
      {/* Profile validity banner (renders only when non-valid). */}
      {(() => {
        const v0 = Array.isArray(validity) && validity.length > 0 ? validity[0] : null;
        if (!v0 || v0.validity_status === "valid") return null;
        const status = v0.validity_status;
        const isUnknown = status === "unknown";
        const bg = isUnknown ? T.slate100 : T.redLt;
        const fg = isUnknown ? T.slate500 : T.red;
        const msg = v0.warning
          || (isUnknown ? "Assessment scores not yet available — validity cannot be evaluated."
                        : "Profile flagged as questionable. Weigh Reliability + Distortion below before trusting scores.");
        return (
          <div style={{
            marginBottom: 14, padding: "8px 10px", background: bg,
            borderRadius: 6, borderLeft: `3px solid ${fg}`, boxSizing: "border-box",
            fontSize: 12, color: T.slate700,
          }}>
            <div style={{ fontSize: 10, fontWeight: 700, color: fg, textTransform: "uppercase", letterSpacing: 0.3, marginBottom: 2 }}>
              Profile validity — {status}
            </div>
            {msg}
          </div>
        );
      })()}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 16 }}>

        {/* LEFT COLUMN — timing, LSS, validity meters, traits */}
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 2 }}>
            Traits & LSS
          </div>
          {timing != null && timing?.overall_flag !== "no_data" && (() => {
            const flag = String(timing.overall_flag || "green").toLowerCase();
            const bg = flag === "red" ? T.redLt : flag === "yellow" ? T.amberLt : T.greenLt;
            const fg = flag === "red" ? T.red   : flag === "yellow" ? T.amber  : T.green;
            return (
              <div style={{
                padding: "8px 10px", background: bg, borderRadius: 6,
                borderLeft: `3px solid ${fg}`, boxSizing: "border-box",
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
          {detail?.cts_invited_at && detail?.cts_started_at && (() => {
            const invited = new Date(detail.cts_invited_at);
            const started = new Date(detail.cts_started_at);
            const ms = started - invited;
            if (!Number.isFinite(ms) || ms < 0) return null;
            const totalMin = Math.floor(ms / 60000);
            const totalHrs = Math.floor(ms / 3600000);
            const days = Math.floor(ms / 86400000);
            const leftoverHrs = totalHrs - days * 24;
            const label = totalMin < 60
              ? `${totalMin}m`
              : totalHrs < 24
                ? `${totalHrs}h`
                : leftoverHrs === 0
                  ? `${days}d`
                  : `${days}d ${leftoverHrs}h`;
            return (
              <div style={{
                padding: "8px 10px", background: T.slate50, borderRadius: 6,
                borderLeft: `3px solid ${T.slate200}`, boxSizing: "border-box",
              }}>
                <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                  <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>Response latency</span>
                  <span style={{ fontSize: 12, fontWeight: 700, color: T.slate900, whiteSpace: "nowrap" }}>
                    {label}
                    <span style={{ fontSize: 10, color: T.slate600, fontWeight: 400, marginLeft: 6 }}>
                      invited → started
                    </span>
                  </span>
                </div>
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
            subline={(() => {
              const m = detail?.lss_math_accuracy;
              const v = detail?.lss_verbal_accuracy;
              const p = detail?.lss_problem_solving_accuracy;
              if (m == null && v == null && p == null) return null;
              return `Math ${m ?? "—"} · Verbal ${v ?? "—"} · PS ${p ?? "—"}`;
            })()}
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
            subline={(() => {
              const m = detail?.lss_math_speed_seconds;
              const v = detail?.lss_verbal_speed_seconds;
              const p = detail?.lss_problem_solving_speed_seconds;
              if (m == null && v == null && p == null) return null;
              return `Math ${m ?? "—"}s · Verbal ${v ?? "—"}s · PS ${p ?? "—"}s`;
            })()}
          />
          <AssessRow label="Reliability" value={detail?.reliability} band={RELIABILITY_BAND(detail?.reliability)} />
          <AssessRow label="Distortion" value={detail?.response_distortion} band={DISTORTION_BAND(detail?.response_distortion)} />
          <AssessRow label="Drive" value={detail?.ego_drive_score} />
          <AssessRow label="Empathy" value={detail?.empathy_score} />

          <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />

          {Object.entries(TRAIT_LABELS).map(([trait, label]) => {
            const value = detail?.[trait];
            const band = TRAIT_BAND[trait](value);
            return <AssessRow key={trait} label={label} value={value} band={band} />;
          })}
        </div>

        {/* RIGHT COLUMN — Role Fit selector (clickable, sorted by OS descending)
            then Competencies filtered to the selected role. Best Fit box +
            "OS" label removed per Peter 2026-07-17: sort order already tells
            you which is best; the number carries no user-facing meaning as
            "OS" so we just show the number. */}
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 2 }}>
            Role Fit
          </div>

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
              sales_outbound:       "Sales - Outbound",
              sales_inbound:        "Sales - Inbound",
              sales_in_book:        "Sales - In-Book",
              retention_reception:  "Retention - Reception",
              retention_escalation: "Retention - Escalation",
              retention_support:    "Retention - Support",
              aspirant:             "Aspirant",
            };
            const roleRows = [
              { key: "sales_outbound",       os: bf.sales_outbound_os },
              { key: "sales_inbound",        os: bf.sales_inbound_os },
              { key: "sales_in_book",        os: bf.sales_in_book_os },
              { key: "retention_reception",  os: bf.retention_reception_os },
              { key: "retention_escalation", os: bf.retention_escalation_os },
              { key: "retention_support",    os: bf.retention_support_os },
              { key: "aspirant",             os: bf.aspirant_os },
            ].sort((a, b) => (Number(b.os) || -Infinity) - (Number(a.os) || -Infinity));
            const bestKey = bf.best_role;
            const currentSelected = selectedRole || bestKey || roleRows[0]?.key;
            return (
              <>
                {roleRows.map((r) => {
                  const isSelected = r.key === currentSelected;
                  const isBest = r.key === bestKey;
                  const colors = isBest ? bandColor("green") : null;
                  const baseBg = colors ? colors.bg : T.slate50;
                  const baseStripe = colors ? colors.fg : T.slate200;
                  const valueColor = isBest ? colors.fg : T.slate900;
                  return (
                    <button
                      key={r.key}
                      type="button"
                      onClick={() => setSelectedRole(r.key)}
                      style={{
                        display: "flex", alignItems: "center", justifyContent: "space-between",
                        padding: "6px 10px", background: baseBg, borderRadius: 6,
                        borderTop: "none", borderRight: "none", borderBottom: "none",
                        borderLeft: `3px solid ${isSelected ? T.slate700 : baseStripe}`,
                        outline: isSelected ? `1px solid ${T.slate400}` : "none",
                        boxSizing: "border-box", gap: 8, cursor: "pointer",
                        fontFamily: "inherit", textAlign: "left", width: "100%",
                      }}
                      title={isSelected ? "Selected — competencies below" : "Click to show this role's competencies"}
                    >
                      <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>
                        {ROLE_LABELS[r.key] || r.key} Fit
                      </span>
                      <span style={{ fontSize: 14, fontWeight: 700, color: valueColor, whiteSpace: "nowrap" }}>
                        {r.os ?? "—"}
                      </span>
                    </button>
                  );
                })}
              </>
            );
          })()}

          <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />

          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 2 }}>
            Competencies
          </div>

          {(() => {
            const bf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
            const bestKey = bf?.best_role;
            const currentSelected = selectedRole || bestKey || "sales_outbound";
            const ROLE_LABELS = {
              sales_outbound:       "Sales - Outbound",
              sales_inbound:        "Sales - Inbound",
              sales_in_book:        "Sales - In-Book",
              retention_reception:  "Retention - Reception",
              retention_escalation: "Retention - Escalation",
              retention_support:    "Retention - Support",
              aspirant:             "Aspirant",
            };
            const roleC = (competencies && competencies[currentSelected]) || {};
            const entries = Object.entries(roleC).sort(([a], [b]) => a.localeCompare(b));
            const formatCompLabel = (k) =>
              k.replace(/_/g, " ").replace(/\w/g, (c) => c.toUpperCase());
            if (entries.length === 0) {
              return (
                <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
                  {competencies ? `No competencies for ${ROLE_LABELS[currentSelected] || currentSelected}.` : "Competencies computed at runtime from traits."}
                </div>
              );
            }
            return (
              <>
                <div style={{ fontSize: 10, color: T.slate500, fontStyle: "italic", marginBottom: 2, padding: "0 10px" }}>
                  Showing {ROLE_LABELS[currentSelected] || currentSelected} — click any role fit above to swap.
                </div>
                {entries.map(([k, v]) => {
                  const band = competencyBand(v);
                  return <AssessRow key={k} label={formatCompLabel(k)} value={v} band={band} />;
                })}
              </>
            );
          })()}
        </div>
      </div>
    </div>
  );
}

// Interview layer expander — full 60-min interview capture surface.
// Was previously a standalone top-level Section; consolidated 2026-07-17 per
// Peter directive: one home for interview capture, not two. Renders:
//   - 60-min flow legend (5 rapport / 10 warm-up / 30 deep-dive / 10 candidate Qs / 5 close)
//   - Warm-Up (3 fixed Qs — FROGS / Why insurance / Why our agency)
//   - Deep-Dive (LLM probes, flat list, origin pill on top of each)
//   - Candidate Questions (they-asked-us capture)
//   - Save button + Generate/Regenerate button + probe error surface
// interview_answers jsonb keys: warmup:frogs, warmup:why_insurance, warmup:why_agency,
// custom_probes[*].source (manual:*, trait:*, character_floor:*, resume:*, behavioral_tell:*),
// candidate_questions.
function renderInterviewLayer({ detail, T, updateAnswer, saveAnswers, savingAnswers, answersLastSavedAt, generateCustomProbes, probesGenerating, probesError }) {
  return (
    <div>
      <div style={{ fontSize: 10, color: T.slate500, marginBottom: 12, fontStyle: "italic" }}>
        60-min interview: 5 min rapport · 10 min warm-up · 30 min deep-dive · 10 min candidate Qs · 5 min close
      </div>

      {/* Warm-Up — 3 fixed questions, same every candidate. Captured. */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate800, marginBottom: 8, textTransform: "uppercase", letterSpacing: 0.3 }}>
          Warm-Up · 10 min · same every candidate
        </div>
        {[
          { key: "warmup:frogs",          n: 1, q: "Get their FROGS (Family, Recreation, Occupation, Goals, Stress)." },
          { key: "warmup:why_insurance",  n: 2, q: "Why insurance?" },
          { key: "warmup:why_agency",     n: 3, q: "Why our agency?" },
        ].map((w) => {
          const savedAt = detail?.interview_answers?.[w.key]?.saved_at || null;
          const currentAnswer = detail?.interview_answers?.[w.key]?.answer || "";
          return (
            <div key={w.key} style={{ padding: 10, background: T.white, borderRadius: 7, marginBottom: 8, borderLeft: `3px solid ${T.slate400}` }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, marginBottom: 6 }}>
                <strong>{w.n}.</strong> {w.q}
              </div>
              <textarea
                value={currentAnswer}
                onChange={(e) => updateAnswer(w.key, e.target.value)}
                placeholder="Candidate's response..."
                rows={3}
                style={{
                  width: "100%",
                  fontSize: 12,
                  padding: 8,
                  border: `1px solid ${T.slate300}`,
                  borderRadius: 5,
                  fontFamily: "inherit",
                  resize: "vertical",
                  boxSizing: "border-box",
                  background: T.slate50,
                }}
              />
              {savedAt && (
                <div style={{ fontSize: 9, color: T.slate500, marginTop: 3, fontStyle: "italic" }}>
                  Saved {new Date(savedAt).toLocaleString()}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Deep-Dive — LLM-generated candidate-specific probes, flat list. */}
      <div style={{ marginBottom: 12 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate800, marginBottom: 6, textTransform: "uppercase", letterSpacing: 0.3 }}>
          Deep-Dive · ~{detail?.custom_probes?.time_budget_minutes || 30} min · candidate-specific
        </div>

        {(!detail?.custom_probes || !Array.isArray(detail?.custom_probes?.sections) || detail.custom_probes.sections.length === 0) ? (
          <div style={{ fontSize: 11, color: T.slate500, fontStyle: "italic", marginBottom: 12 }}>
            No LLM-generated probes yet — use the Generate button below.
          </div>
        ) : (
          detail.custom_probes.sections.flatMap((sec, si) =>
            (Array.isArray(sec?.probes) ? sec.probes : []).map((p, pi) => {
              const src = p?.source || `s${si}p${pi}`;
              const savedAt = detail?.interview_answers?.[src]?.saved_at || null;
              const currentAnswer = detail?.interview_answers?.[src]?.answer || "";
              const origin = p?.source ? parseProbeOrigin(p.source) : null;
              const pc = origin ? originPillColors(origin.tone) : null;
              return (
                <div key={`${si}-${pi}`} style={{ padding: 10, background: T.white, borderRadius: 7, marginBottom: 8, borderLeft: `3px solid ${T.blue}` }}>
                  {origin && (
                    <div style={{ marginBottom: 8, display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
                      <span style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "2px 8px", fontSize: 10, fontWeight: 700, color: pc.fg, background: pc.bg, borderRadius: 10, textTransform: "uppercase", letterSpacing: 0.3 }}>
                        {origin.label}
                      </span>
                      <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>{origin.detail}</span>
                      <span style={{ fontSize: 9, color: T.slate400, fontFamily: "monospace", marginLeft: "auto" }}>{p.source}</span>
                    </div>
                  )}
                  <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, marginBottom: 4 }}>Q: {p?.question}</div>
                  {p?.listen_for && (
                    <div style={{ fontSize: 11, color: T.slate700, marginBottom: 3 }}>
                      <strong style={{ color: T.green }}>Listen for:</strong> {p.listen_for}
                    </div>
                  )}
                  {p?.concern && (
                    <div style={{ fontSize: 11, color: T.slate700, marginBottom: 6 }}>
                      <strong style={{ color: T.red }}>Concern:</strong> {p.concern}
                    </div>
                  )}
                  <textarea
                    value={currentAnswer}
                    onChange={(e) => updateAnswer(src, e.target.value)}
                    placeholder="Candidate's response..."
                    rows={3}
                    style={{
                      width: "100%",
                      fontSize: 12,
                      padding: 8,
                      border: `1px solid ${T.slate300}`,
                      borderRadius: 5,
                      fontFamily: "inherit",
                      resize: "vertical",
                      boxSizing: "border-box",
                      background: T.slate50,
                    }}
                  />
                  {savedAt && (
                    <div style={{ fontSize: 9, color: T.slate500, marginTop: 3, fontStyle: "italic" }}>
                      Saved {new Date(savedAt).toLocaleString()}
                    </div>
                  )}
                </div>
              );
            })
          )
        )}
      </div>

      {/* Candidate Questions — capture what THEY asked. */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate800, marginBottom: 8, textTransform: "uppercase", letterSpacing: 0.3 }}>
          Candidate Questions · 10 min
        </div>
        {(() => {
          const src = "candidate_questions";
          const savedAt = detail?.interview_answers?.[src]?.saved_at || null;
          const currentAnswer = detail?.interview_answers?.[src]?.answer || "";
          return (
            <div style={{ padding: 10, background: T.white, borderRadius: 7, borderLeft: `3px solid ${T.slate400}` }}>
              <div style={{ fontSize: 11, color: T.slate600, marginBottom: 6, fontStyle: "italic" }}>
                Capture the questions the candidate asks — content and quality of their questions is a signal.
              </div>
              <textarea
                value={currentAnswer}
                onChange={(e) => updateAnswer(src, e.target.value)}
                placeholder="Their questions..."
                rows={4}
                style={{
                  width: "100%",
                  fontSize: 12,
                  padding: 8,
                  border: `1px solid ${T.slate300}`,
                  borderRadius: 5,
                  fontFamily: "inherit",
                  resize: "vertical",
                  boxSizing: "border-box",
                  background: T.slate50,
                }}
              />
              {savedAt && (
                <div style={{ fontSize: 9, color: T.slate500, marginTop: 3, fontStyle: "italic" }}>
                  Saved {new Date(savedAt).toLocaleString()}
                </div>
              )}
            </div>
          );
        })()}
      </div>

      {/* Bottom action row — Save answers + Generate/Regenerate. */}
      <div style={{ marginTop: 12, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
        <button
          onClick={saveAnswers}
          disabled={savingAnswers}
          style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white, background: T.green, border: "none", borderRadius: 7, cursor: savingAnswers ? "wait" : "pointer" }}
        >
          {savingAnswers ? "Saving..." : "💾 Save answers"}
        </button>
        {answersLastSavedAt && (
          <span style={{ fontSize: 11, color: T.slate600 }}>
            Last saved {new Date(answersLastSavedAt).toLocaleString()}
          </span>
        )}
        <button
          onClick={generateCustomProbes}
          disabled={probesGenerating}
          style={{ padding: "6px 12px", fontSize: 11, fontWeight: 600, color: (detail?.custom_probes ? T.slate700 : T.white), background: (detail?.custom_probes ? T.slate100 : T.blue), border: "none", borderRadius: 7, cursor: probesGenerating ? "wait" : "pointer", marginLeft: "auto" }}
        >
          {probesGenerating
            ? (detail?.custom_probes ? "Regenerating..." : "Generating... (may take ~30s)")
            : (detail?.custom_probes ? "🔄 Regenerate probes" : "Generate custom probes")}
        </button>
      </div>

      {probesError && (
        <div style={{ marginTop: 8, padding: 8, background: T.redLt, borderRadius: 6, color: T.red, fontSize: 11 }}>
          {probesError}
        </div>
      )}
    </div>
  );
}

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
  const [probesGenerating, setProbesGenerating] = useState(false);
  const [probesError, setProbesError] = useState(null);
  const [composite, setComposite] = useState(null);
  const [frameworkRules, setFrameworkRules] = useState([]);
  const [competencies, setCompetencies] = useState(null);
  // Which role fit is selected. Sourced from hiring_candidates.assessment_target_role
  // via v_hiring_candidates so it survives page refresh. setSelectedRole persists the
  // choice + refetches view so assessment_nature/nurture/drivers/composite refresh.
  const [selectedRole, setSelectedRoleLocal] = useState(null);
  useEffect(() => {
    if (detail && detail.assessment_target_role !== undefined) {
      setSelectedRoleLocal(detail.assessment_target_role);
    }
  }, [detail?.assessment_target_role]);
  const setSelectedRole = async (roleKey) => {
    const newVal = roleKey || null;
    setSelectedRoleLocal(newVal);
    if (!detail?.id) return;
    const { error } = await supabase
      .from("hiring_candidates")
      .update({ assessment_target_role: newVal })
      .eq("id", detail.id);
    if (error) { alert("Failed to save role selection: " + error.message); return; }
    const { data } = await supabase
      .from("v_hiring_candidates")
      .select("*")
      .eq("id", detail.id)
      .maybeSingle();
    if (data) setDetail(data);
  };
  // Which Results-matrix layer row is expanded (null = none). Only one
  // layer expanded at a time. Click chevron in the layer label cell.
  const [expandedLayer, setExpandedLayer] = useState(null);
  // Three-construct verdict (Nature/Nurture/Drivers) — per-layer verdicts +
  // framework prediction + retrospective observation + calibration status.
  // Fetched via hiregauge_three_construct_verdict RPC.
  const [threeConstruct, setThreeConstruct] = useState(null);
  // Interview answer capture — local state; Save button batch-writes to
  // hiring_candidates.interview_answers jsonb (keyed by probe.source →
  // { answer, saved_at }). See op-rule "Interview probe analysis protocol".
  const [savingAnswers, setSavingAnswers] = useState(false);

  // Fetch full row on mount
  useEffect(() => {
    if (!candidate?.id || !supabase) return;
    let cancelled = false;
    supabase
      .from("v_hiring_candidates")
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
    // Three-construct verdict: Nature/Nurture/Drivers per-layer verdicts +
    // pre-hire framework prediction + retrospective observation + calibration.
    supabase.rpc("hiregauge_three_construct_verdict", { p_assessment_id: detail.id })
      .then(({ data, error }) => {
        if (!error && Array.isArray(data) && data[0]) setThreeConstruct(data[0]);
      })
      .catch(() => {});
  }, [detail?.id]);

  // Auto-default assessment_target_role to best-fit role on first load when unset.
  // Fires once bestFit resolves; setSelectedRole persists to DB + refetches view so
  // assessment_nature/nurture/drivers/composite populate without user click.
  useEffect(() => {
    if (!detail?.id) return;
    if (detail.assessment_target_role) return; // already set — respect stored choice
    const bfBestRole = Array.isArray(bestFit) && bestFit[0]?.best_role;
    if (!bfBestRole) return; // best fit not loaded yet
    setSelectedRole(bfBestRole);
    // setSelectedRole is stable via useCallback? Not currently — but effect only fires when
    // deps change AND both guards clear, so no infinite loop (target_role becomes non-null
    // after write → guard trips on next run).
  }, [detail?.id, detail?.assessment_target_role, bestFit]);

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

  // Most recent saved_at across all captured probe answers.
  const answersLastSavedAt = useMemo(() => {
    const answers = detail?.interview_answers || {};
    let latest = null;
    Object.values(answers).forEach(a => {
      if (a?.saved_at && (!latest || a.saved_at > latest)) latest = a.saved_at;
    });
    return latest;
  }, [detail?.interview_answers]);

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

    const { error } = await supabase
      .from("hiring_candidates")
      .update(updates)
      .eq("id", detail.id);
    if (error) {
      setSavingSection(null);
      alert("Save failed: " + error.message);
      return;
    }
    // Refetch from view so computed aggregates (res_nature/nurture/drivers/composite) refresh
    const { data } = await supabase
      .from("v_hiring_candidates")
      .select("*")
      .eq("id", detail.id)
      .maybeSingle();
    setSavingSection(null);
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
  const saveRC = () => saveFields(["rc_notes", "ref_nature", "ref_nurture", "ref_drivers"], "rc");
  const saveDecision = () => saveFields(["final_decision", "decision_notes"], "decision");

  // Update one probe's answer text in local state. Save button batch-writes
  // to hiring_candidates.interview_answers jsonb.
  const updateAnswer = (source, answerText) => {
    if (!source) return;
    setDetail(prev => ({
      ...prev,
      interview_answers: {
        ...(prev.interview_answers || {}),
        [source]: {
          ...((prev.interview_answers || {})[source] || {}),
          answer: answerText,
        },
      },
    }));
  };

  const saveAnswers = async () => {
    if (!detail?.id) return;
    setSavingAnswers(true);
    const now = new Date().toISOString();
    const answers = { ...(detail.interview_answers || {}) };
    Object.keys(answers).forEach(k => {
      if (answers[k]?.answer && answers[k].answer.trim()) {
        answers[k] = { ...answers[k], saved_at: now };
      }
    });
    const { error } = await supabase
      .from("hiring_candidates")
      .update({ interview_answers: answers })
      .eq("id", detail.id);
    if (error) {
      setSavingAnswers(false);
      alert("Save failed: " + error.message);
      return;
    }
    // Refetch from view so computed aggregates stay populated on detail
    const { data } = await supabase
      .from("v_hiring_candidates")
      .select("*")
      .eq("id", detail.id)
      .maybeSingle();
    setSavingAnswers(false);
    if (data) setDetail(data);
  };

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
        .from("v_hiring_candidates")
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

      {/* Results — Suggs four-layer × three-construct framework read from
          hiregauge_three_construct_verdict. The 4×3 matrix
          (Resume/Assessment/Interview/Reference × Nature/Nurture/Drivers)
          drives the top verdict; each layer row is now clickable to expand
          layer-specific detail. Resume expansion shows extracted resume
          text; Assessment expansion holds the full LSS + traits + role-fit
          + competencies view (formerly a standalone top box); Interview /
          Reference expansions reserved for follow-up work. */}
      <Section title="Results">
        {!threeConstruct ? (
          <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
            No trait data yet — results wait for assessment scores.
          </div>
        ) : (
          <>
            {/* 4×3 matrix table — layers as expandable rows, constructs as columns.
                Each cell shows the (0-10) score plus the weight applied within that construct.
                Cell background bands by score band (green ≥7.5 / amber ≥6.0 / red <6.0).
                Click a layer label to expand its detail row underneath. */}
            {(() => {
              const matrix = threeConstruct.meta?.matrix || {};
              const weights = threeConstruct.meta?.layer_weights_within_construct || {};
              const cw = threeConstruct.meta?.construct_weights || {};
              const layers = [
                { key: "resume",     label: "Resume",     score: threeConstruct.resume_score,     verdict: threeConstruct.resume_verdict },
                // Assessment layer sources composite/nature/nurture/drivers from v_hiring_candidates
                // (populated by role-fit click). Score is 0-100 like Resume. Verdict computed by layerVerdict.
                { key: "assessment", label: "Assessment", score: detail?.assessment_composite ?? null, verdict: null },
                { key: "interview",  label: "Interview",  score: threeConstruct.interview_score,  verdict: threeConstruct.interview_verdict },
                { key: "reference",  label: "Reference",  score: threeConstruct.reference_score,  verdict: threeConstruct.reference_verdict },
              ];
              const constructs = [
                { key: "nature",  label: "Nature",  weight: cw.nature,  score: threeConstruct.nature_score  },
                { key: "nurture", label: "Nurture", weight: cw.nurture, score: threeConstruct.nurture_score },
                { key: "drivers", label: "Drivers", weight: cw.drivers, score: threeConstruct.drivers_score },
              ];
              const scoreBg = (v) => v == null ? T.slate50
                                   : v >= 7.5 ? T.greenLt
                                   : v >= 6.0 ? T.amberLt
                                   : T.redLt;
              const scoreFg = (v) => v == null ? T.slate500
                                   : v >= 7.5 ? T.green
                                   : v >= 6.0 ? T.amber
                                   : T.red;
              // Layer-total coloring: Resume row uses 70/50 (0-100 scale), other rows 7.5/6.0 (0-10 scale).
              const layerThresh = (k) => (k === "resume" || k === "assessment") ? { pass: 70, consider: 50 } : { pass: 7.5, consider: 6.0 };
              const layerBg = (v, k) => { if (v == null) return T.slate50; const t = layerThresh(k); return v >= t.pass ? T.greenLt : v >= t.consider ? T.amberLt : T.redLt; };
              const layerFg = (v, k) => { if (v == null) return T.slate500; const t = layerThresh(k); return v >= t.pass ? T.green : v >= t.consider ? T.amber : T.red; };
              // Resume + Assessment layer scores now 0-100 (view-computed). Other layers still 0-10.
              const fmtLayerScore = (v, k) => v == null ? "—"
                : (k === "resume" || k === "assessment") ? String(Math.round(Number(v)))
                : Number(v).toFixed(2);
              // Resume + Assessment verdicts computed from composite on 0-100 scale (hardcoded 70/50); other layer verdicts come from RPC output.
              const resumeVerdict = (v) => v == null ? null
                                        : v >= 70 ? "pass"
                                        : v >= 50 ? "consider"
                                        :           "decline";
              const layerVerdict = (layer) => (layer.key === "resume" || layer.key === "assessment")
                ? resumeVerdict(layer.score)
                : layer.verdict;
              const verdictLabel = (v) => (v || "not_scored").replace(/_/g, " ");
              const pctFmt = (w) => w == null ? "" : `${Math.round(Number(w) * 100)}%`;
              const th = { padding: "8px 10px", fontSize: 10, fontWeight: 700, color: T.slate600, textTransform: "uppercase", letterSpacing: 0.4, textAlign: "center", borderBottom: `1px solid ${T.slate200}` };
              const rowLabelBase = { padding: "8px 10px", fontSize: 11, fontWeight: 600, color: T.slate700, background: T.slate50, borderRight: `1px solid ${T.slate200}`, whiteSpace: "nowrap" };
              const clickableRowLabel = { ...rowLabelBase, cursor: "pointer", userSelect: "none" };

              return (
                <div style={{ marginBottom: 14, border: `1px solid ${T.slate200}`, borderRadius: 8, overflow: "hidden" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", tableLayout: "fixed" }}>
                    <thead>
                      <tr style={{ background: T.slate50 }}>
                        <th style={{ ...th, width: 130 }}></th>
                        {constructs.map((c) => (
                          <th key={c.key} style={th}>
                            {c.label} <span style={{ color: T.slate500, fontWeight: 500 }}>· {pctFmt(c.weight)}</span>
                          </th>
                        ))}
                        <th style={{ ...th, width: 110, borderLeft: `2px solid ${T.slate200}` }}>Total</th>
                      </tr>
                    </thead>
                    <tbody>
                      {layers.map((layer) => {
                        const isOpen = expandedLayer === layer.key;
                        return (
                          <Fragment key={layer.key}>
                            <tr style={{ borderBottom: `1px solid ${T.slate100}` }}>
                              <td
                                style={clickableRowLabel}
                                onClick={() => setExpandedLayer(isOpen ? null : layer.key)}
                                title={isOpen ? "Click to collapse" : "Click to expand layer detail"}
                              >
                                <span style={{ display: "inline-block", width: 12, color: T.slate500, marginRight: 4, transition: "transform 0.15s", transform: isOpen ? "rotate(90deg)" : "rotate(0deg)" }}>▶</span>
                                {layer.label}
                              </td>
                              {constructs.map((c) => {
                                // Assessment cells come from v_hiring_candidates assessment_* columns.
                                const cell = layer.key === "assessment"
                                  ? (c.key === "nature" ? detail?.assessment_nature
                                    : c.key === "nurture" ? detail?.assessment_nurture
                                    : detail?.assessment_drivers)
                                  : matrix?.[c.key]?.[layer.key];
                                const w = weights?.[c.key]?.[layer.key];
                                const cellDisplay = cell == null ? "—"
                                  : (layer.key === "resume" || layer.key === "assessment") ? String(Math.round(Number(cell)))
                                  : Number(cell).toFixed(2);
                                // Resume + Assessment cells 0-100 (thresh 75/60); other layers 0-10 (thresh 7.5/6.0).
                                const cellBg = cell == null ? T.slate50
                                  : (layer.key === "resume" || layer.key === "assessment")
                                    ? (cell >= 75 ? T.greenLt : cell >= 60 ? T.amberLt : T.redLt)
                                    : (cell >= 7.5 ? T.greenLt : cell >= 6.0 ? T.amberLt : T.redLt);
                                const cellFg = cell == null ? T.slate500
                                  : (layer.key === "resume" || layer.key === "assessment")
                                    ? (cell >= 75 ? T.green : cell >= 60 ? T.amber : T.red)
                                    : (cell >= 7.5 ? T.green : cell >= 6.0 ? T.amber : T.red);
                                return (
                                  <td key={c.key} style={{ padding: "8px 10px", background: cellBg, borderRight: `1px solid ${T.slate100}`, textAlign: "center" }}>
                                    <div style={{ fontSize: 14, fontWeight: 700, color: cell == null ? T.slate500 : T.slate900 }}>
                                      {cellDisplay}
                                    </div>
                                    <div style={{ fontSize: 9, color: cell == null ? T.slate500 : cellFg, fontWeight: 600 }}>
                                      weight {pctFmt(w)}
                                    </div>
                                    {layer.key === "assessment" && c.key === "nurture" && (
                                      <div
                                        style={{ fontSize: 8, color: T.slate600, marginTop: 2, fontWeight: 500, letterSpacing: 0.2 }}
                                        title="Suggs character subscores: Honesty (from distortion) · Concern for Others (compassion 0.7 + belief 0.3) · Hard Work Ethic (from reliability)"
                                      >
                                        H {detail?.assessment_nurture_honesty != null ? Math.round(Number(detail.assessment_nurture_honesty)) : "—"}
                                        {" · "}
                                        C {detail?.assessment_nurture_concern != null ? Math.round(Number(detail.assessment_nurture_concern)) : "—"}
                                        {" · "}
                                        W {detail?.assessment_nurture_work_ethic != null ? Math.round(Number(detail.assessment_nurture_work_ethic)) : "—"}
                                      </div>
                                    )}
                                  </td>
                                );
                              })}
                              <td style={{ padding: "8px 10px", background: layerBg(layer.score, layer.key), borderLeft: `2px solid ${T.slate200}`, textAlign: "center" }}>
                                <div style={{ fontSize: 15, fontWeight: 800, color: layer.score == null ? T.slate500 : T.slate900 }}>
                                  {fmtLayerScore(layer.score, layer.key)}
                                </div>
                                <div style={{ marginTop: 2 }}>
                                  <span style={{ display: "inline-block", padding: "2px 6px", borderRadius: 3, fontSize: 9, fontWeight: 700, color: layer.score == null ? T.slate500 : T.white, background: layer.score == null ? T.slate100 : layerFg(layer.score, layer.key), textTransform: "uppercase", letterSpacing: 0.4 }}>
                                    {verdictLabel(layerVerdict(layer))}
                                  </span>
                                </div>
                                {layer.key === "assessment" && (
                                  <div style={{ marginTop: 3 }}>
                                    <span style={{ display: "inline-block", padding: "2px 6px", borderRadius: 3, fontSize: 9, fontWeight: 600, color: T.slate700, background: T.slate100, textTransform: "uppercase", letterSpacing: 0.4 }}>
                                      {detail?.assessment_target_role
                                        ? (ROLE_LABELS[detail.assessment_target_role] || detail.assessment_target_role)
                                        : "click a role fit →"}
                                    </span>
                                  </div>
                                )}
                              </td>
                            </tr>
                            {isOpen && (
                              <tr style={{ borderBottom: `1px solid ${T.slate200}`, background: T.white }}>
                                <td colSpan={5} style={{ padding: "14px 16px", background: T.slate50 }}>
                                  {layer.key === "resume" && renderResumeLayer(detail, T)}
                                  {layer.key === "assessment" && renderAssessmentLayer({
                                    detail, timing, validity, competencies, bestFit,
                                    selectedRole, setSelectedRole, T,
                                  })}
                                  {layer.key === "interview" && renderInterviewLayer({
                                    detail, T,
                                    updateAnswer, saveAnswers, savingAnswers, answersLastSavedAt,
                                    generateCustomProbes, probesGenerating, probesError,
                                  })}
                                  {layer.key === "reference" && (
                                    <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
                                      Reference layer detail — coming next.
                                    </div>
                                  )}
                                </td>
                              </tr>
                            )}
                          </Fragment>
                        );
                      })}
                      {/* Per-construct weighted subtotal row */}
                      <tr style={{ borderTop: `2px solid ${T.slate200}`, background: T.slate50 }}>
                        <td style={{ ...rowLabelBase, background: T.slate100, fontWeight: 700 }}>Subtotal</td>
                        {constructs.map((c) => (
                          <td key={c.key} style={{ padding: "10px", background: scoreBg(c.score), borderLeft: `3px solid ${scoreFg(c.score)}`, borderRight: `1px solid ${T.slate100}`, textAlign: "center" }}>
                            <div style={{ fontSize: 16, fontWeight: 800, color: c.score == null ? T.slate500 : T.slate900 }}>
                              {c.score != null ? Number(c.score).toFixed(2) : "—"}
                              <span style={{ fontSize: 9, color: T.slate500, fontWeight: 400, marginLeft: 3 }}>/ 10</span>
                            </div>
                          </td>
                        ))}
                        <td style={{ padding: "10px", background: T.slate100, borderLeft: `2px solid ${T.slate200}` }}></td>
                      </tr>
                      {/* Overall result row — score + verdict + confidence + threshold previews */}
                      <tr>
                        <td style={{ ...rowLabelBase, background: T.slate900, color: T.white, fontWeight: 700, borderRight: `1px solid ${T.slate900}` }}>Result</td>
                        <td colSpan={4} style={{ padding: "10px 12px", background: scoreBg(threeConstruct.score_0_10), borderLeft: `3px solid ${scoreFg(threeConstruct.score_0_10)}`, textAlign: "center" }}>
                          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, flexWrap: "wrap", marginBottom: 6 }}>
                            <span style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>
                              {threeConstruct.score_0_10 != null ? Number(threeConstruct.score_0_10).toFixed(2) : "—"}
                              <span style={{ fontSize: 10, color: T.slate500, fontWeight: 400, marginLeft: 3 }}>/ 10</span>
                            </span>
                            <span style={{ padding: "3px 10px", borderRadius: 4, fontSize: 10, fontWeight: 700, color: T.white, background: scoreFg(threeConstruct.score_0_10), textTransform: "uppercase", letterSpacing: 0.5 }}>
                              {(threeConstruct.verdict || "insufficient data").replace(/_/g, " ")}
                            </span>
                            <span style={{ fontSize: 11, color: T.slate600 }}>
                              confidence: {threeConstruct.confidence || "—"}
                            </span>
                          </div>
                          <div style={{ display: "flex", gap: 12, fontSize: 10, color: T.slate600, justifyContent: "center", flexWrap: "wrap" }}>
                            <span>@7.0: <strong style={{ color: T.slate900 }}>{threeConstruct.score_hire_at_70 || "n/a"}</strong></span>
                            <span>@7.5: <strong style={{ color: T.slate900 }}>{threeConstruct.score_hire_at_75 || "n/a"}</strong></span>
                            <span>@8.0: <strong style={{ color: T.slate900 }}>{threeConstruct.score_hire_at_80 || "n/a"}</strong></span>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              );
            })()}

          </>
        )}
      </Section>

      {/* HireGauge Framework Read — narrative walkthrough (Claude's synthesis
          from hiring_candidates.notes) on top, then the auto-computed verdict
          + every matched rule from hiregauge_evaluate_candidate, bucketed by
          verdict impact via hiregauge_composite_recommendation's signal arrays.
          Walkthrough renders independently — may exist even without composite
          (e.g. former-team retrospective reads pre-CTS). Customized Interview
          Probes below is the LLM-crafted, candidate-specific probe list built
          from this same input. */}
      <Section title="HireGauge Framework Read">
        {/* Walkthrough — Claude's per-candidate narrative synthesis. Preserved-
            whitespace prose with ALL-CAPS section labels, bullets, dividers.
            Resume-specific analysis lives in the Resume layer expander in
            Results (composite + 10 sub-signals + rules fired) — do not
            duplicate resume prose here going forward. */}
        {detail?.notes && detail.notes.trim().length > 0 && (
          <div style={{
            marginBottom: 14, padding: "12px 14px", background: T.slate50,
            borderRadius: 8, borderLeft: `3px solid ${T.slate300}`,
          }}>
            <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 8 }}>
              Walkthrough
            </div>
            <div style={{
              fontSize: 12.5,
              lineHeight: 1.55,
              color: T.slate800,
              whiteSpace: "pre-wrap",
              wordBreak: "break-word",
              fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
            }}>
              {detail.notes}
            </div>
          </div>
        )}

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
      <Section title="Reference Check">
        {/* Reference layer scoring — feeds Results 4×3 matrix Reference row */}
        <div style={{ marginBottom: 10, padding: "10px 12px", borderRadius: 7, background: T.slate50, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 8 }}>
            Reference Layer Scoring <span style={{ opacity: 0.7, textTransform: "none", letterSpacing: 0, fontWeight: 500, fontStyle: "italic" }}>· 1–10 based on 2–3 reference calls; feeds Result matrix Reference row</span>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10 }}>
            {[
              { key: "ref_nature",  label: "Nature",  hint: "core temperament, drive, honesty" },
              { key: "ref_nurture", label: "Nurture", hint: "developed skills, resilience, adaptability" },
              { key: "ref_drivers", label: "Drivers", hint: "motivation quality, ownership, work ethic" },
            ].map(({ key, label, hint }) => (
              <div key={key}>
                <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2, fontWeight: 600 }}>{label}</label>
                <input
                  type="number"
                  min={1}
                  max={10}
                  step={1}
                  value={detail?.[key] ?? ""}
                  onChange={(e) => {
                    const raw = e.target.value;
                    if (raw === "") { updateField(key, null); return; }
                    const n = Math.max(1, Math.min(10, parseInt(raw, 10) || 0));
                    updateField(key, n);
                  }}
                  placeholder="—"
                  style={{ width: "100%", padding: 6, fontSize: 13, borderRadius: 5, border: `1px solid ${T.slate200}`, textAlign: "center" }}
                />
                <div style={{ fontSize: 9, color: T.slate500, marginTop: 2 }}>{hint}</div>
              </div>
            ))}
          </div>
        </div>
        <textarea
          value={detail?.rc_notes || ""}
          onChange={(e) => updateField("rc_notes", e.target.value)}
          placeholder="Notes from 2-3 reference calls (script on Reference Check manual page)"
          rows={6}
          style={{ width: "100%", padding: 8, fontSize: 12, borderRadius: 7, border: `1px solid ${T.slate200}` }}
        />
        <div style={{ marginTop: 8, display: "flex", alignItems: "center", gap: 10 }}>
          <button onClick={saveRC} disabled={savingSection === "rc"} style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: savingSection === "rc" ? "wait" : "pointer" }}>
            {savingSection === "rc" ? "Saving..." : "Save Reference Check"}
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
