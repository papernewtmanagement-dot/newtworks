import { useState, useEffect, useMemo, Fragment } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport, useVerdictThresholds } from "../lib/hooks.js";

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

// Newtworks v2 assessment — the 21 live personality facets, strategic labels
// pulled from hiregauge_trait_documentation.strategic_label. Feeds the 12
// competencies + 7 role-fit functions below (Newtworks competency layer,
// confirmed 2026-08-02, live 2026-08-03 — the earlier "no competency layer"
// note reflected a different, since-superseded thread; see op-rule
// "CORRECTION 2026-08-03: competency/role-fit descope directive was
// thread-specific, not agency-wide").
const V2_FACET_LABELS = {
  achievement_striving:       "Achievement Striving",
  self_discipline:            "Self-Discipline",
  emotional_stability:        "Emotional Stability",
  dutifulness:                "Dutifulness",
  customer_orientation:       "Customer Orientation",
  self_efficacy:              "Self-Efficacy",
  proactive_personality:      "Proactive Personality",
  cautiousness:                "Cautiousness",
  anxiety:                    "Anxiety",
  friendliness:               "Friendliness",
  anger:                      "Anger",
  cooperation:                "Cooperation",
  trust:                      "Trust",
  dispositional_optimism:     "Dispositional Optimism",
  political_skill_networking: "Political Skill (Networking)",
  enterprising:                "Enterprising",
  sincerity:                  "Sincerity",
  fairness:                   "Fairness",
  greed_avoidance:            "Greed-Avoidance",
};

// SJT (situational judgement test) topics — hypothesized_trait values on
// newtworks_v2_sjt items, keys into sjt_topic_detail jsonb.
const SJT_TOPIC_LABELS = {
  sjt_compliance_licensing_boundary: "Compliance — Licensing Boundary",
  sjt_compliance_outbound_consent:   "Compliance — Outbound Consent",
  sjt_composure_under_load:          "Composure Under Load",
  sjt_escalation_judgment:           "Escalation Judgment",
  sjt_honesty_integrity:             "Honesty & Integrity",
};

// Reliability (careless-response) composite — six detection methods, per
// hiregauge_v2_reliability_composite. 'fired' = flagged as a concern.
const RELIABILITY_METHOD_LABELS = {
  response_time_fast:  "Too-fast responding",
  disengagement_slow:  "Disengagement (too slow)",
  straightlining:      "Straight-lining",
  retest_divergence:   "Retest divergence",
  evenodd_consistency: "Even/odd consistency",
  bogus_items:         "Bogus/attention items",
};

// v2 reliability band is high/medium/low (fired-count based) — distinct from
// the v1 RELIABILITY_BAND's five-value text scale. Higher fired_count = worse.
const V2_RELIABILITY_BAND = (v) => {
  if (v === "high") return "green";
  if (v === "medium") return "yellow";
  if (v === "low") return "red";
  return "none";
};

// Faking-good (impression management) band — typical/elevated/very_elevated.
const IM_BAND_COLOR = (band) => {
  if (band === "typical") return "green";
  if (band === "elevated") return "yellow";
  if (band === "very_elevated") return "red";
  return "none";
};

// TRAIT_BAND removed 2026-07-24 — the nine primary CTS trait tiles now render
// neutral because their ideal bands are role-dependent, and coloring them
// against a generic sales-seat band was misleading. Role-aware judgment lives
// in the Role Fit + Competencies sections on the right of the same expander.

// Role display labels — shared between Results matrix, Assessment layer expansion,
// and Competencies section. Keys are the seven canonical role fits.
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

// ─── Interview scoring helpers ─────────────────────────────────────
// Read per-probe score + verdict from interview_answers[source] and derive
// construct from source prefix. Mapping per hiregauge_rules
// rule_type=interview_score_rubric row "Probe source to construct mapping".
const constructForSource = (source) => {
  if (!source) return "capability";
  const s = String(source);
  if (s.startsWith("warmup:") || s === "candidate_questions" || s.startsWith("motivation:")) return "commitment";
  if (s.startsWith("character_floor:") || s.startsWith("validity:")) return "character";
  if (s.startsWith("resume:") && /(agent-title|title-float|gap|honesty|misattrib)/i.test(s)) return "character";
  return "capability"; // default: manual:*, resume:*, framework:archetype:*, structure:*, trait:*, behavioral_tell:*
};

const verdictPillColors = (verdict) => {
  const v = String(verdict || "").toLowerCase();
  if (v === "green")               return { bg: T.greenLt, fg: T.green };
  if (v === "yellow" || v === "amber") return { bg: T.amberLt, fg: T.amber };
  if (v === "red")                 return { bg: T.redLt, fg: T.red };
  if (v === "no_answer")           return { bg: T.slate100, fg: T.slate500 };
  return null;
};

const renderScorePill = (entry, _source) => {
  // Per-construct pill rendering. An answer may score on 0, 1, 2, or 3 constructs.
  // Reads entry.scores.<construct>.{score,verdict}. Old single-construct shape
  // (entry.score / entry.verdict / entry.construct) is not supported here —
  // Priscilla's row was migrated 2026-07-20 (step 2), no legacy shape remains
  // in production data. constructForSource() helper is retained for scoring-path
  // default suggestions but no longer used here.
  const scores = entry?.scores;
  if (!scores || typeof scores !== "object") return null;
  const constructs = ["capability", "character", "commitment"].filter((c) => scores[c]);
  if (constructs.length === 0) return null;
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 4, flexWrap: "wrap" }}>
      {constructs.map((c) => {
        const s = scores[c] || {};
        const score = s.score;
        const verdict = s.verdict;
        const colors = verdictPillColors(verdict) || { bg: T.slate100, fg: T.slate600 };
        const scoreDisplay = (verdict === "no_answer" || score == null) ? "—" : String(score * 10);
        return (
          <span key={c} style={{ display: "inline-flex", alignItems: "center", gap: 4, padding: "2px 8px", fontSize: 10, fontWeight: 700, color: colors.fg, background: colors.bg, borderRadius: 10, textTransform: "uppercase", letterSpacing: 0.3 }}>
            {c} · {scoreDisplay}
          </span>
        );
      })}
    </span>
  );
};

const verdictBandColors = (verdict) => {
  const v = String(verdict || "").toLowerCase();
  if (v === "hire")         return { bg: T.greenLt, fg: T.green };
  if (v === "consider")     return { bg: T.blueLt || T.slate100, fg: T.blue || T.slate700 };
  if (v === "lean_decline") return { bg: T.amberLt, fg: T.amber };
  if (v === "decline")      return { bg: T.redLt, fg: T.red };
  return { bg: T.slate100, fg: T.slate600 };
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
//
// Universal gauge bar: the row background renders as a horizontal fill (0-100%)
// showing the value's magnitude on its scale. Score-band-colored fill up to
// (value/max)% of the row width, neutral rest to the right.
//   - `max` (default 100) scales numeric values (e.g. 12 for LSS Math, 35 for LSS Total).
//   - `noBar` opts out (for time values like LSS Speed where "fill" would mislead).
//   - Text values with a `band` render a band-inferred fill (green 85 / yellow 55 / red 25).
//
// Optional `lssDelta` (numeric, on the same scale as value): adds a colored extension
// past the base bar — blue if positive (LSS boost), red if negative (LSS dampen).
// Extension width proportional to |delta|/max, so +10 on 50 (max 100) = 1/5 the
// width of the base bar.
const AssessRow = ({ label, value, extra, band, subline, lssDelta, max, noBar }) => {
  const colors = band ? bandColor(band) : null;
  const bandBg = colors ? colors.bg : T.slate50;
  const stripe = colors ? colors.fg : T.slate200;
  const valueColor = colors && (band === "green" || band === "yellow" || band === "red") ? colors.fg : T.slate900;
  // Gauge fill color: banded rows use their bandBg; unbanded rows fall back to a
  // muted grey so the fill is visible against the neutral slate50 "rest".
  const gaugeFill = colors ? colors.bg : (T.slate200 || "#e2e8f0");
  const numMax = typeof max === "number" && max > 0 ? max : 100;
  const numValue = typeof value === "number" ? value : Number(value);
  let fillPct = null;
  if (!noBar) {
    if (Number.isFinite(numValue)) {
      fillPct = Math.max(0, Math.min(100, (numValue / numMax) * 100));
    } else if (typeof value === "string" && value !== "" && band && band !== "none") {
      fillPct = band === "green" ? 85 : band === "yellow" ? 55 : band === "red" ? 25 : null;
    }
  }
  let bg = bandBg;
  if (fillPct != null) {
    const rest = T.slate50 || "#f8fafc";
    const d = Number(lssDelta);
    const hasLss = Number.isFinite(d) && Math.abs(d) >= 0.5 && Number.isFinite(numValue);
    if (hasLss) {
      const deltaPct = Math.max(-100, Math.min(100, (d / numMax) * 100));
      const extColor = d > 0 ? "rgba(37, 99, 235, 0.55)" : "rgba(220, 38, 38, 0.55)";
      if (d > 0) {
        const basePct = Math.max(0, Math.min(100, fillPct - deltaPct));
        bg = `linear-gradient(to right, ${gaugeFill} 0%, ${gaugeFill} ${basePct}%, ${extColor} ${basePct}%, ${extColor} ${fillPct}%, ${rest} ${fillPct}%, ${rest} 100%)`;
      } else {
        const totalPct = Math.max(0, Math.min(100, fillPct - deltaPct));
        bg = `linear-gradient(to right, ${gaugeFill} 0%, ${gaugeFill} ${fillPct}%, ${extColor} ${fillPct}%, ${extColor} ${totalPct}%, ${rest} ${totalPct}%, ${rest} 100%)`;
      }
    } else {
      bg = `linear-gradient(to right, ${gaugeFill} 0%, ${gaugeFill} ${fillPct}%, ${rest} ${fillPct}%, ${rest} 100%)`;
    }
  }
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

// Intelligence headline — the top-of-column signal for the Assessment layer.
// Composite (0-100 scale, mean ~50 / SD ~15) comes from hiregauge_lss_delta_v2
// via the assessment_intelligence_composite RPC wrapper. Band is role-specific,
// pulled live from hiregauge_role_ideal_ranges (floor/ceiling for the currently
// selected role) — NOT a hardcoded threshold. Below floor = red (2c comp-side
// penalty engages). Within range = green. Above ceiling = amber — not a penalty
// on the candidate, a fit note per Ganzach 1998 / Maltarich et al. 2010
// (cognitively over-qualified for this specific seat, may fit a higher-ceiling
// role better). Replaces the old hardcoded greenT=15/yellowT=12 raw-item-count
// bands (Step 6, 2026-08-01).
const IntelligenceHeadline = ({ composite, floor, ceiling, roleLabel, T }) => {
  const c = composite == null ? null : Number(composite);
  const hasRange = floor != null && ceiling != null;
  const band = c == null || !hasRange ? "none"
    : c < floor ? "red"
    : c > ceiling ? "yellow"
    : "green";
  const colors = bandColor(band);
  const fillPct = c == null ? 0 : Math.max(0, Math.min(100, c));
  const fitNote = band === "red" ? "Below role floor"
    : band === "yellow" ? "Above role ceiling — over-qualified for this seat"
    : band === "green" ? "Within ideal range"
    : null;
  const rangeNote = hasRange
    ? `Ideal range for ${roleLabel || "this role"}: ${floor}\u2013${ceiling}`
    : roleLabel ? `No calibrated range yet for ${roleLabel}` : null;
  return (
    <div style={{
      padding: "14px 16px", background: colors.bg, borderRadius: 8,
      borderLeft: `4px solid ${colors.fg}`, boxSizing: "border-box",
      display: "flex", flexDirection: "column", gap: 6, marginBottom: 4,
    }}>
      <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
        <span style={{ fontSize: 11, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600 }}>
          Intelligence
        </span>
        <span style={{ fontSize: 26, fontWeight: 800, color: band === "none" ? T.slate500 : colors.fg }}>
          {c != null ? Math.round(c) : "—"}
        </span>
      </div>
      <div style={{ height: 6, background: T.slate200, borderRadius: 3, overflow: "hidden", boxSizing: "border-box" }}>
        <div style={{ height: "100%", width: `${fillPct}%`, background: band === "none" ? T.slate300 : colors.fg, borderRadius: 3 }} />
      </div>
      {fitNote && <div style={{ fontSize: 11, fontWeight: 600, color: colors.fg }}>{fitNote}</div>}
      {rangeNote && <div style={{ fontSize: 10, color: T.slate500 }}>{rangeNote}</div>}
    </div>
  );
};


// Resume layer expansion body — plain-text extracted resume, scrollable.
// Falls back to a hint when no extraction exists (usually because
// document-processor hasn't parsed the file yet).
// Resume layer expansion body — shows HOW the resume score was arrived at.
// Renders (when present): composite + verdict pill, Capability/Character/Commitment
// construct rollups with sub-signals grouped underneath (11 total: 3 Capability,
// 4 Character, 4 Commitment), fired resume-tell rule chips, and a collapsible
// extracted-text pane. Sub-signal scores + reasoning read from the resume_analysis
// jsonb col (migration 20260723080000 step 4a). Step 4d (migration 20260723225121)
// removed the flat-col fallback — jsonb is the sole source. All scores render on
// the 0-100 whole-number scale (bands: ≥75 green / ≥60 amber / <60 red).
function renderResumeLayer(detail, T, resumeThresh) {
  const text = detail?.resume_extracted_text;
  const composite = detail?.res_composite;
  const capability = detail?.res_capability;
  const character = detail?.res_character;
  const commitment = detail?.res_commitment;
  // resume_analysis jsonb (step 4a) is the sole source of truth for signals,
  // rules_fired, scored_at, scored_model, qualifications. Step 4d removed the
  // flat-col fallback.
  const ra = detail?.resume_analysis;
  const rulesFired = ra?.rules_fired;
  const scoredAt = ra?.scored_at;
  const scoredModel = ra?.scored_model;

  // Helper: resolve a sub-signal's {score,reason} from resume_analysis.signals jsonb.
  const sigOf = (slug) => {
    const j = ra?.signals?.[slug];
    return { score: j?.score, reason: j?.reason };
  };

  // Sub-signal → construct mapping. Canonical from hiregauge_rules.resume_score_rubric.
  //   Capability = mean(Autonomy, Leadership Emergence, Interpersonal Substrate)
  //   Character  = mean(Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility)
  //   Commitment = mean(Trajectory Direction, Coherent Pursuit, Follow-Through, Goal Orientation)
  // Each sub-signal resolves via sigOf(slug) → jsonb-first, flat-col fallback.
  const CONSTRUCTS = [
    { key: "capability", label: "Capability", score: capability, signals: [
      { label: "Autonomy",                slug: "autonomy" },
      { label: "Leadership Emergence",    slug: "leadership_emergence" },
      { label: "Interpersonal Substrate", slug: "interpersonal_substrate" },
    ]},
    { key: "character", label: "Character", score: character, signals: [
      { label: "Honesty",                 slug: "honesty" },
      { label: "Concern for Others",      slug: "concern_for_others" },
      { label: "Hard Work Ethic",         slug: "hard_work_ethic" },
      { label: "Personal Responsibility", slug: "personal_responsibility" },
    ]},
    { key: "commitment", label: "Commitment", score: commitment, signals: [
      { label: "Trajectory Direction",    slug: "trajectory_direction" },
      { label: "Coherent Pursuit",        slug: "coherent_pursuit" },
      { label: "Follow-Through",          slug: "follow_through" },
      { label: "Goal Orientation",        slug: "goal_orientation" },
    ]},
  ];

  const anySubSignalScored = CONSTRUCTS.some((c) =>
    c.signals.some((s) => {
      const { score, reason } = sigOf(s.slug);
      return score != null || reason;
    })
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

  // Coloring thresholds pulled from useVerdictThresholds() hook, kept in sync with the scoring RPC.
  const scoreBg = (v) => v == null ? T.slate50  : v >= resumeThresh.pass ? T.greenLt : v >= resumeThresh.consider ? T.amberLt : T.redLt;
  const scoreFg = (v) => v == null ? T.slate500 : v >= resumeThresh.pass ? T.green   : v >= resumeThresh.consider ? T.amber   : T.red;

  // Round to whole number for display. Rubric scores stored on 0-100 scale.
  const pct = (v) => v == null ? null : Math.round(Number(v));

  // Verdict computed from composite at view time — NOT stored on the row (per
  // Peter directive 2026-07-18: derived data drifts when stored). Thresholds
  // come from resumeThresh (fed by useVerdictThresholds hook — same source as RPC).
  const verdict = composite == null ? null
                : Number(composite) >= resumeThresh.pass     ? "pass"
                : Number(composite) >= resumeThresh.consider ? "consider"
                :                                              "decline";

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

      {/* Construct rollups — what went into Capability / Character / Commitment.
          Each construct score is the mean of its sub-signals; sub-signals
          nested under their construct heading with reasoning text.
          All scores displayed as whole numbers on the 0-100 scale.
          Sub-signal values resolve via sigOf() from resume_analysis.signals jsonb. */}
      {(capability != null || character != null || commitment != null || anySubSignalScored) && (
        <div style={{ marginBottom: 12 }}>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 8 }}>
            How we got here — construct rollups
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
            {CONSTRUCTS.map((c) => {
              const cpct = pct(c.score);
              const scoredSignals = c.signals
                .map((sig) => ({ ...sig, ...sigOf(sig.slug) }))
                .filter((sig) => sig.score != null || sig.reason);
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
                        const spct = pct(sig.score);
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
                              {sig.reason && <div style={{ fontSize: 11, color: T.slate600, lineHeight: 1.5 }}>{sig.reason}</div>}
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

      {/* Qualifications — structured extracts of licensure, language, education,
          and prior-similar-role fit. Reads from resume_analysis.qualifications jsonb
          (step 4a). Step 4d removed the flat-col fallback (migration 20260723225121).
          Feeds the LSS auto-pass exception logic in _hiregauge_lss_autopass so tier4
          candidates with license or prior insurance experience keep their framework
          verdict. Always visible when qualifications are populated. */}
      {detail?.resume_analysis?.qualifications && (() => {
        const q = detail.resume_analysis.qualifications;
        const lic = q.licenses ?? {};
        const lang = q.languages ?? {};
        const edu = q.education ?? {};
        const prior = q.prior_similar_role ?? {};
        const heldLicenses = [
          lic.pc && "P&C", lic.lh && "L&H", lic.ips && "IPS",
          lic.series_6 && "Series 6", lic.series_63 && "Series 63",
          lic.series_7 && "Series 7", lic.series_24 && "Series 24",
        ].filter(Boolean);
        const spanish = lang.spanish;
        const spanishLabel = spanish && spanish !== "none" ? `Spanish · ${spanish}` : null;
        const otherLangs = Array.isArray(lang.other_languages) ? lang.other_languages : [];
        const eduLevel = edu.highest_completed;
        const eduLine = eduLevel && eduLevel !== "unknown"
          ? [eduLevel.replace(/_/g, " "), edu.institution, edu.field, edu.year_completed].filter(Boolean).join(" · ")
          : null;
        const relev = prior.highest_relevance;
        const insMonths = prior.insurance_tenure_months;
        const relevLabel = relev && relev !== "none" ? relev.replace(/_/g, " ") : null;
        const signals = Array.isArray(prior.success_signals) ? prior.success_signals : [];

        // Tile color signals whether the field would fire an LSS auto-pass exception
        const licColor = heldLicenses.length > 0 ? T.green : T.slate500;
        const langColor = spanishLabel ? T.green : T.slate500;
        const eduColor = ["bachelors","masters","doctorate"].includes(eduLevel) && edu.institution ? T.green : T.slate500;
        const relevColor = ["insurance_direct","insurance_adjacent"].includes(relev) && signals.length > 0 ? T.green : T.slate500;

        const Tile = ({ heading, color, children }) => (
          <div style={{
            flex: "1 1 200px", minWidth: 180,
            padding: "8px 10px",
            background: T.white, border: `1px solid ${T.slate200}`,
            borderLeft: `3px solid ${color}`, borderRadius: 6,
          }}>
            <div style={{ fontSize: 9, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate500, marginBottom: 4 }}>
              {heading}
            </div>
            <div style={{ fontSize: 12, color: T.slate800, lineHeight: 1.4 }}>
              {children}
            </div>
          </div>
        );
        return (
          <div style={{ marginBottom: 12 }}>
            <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 6 }}>
              Qualifications (structured)
            </div>
            <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              <Tile heading="Licenses" color={licColor}>
                {heldLicenses.length > 0
                  ? (
                    <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                      {heldLicenses.map((L) => (
                        <span key={L} style={{ padding: "1px 6px", borderRadius: 3, background: T.greenLt, color: T.green, fontSize: 11, fontWeight: 600 }}>{L}</span>
                      ))}
                    </div>
                  )
                  : <span style={{ color: T.slate500, fontStyle: "italic" }}>None noted</span>}
                {lic.notes && <div style={{ fontSize: 10, color: T.slate500, marginTop: 4, lineHeight: 1.4 }}>{lic.notes}</div>}
              </Tile>
              <Tile heading="Language" color={langColor}>
                {spanishLabel || (otherLangs.length > 0 ? "" : <span style={{ color: T.slate500, fontStyle: "italic" }}>None noted</span>)}
                {otherLangs.length > 0 && (
                  <div style={{ marginTop: spanishLabel ? 4 : 0 }}>
                    {otherLangs.map((l, i) => (
                      <div key={i} style={{ fontSize: 11 }}>{l.language} · {l.proficiency}</div>
                    ))}
                  </div>
                )}
                {lang.notes && <div style={{ fontSize: 10, color: T.slate500, marginTop: 4, lineHeight: 1.4 }}>{lang.notes}</div>}
              </Tile>
              <Tile heading="Education" color={eduColor}>
                {eduLine || <span style={{ color: T.slate500, fontStyle: "italic" }}>Not stated</span>}
                {edu.notes && <div style={{ fontSize: 10, color: T.slate500, marginTop: 4, lineHeight: 1.4 }}>{edu.notes}</div>}
              </Tile>
              <Tile heading="Prior similar role" color={relevColor}>
                {relevLabel
                  ? (
                    <div>
                      <div><strong style={{ color: T.slate900 }}>{relevLabel}</strong>{insMonths ? ` · ${insMonths} mo insurance` : ""}</div>
                      {signals.length > 0 && (
                        <ul style={{ margin: "4px 0 0 0", paddingLeft: 16, fontSize: 11, lineHeight: 1.4 }}>
                          {signals.slice(0, 3).map((s, i) => <li key={i}>{s}</li>)}
                          {signals.length > 3 && <li style={{ color: T.slate500, fontStyle: "italic" }}>+{signals.length - 3} more</li>}
                        </ul>
                      )}
                    </div>
                  )
                  : <span style={{ color: T.slate500, fontStyle: "italic" }}>None noted</span>}
                {prior.notes && <div style={{ fontSize: 10, color: T.slate500, marginTop: 4, lineHeight: 1.4 }}>{prior.notes}</div>}
              </Tile>
            </div>
          </div>
        );
      })()}

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

// Assessment layer expansion body — the LSS + traits view on the left;
// role-fit selector + competencies for the currently-selected role on the
// right. Moved here from the standalone top-of-page Assessment section per
// Peter directive 2026-07-17.
// Newtworks v2 assessment layer — trait/GMA/SJT results, plus Role Fit +
// Competencies from the Newtworks competency layer (12 competencies x 7
// roles, confirmed 2026-08-02, live 2026-08-03). bestFit comes from
// assessment_best_fit_role (uuid RPC, already gated); v2RoleFits comes from
// newtworks_all_role_fits (uuid RPC) and carries the full per-role competency
// detail (tier/floor/adjusted) the selector below drills into. v1/CTS
// candidates keep the legacy renderAssessmentLayer below — this function only
// renders when detail.assessment_source === "v2".
function renderAssessmentLayerV2({ detail, v2Facets, bestFit, v2RoleFits, selectedRole, setSelectedRole, T, gmaOpen, setGmaOpen }) {
  const exitGate = detail?.assessment_exit_gate;
  const exitDetail = detail?.assessment_exit_detail || {};
  const exitedAt = detail?.assessment_exited_at;

  const reliability = detail?.reliability; // 'high' | 'medium' | 'low'
  const reliabilityDetail = detail?.reliability_detail || {};
  const reliabilityMethods = Object.keys(RELIABILITY_METHOD_LABELS);

  const imScore = detail?.impression_management;
  const imBand = detail?.impression_management_band;
  const imDetail = detail?.impression_management_detail || {};

  const gmaTotal = detail?.gma_total_accuracy; // raw correct count, max 16
  const gmaPct = gmaTotal != null ? Math.round((Number(gmaTotal) / 16) * 100) : null;

  const sjtScore = detail?.sjt_score; // 0-100
  const sjtTopics = detail?.sjt_topic_detail || {};

  const facetRows = Array.isArray(v2Facets) ? v2Facets : null;
  const facetByTrait = {};
  if (facetRows) {
    for (const r of facetRows) facetByTrait[r.hypothesized_trait] = r;
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      {exitGate && (
        <div style={{
          padding: "10px 12px", background: T.redLt, borderRadius: 6,
          borderLeft: `4px solid ${T.red}`, boxSizing: "border-box",
        }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.red }}>
            Stint 1 exit gate fired — {exitGate}
          </div>
          {exitDetail?.reason && (
            <div style={{ fontSize: 11, color: T.slate700, marginTop: 3 }}>{exitDetail.reason}</div>
          )}
          <div style={{ fontSize: 10, color: T.slate500, marginTop: 3 }}>
            Assessment stopped early on this stint. Candidate was shown a neutral completion screen and told nothing.
            {exitedAt ? ` · ${new Date(exitedAt).toLocaleString()}` : ""}
          </div>
        </div>
      )}

      {/* Reliability + Faking-good — validity indices, not personality traits */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 8 }}>
        <div>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
            Reliability
          </div>
          <AssessRow
            label="Data quality"
            value={reliability ? reliability.charAt(0).toUpperCase() + reliability.slice(1) : null}
            band={V2_RELIABILITY_BAND(reliability)}
            subline={reliabilityDetail?.fired_count != null ? `${reliabilityDetail.fired_count} of 6 checks fired` : null}
          />
          {reliability && (
            <div style={{ display: "flex", flexDirection: "column", gap: 2, marginTop: 4, padding: "0 4px" }}>
              {reliabilityMethods.map((k) => {
                const m = reliabilityDetail[k];
                const fired = m?.fired;
                return (
                  <div key={k} style={{ display: "flex", justifyContent: "space-between", fontSize: 10.5 }}>
                    <span style={{ color: T.slate600 }}>{RELIABILITY_METHOD_LABELS[k]}</span>
                    <span style={{ color: fired ? T.red : T.slate400, fontWeight: fired ? 700 : 400 }}>
                      {fired == null ? "—" : fired ? "flagged" : "ok"}
                    </span>
                  </div>
                );
              })}
            </div>
          )}
        </div>
        <div>
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
            Faking-good (Impression Management)
          </div>
          <AssessRow
            label="Score"
            value={imScore}
            extra={imBand ? imBand.replace(/_/g, " ") : null}
            band={IM_BAND_COLOR(imBand)}
          />
          {imDetail?.interpretation && (
            <div style={{ fontSize: 10.5, color: T.slate600, marginTop: 4, padding: "0 4px", lineHeight: 1.4 }}>
              {imDetail.interpretation}
            </div>
          )}
        </div>
      </div>

      <div style={{ height: 1, background: T.slate200 }} />

      {/* GMA — total only is a decision input; subtests are diagnostics */}
      <div>
        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
          GMA (General Mental Ability)
        </div>
        <AssessRow
          label="Total"
          value={gmaTotal}
          extra={gmaTotal != null ? `/16 (${gmaPct}%)` : null}
          max={16}
        />
        <button
          type="button"
          onClick={() => setGmaOpen((o) => !o)}
          style={{
            marginTop: 4, background: "none", border: "none", padding: "2px 4px",
            fontSize: 10.5, color: T.blue, cursor: "pointer", fontFamily: "inherit",
          }}
        >
          {gmaOpen ? "Hide subtest diagnostics" : "Show subtest diagnostics"}
        </button>
        {gmaOpen && (
          <div style={{ display: "flex", flexDirection: "column", gap: 4, marginTop: 4 }}>
            <AssessRow label="Pattern" value={detail?.gma_pattern_accuracy} extra="/4" max={4}
              subline={detail?.gma_pattern_speed_seconds != null ? `${detail.gma_pattern_speed_seconds}s/item` : null} />
            <AssessRow label="Deductive" value={detail?.gma_deductive_accuracy} extra="/4" max={4}
              subline={detail?.gma_deductive_speed_seconds != null ? `${detail.gma_deductive_speed_seconds}s/item` : null} />
            <AssessRow label="Numerical" value={detail?.gma_numerical_accuracy} extra="/4" max={4}
              subline={detail?.gma_numerical_speed_seconds != null ? `${detail.gma_numerical_speed_seconds}s/item` : null} />
            <AssessRow label="Verbal" value={detail?.gma_verbal_accuracy} extra="/4" max={4}
              subline={detail?.gma_verbal_speed_seconds != null ? `${detail.gma_verbal_speed_seconds}s/item` : null} />
          </div>
        )}
      </div>

      <div style={{ height: 1, background: T.slate200 }} />

      {/* SJT — total + 5 topic rows */}
      <div>
        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
          SJT (Situational Judgement Test)
        </div>
        <AssessRow label="Total" value={sjtScore} extra={sjtScore != null ? "%" : null} />
        <div style={{ display: "flex", flexDirection: "column", gap: 4, marginTop: 4 }}>
          {Object.entries(SJT_TOPIC_LABELS).map(([k, label]) => {
            const t = sjtTopics[k];
            const pct = t && t.n > 0 ? Math.round((100 * t.correct) / t.n) : null;
            return (
              <AssessRow
                key={k}
                label={label}
                value={pct}
                extra={t ? `${t.correct}/${t.n}` : null}
              />
            );
          })}
        </div>
      </div>

      <div style={{ height: 1, background: T.slate200 }} />

      {/* 21 personality facets */}
      <div>
        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
          Personality Facets
        </div>
        {facetRows == null ? (
          <div style={{ fontSize: 11, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
            Loading facet detail…
          </div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 6 }}>
            {Object.entries(V2_FACET_LABELS).map(([trait, label]) => {
              const row = facetByTrait[trait];
              const nItems = row?.n_items_scored;
              const insufficient = nItems != null && nItems < 5;
              return (
                <AssessRow
                  key={trait}
                  label={label}
                  value={insufficient ? "insufficient data" : row?.facet_score}
                  extra={row && !insufficient ? `n=${nItems}` : null}
                  band={insufficient ? "none" : null}
                />
              );
            })}
          </div>
        )}
      </div>

      <div style={{ height: 1, background: T.slate200 }} />

      {/* Role Fit + Competencies — Newtworks competency layer (12 competencies
          x 7 roles, confirmed 2026-08-02, live 2026-08-03). Role buttons sorted
          by fit_score descending, best-fit highlighted (mirrors the v1/CTS
          selector in the legacy renderAssessmentLayer below). Selecting a role
          swaps which role's 12 competencies + gates display underneath. */}
      <div>
        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
          Role Fit
        </div>
        {(() => {
          const bf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
          if (!bf || bf.best_role == null) {
            return (
              <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
                Best-fit role computes from traits — awaiting assessment.
              </div>
            );
          }
          const roleRows = [
            { key: "sales_outbound",       fitScore: bf.sales_outbound_fit_score },
            { key: "sales_inbound",        fitScore: bf.sales_inbound_fit_score },
            { key: "sales_in_book",        fitScore: bf.sales_in_book_fit_score },
            { key: "retention_reception",  fitScore: bf.retention_reception_fit_score },
            { key: "retention_escalation", fitScore: bf.retention_escalation_fit_score },
            { key: "retention_support",    fitScore: bf.retention_support_fit_score },
            { key: "aspirant",             fitScore: bf.aspirant_fit_score },
          ].sort((a, b) => (Number(b.fitScore) || -Infinity) - (Number(a.fitScore) || -Infinity));
          const bestKey = bf.best_role;
          const currentSelected = selectedRole || bestKey || roleRows[0]?.key;
          return (
            <>
              {bf.best_hard_decline && (
                <div style={{ padding: "6px 10px", background: T.redLt, borderRadius: 6, marginBottom: 4, fontSize: 11, fontWeight: 700, color: T.red }}>
                  Hard decline — integrity gate fired on best-fit role
                </div>
              )}
              {!bf.best_hard_decline && bf.best_verdict_cap === "consider" && (
                <div style={{ padding: "6px 10px", background: T.amberLt, borderRadius: 6, marginBottom: 4, fontSize: 11, fontWeight: 700, color: T.amber }}>
                  Verdict capped at "consider" — a critical competency or reasoning floor missed on best-fit role
                </div>
              )}
              {bf.best_churn_risk && (
                <div style={{ padding: "6px 10px", background: T.slate100, borderRadius: 6, marginBottom: 4, fontSize: 11, fontWeight: 600, color: T.slate700 }}>
                  Churn-risk flag on best-fit role — reasoning ceiling exceeded, performance unaffected
                </div>
              )}
              {roleRows.map((r) => {
                const isSelected = r.key === currentSelected;
                const isBest = r.key === bestKey;
                const colors = isBest ? bandColor("green") : null;
                const baseBg = colors ? colors.bg : (T.slate200 || "#e2e8f0");
                const baseStripe = colors ? colors.fg : T.slate200;
                const valueColor = isBest ? colors.fg : T.slate900;
                const numFit = Number(r.fitScore);
                const restBg = T.slate50 || "#f8fafc";
                const gaugeBg = Number.isFinite(numFit)
                  ? `linear-gradient(to right, ${baseBg} 0%, ${baseBg} ${Math.max(0, Math.min(100, numFit))}%, ${restBg} ${Math.max(0, Math.min(100, numFit))}%, ${restBg} 100%)`
                  : (colors ? baseBg : restBg);
                return (
                  <button
                    key={r.key}
                    type="button"
                    onClick={() => setSelectedRole(r.key)}
                    style={{
                      display: "flex", alignItems: "center", justifyContent: "space-between",
                      padding: "6px 10px", background: gaugeBg, borderRadius: 6,
                      borderTop: "none", borderRight: "none", borderBottom: "none",
                      borderLeft: `3px solid ${isSelected ? T.slate700 : baseStripe}`,
                      outline: isSelected ? `1px solid ${T.slate400}` : "none",
                      boxSizing: "border-box", gap: 8, cursor: "pointer",
                      fontFamily: "inherit", textAlign: "left", width: "100%",
                      marginBottom: 2,
                    }}
                    title={isSelected ? "Selected — competencies below" : "Click to show this role's competencies"}
                  >
                    <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>
                      {ROLE_LABELS[r.key] || r.key} Fit
                    </span>
                    <span style={{ fontSize: 14, fontWeight: 700, color: valueColor, whiteSpace: "nowrap" }}>
                      {r.fitScore ?? "—"}
                    </span>
                  </button>
                );
              })}
            </>
          );
        })()}

        <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />

        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
          Competencies
        </div>

        {(() => {
          const bf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
          const bestKey = bf?.best_role;
          const currentSelected = selectedRole || bestKey || "sales_outbound";
          const roleDetail = v2RoleFits ? v2RoleFits[currentSelected] : null;
          const comps = roleDetail?.competencies || {};
          const entries = Object.entries(comps);
          const formatCompLabel = (k) =>
            k.replace(/_/g, " ").replace(/\w/g, (c) => c.toUpperCase());
          const TIER_LABEL = { critical: "critical · hard floor", important: "important", supporting: "supporting" };
          if (entries.length === 0) {
            return (
              <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
                {v2RoleFits ? `No competency data for ${ROLE_LABELS[currentSelected] || currentSelected}.` : "Competencies computed at runtime from traits."}
              </div>
            );
          }
          return (
            <>
              <div style={{ fontSize: 10, color: T.slate500, fontStyle: "italic", marginBottom: 2, padding: "0 10px" }}>
                Showing {ROLE_LABELS[currentSelected] || currentSelected} — click any role fit above to swap.
              </div>
              {roleDetail?.gates_fired?.length > 0 && (
                <div style={{ fontSize: 10, color: T.red, fontWeight: 600, marginBottom: 2, padding: "0 10px" }}>
                  Gates fired: {roleDetail.gates_fired.join(", ")}
                </div>
              )}
              {/* Integrity gate shadow result — SHADOW MODE, not yet active
                  (Peter directive 2026-08-03). The gate never declines a
                  candidate; this only shows what the conjunctive 4-condition
                  test WOULD have done, for review once 25-30 real candidates
                  have been scored. Role-agnostic — same value regardless of
                  which role is selected above. */}
              {roleDetail?.gate_detail?.integrity_decline && (() => {
                const ig = roleDetail.gate_detail.integrity_decline;
                const cond = ig.conditions || {};
                const metCount = Object.values(cond).filter((c) => c?.met).length;
                return (
                  <div style={{
                    padding: "6px 10px", background: T.slate50, borderRadius: 6,
                    border: `1px dashed ${T.slate300 || T.slate200}`, marginBottom: 4,
                  }}>
                    <div style={{ fontSize: 9.5, textTransform: "uppercase", letterSpacing: 0.3, fontWeight: 700, color: T.slate500 }}>
                      Integrity gate — shadow mode, not yet active
                    </div>
                    <div style={{ fontSize: 11, color: T.slate700, marginTop: 2 }}>
                      Would {ig.shadow_would_decline ? "flag for decline" : "pass"} — {metCount}/4 conditions met
                      {cond.raw_composite_low?.value != null && ` · raw self-report ${cond.raw_composite_low.value}`}
                      {cond.sjt_honesty_low?.value != null && ` · SJT honesty ${cond.sjt_honesty_low.value}%`}
                    </div>
                  </div>
                );
              })()}
              {entries.map(([k, c]) => {
                const v = c?.adjusted;
                const band = competencyBand(v);
                const floor = c?.floor;
                const tier = c?.tier;
                const breached = tier === "critical" && floor != null && v != null && Number(v) < Number(floor);
                const sublineBits = [];
                if (floor != null) sublineBits.push(breached ? `Below critical floor (${floor})` : `Floor ${floor}`);
                if (c?.missing_inputs?.length > 0) sublineBits.push(`Missing: ${c.missing_inputs.join(", ")}`);
                return (
                  <AssessRow
                    key={k}
                    label={formatCompLabel(k)}
                    value={v}
                    band={v == null ? "none" : band}
                    extra={tier ? TIER_LABEL[tier] || tier : null}
                    subline={sublineBits.length > 0 ? sublineBits.join(" · ") : null}
                  />
                );
              })}
            </>
          );
        })()}
      </div>
    </div>
  );
}

function renderAssessmentLayer({ detail, competencies, bestFit, selectedRole, setSelectedRole, T, v1Extras, v1InvitedAt, intelligence, roleIdealRange, v2Facets, v2RoleFits, gmaOpen, setGmaOpen }) {
  if (detail?.assessment_source === "v2") {
    return renderAssessmentLayerV2({ detail, v2Facets, bestFit, v2RoleFits, selectedRole, setSelectedRole, T, gmaOpen, setGmaOpen });
  }
  return (
    <div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 16 }}>

        {/* LEFT COLUMN — LSS + traits */}
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <IntelligenceHeadline
            composite={intelligence?.intelligence_composite}
            floor={roleIdealRange?.intelligence_ideal_min}
            ceiling={roleIdealRange?.intelligence_ideal_max}
            roleLabel={ROLE_LABELS[roleIdealRange?.role_category] || roleIdealRange?.role_category}
            T={T}
          />
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 2 }}>
            Traits & LSS
          </div>
          {detail?.assessment_timing?.invited_at && detail?.assessment_timing?.cts?.started_at && (() => {
            const invited = new Date(detail.assessment_timing.invited_at);
            const started = new Date(detail.assessment_timing.cts.started_at);
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
          {(() => {
            const isV1 = detail?.assessment_source === "v1";
            const maxMath = isV1 ? 6 : 12;
            const maxVerbal = isV1 ? 6 : 10;
            const maxPs = isV1 ? 5 : 9;
            const maxTotal = isV1 ? 17 : 35;
            return (
              <>
                <AssessRow
                  label="LSS Math"
                  value={detail?.lss_math_accuracy}
                  max={maxMath}
                  extra={detail?.lss_math_speed_seconds != null ? `${detail.lss_math_speed_seconds}s/item` : null}
                />
                <AssessRow
                  label="LSS Verbal"
                  value={detail?.lss_verbal_accuracy}
                  max={maxVerbal}
                  extra={detail?.lss_verbal_speed_seconds != null ? `${detail.lss_verbal_speed_seconds}s/item` : null}
                />
                <AssessRow
                  label="LSS Problem Solving"
                  value={detail?.lss_problem_solving_accuracy}
                  max={maxPs}
                  extra={detail?.lss_problem_solving_speed_seconds != null ? `${detail.lss_problem_solving_speed_seconds}s/item` : null}
                />
                <AssessRow
                  label="LSS Total"
                  value={detail?.lss_total_accuracy}
                  max={maxTotal}
                  extra={detail?.lss_total_accuracy != null ? `/${maxTotal}` : null}
                  band="none"
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
                  noBar
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
              </>
            );
          })()}
          <AssessRow label="Reliability" value={detail?.reliability} band={RELIABILITY_BAND(detail?.reliability)} />
          <AssessRow label="Distortion" value={detail?.response_distortion} band={DISTORTION_BAND(detail?.response_distortion)} />

          <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />

          {Object.entries(TRAIT_LABELS).map(([trait, label]) => {
            const value = detail?.[trait];
            // No band: primary CTS traits render neutral. Role-dependent
            // ideals are surfaced via Role Fit + Competencies (right column).
            return <AssessRow key={trait} label={label} value={value} />;
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
            const roleRows = [
              { key: "sales_outbound",       fitScore: bf.sales_outbound_fit_score },
              { key: "sales_inbound",        fitScore: bf.sales_inbound_fit_score },
              { key: "sales_in_book",        fitScore: bf.sales_in_book_fit_score },
              { key: "retention_reception",  fitScore: bf.retention_reception_fit_score },
              { key: "retention_escalation", fitScore: bf.retention_escalation_fit_score },
              { key: "retention_support",    fitScore: bf.retention_support_fit_score },
              { key: "aspirant",             fitScore: bf.aspirant_fit_score },
            ].sort((a, b) => (Number(b.fitScore) || -Infinity) - (Number(a.fitScore) || -Infinity));
            const bestKey = bf.best_role;
            const currentSelected = selectedRole || bestKey || roleRows[0]?.key;
            return (
              <>
                {roleRows.map((r) => {
                  const isSelected = r.key === currentSelected;
                  const isBest = r.key === bestKey;
                  const colors = isBest ? bandColor("green") : null;
                  const baseBg = colors ? colors.bg : (T.slate200 || "#e2e8f0");
                  const baseStripe = colors ? colors.fg : T.slate200;
                  const valueColor = isBest ? colors.fg : T.slate900;
                  // Gauge fill: OS/100 of row width. Best-fit fills in greenLt, others fill in
                  // muted slate200 so the gauge is visible without implying "best." Rest is slate50.
                  const numFit = Number(r.fitScore);
                  const restBg = T.slate50 || "#f8fafc";
                  const gaugeBg = Number.isFinite(numFit)
                    ? `linear-gradient(to right, ${baseBg} 0%, ${baseBg} ${Math.max(0, Math.min(100, numFit))}%, ${restBg} ${Math.max(0, Math.min(100, numFit))}%, ${restBg} 100%)`
                    : (colors ? baseBg : restBg);
                  return (
                    <button
                      key={r.key}
                      type="button"
                      onClick={() => setSelectedRole(r.key)}
                      style={{
                        display: "flex", alignItems: "center", justifyContent: "space-between",
                        padding: "6px 10px", background: gaugeBg, borderRadius: 6,
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
                        {r.fitScore ?? "—"}
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
            const roleC = (competencies && competencies[currentSelected]) || {};
            const roleDeltas = (competencies && competencies._lss_deltas && competencies._lss_deltas[currentSelected]) || {};
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
                  const d = roleDeltas[k];
                  const lssDelta = typeof d === "number" ? d : (d != null ? Number(d) : null);
                  return <AssessRow key={k} label={formatCompLabel(k)} value={v} band={band} lssDelta={lssDelta} />;
                })}
              </>
            );
          })()}
        </div>
      </div>

      {/* Newtworks v1 diagnostics — timing, reliability by trait, distortion
          signals. Panel hides silently when the candidate has no v1 scoring
          data (n_items_scored == 0 or v1Extras missing). Legacy CTS-source
          candidates never trigger this section. */}
      {v1Extras && (v1Extras.n_items_scored || 0) > 0 && (() => {
        const started = detail?.assessment_started_at ? new Date(detail.assessment_started_at) : null;
        const completed = detail?.assessment_completed_at ? new Date(detail.assessment_completed_at) : null;
        const invited = v1InvitedAt ? new Date(v1InvitedAt) : null;

        const fmtDuration = (ms) => {
          if (!Number.isFinite(ms) || ms < 0) return null;
          const totalMin = Math.floor(ms / 60000);
          const totalHrs = Math.floor(ms / 3600000);
          const days = Math.floor(ms / 86400000);
          const leftoverHrs = totalHrs - days * 24;
          if (totalMin < 60) return `${totalMin}m`;
          if (totalHrs < 24) return `${totalHrs}h ${totalMin - totalHrs * 60}m`;
          return leftoverHrs === 0 ? `${days}d` : `${days}d ${leftoverHrs}h`;
        };
        const inviteLag = invited && started ? fmtDuration(started - invited) : null;
        const takingDur = started && completed ? fmtDuration(completed - started) : null;

        const reliabilityMap = v1Extras.reliability_by_trait || {};
        const traitOrder = [
          ["assertiveness", "Assertiveness"],
          ["independent_spirit", "Independent Spirit"],
          ["compassion", "Compassion"],
          ["belief_in_others", "Belief in Others"],
          ["optimism", "Optimism"],
          ["analytical", "Analytical"],
          ["deadline_motivation", "Deadline Motivation"],
          ["self_promotion", "Self Promotion"],
          ["recognition_drive", "Recognition Drive"],
        ];

        const flagBadge = (fires, label) => (
          <span style={{
            display: "inline-block",
            padding: "2px 8px",
            fontSize: 10,
            fontWeight: 700,
            borderRadius: 999,
            background: fires ? "#fee2e2" : "#dcfce7",
            color: fires ? "#991b1b" : "#166534",
          }}>{fires ? label : `${label} OK`}</span>
        );

        const strLine = v1Extras.distortion_straight_line_flag;
        const acq = v1Extras.distortion_acquiescence_flag;
        const strThrough = v1Extras.distortion_straight_through_flag;
        const nTimed = v1Extras.distortion_n_timed_items ?? 0;
        const meanMs = v1Extras.distortion_mean_response_ms;
        const minMs = v1Extras.distortion_min_response_ms;

        return (
          <div style={{ marginTop: 16 }}>
            <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 6 }}>
              V1 Diagnostics
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 12 }}>

              {/* Timing */}
              <div style={{ padding: "10px 12px", background: T.slate50, borderRadius: 6, borderLeft: `3px solid ${T.slate200}` }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>Timing</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 12 }}>
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: T.slate600 }}>Invite → start</span>
                    <span style={{ fontWeight: 600, color: T.slate900 }}>{inviteLag ?? "—"}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: T.slate600 }}>Start → complete</span>
                    <span style={{ fontWeight: 600, color: T.slate900 }}>{takingDur ?? "—"}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: T.slate600 }}>Mean per item</span>
                    <span style={{ fontWeight: 600, color: T.slate900 }}>{meanMs != null ? `${(Number(meanMs) / 1000).toFixed(1)}s` : "—"}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: T.slate600 }}>Fastest item</span>
                    <span style={{ fontWeight: 600, color: T.slate900 }}>{minMs != null ? `${(Number(minMs) / 1000).toFixed(1)}s` : "—"}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: T.slate600 }}>Timed items</span>
                    <span style={{ fontWeight: 600, color: T.slate900 }}>{nTimed}</span>
                  </div>
                </div>
              </div>

              {/* Distortion signals */}
              <div style={{ padding: "10px 12px", background: T.slate50, borderRadius: 6, borderLeft: `3px solid ${T.slate200}` }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>Response quality</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 12 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <div style={{ display: "flex", flexDirection: "column" }}>
                      <span style={{ color: T.slate900, fontWeight: 600 }}>Straight-line</span>
                      <span style={{ fontSize: 10, color: T.slate500 }}>max run {v1Extras.distortion_max_consecutive_run ?? "—"} · sd {v1Extras.distortion_overall_sd ?? "—"}</span>
                    </div>
                    {flagBadge(strLine, "Flag")}
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <div style={{ display: "flex", flexDirection: "column" }}>
                      <span style={{ color: T.slate900, fontWeight: 600 }}>Acquiescence</span>
                      <span style={{ fontSize: 10, color: T.slate500 }}>mean {v1Extras.distortion_acquiescence_mean ?? "—"} · bias {v1Extras.distortion_acquiescence_bias ?? "—"}</span>
                    </div>
                    {flagBadge(acq, "Flag")}
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <div style={{ display: "flex", flexDirection: "column" }}>
                      <span style={{ color: T.slate900, fontWeight: 600 }}>Straight-through</span>
                      <span style={{ fontSize: 10, color: T.slate500 }}>{nTimed >= 5 && meanMs != null ? `mean ${(Number(meanMs) / 1000).toFixed(1)}s · <2s = flag` : "n < 5 timed items"}</span>
                    </div>
                    {nTimed >= 5 ? flagBadge(strThrough, "Flag") : (
                      <span style={{ fontSize: 10, color: T.slate400, fontStyle: "italic" }}>—</span>
                    )}
                  </div>
                </div>
              </div>

              {/* Reliability by trait */}
              <div style={{ padding: "10px 12px", background: T.slate50, borderRadius: 6, borderLeft: `3px solid ${T.slate200}`, gridColumn: "span 1" }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>Reliability by trait</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 3, fontSize: 11 }}>
                  {traitOrder.map(([k, label]) => {
                    const r = reliabilityMap[k];
                    if (!r) {
                      return (
                        <div key={k} style={{ display: "flex", justifyContent: "space-between", color: T.slate500 }}>
                          <span>{label}</span>
                          <span style={{ fontStyle: "italic" }}>—</span>
                        </div>
                      );
                    }
                    const nItems = r.n_items ?? 0;
                    const sd = r.within_trait_sd;
                    const rd = r.retest_divergence;
                    const nPairs = r.n_retest_pairs ?? 0;
                    return (
                      <div key={k} style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
                        <span style={{ color: T.slate700 }}>{label}</span>
                        <span style={{ color: T.slate900, fontVariantNumeric: "tabular-nums" }}>
                          <span title="within-trait SD">sd {sd ?? "—"}</span>
                          <span style={{ color: T.slate400, margin: "0 4px" }}>·</span>
                          <span title="items scored">n {nItems}</span>
                          <span style={{ color: T.slate400, margin: "0 4px" }}>·</span>
                          <span title="retest divergence" style={{ color: nPairs > 0 && rd != null ? (Number(rd) > 1.5 ? "#991b1b" : T.slate900) : T.slate400 }}>
                            {nPairs > 0 && rd != null ? `Δ ${rd}` : "no retest"}
                          </span>
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>

            </div>
          </div>
        );
      })()}
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

      {/* Score breakdown — 3-column grid (Capability | Character | Commitment), each column showing
          construct name + weight + list of contributing answers with per-construct verdict pills.
          Construct score number + composite footer intentionally omitted — Results matrix above
          already surfaces both. Grid auto-wraps to fewer columns on narrow viewports. */}
      {(() => {
        const answers = detail?.interview_answers || {};
        const constructOrder = [
          { key: "capability", label: "Capability", weight: "14.3%", score: detail?.iv_capability },
          { key: "character",  label: "Character",  weight: "42.9%", score: detail?.iv_character },
          { key: "commitment", label: "Commitment", weight: "42.9%", score: detail?.iv_commitment },
        ];
        const rows = constructOrder.map((c) => {
          const contribs = Object.entries(answers)
            .filter(([, v]) => v && v.scores && v.scores[c.key])
            .map(([k, v]) => ({
              key: k,
              score: v.scores[c.key].score,
              verdict: v.scores[c.key].verdict,
            }));
          return { ...c, contribs };
        });
        const hasAny = rows.some((r) => r.contribs.length > 0);
        if (!hasAny) {
          return (
            <div style={{ marginBottom: 16, padding: 10, background: T.slate50, border: `1px dashed ${T.slate300}`, borderRadius: 8, fontSize: 11, color: T.slate500, fontStyle: "italic" }}>
              No interview answers scored yet. Breakdown appears here as answers are graded.
            </div>
          );
        }
        return (
          <div style={{ marginBottom: 16, padding: 12, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8 }}>
            {/* Header */}
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
              <span style={{ fontSize: 11, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4 }}>
                Score breakdown
              </span>
              {detail?.interview_analysis?.analyzed_at && (
                <span style={{ fontSize: 10, color: T.slate400, marginLeft: "auto", fontStyle: "italic" }}>
                  Graded {new Date(detail.interview_analysis.analyzed_at).toLocaleDateString()}
                </span>
              )}
            </div>
            {/* 3 columns — auto-fit wraps to stacked rows on narrow viewports */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8, marginBottom: 12 }}>
              {rows.map((r) => (
                <div key={r.key} style={{ padding: 10, background: T.white, borderRadius: 8, border: `1px solid ${T.slate200}` }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: T.slate600, textTransform: "uppercase", letterSpacing: 0.5 }}>
                    {r.label}
                  </div>
                  <div style={{ fontSize: 9, fontWeight: 500, color: T.slate400, textTransform: "uppercase", letterSpacing: 0.4, marginTop: 1, marginBottom: 8 }}>
                    weight {r.weight}
                  </div>
                  <div style={{ borderTop: `1px solid ${T.slate200}`, paddingTop: 6 }}>
                    {r.contribs.length === 0 ? (
                      <div style={{ fontSize: 10, color: T.slate500, fontStyle: "italic" }}>No answers scored on this construct.</div>
                    ) : (
                      <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
                        {r.contribs.map((a) => {
                          const colors = verdictPillColors(a.verdict) || { bg: T.slate100, fg: T.slate600 };
                          const scoreDisplay = (a.verdict === "no_answer" || a.score == null) ? "—" : String(a.score * 10);
                          return (
                            <div key={a.key} style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 10, color: T.slate700 }}>
                              <span style={{ fontFamily: "ui-monospace, SFMono-Regular, monospace", fontSize: 9, color: T.slate500, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }} title={a.key}>{a.key}</span>
                              <span style={{ padding: "1px 6px", fontSize: 9, fontWeight: 700, color: colors.fg, background: colors.bg, borderRadius: 8 }}>
                                {scoreDisplay}
                              </span>
                            </div>
                          );
                        })}
                      </div>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        );
      })()}

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
              <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, flex: 1 }}>
                  <strong>{w.n}.</strong> {w.q}
                </div>
                {renderScorePill(detail?.interview_answers?.[w.key], w.key)}
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
                      {renderScorePill(detail?.interview_answers?.[src], src)}
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
              <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
                <div style={{ fontSize: 11, color: T.slate600, flex: 1, fontStyle: "italic" }}>
                  Capture the questions the candidate asks — content and quality of their questions is a signal.
                </div>
                {renderScorePill(detail?.interview_answers?.[src], src)}
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

// ─── Main component ────────────────────────────────────────────────

export default function CandidateDetail({ candidate, onBack, onUpdate }) {
  const { isPhone } = useViewport();
  const verdictThresh = useVerdictThresholds();
  const [detail, setDetail] = useState(candidate || {});
  const [savingSection, setSavingSection] = useState(null);
  const [bestFit, setBestFit] = useState(null);
  const [probesGenerating, setProbesGenerating] = useState(false);
  const [probesError, setProbesError] = useState(null);
  const [composite, setComposite] = useState(null);
  const [frameworkRules, setFrameworkRules] = useState([]);
  const [competencies, setCompetencies] = useState(null);
  // Intelligence composite (0-100, from hiregauge_lss_delta_v2) + the currently
  // selected role's ideal range (floor/ceiling from hiregauge_role_ideal_ranges).
  // Both feed the IntelligenceHeadline at the top of the Assessment layer. See
  // Step 6, 2026-08-01.
  const [intelligence, setIntelligence] = useState(null);
  const [roleIdealRange, setRoleIdealRange] = useState(null);
  // Newtworks v1 assessment extras: reliability_by_trait + distortion signals +
  // timing come from compute_newtworks_v1_traits_as_row RPC (not stored on the
  // v_hiring_candidates view). Populated even for legacy CTS-source candidates
  // if they happen to have v1 responses; otherwise n_items_scored is 0 and the
  // panel hides. See op-rule "HireGauge trait interpretation" for the
  // trait-label vs psychometric-construct mismatch caveats.
  const [v1Extras, setV1Extras] = useState(null);
  const [v1InvitedAt, setV1InvitedAt] = useState(null);
  // Newtworks v2 facet detail — {hypothesized_trait, facet_score, n_items_scored}
  // per facet, fetched fresh via RPC (item counts aren't stored on the flat
  // hiring_candidates columns). Only fetched for v2 candidates. Used to grey out
  // any facet with n_items_scored < 5 per op-rule "Hardcoded functions: never
  // prefer simpler over more accurate" / P9 in the trait scoring build spec.
  const [v2Facets, setV2Facets] = useState(null);
  // Newtworks v2 competency layer — full per-role detail (12 competencies with
  // tier/floor/adjusted + gates_fired/verdict_cap/hard_decline/churn_risk),
  // keyed by role_category. Only fetched for v2 candidates; replaces the old
  // assessment_all_competencies orchestrator for the v2 path (Step 8, 2026-08-03).
  const [v2RoleFits, setV2RoleFits] = useState(null);
  // v2 GMA subtest diagnostics disclosure — ephemeral UI toggle, not URL-persisted
  // (per frontend coding rule 24: disclosure state stays useState, not a tab).
  const [gmaOpen, setGmaOpen] = useState(false);
  // Which role fit is selected. Local UI state only — session-scoped, defaults to
  // bestFit on load. Framework scoring always uses assessment_best_fit_role's best_role;
  // the selector only controls which competency detail displays.
  const [selectedRole, setSelectedRoleLocal] = useState(null);
  const setSelectedRole = (roleKey) => {
    setSelectedRoleLocal(roleKey || null);
  };
  // Which Results-matrix layer row is expanded (null = none). Only one
  // layer expanded at a time. Click chevron in the layer label cell.
  const [expandedLayer, setExpandedLayer] = useState(null);
  // Three-construct verdict (Capability/Character/Commitment) — per-layer verdicts +
  // framework prediction + retrospective observation + calibration status.
  // Fetched via verdict_overall RPC.
  const [threeConstruct, setThreeConstruct] = useState(null);
  // Interview answer capture — local state; Save button batch-writes to
  // hiring_candidates.interview_answers jsonb (keyed by probe.source →
  // { answer, saved_at }). See op-rule "Interview probe analysis protocol".
  const [savingAnswers, setSavingAnswers] = useState(false);
  // v1 assessment copy-link button state. "idle"|"copying"|"copied"|"error".
  const [copyLinkStatus, setCopyLinkStatus] = useState("idle");

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

  // v2 facet detail (item counts) — only for v2 candidates.
  useEffect(() => {
    if (!detail?.id || !supabase || detail?.assessment_source !== "v2") return;
    let cancelled = false;
    supabase
      .rpc("compute_newtworks_v2_facets_as_row", { p_candidate_id: detail.id, p_stint: null, p_sitting: 1 })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        setV2Facets(Array.isArray(data) ? data : []);
      });
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // v2 role fit + competency detail — only for v2 candidates. Replaces
  // assessment_all_competencies for the v2 path (Step 8, 2026-08-03).
  useEffect(() => {
    if (!detail?.id || !supabase || detail?.assessment_source !== "v2") return;
    let cancelled = false;
    supabase
      .rpc("newtworks_all_role_fits", { p_assessment_id: detail.id })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        setV2RoleFits(data || {});
      });
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // Best-fit role via RPC (graceful fallback if function missing)
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    // v2 candidates: assessment_best_fit_role was rewired onto the v2
    // architecture (*Ass Comp Build 2) and stays live for both paths. The
    // other three legacy RPCs below (assessment_all_competencies,
    // hiregauge_composite_recommendation, hiregauge_evaluate_candidate) read
    // the old rules-narrative engine and retired trait columns — gated to
    // v1/CTS only so they never fire against a v2 candidate.
    const isV2 = detail?.assessment_source === "v2";
    supabase.rpc("assessment_best_fit_role", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!error) setBestFit(data); })
      .catch(() => {});
    if (!isV2) {
      // Competencies for all four role fits (single RPC returning JSONB keyed by role)
      supabase.rpc("assessment_all_competencies", { p_assessment_id: detail.id })
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
    }
    // Intelligence composite for the headline signal — thin wrapper around
    // hiregauge_lss_delta_v2 so the frontend keeps the p_assessment_id calling
    // convention used by every other RPC on this page.
    supabase.rpc("assessment_intelligence_composite", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!error && data) setIntelligence(data); })
      .catch(() => {});
    // Three-construct verdict: Capability/Character/Commitment per-layer verdicts +
    // pre-hire framework prediction + retrospective observation + calibration.
    supabase.rpc("verdict_overall", { p_candidate_id: detail.id })
      .then(({ data, error }) => {
        if (!error && Array.isArray(data) && data[0]) setThreeConstruct(data[0]);
      })
      .catch(() => {});
    // Newtworks v1 assessment extras (reliability + distortion + timing signals).
    // Merged read (p_stint = NULL) scores stint 1 + stint 2 items together on
    // sitting=1 — same call the finalize path uses to write flat trait cols.
    supabase.rpc("compute_newtworks_v1_traits_as_row", {
      p_candidate_id: detail.id, p_stint: null, p_sitting: 1,
    })
      .then(({ data, error }) => {
        if (!error && Array.isArray(data) && data[0]) setV1Extras(data[0]);
      })
      .catch(() => {});
    // Earliest invitation sent_at drives invite→start lag calculation for v1
    // candidates. Multiple invites (initial + reminders) → take MIN so the lag
    // reflects the earliest outreach, not the last nudge.
    supabase
      .from("assessment_invitations")
      .select("sent_at")
      .eq("candidate_id", detail.id)
      .order("sent_at", { ascending: true })
      .limit(1)
      .maybeSingle()
      .then(({ data, error }) => {
        if (!error && data?.sent_at) setV1InvitedAt(data.sent_at);
      });
  }, [detail?.id, detail?.assessment_source]);

  // Default selectedRole to best-fit role once bestFit resolves. Local UI state only —
  // framework scoring always uses assessment_best_fit_role's best_role regardless of selection;
  // the selector only controls which competency detail displays on this page.
  useEffect(() => {
    if (!detail?.id) return;
    if (selectedRole) return; // already picked this session
    const bfBestRole = Array.isArray(bestFit) && bestFit[0]?.best_role;
    if (!bfBestRole) return;
    setSelectedRoleLocal(bfBestRole);
  }, [detail?.id, selectedRole, bestFit]);

  // Role-specific intelligence ideal range for the IntelligenceHeadline band.
  // Live from hiregauge_role_ideal_ranges — never hardcoded. Refetches whenever
  // the selected role changes (selector click) or best-fit resolves for the
  // first time. role_level is always 'default' — no per-agent variants exist yet.
  useEffect(() => {
    const bfBestRole = Array.isArray(bestFit) && bestFit[0]?.best_role;
    const roleKey = selectedRole || bfBestRole;
    if (!roleKey) { setRoleIdealRange(null); return; }
    let cancelled = false;
    supabase
      .from("hiregauge_role_ideal_ranges")
      .select("role_category, intelligence_ideal_min, intelligence_ideal_max")
      .eq("agency_id", AGENCY_ID)
      .eq("role_category", roleKey)
      .eq("role_level", "default")
      .maybeSingle()
      .then(({ data, error }) => {
        if (!cancelled && !error) setRoleIdealRange(data);
      });
    return () => { cancelled = true; };
  }, [selectedRole, bestFit]);

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
    // Refetch from view so computed aggregates (res_capability/character/commitment/composite) refresh
    const { data } = await supabase
      .from("v_hiring_candidates")
      .select("*")
      .eq("id", detail.id)
      .maybeSingle();
    setSavingSection(null);
    if (data) setDetail(data);
  };

  const saveRC = () => saveFields(["rc_notes"], "rc");
  const saveDecision = () => saveFields(["final_decision", "decision_notes"], "decision");

  // Copy the public /assess/<id>/<token> URL to clipboard. mint_v1_assessment_link
  // returns the path; we prepend window.location.origin. HMAC token is baked in
  // and the edge fn verifies it server-side, so the link is safe to hand out
  // even though it bypasses auth on the frontend.
  const copyAssessmentLink = async () => {
    if (!detail?.id || !supabase) return;
    setCopyLinkStatus("copying");
    try {
      const { data, error } = await supabase.rpc("mint_v1_assessment_link", { p_candidate_id: detail.id });
      if (error || !data) throw error || new Error("no link returned");
      const url = window.location.origin + data;
      await navigator.clipboard.writeText(url);
      setCopyLinkStatus("copied");
      setTimeout(() => setCopyLinkStatus("idle"), 2000);
    } catch (e) {
      console.error("[CandidateDetail] copy link failed:", e);
      setCopyLinkStatus("error");
      setTimeout(() => setCopyLinkStatus("idle"), 2500);
    }
  };

  const saveDecline = async () => {
    if (!detail?.id) return;
    if (!detail.decline_reason) {
      alert("Please select a decline reason before declining.");
      return;
    }
    if (!window.confirm(`Decline ${detail.first_name || ""} ${detail.last_name || ""}? They will be moved to the Declined view.`)) return;
    setSavingSection("decline");
    const updates = {
      status: "declined",
      status_updated_at: new Date().toISOString(),
      decline_reason: detail.decline_reason,
      final_decision: "no_hire",
      decision_at: new Date().toISOString(),
    };
    if (detail.decision_notes) updates.decision_notes = detail.decision_notes;
    const { error } = await supabase
      .from("hiring_candidates")
      .update(updates)
      .eq("id", detail.id);
    if (error) {
      setSavingSection(null);
      alert("Decline failed: " + error.message);
      return;
    }
    const { data } = await supabase
      .from("v_hiring_candidates")
      .select("*")
      .eq("id", detail.id)
      .maybeSingle();
    setSavingSection(null);
    if (data) setDetail(data);
    if (typeof onUpdate === "function") onUpdate(detail.id, "declined");
  };

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
      {/* Identity + nav — name + status pill on left, action buttons on right */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, flexWrap: "wrap" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
            <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>{displayName}</div>
            <div style={{ padding: "5px 12px", fontSize: 11, fontWeight: 600, color: T.slate700, background: T.slate100, borderRadius: 12 }}>
              {STAGE_LABELS[detail?.status] || detail?.status || "—"}
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 10, flexShrink: 0 }}>
            <button
              onClick={copyAssessmentLink}
              disabled={copyLinkStatus === "copying" || !detail?.id}
              title="Generate and copy the public /assess/<id>/<token> link — hand to candidate"
              style={{
                padding: "7px 14px",
                fontSize: 12,
                fontWeight: 600,
                color: copyLinkStatus === "copied" || copyLinkStatus === "error" ? T.white : T.slate700,
                background: copyLinkStatus === "copied" ? T.green : copyLinkStatus === "error" ? T.red : T.slate100,
                border: "none",
                borderRadius: 7,
                cursor: copyLinkStatus === "copying" ? "wait" : "pointer",
              }}
            >
              {copyLinkStatus === "copying" ? "Copying…" : copyLinkStatus === "copied" ? "✓ Copied!" : copyLinkStatus === "error" ? "Copy failed" : "Copy assessment link"}
            </button>
            <button onClick={onBack} style={{ padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.slate700, background: T.slate100, border: "none", borderRadius: 7, cursor: "pointer" }}>← Back to Pipeline</button>
          </div>
        </div>
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
          verdict_overall. The 4×3 matrix
          (Resume/Assessment/Interview/Reference × Capability/Character/Commitment)
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
              // The old "composite" column this layer used to read does not exist on
              // hiring_candidates (verified against information_schema) — dropped
              // entirely. v2 candidates source the Assessment layer score from the
              // selected role's fit_score in v2RoleFits. v1/CTS falls back to
              // overall_score, same as it always did.
              const isV2Matrix = detail?.assessment_source === "v2";
              const matrixBf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
              const matrixCurrentRole = selectedRole || matrixBf?.best_role || "sales_outbound";
              const assessmentLayerScore = isV2Matrix
                ? (v2RoleFits ? v2RoleFits[matrixCurrentRole]?.fit_score ?? null : null)
                : (detail?.overall_score ?? null);
              const layers = [
                { key: "resume",     label: "Resume",     score: threeConstruct.resume_score,     verdict: threeConstruct.resume_verdict },
                // Assessment layer sources composite/capability/character/commitment from v_hiring_candidates
                // (populated by role-fit click). Score is 0-100 like Resume. Verdict computed by layerVerdict.
                { key: "assessment", label: "Assessment", score: assessmentLayerScore, verdict: null },
                { key: "interview",  label: "Interview",  score: detail?.iv_composite,           verdict: detail?.interview_analysis?.verdict },
                { key: "reference",  label: "Reference",  score: threeConstruct.reference_score,  verdict: threeConstruct.reference_verdict },
              ];
              const constructs = [
                { key: "capability", label: "Capability", weight: cw.capability, score: threeConstruct.capability_score },
                { key: "character",  label: "Character",  weight: cw.character,  score: threeConstruct.character_score  },
                { key: "commitment", label: "Commitment", weight: cw.commitment, score: threeConstruct.commitment_score },
              ];
              const scoreBg = (v) => v == null ? T.slate50
                                   : v >= 75 ? T.greenLt
                                   : v >= 60 ? T.amberLt
                                   : T.redLt;
              const scoreFg = (v) => v == null ? T.slate500
                                   : v >= 75 ? T.green
                                   : v >= 60 ? T.amber
                                   : T.red;
              // All layers now on 0-100 scale (RPC normalized 2026-07-21). is100() kept for
              // legacy call-site safety but always true; can drop after next cleanup pass.
              const is100 = (k) => true;
              // Per-layer verdict thresholds come from useVerdictThresholds hook (same source the scoring RPC reads).
              const layerThresh = (k) => verdictThresh[k] || verdictThresh.assessment;
              const layerBg = (v, k) => { if (v == null) return T.slate50; const t = layerThresh(k); return v >= t.pass ? T.greenLt : v >= t.consider ? T.amberLt : T.redLt; };
              const layerFg = (v, k) => { if (v == null) return T.slate500; const t = layerThresh(k); return v >= t.pass ? T.green : v >= t.consider ? T.amber : T.red; };
              // Verdict-driven color (used when a stored verdict may override the score-based
              // read — e.g. interview character-floor decline where composite is above 50 but
              // verdict is decline. Pill/cell color must follow the verdict text, not the score.
              const verdictBg = (v) => (v === "pass" || v === "hire") ? T.greenLt
                                    : (v === "consider" || v === "lean_hire" || v === "lean_decline") ? T.amberLt
                                    : (v === "decline" || v === "no_hire" || v === "decline_lss" || v === "decline_character") ? T.redLt
                                    : T.slate50;
              const verdictFg = (v) => (v === "pass" || v === "hire") ? T.green
                                    : (v === "consider" || v === "lean_hire" || v === "lean_decline") ? T.amber
                                    : (v === "decline" || v === "no_hire" || v === "decline_lss" || v === "decline_character") ? T.red
                                    : T.slate500;
              // 0-100 layer scores rendered as rounded ints; 0-10 layers as x.xx.
              const fmtLayerScore = (v, k) => v == null ? "—"
                : is100(k) ? String(Math.round(Number(v)))
                : Number(v).toFixed(2);
              // Score→verdict uses the same per-layer thresholds as layerThresh (resume 70/50, others 75/60).
              const scoreVerdict = (v, k) => {
                if (v == null) return null;
                const t = layerThresh(k);
                return v >= t.pass ? "pass" : v >= t.consider ? "consider" : "decline";
              };
              const layerVerdict = (layer) => {
                if (layer.key === "resume" || layer.key === "assessment") return scoreVerdict(layer.score, layer.key);
                // Interview: honor stored iv_verdict (character-floor overrides, structural mismatch)
                // when present, else derive from composite on the per-layer scale.
                if (layer.key === "interview") return layer.verdict || scoreVerdict(layer.score, layer.key);
                // Reference: same pattern — stored verdict wins, else derived per-layer.
                return layer.verdict || scoreVerdict(layer.score, layer.key);
              };
              const verdictLabel = (v) => (v || "not_scored").replace(/_/g, " ");
              const pctFmt = (w) => w == null ? "" : `${Math.round(Number(w) * 100)}%`;
              // Phone-aware sizing: tighter paddings, smaller fonts, narrower fixed columns
              // so the 4×3 matrix fits ~370px viewport without header/value overlap.
              const th = isPhone
                ? { padding: "5px 3px", fontSize: 9, fontWeight: 700, color: T.slate600, textTransform: "uppercase", letterSpacing: 0, textAlign: "center", borderBottom: `1px solid ${T.slate200}`, lineHeight: 1.15 }
                : { padding: "8px 10px", fontSize: 10, fontWeight: 700, color: T.slate600, textTransform: "uppercase", letterSpacing: 0.4, textAlign: "center", borderBottom: `1px solid ${T.slate200}` };
              const rowLabelBase = isPhone
                ? { padding: "6px 6px", fontSize: 10.5, fontWeight: 600, color: T.slate700, background: T.slate50, borderRight: `1px solid ${T.slate200}`, whiteSpace: "nowrap" }
                : { padding: "8px 10px", fontSize: 11, fontWeight: 600, color: T.slate700, background: T.slate50, borderRight: `1px solid ${T.slate200}`, whiteSpace: "nowrap" };
              const clickableRowLabel = { ...rowLabelBase, cursor: "pointer", userSelect: "none" };
              const labelColW = isPhone ? 92 : 130;
              const totalColW = isPhone ? 72 : 110;
              const cellPad = isPhone ? "5px 4px" : "8px 10px";
              const cellFont = isPhone ? 12 : 14;
              const layerTotalFont = isPhone ? 13 : 15;
              const subtotalFont = isPhone ? 13 : 16;
              const resultFont = isPhone ? 15 : 18;
              const weightFont = isPhone ? 8 : 9;
              const verdictPillFont = isPhone ? 8 : 9;
              const subDetailFont = isPhone ? 7.5 : 8;

              return (
                <div style={{ marginBottom: 14, border: `1px solid ${T.slate200}`, borderRadius: 8, overflow: "hidden" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", tableLayout: "fixed" }}>
                    <thead>
                      <tr style={{ background: T.slate50 }}>
                        <th style={{ ...th, width: labelColW }}></th>
                        {constructs.map((c) => (
                          <th key={c.key} style={th}>
                            {isPhone ? (
                              <>
                                <div>{c.label}</div>
                                <div style={{ color: T.slate500, fontWeight: 500, fontSize: weightFont, marginTop: 1 }}>{pctFmt(c.weight)}</div>
                              </>
                            ) : (
                              <>
                                {c.label} <span style={{ color: T.slate500, fontWeight: 500 }}>· {pctFmt(c.weight)}</span>
                              </>
                            )}
                          </th>
                        ))}
                        <th style={{ ...th, width: totalColW, borderLeft: `2px solid ${T.slate200}` }}>Total</th>
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
                                // All layers 0-100 (RPC normalized 2026-07-21). Assessment cells read
                                // from view assessment_* cols, interview from iv_*, resume/reference
                                // from RPC matrix.
                                const cell = layer.key === "assessment"
                                  ? (c.key === "capability" ? detail?.assessment_capability
                                    : c.key === "character" ? detail?.assessment_character
                                    : detail?.assessment_commitment)
                                  : layer.key === "interview"
                                  ? (c.key === "capability" ? detail?.iv_capability
                                    : c.key === "character" ? detail?.iv_character
                                    : detail?.iv_commitment)
                                  : matrix?.[c.key]?.[layer.key];
                                const w = weights?.[c.key]?.[layer.key];
                                const cellDisplay = cell == null ? "—"
                                  : is100(layer.key) ? String(Math.round(Number(cell)))
                                  : Number(cell).toFixed(2);
                                // Cell coloring uses the layer's own verdict thresholds (resume 70/50, others 75/60).
                                const cellBg = layerBg(cell, layer.key);
                                const cellFg = layerFg(cell, layer.key);
                                return (
                                  <td key={c.key} style={{ padding: cellPad, background: cellBg, borderRight: `1px solid ${T.slate100}`, textAlign: "center" }}>
                                    <div style={{ fontSize: cellFont, fontWeight: 700, color: cell == null ? T.slate500 : T.slate900 }}>
                                      {cellDisplay}
                                    </div>
                                    <div style={{ fontSize: weightFont, color: cell == null ? T.slate500 : cellFg, fontWeight: 600 }}>
                                      weight {pctFmt(w)}
                                    </div>
                                    {layer.key === "assessment" && c.key === "character" && (
                                      <div
                                        style={{ fontSize: subDetailFont, color: T.slate600, marginTop: 2, fontWeight: 500, letterSpacing: 0.2, lineHeight: 1.3 }}
                                        title="Character components from measured personality facets. C = Concern for Others (compassion, cooperation, trust) · W = Hard Work Ethic (self-discipline, achievement striving, dutifulness) · R = Personal Responsibility (dutifulness, self-efficacy). A component with no facet data shows a dash. Honesty is not measured here — it belongs to the interview and reference layers."
                                      >
                                        C {detail?.assessment_character_concern != null ? Math.round(Number(detail.assessment_character_concern)) : "—"}
                                        {" · "}
                                        W {detail?.assessment_character_work_ethic != null ? Math.round(Number(detail.assessment_character_work_ethic)) : "—"}
                                        {" · "}
                                        R {detail?.assessment_character_personal_resp != null ? Math.round(Number(detail.assessment_character_personal_resp)) : "—"}
                                      </div>
                                    )}
                                    {layer.key === "assessment" && c.key === "commitment" && (
                                      <div
                                        style={{ fontSize: subDetailFont, color: T.slate600, marginTop: 2, fontWeight: 500, letterSpacing: 0.2, lineHeight: 1.3 }}
                                        title="Suggs motivation drivers measurable via CTS: Achievement (deadline motivation) · Recognition (recognition drive) · Autonomy (independent spirit). Six other Suggs driver types not measurable via CTS."
                                      >
                                        Ach {detail?.deadline_motivation != null ? Math.round(Number(detail.deadline_motivation)) : "—"}
                                        {" · "}
                                        Rec {detail?.recognition_drive != null ? Math.round(Number(detail.recognition_drive)) : "—"}
                                        {" · "}
                                        Aut {detail?.independent_spirit != null ? Math.round(Number(detail.independent_spirit)) : "—"}
                                      </div>
                                    )}
                                  </td>
                                );
                              })}
                              <td style={{ padding: cellPad, background: layer.score == null ? T.slate50 : verdictBg(layerVerdict(layer)), borderLeft: `2px solid ${T.slate200}`, textAlign: "center" }}>
                                <div style={{ fontSize: layerTotalFont, fontWeight: 800, color: layer.score == null ? T.slate500 : T.slate900 }}>
                                  {fmtLayerScore(layer.score, layer.key)}
                                </div>
                                <div style={{ marginTop: 2 }}>
                                  <span style={{ display: "inline-block", padding: isPhone ? "1px 4px" : "2px 6px", borderRadius: 3, fontSize: verdictPillFont, fontWeight: 700, color: layer.score == null ? T.slate500 : T.white, background: layer.score == null ? T.slate100 : verdictFg(layerVerdict(layer)), textTransform: "uppercase", letterSpacing: isPhone ? 0.2 : 0.4 }}>
                                    {verdictLabel(layerVerdict(layer))}
                                  </span>
                                </div>
                                {layer.key === "assessment" && (
                                  <div style={{ marginTop: 3 }}>
                                    <span style={{ display: "inline-block", padding: isPhone ? "1px 4px" : "2px 6px", borderRadius: 3, fontSize: verdictPillFont, fontWeight: 600, color: T.slate700, background: T.slate100, textTransform: "uppercase", letterSpacing: isPhone ? 0.2 : 0.4 }}>
                                      {selectedRole
                                        ? (ROLE_LABELS[selectedRole] || selectedRole)
                                        : (isPhone ? "role →" : "click a role fit →")}
                                    </span>
                                  </div>
                                )}
                              </td>
                            </tr>
                            {isOpen && (
                              <tr style={{ borderBottom: `1px solid ${T.slate200}`, background: T.white }}>
                                <td colSpan={5} style={{ padding: "14px 16px", background: T.slate50 }}>
                                  {layer.key === "resume" && renderResumeLayer(detail, T, verdictThresh.resume)}
                                  {layer.key === "assessment" && renderAssessmentLayer({
                                    detail, competencies, bestFit,
                                    selectedRole, setSelectedRole, T,
                                    v1Extras, v1InvitedAt,
                                    intelligence, roleIdealRange,
                                    v2Facets, v2RoleFits, gmaOpen, setGmaOpen,
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
                          <td key={c.key} style={{ padding: isPhone ? "6px 3px" : "10px", background: scoreBg(c.score), borderLeft: `3px solid ${scoreFg(c.score)}`, borderRight: `1px solid ${T.slate100}`, textAlign: "center" }}>
                            <div style={{ fontSize: subtotalFont, fontWeight: 800, color: c.score == null ? T.slate500 : T.slate900 }}>
                              {c.score != null ? Math.round(Number(c.score)) : "—"}
                            </div>
                          </td>
                        ))}
                        <td style={{ padding: isPhone ? "6px 3px" : "10px", background: T.slate100, borderLeft: `2px solid ${T.slate200}` }}></td>
                      </tr>
                      {/* Overall result row — score + verdict + confidence + threshold previews */}
                      <tr>
                        <td style={{ ...rowLabelBase, background: T.slate900, color: T.white, fontWeight: 700, borderRight: `1px solid ${T.slate900}` }}>Result</td>
                        <td colSpan={4} style={{ padding: isPhone ? "8px 6px" : "10px 12px", background: threeConstruct.verdict ? verdictBg(threeConstruct.verdict) : scoreBg(threeConstruct.score_0_10), borderLeft: `3px solid ${threeConstruct.verdict ? verdictFg(threeConstruct.verdict) : scoreFg(threeConstruct.score_0_10)}`, textAlign: "center" }}>
                          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: isPhone ? 6 : 10, flexWrap: "wrap", marginBottom: 6 }}>
                            <span style={{ fontSize: resultFont, fontWeight: 800, color: T.slate900 }}>
                              {threeConstruct.score_0_10 != null ? Math.round(Number(threeConstruct.score_0_10)) : "—"}
                            </span>
                            <span style={{ padding: isPhone ? "2px 6px" : "3px 10px", borderRadius: 4, fontSize: isPhone ? 9 : 10, fontWeight: 700, color: T.white, background: threeConstruct.verdict ? verdictFg(threeConstruct.verdict) : scoreFg(threeConstruct.score_0_10), textTransform: "uppercase", letterSpacing: 0.5 }}>
                              {(threeConstruct.verdict || "insufficient data").replace(/_/g, " ")}
                            </span>
                            <span style={{ fontSize: isPhone ? 10 : 11, color: T.slate600 }}>
                              confidence: {threeConstruct.confidence || "—"}
                            </span>
                          </div>
                          <div style={{ display: "flex", gap: isPhone ? 8 : 12, fontSize: isPhone ? 9 : 10, color: T.slate600, justifyContent: "center", flexWrap: "wrap" }}>
                            <span>@70: <strong style={{ color: T.slate900 }}>{threeConstruct.score_hire_at_70 || "n/a"}</strong></span>
                            <span>@75: <strong style={{ color: T.slate900 }}>{threeConstruct.score_hire_at_75 || "n/a"}</strong></span>
                            <span>@80: <strong style={{ color: T.slate900 }}>{threeConstruct.score_hire_at_80 || "n/a"}</strong></span>
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
      {/* v1/CTS only. This panel is fed by the legacy rules-narrative engine
          (hiregauge_composite_recommendation + hiregauge_evaluate_candidate),
          which reads retired trait columns (recognition_drive,
          deadline_motivation) that v2 never fills. Deliberately not rebuilt
          for v2 — mechanical combination beats configural judgment (Kuncel
          et al. 2013). The v2 role-fit + gate display is the verdict
          surface for v2 candidates. */}
      {detail?.assessment_source !== "v2" && (
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
        ) : (detail?.overall_score == null) ? (
          // Pre-assessment: composite may fire "unverified" floor signals off the resume
          // alone, but rendering those as "Floors failed" reads as a scoring failure
          // when the candidate hasn't answered anything yet. Clean pill instead of the
          // misleading chip cascade — framework read waits for real assessment scores.
          <div style={{ padding: "10px 14px", marginBottom: 12, borderRadius: 8, background: T.slate100, borderLeft: `4px solid ${T.slate500}` }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
              <span style={{ padding: "3px 10px", borderRadius: 4, fontSize: 11, fontWeight: 700, color: T.white, background: T.slate500, textTransform: "uppercase", letterSpacing: 0.5 }}>
                Assessment not started
              </span>
              <span style={{ fontSize: 12, color: T.slate700 }}>
                HireGauge scores will populate here once the candidate completes the assessment.
              </span>
            </div>
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
      )}

      {/* Reference Check */}
      <Section title="Reference Check">
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

      {/* Decline Candidate — moves out of active pipeline into Declined view */}
      {detail?.status !== "declined" && (
        <Section title="Decline Candidate" tone={T.redLt}>
          <div style={{ fontSize: 11, color: T.slate600, marginBottom: 8 }}>
            Moves this candidate out of the active pipeline into the Declined view. Sets Final Decision to No Hire.
          </div>
          <div style={{ marginBottom: 8 }}>
            <label style={{ fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 }}>Decline reason</label>
            <select
              value={detail?.decline_reason || ""}
              onChange={(e) => updateField("decline_reason", e.target.value || null)}
              style={{ padding: 6, fontSize: 13, borderRadius: 5, border: `1px solid ${T.slate200}`, minWidth: 220 }}
            >
              <option value="">Select a reason...</option>
              <option value="active_applicant">Active — declined</option>
              <option value="offer_rescinded">Offer rescinded</option>
              <option value="calibration_only">Calibration test only</option>
              <option value="former_team">Former team member</option>
            </select>
          </div>
          <div style={{ marginTop: 8, display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
            <button
              onClick={saveDecline}
              disabled={savingSection === "decline" || !detail?.decline_reason}
              style={{
                padding: "7px 14px", fontSize: 12, fontWeight: 600,
                color: T.white,
                background: detail?.decline_reason ? T.red : T.slate300,
                border: "none", borderRadius: 7,
                cursor: (savingSection === "decline" || !detail?.decline_reason) ? "not-allowed" : "pointer",
              }}
            >
              {savingSection === "decline" ? "Declining..." : "Decline Candidate"}
            </button>
            <span style={{ fontSize: 10, color: T.slate500 }}>Reasoning uses the notes field above.</span>
          </div>
        </Section>
      )}
    </div>
  );
}
