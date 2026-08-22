import { useState, useEffect, useMemo, useRef, Fragment } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport, useVerdictThresholds } from "../lib/hooks.js";
import { STAGES, PIPELINE_STAGES, stageLabel } from "../lib/hiringStages.js";
import OfferLetterModal from "./OfferLetterModal.jsx";

// ─── Constants ─────────────────────────────────────────────────────

const DECLINE_REASON_LABEL = {
  active_applicant: "Active — declined",
  offer_rescinded:  "Offer rescinded",
  calibration_only: "Calibration",
  former_team:      "Former team",
};

// Seven of the nine old CTS traits, and every lss_* column, were dropped from
// hiring_candidates on 2026-08-06 (migration 20260806170033). Only assertiveness
// and compassion survive, so only those two can be labelled or rendered.
const TRAIT_LABELS = {
  assertiveness:       "Assertiveness",
  compassion:          "Compassion",
};

// Newtworks v2 assessment — the 25 live personality facets, strategic labels
// pulled from hiregauge_trait_documentation.strategic_label. Feeds the 12
// competencies + 7 role-fit functions below (Newtworks competency layer,
// confirmed 2026-08-02, live 2026-08-03 — the earlier "no competency layer"
// note reflected a different, since-superseded thread; see op-rule
// "CORRECTION 2026-08-03: competency/role-fit descope directive was
// thread-specific, not agency-wide").
const V2_FACET_LABELS = {
  achievement_striving:       "Achievement Striving",
  assertiveness:              "Assertiveness",
  compassion:                 "Compassion",
  competitiveness:            "Competitiveness",
  learning_goal_orientation:  "Learning Goal Orientation",
  prove_goal_orientation:     "Prove Goal Orientation",
  avoid_goal_orientation:     "Avoid Goal Orientation",
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

// Role Fit input labels — the 27 weighted inputs behind every
// newtworks_all_role_fits() role score (25 facets + gma + sjt). Used only by
// the admin-only Role Fit breakdown expander (Peter directive 2026-08-14).
const ROLE_FIT_INPUT_LABELS = {
  ...V2_FACET_LABELS,
  gma: "General Mental Ability",
  sjt: "Situational Judgment",
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

// v2 reliability band is high/moderate/low (fired-count based) — distinct
// from the v1 RELIABILITY_BAND's five-value text scale. Higher fired_count =
// worse. BUG FIXED 2026-08-06: this checked for 'medium', but
// hiregauge_v2_reliability_composite has always returned 'moderate' for the
// middle band — 9 live candidates were silently rendering uncolored ('none')
// instead of yellow.
const V2_RELIABILITY_BAND = (v) => {
  if (v === "high") return "green";
  if (v === "moderate") return "yellow";
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

// Protocol validity band — high/reduced/low, per _newtworks_protocol_validity
// (im_mult * rel_mult, floored at 0.30). Higher = more trustworthy self-report.
const PROTOCOL_VALIDITY_BAND = (label) => {
  if (label === "high") return "green";
  if (label === "reduced") return "yellow";
  if (label === "low") return "red";
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

// Validity band — reliability higher-is-better.
// Values are text: 'very_low' | 'low' | 'moderate' | 'high' | 'very_high'.
const RELIABILITY_BAND = (v) => {
  if (v == null) return "none";
  if (v === "very_high" || v === "high") return "green";
  if (v === "moderate") return "yellow";
  return "red"; // low, very_low
};

// Competency band — green ≥ 50, yellow 40–49, red < 40. Same threshold across
// all four role fits (per Peter directive 2026-07-16).
const competencyBand = (v) => {
  if (v == null) return "none";
  if (v >= 50) return "green";
  if (v >= 40) return "yellow";
  return "red";
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
  // Display-only rounding (Peter directive 2026-08-06 — every score should
  // read as a whole number). Bar-fill math above still uses the unrounded
  // numValue so the gauge stays precise; this only affects the printed digits.
  const displayValue = Number.isFinite(numValue) ? Math.round(numValue) : value;
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
          {displayValue ?? "—"}
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

// Admin-only collapsible breakdown, meant to sit directly under an AssessRow
// (or a Role Fit button). Renders nothing at all for non-admin roles — not
// just hidden via CSS, actually absent from the DOM, since this is scoring
// detail Peter wants for himself only (2026-08-14 directive). Closed by
// default. Deliberately quiet styling (small, slate400 toggle text) so it
// reads as a light admin affordance, not a headline UI element.
const AdminBreakdown = ({ isAdmin, children }) => {
  const [open, setOpen] = useState(false);
  if (!isAdmin) return null;
  return (
    <div style={{ marginTop: -2, marginBottom: 2 }}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        style={{
          display: "flex", alignItems: "center", gap: 4,
          fontSize: 9, fontWeight: 600, color: T.slate400,
          background: "none", border: "none", padding: "3px 10px",
          cursor: "pointer", fontFamily: "inherit", textTransform: "uppercase", letterSpacing: 0.3,
        }}
      >
        <span style={{ display: "inline-block", transform: open ? "rotate(90deg)" : "none", transition: "transform 0.12s" }}>▸</span>
        Admin breakdown
      </button>
      {open && (
        <div style={{ padding: "8px 10px", marginTop: 2, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 6, fontSize: 10, color: T.slate600, display: "flex", flexDirection: "column", gap: 4 }}>
          {children}
        </div>
      )}
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
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 14, alignItems: "start" }}>
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
// role-fit selector for the currently-selected role on the right. Moved
// here from the standalone top-of-page Assessment section per Peter
// directive 2026-07-17.
// Newtworks v2 assessment layer — facet percentiles (vs typical adults,
// via hiregauge_candidate_facet_percentiles, computed on read, never
// stored), GMA/SJT results, and Role Fit from the facet-direct v5 model
// (role_fit_v5_0_facet_direct_2026_08_06, live migration D). bestFit comes
// from assessment_best_fit_role (uuid RPC, already gated); v2RoleFits comes
// from newtworks_all_role_fits (uuid RPC). The competency layer no longer
// drives role fit or display here and is slated for removal in Migration F.
// v1/CTS candidates keep the legacy renderAssessmentLayer below — this
// function renders for detail.assessment_source "v2" or "v2fc" (widened
// 2026-08-16, see the dispatch function's own comment for the incident).
// Explicit grid-template-areas per breakpoint (rather than plain CSS Grid
// auto-fit) so Role Fit always lands under Traits at the 2-column width,
// never under Facets. auto-fit's implicit placement fills the first open
// cell left-to-right, which put Role Fit under Facets whenever exactly 2
// columns fit (Peter directive 2026-08-06). Breakpoints match
// lib/hooks.js useViewport (phone <640, tablet 640-1023, desktop >=1024)
// for consistency with the rest of the app's responsive behavior.
const CD_ASSESS_GRID_CSS = `
.cd-assess-grid {
  display: grid;
  gap: 16px;
  align-items: start;
  grid-template-columns: 1fr;
  grid-template-areas: "facets" "rolefit";
}
@media (min-width: 640px) {
  .cd-assess-grid {
    grid-template-columns: 1fr 1fr;
    grid-template-areas: "facets rolefit";
  }
}
.cd-col-facets  { grid-area: facets;  min-width: 0; }
.cd-col-rolefit { grid-area: rolefit; min-width: 0; }
`;

function renderAssessmentLayerV2({ detail, v2Facets, v2Percentiles, bestFit, v2RoleFits, facetRewordedFlags, v2PoolPosition, selectedRole, setSelectedRole, T, screenAnswers, isAdmin }) {
  const exitGate = detail?.assessment_exit_gate;
  const exitDetail = detail?.assessment_exit_detail || {};
  const exitedAt = detail?.assessment_exited_at;
  const assessmentFlags = Array.isArray(detail?.assessment_flags) ? detail.assessment_flags : [];

  const reliability = detail?.reliability; // 'high' | 'moderate' | 'low' — still the color source
  // Reliability score (Peter directive 2026-08-06 — show a number, not just
  // the band word). hiregauge_v2_reliability_composite already stamps
  // fired_count straight into reliability_detail, so this just reads it —
  // no migration, no re-deriving. Same 0-1/2/3+ boundaries drive the color
  // via V2_RELIABILITY_BAND(reliability) below.
  const reliabilityFiredCount = detail?.reliability_detail?.fired_count ?? null;
  // Reliability score (Peter directive 2026-08-06, same day as the fired-count
  // display above it): (checks not fired) / (total checks) * 100. Total is a
  // fixed 6 — hiregauge_v2_reliability_composite always evaluates all six
  // methods and each always returns a real true/false, never null/skipped
  // (confirmed in migration 20260802033616 — e.g. retest_divergence returns
  // fired=false, not null, when there are no retest pairs to compare).
  const RELIABILITY_TOTAL_CHECKS = 6;
  const reliabilityScore = reliabilityFiredCount != null
    ? Math.round(((RELIABILITY_TOTAL_CHECKS - reliabilityFiredCount) / RELIABILITY_TOTAL_CHECKS) * 100)
    : null;

  const imBand = detail?.impression_management_band;

  const sjtScore = detail?.sjt_score; // 0-100

  // GMA total, as percent correct — canonical live-count formula from the
  // role-fit payload. NEVER client-derive this from detail.gma_total_accuracy
  // (that column is a raw count, not a percent). T4, Step 8, 2026-08-07.
  const gmaRoleFits = v2RoleFits || {};
  const gmaBestRoleKey = (Array.isArray(bestFit) && bestFit[0]?.best_role) || Object.keys(gmaRoleFits)[0];
  const gmaPct = gmaRoleFits?.[gmaBestRoleKey]?.inputs?.gma?.value ?? null;

  const facetRows = Array.isArray(v2Facets) ? v2Facets : null;
  const facetByTrait = {};
  if (facetRows) {
    for (const r of facetRows) facetByTrait[r.hypothesized_trait] = r;
  }
  // Facet percentiles vs typical adults — hiregauge_candidate_facet_percentiles,
  // computed on read, never stored. Replaces raw facet_score display (Step 8,
  // 2026-08-07). Any facet with no row in hiregauge_facet_norms returns
  // percentile null and renders as an em dash — as of 2026-08-13 all facets,
  // including competitiveness (Houston et al. 2002 Revised Competitiveness
  // Index), have a seeded norm.
  const pctRowsLoading = v2Percentiles == null;
  const pctRows = Array.isArray(v2Percentiles) ? v2Percentiles : null;
  const pctByFacet = {};
  if (pctRows) {
    for (const r of pctRows) pctByFacet[r.facet] = r.percentile;
  }
  // Batch 0 / 0E — dual-reference facet display inputs.
  const rewordedByFacet = facetRewordedFlags || {};
  const poolRows = Array.isArray(v2PoolPosition) ? v2PoolPosition : null;
  const poolByFacet = {};
  if (poolRows) {
    for (const r of poolRows) poolByFacet[r.facet] = r;
  }
  // Note shows once per facet section (not once per facet) — only if at
  // least one VISIBLE facet on this candidate has been reworded.
  let anyRewordedVisible = false;
  for (const trait of Object.keys(V2_FACET_LABELS)) {
    if (rewordedByFacet[trait]) { anyRewordedVisible = true; break; }
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

      {/* Non-blocking assessment flags — interview probes only, never a
          decline reason. Amber, not red: distinct from the exit-gate banner
          above so nobody reads a flag as a stop. Written by
          apply_hiregauge_v2_stint1_exit_gate. Peter directive 2026-08-06 —
          op-rule "Made-up-word check is a FLAG, never an eliminator". */}
      {assessmentFlags.length > 0 && (
        <div style={{
          padding: "10px 12px", background: T.amberLt, borderRadius: 6,
          borderLeft: `4px solid ${T.amber}`, boxSizing: "border-box",
        }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.amber }}>
            {assessmentFlags.length === 1 ? "Assessment flag" : `Assessment flags (${assessmentFlags.length})`} — interview probe, not a decline reason
          </div>
          {assessmentFlags.map((f, i) => (
            <div key={f?.flag ?? i} style={{ fontSize: 11, color: T.slate700, marginTop: i === 0 ? 3 : 6 }}>
              {f?.detail || f?.flag || "Flag recorded."}
            </div>
          ))}
        </div>
      )}

      {/* Two-column layout: facets | role fit. Explicit grid-template-areas
          per breakpoint (see CD_ASSESS_GRID_CSS above) — single-column
          stack (facets above rolefit) on phone, side by side (facets left,
          rolefit right) from the tablet breakpoint up. */}
      <style>{CD_ASSESS_GRID_CSS}</style>
      <div className="cd-assess-grid">

      {/* Column 1 — Personality Facets */}
      <div className="cd-col-facets">
        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 4 }}>
          Personality Facets
        </div>
        {(facetRows == null || pctRowsLoading) ? (
          <div style={{ fontSize: 11, color: T.slate500, fontStyle: "italic", padding: "4px 10px" }}>
            Loading facet detail…
          </div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 6 }}>
            {Object.entries(V2_FACET_LABELS).map(([trait, label]) => {
              const row = facetByTrait[trait];
              const nItems = row?.n_items_scored;
              const insufficient = nItems != null && nItems < 4;
              const pct = pctByFacet[trait];
              const pool = poolByFacet[trait];
              const reworded = !!rewordedByFacet[trait];

              return (
                <div key={trait}>
                  <AssessRow
                    label={label}
                    value={insufficient ? "insufficient data" : (pct == null ? "—" : pct)}
                    band="none"
                  />
                  <AdminBreakdown isAdmin={isAdmin}>
                    <div>Raw facet score: {row?.facet_score ?? "—"}</div>
                    <div>Items scored: {nItems ?? "—"}</div>
                    {pool && (
                      <div>Pool position: {pool.pool_position ?? "—"} of {pool.pool_n ?? "—"}{pool.pool_percentile != null ? ` (${pool.pool_percentile} pctile)` : ""}</div>
                    )}
                    {reworded && <div>Item(s) reworded after norm was set — percentile may be imprecise.</div>}
                  </AdminBreakdown>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Column 3 — Role Fit */}

      {/* Column 3 — Role Fit */}
      <div className="cd-col-rolefit">
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
                  Verdict capped at "consider" — an integrity flag or reasoning floor fired on best-fit role
                </div>
              )}
              {bf.best_churn_risk && (
                <div style={{ padding: "6px 10px", background: T.slate100, borderRadius: 6, marginBottom: 4, fontSize: 11, fontWeight: 600, color: T.slate700 }}>
                  {Array.isArray(bf.best_gates_fired) && bf.best_gates_fired.includes("gma_above_band")
                    ? "May be under-challenged in this seat — retention risk to probe in interview."
                    : "Churn-risk flag on best-fit role — reasoning ceiling exceeded, performance unaffected"}
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
                const roleFitDetail = gmaRoleFits?.[r.key];
                const inputRows = roleFitDetail?.inputs && typeof roleFitDetail.inputs === "object"
                  ? Object.entries(roleFitDetail.inputs).sort((a, b) => Math.abs(Number(b[1]?.effective_weight) || 0) - Math.abs(Number(a[1]?.effective_weight) || 0))
                  : [];
                return (
                  <div key={r.key}>
                    <button
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
                      title={isSelected ? "Selected — the score matrix Capability row uses this role" : "Click to score Capability against this role"}
                    >
                      <span style={{ fontSize: 11, color: T.slate700, fontWeight: 600 }}>
                        {ROLE_LABELS[r.key] || r.key} Fit
                      </span>
                      <span style={{ fontSize: 14, fontWeight: 700, color: valueColor, whiteSpace: "nowrap" }}>
                        {r.fitScore ?? "—"}
                      </span>
                    </button>
                    <AdminBreakdown isAdmin={isAdmin}>
                      {inputRows.length === 0 ? (
                        <div>No input detail available.</div>
                      ) : (
                        inputRows.map(([key, inp]) => (
                          <div key={key} style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
                            <span>
                              {ROLE_FIT_INPUT_LABELS[key] || key}
                              {inp?.basis && <span style={{ color: T.slate400 }}> — {inp.basis}</span>}
                            </span>
                            <span style={{ whiteSpace: "nowrap", fontWeight: 600 }}>
                              {inp?.value ?? "—"} × {inp?.weight ?? "—"} = {inp?.effective ?? "—"}
                            </span>
                          </div>
                        ))
                      )}
                    </AdminBreakdown>
                  </div>
                );
              })}
            </>
          );
        })()}

        {/* GMA / SJT / Protocol Validity / Reliability / Impression Management
            — moved under the Role Fit rows and color-coded (Peter directive
            2026-08-13). Order per Peter directive 2026-08-13 (second pass):
            GMA, SJT (the two capability/aptitude measures) first, then
            Protocol Validity as the headline trust summary, then Reliability
            and Impression Management as its two drill-down components (the
            same order they've always computed in — see
            _newtworks_protocol_validity: v = im_mult * rel_mult). Protocol
            Validity replaces the old "Answer trust" chip as a plain data
            row in the same format as the others; value is
            detail.protocol_validity_v * 100 (v ranges 0.30-1.00), banded via
            PROTOCOL_VALIDITY_BAND(detail.protocol_validity_label). Reliability
            bands off detail.reliability (canonical band source — the same
            field V2_RELIABILITY_BAND already used elsewhere for this
            fired-count-derived score). Impression Management reads
            detail.impression_management (0-100 raw) with
            IM_BAND_COLOR(imBand). GMA/SJT are percent-correct scores banded
            with the same >=50 green / 40-49 yellow / <40 red thresholds
            already used for SJT (2026-08-06 session) and for role-fit/
            competency scores generally on this page — provisional the same
            way those are (see OQ 12ba414d), not yet locally validated for
            GMA specifically. */}
        {(reliabilityScore != null || gmaPct != null || sjtScore != null || detail?.impression_management != null || detail?.protocol_validity_v != null) && (
          <div style={{ display: "flex", flexDirection: "column", gap: 4, marginTop: 8 }}>
            {gmaPct != null && (() => {
              const gmaInput = gmaRoleFits?.[gmaBestRoleKey]?.inputs?.gma;
              return (
                <div>
                  <AssessRow label="General Mental Ability" value={gmaPct} band={competencyBand(gmaPct)} />
                  <AdminBreakdown isAdmin={isAdmin}>
                    <div>Accuracy: {gmaInput?.raw_0_100 ?? "—"}%{gmaInput?.accuracy_percentile != null ? ` (${gmaInput.accuracy_percentile} pctile)` : ""}</div>
                    <div>Speed: {gmaInput?.correct_items_per_minute ?? "—"} correct items/min{gmaInput?.speed_percentile != null ? ` (${gmaInput.speed_percentile} pctile)` : ""}</div>
                    {gmaInput?.basis && <div style={{ color: T.slate400 }}>{gmaInput.basis}</div>}
                  </AdminBreakdown>
                </div>
              );
            })()}
            {sjtScore != null && (() => {
              const topicRows = detail?.sjt_topic_detail && typeof detail.sjt_topic_detail === "object"
                ? Object.entries(detail.sjt_topic_detail) : [];
              return (
                <div>
                  <AssessRow label="Situational Judgment" value={sjtScore} band={competencyBand(sjtScore)} />
                  <AdminBreakdown isAdmin={isAdmin}>
                    {topicRows.length === 0 ? (
                      <div>No topic detail available.</div>
                    ) : (
                      topicRows.map(([topic, t]) => (
                        <div key={topic} style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
                          <span>{SJT_TOPIC_LABELS[topic] || topic}</span>
                          <span style={{ fontWeight: 600 }}>{t?.correct ?? "—"} / {t?.n ?? "—"}</span>
                        </div>
                      ))
                    )}
                  </AdminBreakdown>
                </div>
              );
            })()}
            {detail?.protocol_validity_v != null && (
              <div>
                <AssessRow label="Validity (Reliability + Faking)" value={Math.round(Number(detail.protocol_validity_v) * 100)} band={PROTOCOL_VALIDITY_BAND(detail.protocol_validity_label)} max={100} />
                <AdminBreakdown isAdmin={isAdmin}>
                  <div style={{ fontWeight: 700, color: T.slate700 }}>Reliability {reliabilityScore != null ? `— ${reliabilityScore}/100 (${reliability || "—"})` : ""}</div>
                  {Object.entries(RELIABILITY_METHOD_LABELS).map(([key, mLabel]) => {
                    const m = detail?.reliability_detail?.[key];
                    if (!m) return null;
                    return (
                      <div key={key} style={{ display: "flex", justifyContent: "space-between", gap: 8, color: m.fired ? T.red : T.slate600 }}>
                        <span>{mLabel}{m.fired ? " — flagged" : ""}</span>
                        <span style={{ textAlign: "right", maxWidth: "60%" }}>{m.detail || "—"}</span>
                      </div>
                    );
                  })}
                  <div style={{ fontWeight: 700, color: T.slate700, marginTop: 4 }}>Faking (Impression Management) {detail?.impression_management != null ? `— ${detail.impression_management}/100 (${imBand || "—"})` : ""}</div>
                </AdminBreakdown>
              </div>
            )}
          </div>
        )}
      </div>

      </div>

    </div>
  );
}

// Assessment layer — every candidate renders through this single function,
// regardless of assessment_source / version. The legacy v1/CTS-specific
// layout (separate LSS/traits column, IntelligenceHeadline, v1 reliability +
// distortion panel) was retired 2026-08-16 per Peter directive: the
// candidate detail page must render identically for every candidate, with
// no version-conditional branching anywhere on the page. Candidates without
// v2 facet/role-fit/reliability data (old CTS-source candidates, or anyone
// mid-assessment) simply show "insufficient data" / em-dashes in those
// slots — same convention already used for any candidate missing a
// particular score, not a separate code path.
function renderAssessmentLayer({ detail, bestFit, selectedRole, setSelectedRole, T, v2Facets, v2Percentiles, v2RoleFits, facetRewordedFlags, v2PoolPosition, screenAnswers, isAdmin }) {
  return renderAssessmentLayerV2({ detail, v2Facets, v2Percentiles, bestFit, v2RoleFits, facetRewordedFlags, v2PoolPosition, selectedRole, setSelectedRole, T, screenAnswers, isAdmin });
}

// ─── Reference layer ───────────────────────────────────────────────
// Reference emails ingested by the document-processor "references" mode into
// hiring_candidate_references (deterministic parse, no LLM — see the reference
// intake recipe). Each row is one emailed reference write-up: the person who
// gave it, when it landed, and the body exactly as it was written. Nothing is
// scored here yet; this is the read surface.
//
// Rows whose candidate_id is null never got matched to a candidate record by
// the intake job. Those are surfaced deliberately with an UNLINKED tag when the
// name in the subject line matches this candidate, so a reference can never sit
// invisible in the table just because the automatic match missed.
// Marie's mail client sends every reference twice in one message: a plain-text
// copy of the write-up followed by an HTML copy of the same thing. The intake
// stores the message body whole, so roughly half of every stored reference is a
// duplicate wrapped in markup. Trim it for display only — the stored text is
// left exactly as received, so nothing is lost and the durable fix belongs
// upstream in the intake parser.
function referenceBodyText(raw) {
  const s = String(raw || "");
  const idx = s.search(/<div[^>]*dir=["']ltr["'][^>]*>/i);
  if (idx > 0) {
    const plain = s.slice(0, idx).trim();
    if (plain.length > 0) return plain;
  }
  if (/<[a-z][^>]*>/i.test(s)) {
    return s
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(p|div|tr|li)\s*>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .replace(/&nbsp;/g, " ")
      .replace(/&#39;/g, "'")
      .replace(/&quot;/g, '"')
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }
  return s.trim();
}

function renderReferenceLayer({ refEmails, refLoadError, openRefs, toggleRef, T, isPhone }) {
  if (refLoadError) {
    return (
      <div style={{ fontSize: 12, color: T.red }}>
        Could not load reference emails. Reopen this row to try again.
      </div>
    );
  }
  if (refEmails == null) {
    return <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>Loading references…</div>;
  }
  if (refEmails.length === 0) {
    return (
      <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic" }}>
        No reference emails received yet. They appear here automatically once they arrive.
      </div>
    );
  }
  return (
    <div>
      <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 8 }}>
        Reference Emails · {refEmails.length}
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {(refEmails || []).map((r) => {
          const isOpen = !!openRefs[r.id];
          const unlinked = r.candidate_id == null;
          const when = r.received_at ? new Date(r.received_at).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) : "—";
          const label = r.reference_number != null ? `Reference ${r.reference_number}` : "Reference";
          return (
            <div key={r.id} style={{
              background: T.white,
              border: `1px solid ${unlinked ? T.amber : T.slate200}`,
              borderRadius: 7,
              boxSizing: "border-box",
              overflow: "hidden",
            }}>
              <button
                onClick={() => toggleRef(r.id)}
                style={{
                  width: "100%", textAlign: "left", background: unlinked ? T.amberLt : T.slate50,
                  border: "none", borderBottom: isOpen ? `1px solid ${T.slate200}` : "none",
                  padding: isPhone ? "8px 10px" : "10px 12px", cursor: "pointer",
                  display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8,
                  boxSizing: "border-box",
                }}
              >
                <span style={{ fontSize: 12, fontWeight: 700, color: T.slate900 }}>
                  {isOpen ? "▾" : "▸"} {label}
                </span>
                {unlinked && (
                  <span style={{ display: "inline-block", padding: "1px 6px", borderRadius: 3, fontSize: 9, fontWeight: 700, letterSpacing: 0.3, textTransform: "uppercase", color: T.white, background: T.amber }}>
                    Unlinked
                  </span>
                )}
                <span style={{ fontSize: 11, color: T.slate500 }}>{when}</span>
              </button>
              {isOpen && (
                <div style={{ padding: isPhone ? "10px" : "12px 14px", boxSizing: "border-box" }}>
                  <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Sent by</div>
                  <div style={{ fontSize: 11.5, color: T.slate700, marginBottom: 8, wordBreak: "break-word" }}>{r.sender || "—"}</div>
                  <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Subject</div>
                  <div style={{ fontSize: 11.5, color: T.slate700, marginBottom: 10, wordBreak: "break-word" }}>{r.subject || "—"}</div>
                  {unlinked && (
                    <div style={{ fontSize: 11, color: T.slate700, background: T.amberLt, border: `1px solid ${T.amber}`, borderRadius: 6, padding: "6px 8px", marginBottom: 10, boxSizing: "border-box" }}>
                      This one was never attached to a candidate record automatically. It is shown here
                      because the name on the subject line matches — treat the link as unconfirmed.
                    </div>
                  )}
                  <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>Written reference, verbatim</div>
                  <div style={{
                    fontSize: 12.5, lineHeight: 1.55, color: T.slate800,
                    whiteSpace: "pre-wrap", wordBreak: "break-word",
                    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
                  }}>
                    {referenceBodyText(r.body)}
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function renderInterviewLayer({ detail, T, updateAnswer, saveAnswers, savingAnswers, answersLastSavedAt, generateCustomProbes, probesGenerating, probesError, buildInterviewPlan, planBuilding, planError }) {
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
        <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8, marginBottom: 6 }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.slate800, textTransform: "uppercase", letterSpacing: 0.3 }}>
            Deep-Dive · ~{detail?.custom_probes?.time_budget_minutes || 30} min · candidate-specific
          </div>
          <button
            onClick={buildInterviewPlan}
            disabled={planBuilding}
            title="Build a 60-min interview plan from the interview_questions bank, driven by this candidate's trigger codes"
            style={{ padding: "5px 10px", fontSize: 10, fontWeight: 600, color: T.blue, background: T.blueLt, border: "none", borderRadius: 7, cursor: planBuilding ? "wait" : "pointer", marginLeft: "auto" }}
          >
            {planBuilding ? "Building..." : "🧭 Build Interview Plan"}
          </button>
        </div>
        {planError && (
          <div style={{ marginBottom: 8, padding: 8, background: T.redLt, borderRadius: 6, color: T.red, fontSize: 11 }}>
            {planError}
          </div>
        )}

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

// ─── Stage Stepper ─────────────────────────────────────────────────
// Tap-to-move pipeline control at the top of the detail page. Every active
// stage is its own button: the current stage is filled in its stage color,
// stages already passed read as done, stages still ahead read as pending.
// Tapping any stage writes hiring_candidates.status immediately — no confirm,
// because a wrong tap is undone by tapping the right stage.
//
// The strip scrolls sideways rather than wrapping (frontend rule 20) so all
// eight stages stay in one line on a 412px phone, and it auto-centers the
// current stage on open so the candidate's position is visible without a swipe.
const StageStepper = ({ status, saving, onPick }) => {
  const stripRef = useRef(null);
  const currentIdx = PIPELINE_STAGES.indexOf(status);
  const offPipeline = currentIdx === -1;   // declined or former

  useEffect(() => {
    const strip = stripRef.current;
    if (!strip) return;
    const el = strip.querySelector('[data-current="1"]');
    if (!el) return;
    // Set scrollLeft directly rather than scrollIntoView — scrollIntoView can
    // drag the whole page vertically on mobile.
    strip.scrollLeft = Math.max(0, el.offsetLeft - (strip.clientWidth - el.offsetWidth) / 2);
  }, [status]);

  return (
    <div style={{ marginBottom: 18 }}>
      <div
        ref={stripRef}
        style={{
          display: "flex", alignItems: "center", gap: 6,
          overflowX: "auto", WebkitOverflowScrolling: "touch",
          paddingBottom: 4,
        }}
      >
        {PIPELINE_STAGES.map((s, i) => {
          const cfg       = STAGES[s] || {};
          const isCurrent = s === status;
          const isDone    = !offPipeline && i < currentIdx;
          const busy      = saving === s;
          return (
            <Fragment key={s}>
              {i > 0 && (
                <span style={{ fontSize: 14, color: T.slate300, flexShrink: 0, userSelect: "none" }}>›</span>
              )}
              <button
                data-current={isCurrent ? "1" : undefined}
                onClick={() => { if (!isCurrent && !saving) onPick(s); }}
                disabled={!!saving || isCurrent}
                title={isCurrent ? `Currently ${cfg.label}` : `Move to ${cfg.label}`}
                style={{
                  flexShrink: 0, whiteSpace: "nowrap", boxSizing: "border-box",
                  padding: "6px 12px", fontSize: 11, fontWeight: 700, borderRadius: 20,
                  border: `1px solid ${isCurrent ? (cfg.color || T.slate400) : T.slate200}`,
                  background: isCurrent ? (cfg.color || T.slate400) : isDone ? T.slate100 : T.white,
                  color: isCurrent ? T.white : isDone ? T.slate600 : T.slate500,
                  cursor: isCurrent ? "default" : saving ? "wait" : "pointer",
                  opacity: saving && !busy ? 0.55 : 1,
                }}
              >
                {busy ? "Saving…" : cfg.label || s}
              </button>
            </Fragment>
          );
        })}
      </div>
      <div style={{ fontSize: 10, color: T.slate500, marginTop: 2 }}>
        {offPipeline
          ? `${stageLabel(status)} — tap a stage above to put this candidate back in the active pipeline.`
          : "Tap a stage to move this candidate. Hired also opens the new team member form in a second tab."}
      </div>
    </div>
  );
};

export default function CandidateDetail({ candidate, onBack, onUpdate, userRole }) {
  // App-wide admin convention (Manual.jsx, FitScorecards.jsx, Onboarding.jsx,
  // Licensing.jsx, PFA.jsx all use the same ["owner","manager"] check). Gates
  // the admin-only assessment breakdown expanders (Peter directive 2026-08-14).
  const isAdmin = ["owner", "manager"].includes(userRole);
  const { isPhone } = useViewport();
  const verdictThresh = useVerdictThresholds();
  const [detail, setDetail] = useState(candidate || {});
  const [savingSection, setSavingSection] = useState(null);
  // Which stage button is mid-write (null = idle). Drives the stepper's
  // saving state so a double-tap can't fire two writes.
  const [stageSaving, setStageSaving] = useState(null);
  // Moving to the Offer stage opens the offer letter form first — see changeStage.
  const [offerModalOpen, setOfferModalOpen] = useState(false);
  const [bestFit, setBestFit] = useState(null);
  const [probesGenerating, setProbesGenerating] = useState(false);
  const [probesError, setProbesError] = useState(null);
  const [planBuilding, setPlanBuilding] = useState(false);
  const [planError, setPlanError] = useState(null);
  // Newtworks v2 facet detail — {hypothesized_trait, facet_score, n_items_scored}
  // per facet, fetched fresh via RPC (item counts aren't stored on the flat
  // hiring_candidates columns). Only fetched for v2 candidates. Used to grey out
  // any facet with n_items_scored < 4 — the design floor since the 2026-08-05
  // aggressive trim (op-rule "Assessment aggressive trim 2026-08-05"): twelve
  // traits legitimately score from exactly 4 items, so the old < 5 guard
  // mislabeled valid on-design scores as "insufficient data".
  const [v2Facets, setV2Facets] = useState(null);
  // Facet percentiles vs typical adults — computed on read via
  // hiregauge_candidate_facet_percentiles, never stored. Step 8 frontend
  // work order (2026-08-07): facet display shows percentile, not raw score.
  const [v2Percentiles, setV2Percentiles] = useState(null);
  // Batch 0 / 0E — dual-reference facet display. items_reworded_after_norm
  // per facet (hiregauge_facet_norms.items_reworded_after_norm) tells the
  // renderer whether the published-norm percentile above is shifted low by
  // item neutralization. pool_position/pool_n/pool_percentile/pool_is_primary
  // come from hiregauge_candidate_pool_position, computed on read, never
  // stored — empty until the neutralization cutover marker is set AND the
  // pool has at least 2 completed post-cutover assessments for that facet.
  const [facetRewordedFlags, setFacetRewordedFlags] = useState(null);
  const [v2PoolPosition, setV2PoolPosition] = useState(null);
  // Newtworks v2 competency layer — full per-role detail (12 competencies with
  // tier/floor/adjusted + gates_fired/verdict_cap/hard_decline/churn_risk),
  // keyed by role_category. Only fetched for v2 candidates; replaces the old
  // assessment_all_competencies orchestrator for the v2 path (Step 8, 2026-08-03).
  const [v2RoleFits, setV2RoleFits] = useState(null);
  // Written screen (stint 5, "Part 2") answers — v2 candidates only. Two
  // plain queries (items + this candidate's responses) merged client-side
  // rather than a PostgREST embed, to avoid depending on the exact FK
  // constraint name between hiregauge_candidate_responses and
  // hiregauge_instrument_items.
  const [screenAnswers, setScreenAnswers] = useState(null);
  // Reference emails from hiring_candidate_references. Null = still loading,
  // [] = none received. openRefs tracks which bodies are expanded — plain UI
  // state, same as expandedLayer above, not a record view worth URL-persisting.
  const [refEmails, setRefEmails] = useState(null);
  const [refLoadError, setRefLoadError] = useState(false);
  const [openRefs, setOpenRefs] = useState({});
  const toggleRef = (id) => setOpenRefs((prev) => ({ ...prev, [id]: !prev[id] }));
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

  // Fetch full row on mount. `detail` starts as the (partial) card data passed
  // in from the pipeline list, so a silent failure here used to just leave the
  // page looking complete-but-thin with zero indication anything was missing —
  // same silent-swallow class as the Growth tab kanban bug (2026-08-05 sweep).
  const [detailError, setDetailError] = useState(false);
  const [detailRetryTick, setDetailRetryTick] = useState(0);
  useEffect(() => {
    if (!candidate?.id || !supabase) return;
    let cancelled = false;

    const fetchDetail = async (isRetry) => {
      if (!isRetry) setDetailError(false);
      const { data, error } = await supabase
        .from("v_hiring_candidates")
        .select("*")
        .eq("id", candidate.id)
        .maybeSingle();
      if (cancelled) return;
      if (error || !data) {
        console.error("Failed to load full candidate record:", error);
        if (!isRetry) { setTimeout(() => { if (!cancelled) fetchDetail(true); }, 1500); return; }
        setDetailError(true);
        return;
      }
      setDetail(data);
      setDetailError(false);
      // Fire-and-forget: heal this candidate's Kanban board scoring cache if
      // it's behind the current scoring version. No-ops server-side (touches
      // nothing) when already current -- see
      // hiregauge_refresh_candidate_cache_if_stale. This is a supplementary
      // safety net alongside the Kanban board's own hourly background
      // refresh: it catches candidates outside that refresh's active-pipeline
      // scope (e.g. reopening someone already declined) essentially for free,
      // since it's one candidate, not the whole pool.
      supabase.rpc("hiregauge_refresh_candidate_cache_if_stale", { p_candidate_id: candidate.id })
        .then(({ error: healError }) => {
          if (healError) console.error("Candidate scoring-cache heal failed:", healError);
        });
    };

    fetchDetail(false);
    return () => { cancelled = true; };
  }, [candidate?.id, detailRetryTick]);

  // v2 facet detail (item counts) — v2 and v2fc, but NOT the same RPC.
  // CORRECTION 2026-08-16 (same day as the widening above): my first pass
  // assumed compute_newtworks_v2_facets_as_row (Likert-only) would just
  // return nothing for a v2fc candidate and was harmless to call. Wrong --
  // v2fc candidates still have Stint 1 responses in the SAME section
  // ('newtworks_v2_personality'), including each facet's lone within-sitting
  // retest item. The Likert-only function picks that single stray response
  // up, reports n_items_scored=1 for that one facet, and the "insufficient
  // data" threshold below (< 4) then incorrectly hides an otherwise fully
  // valid forced-choice score. Caught live: Alvi Story's dutifulness showed
  // "insufficient data" despite a real, valid 5-item forced-choice read.
  // Fix: call the matching scoring function for whichever source this
  // candidate actually used.
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    const src = detail?.assessment_source;
    let cancelled = false;
    const rpcName = src === "v2fc" ? "compute_newtworks_v2fc_facets_as_row" : "compute_newtworks_v2_facets_as_row";
    const rpcArgs = src === "v2fc"
      ? { p_candidate_id: detail.id, p_sitting: 1 }
      : { p_candidate_id: detail.id, p_stint: null, p_sitting: 1 };
    supabase
      .rpc(rpcName, rpcArgs)
      .then(({ data, error }) => {
        if (cancelled || error) return;
        setV2Facets(Array.isArray(data) ? data : []);
      });
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // v2 facet percentiles vs typical adults — only for v2 candidates. Computed
  // on read via hiregauge_candidate_facet_percentiles, never stored (Step 8,
  // 2026-08-07).
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    setV2Percentiles(null);
    let cancelled = false;
    supabase
      .rpc("hiregauge_candidate_facet_percentiles", { p_candidate_id: detail.id })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        setV2Percentiles(Array.isArray(data) ? data : []);
      });
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // Batch 0 / 0E — items_reworded_after_norm per facet. Agency-wide, not
  // per-candidate, so it only needs to refetch when the agency does (i.e.
  // effectively once) — not keyed to detail.id.
  useEffect(() => {
    if (!supabase) return;
    let cancelled = false;
    supabase
      .from("hiregauge_facet_norms")
      .select("facet, items_reworded_after_norm")
      .eq("agency_id", AGENCY_ID)
      .then(({ data, error }) => {
        if (cancelled || error || !Array.isArray(data)) return;
        const byFacet = {};
        for (const r of data) byFacet[r.facet] = r.items_reworded_after_norm;
        setFacetRewordedFlags(byFacet);
      });
    return () => { cancelled = true; };
  }, []);

  // Batch 0 / 0E — applicant-pool position per facet, only for v2 candidates.
  // Returns zero rows for every facet until the neutralization cutover marker
  // is set (0C) and enough post-cutover assessments exist (0D thresholds).
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    setV2PoolPosition(null);
    let cancelled = false;
    supabase
      .rpc("hiregauge_candidate_pool_position", { p_candidate_id: detail.id })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        setV2PoolPosition(Array.isArray(data) ? data : []);
      });
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // v2 role fit + competency detail — v2 and v2fc. Replaces
  // assessment_all_competencies for the v2 path (Step 8, 2026-08-03); widened
  // to v2fc 2026-08-16 (same role-fit chain, see incident note above).
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    let cancelled = false;
    supabase
      .rpc("newtworks_all_role_fits", { p_assessment_id: detail.id })
      .then(({ data, error }) => {
        if (cancelled || error) return;
        setV2RoleFits(data || {});
      });
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // Written screen (stint 5, "Part 2") answers — v2 and v2fc (stint 5 is
  // shared, unaffected by which personality format stint 2 used).
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    let cancelled = false;
    (async () => {
      const [itemsRes, respRes] = await Promise.all([
        supabase
          .from("hiregauge_instrument_items")
          .select("id, item_number, item_text, answer_key")
          .eq("section", "newtworks_v2_screen")
          .order("item_number", { ascending: true }),
        supabase
          .from("hiregauge_candidate_responses")
          .select("item_id, response_label, response_value, is_correct, answered_at")
          .eq("candidate_id", detail.id),
      ]);
      if (cancelled) return;
      const items = itemsRes?.data;
      const responses = respRes?.data;
      if (itemsRes?.error || respRes?.error || !Array.isArray(items)) return;
      const byItem = {};
      for (const r of responses || []) byItem[r.item_id] = r;
      setScreenAnswers(items.map((it) => ({ ...it, response: byItem[it.id] || null })));
    })();
    return () => { cancelled = true; };
  }, [detail?.id, detail?.assessment_source]);

  // Reference emails. Pulls rows already linked to this candidate, plus any
  // unlinked row whose subject-line name matches this candidate — an unmatched
  // reference must never sit invisible just because the intake job's automatic
  // match missed it.
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    let cancelled = false;
    setRefEmails(null);
    setRefLoadError(false);
    setOpenRefs({});
    (async () => {
      const { data, error } = await supabase
        .from("hiring_candidate_references")
        .select("id, candidate_id, candidate_name_from_subject, reference_number, sender, received_at, subject, body")
        .eq("agency_id", AGENCY_ID)
        .or(`candidate_id.eq.${detail.id},candidate_id.is.null`);
      if (cancelled) return;
      if (error) {
        console.error("Failed to load reference emails:", error);
        setRefLoadError(true);
        return;
      }
      const norm = (s) => String(s || "").toLowerCase().replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
      const names = new Set(
        [detail.candidate_name, `${detail.first_name || ""} ${detail.last_name || ""}`]
          .map(norm).filter(Boolean)
      );
      const rows = (data || []).filter((r) =>
        r.candidate_id === detail.id || names.has(norm(r.candidate_name_from_subject))
      );
      rows.sort((a, b) => {
        const an = a.reference_number, bn = b.reference_number;
        if (an != null && bn != null && an !== bn) return an - bn;
        if (an != null && bn == null) return -1;
        if (an == null && bn != null) return 1;
        return String(a.received_at || "").localeCompare(String(b.received_at || ""));
      });
      setRefEmails(rows);
    })();
    return () => { cancelled = true; };
  }, [detail?.id, detail?.candidate_name, detail?.first_name, detail?.last_name]);

  // Best-fit role via RPC (graceful fallback if function missing)
  //
  // FIX 2026-08-06 (Peter directive): this effect had no `cancelled` guard and
  // never reset its own state when detail.id changed. Two bugs from that:
  // (1) stale-candidate flash — old candidate's verdict/score stayed on screen
  //     during the gap before the new candidate's fetch resolved;
  // (2) out-of-order race — if a PRIOR candidate's request was still in flight
  //     when you navigated to a NEW candidate, the old response could land
  //     after the new one and silently overwrite it — e.g. threeConstruct set
  //     to a prior candidate's "decline" verdict while the page shows a
  //     candidate whose real score/verdict is "hire". Reported live 2026-08-06:
  //     candidate showing an averaged ~84 score with a "decline" verdict —
  //     verdict_overall for that candidate returns "hire" when queried
  //     directly, confirming the displayed verdict was stale, not computed.
  useEffect(() => {
    if (!detail?.id || !supabase) return;
    let cancelled = false;
    // Clear all state this effect owns immediately on candidate change so a
    // slow-to-resolve fetch can't leave a previous candidate's verdict/score
    // visible against the new candidate's page.
    setBestFit(null);
    setThreeConstruct(null);
    // assessment_best_fit_role was rewired onto the v2 architecture
    // (*Ass Comp Build 2) and stays live for every candidate. The legacy
    // v1/CTS rules-narrative RPCs (assessment_all_competencies,
    // hiregauge_composite_recommendation, hiregauge_evaluate_candidate,
    // assessment_intelligence_composite, compute_newtworks_v1_traits_as_row)
    // and the "HireGauge Framework Read" panel they fed were dropped in the
    // 2026-08-13 CTS purge / 2026-08-16 version-separation cleanup — no
    // candidate page calls them anymore.
    supabase.rpc("assessment_best_fit_role", { p_assessment_id: detail.id })
      .then(({ data, error }) => { if (!cancelled && !error) setBestFit(data); })
      .catch(() => {});
    // Three-construct verdict: Capability/Character/Commitment per-layer verdicts +
    // pre-hire framework prediction + retrospective observation + calibration.
    supabase.rpc("verdict_overall", { p_candidate_id: detail.id })
      .then(({ data, error }) => {
        if (!cancelled && !error && Array.isArray(data) && data[0]) setThreeConstruct(data[0]);
      })
      .catch(() => {});
    return () => { cancelled = true; };
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

  // Move the candidate to another pipeline stage. Writes status +
  // status_updated_at, refetches the view row so every computed column on the
  // page stays in step, then tells the parent list to re-render. The parent's
  // updater is told the write already happened so it only syncs its own state
  // instead of writing the same row a second time.
  const changeStage = async (newStatus) => {
    if (!detail?.id || !newStatus || newStatus === detail.status) return;
    if (stageSaving) return;
    // Moving to Offer opens the offer letter form instead of writing the stage
    // straight away. The form captures the pay terms, fills in the stored
    // letter, and does the stage write itself when it saves.
    if (newStatus === "offer") { setOfferModalOpen(true); return; }
    // Moving to Hired opens the new team member form in a second tab with this
    // candidate's details already filled in. The tab is opened here, before the
    // first await, because browsers only allow a new window while the click that
    // asked for it is still being handled — opening it after the database write
    // comes back gets it blocked. If the write then fails we close it again.
    let hireTab = null;
    if (newStatus === "hired" && typeof window !== "undefined") {
      hireTab = window.open(`/team?tab=members&newhire=${encodeURIComponent(detail.id)}`, "_blank");
    }
    setStageSaving(newStatus);
    const nowIso = new Date().toISOString();
    const { error } = await supabase
      .from("hiring_candidates")
      .update({ status: newStatus, status_updated_at: nowIso })
      .eq("id", detail.id);
    if (error) {
      setStageSaving(null);
      try { if (hireTab && !hireTab.closed) hireTab.close(); } catch (e) { /* popup blocked — nothing to close */ }
      alert("Stage change failed: " + error.message);
      return;
    }
    if (newStatus === "hired" && !hireTab) {
      // The browser blocked the second tab. Say so plainly rather than leaving
      // the impression the form is waiting somewhere.
      alert("Moved to Hired. Your browser blocked the new tab — open Team › Members and use + Add member.");
    }
    const { data } = await supabase
      .from("v_hiring_candidates")
      .select("*")
      .eq("id", detail.id)
      .maybeSingle();
    setStageSaving(null);
    if (data) setDetail(data);
    else setDetail(prev => ({ ...prev, status: newStatus, status_updated_at: nowIso }));
    if (typeof onUpdate === "function") onUpdate(detail.id, newStatus, { alreadyPersisted: true });
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
    if (typeof onUpdate === "function") onUpdate(detail.id, "declined", { alreadyPersisted: true });
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

  // Invoke apply_interview_plan RPC (interview-bank-v1) -- builds off interview_questions
  // bank + trigger codes, writes custom_probes, force=false so it reuses a plan generated
  // in the last 24h instead of clobbering it.
  const buildInterviewPlan = async () => {
    if (!detail?.id || !supabase) return;
    setPlanBuilding(true);
    setPlanError(null);
    try {
      const { data, error } = await supabase.rpc("apply_interview_plan", {
        p_candidate_id: detail.id,
        p_target_minutes: 60,
        p_force: false,
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
      setPlanError(e?.message || String(e));
    } finally {
      setPlanBuilding(false);
    }
  };

  const displayName = [detail?.first_name, detail?.last_name].filter(Boolean).join(" ") || detail?.candidate_name || "Unknown Candidate";
  // Declined / former candidates sit outside the eight active stages. The
  // decline reason only makes sense while they are there — once they are put
  // back in the pipeline the stored reason stays on the row but stops showing.
  const isOffPipeline = !PIPELINE_STAGES.includes(detail?.status);

  return (
    <div>
      {/* Identity + nav — name + status pill on left, action buttons on right */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, flexWrap: "wrap" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
            <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900 }}>{displayName}</div>
            <div style={{ padding: "5px 12px", fontSize: 11, fontWeight: 600, color: STAGES[detail?.status]?.color || T.slate700, background: STAGES[detail?.status]?.bg || T.slate100, borderRadius: 12 }}>
              {stageLabel(detail?.status)}
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
        {detailError && (
          <div style={{ marginTop: 10, padding: "8px 12px", fontSize: 12, color: "#7B241C", background: "#FDEDEC", border: "1px solid #F5B7B1", borderRadius: 7, display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
            <span>Couldn't load the full record for this candidate — showing what's cached from the pipeline list.</span>
            <button onClick={() => setDetailRetryTick(t => t + 1)} style={{ padding: "4px 10px", fontSize: 11, fontWeight: 600, color: T.white, background: T.red, border: "none", borderRadius: 6, cursor: "pointer", flexShrink: 0 }}>Retry</button>
          </div>
        )}
        {((isOffPipeline && detail?.decline_reason) || detail?.assessment_date) && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
            {isOffPipeline && detail?.decline_reason && (<>Declined: {DECLINE_REASON_LABEL[detail.decline_reason] || detail.decline_reason} · </>)}
            Assessed {detail?.assessment_date || "—"}
          </div>
        )}
      </div>

      {/* Pipeline stage stepper — tap a stage to move this candidate. */}
      <StageStepper status={detail?.status} saving={stageSaving} onPick={changeStage} />

      {offerModalOpen && (
        <OfferLetterModal
          candidate={detail}
          onClose={() => setOfferModalOpen(false)}
          onSaved={async () => {
            setOfferModalOpen(false);
            const { data } = await supabase
              .from("v_hiring_candidates")
              .select("*")
              .eq("id", detail.id)
              .maybeSingle();
            if (data) setDetail(data);
            else setDetail(prev => ({ ...prev, status: "offer" }));
            if (typeof onUpdate === "function") onUpdate(detail.id, "offer", { alreadyPersisted: true });
          }}
        />
      )}

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
              // entirely. Every candidate — regardless of assessment_source /
              // version — sources the Assessment layer score the same way: the
              // selected role's fit_score in v2RoleFits. Candidates with no v2
              // role-fit data (old CTS-source candidates) simply show "—" here,
              // same as any other missing score (Peter directive 2026-08-16, no
              // version-conditional branching on this page).
              const matrixBf = Array.isArray(bestFit) && bestFit.length > 0 ? bestFit[0] : null;
              const matrixCurrentRole = selectedRole || matrixBf?.best_role || "sales_outbound";
              // v2 facet percentile lookup — hiregauge_candidate_facet_percentiles
              // (vs typical adults, computed on read, never stored); used for the
              // Commitment sub-score line below. Matches Migration E, which wraps
              // assessment_commitment's raw facet inputs in the same percentile
              // function. reversed=true mirrors the (100 - pct) reversal Migration E
              // applies to avoid_goal_orientation AFTER percentile conversion.
              const commitPctByFacet = {};
              if (Array.isArray(v2Percentiles)) {
                for (const r of v2Percentiles) commitPctByFacet[r.facet] = r.percentile;
              }
              const commitPct = (trait, reversed) => {
                const p = commitPctByFacet[trait];
                if (p == null) return "—";
                return reversed ? Math.round(100 - Number(p)) : Math.round(Number(p));
              };
              // Assessment layer total blends all three constructs (Capability, Character,
              // Commitment) — it used to read capability alone (the selected role's fit
              // score), which is why Character/Commitment never reached the Total column.
              // Capability stays role-aware (reads the selected role's fit score from
              // v2RoleFits, same as before); Character/Commitment are role-independent and
              // come straight off detail. Blend weights are read from meta.layer_weights_
              // within_construct — the same hiregauge_layer_composite_weights row the
              // DB-side verdict_assessment RPC uses for the assessment layer, so the two
              // can never drift apart. Fixed 2026-08-05.
              const assessmentCapForTotal = v2RoleFits ? v2RoleFits[matrixCurrentRole]?.fit_score ?? null : null;
              const assessmentChrForTotal = detail?.assessment_character ?? null;
              const assessmentComForTotal = detail?.assessment_commitment ?? null;
              const aLayerCapW = weights?.capability?.assessment;
              const aLayerChrW = weights?.character?.assessment;
              const aLayerComW = weights?.commitment?.assessment;
              let assessmentLayerScore = null;
              {
                let wsum = 0, sum = 0;
                if (assessmentCapForTotal != null && aLayerCapW != null) { sum += assessmentCapForTotal * aLayerCapW; wsum += aLayerCapW; }
                if (assessmentChrForTotal != null && aLayerChrW != null) { sum += assessmentChrForTotal * aLayerChrW; wsum += aLayerChrW; }
                if (assessmentComForTotal != null && aLayerComW != null) { sum += assessmentComForTotal * aLayerComW; wsum += aLayerComW; }
                assessmentLayerScore = wsum > 0 ? (sum / wsum) : (detail?.overall_score ?? null);
              }
              const layers = [
                { key: "resume",     label: "Resume",     score: threeConstruct.resume_score,     verdict: threeConstruct.resume_verdict },
                // Assessment layer sources composite/capability/character/commitment from v_hiring_candidates
                // (populated by role-fit click). Score is 0-100 like Resume. Verdict computed by layerVerdict.
                { key: "assessment", label: "Assessment", score: assessmentLayerScore, verdict: null },
                // Screen layer (5th scored layer, added 2026-08-13) — stint-5 free-text
                // scoring. No capability term (structurally absent — writing quality is
                // never scored). Score/verdict come straight off verdict_overall; the
                // generic cell-rendering branch below reads matrix.<construct>.screen,
                // which naturally renders the capability cell as an em-dash since
                // matrix.capability.screen is always null.
                { key: "screen",     label: "Screen",     score: threeConstruct.screen_score,     verdict: threeConstruct.screen_verdict },
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
                                        title="IPIP-sourced commitment facets: Ach = Achievement striving · Comp = Competitiveness · Prv = Prove-goal orientation · Lrn = Learning-goal orientation · Avd = Avoid-goal orientation (reversed before averaging) · Ent = Enterprising interest."
                                      >
                                        Ach {commitPct("achievement_striving")}
                                        {" · "}
                                        Comp {commitPct("competitiveness")}
                                        {" · "}
                                        Prv {commitPct("prove_goal_orientation")}
                                        {" · "}
                                        Lrn {commitPct("learning_goal_orientation")}
                                        {" · "}
                                        Avd(rev) {commitPct("avoid_goal_orientation", true)}
                                        {" · "}
                                        Ent {commitPct("enterprising")}
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
                                    detail, bestFit,
                                    selectedRole, setSelectedRole, T,
                                    v2Facets, v2Percentiles, v2RoleFits,
                                    facetRewordedFlags, v2PoolPosition,
                                    screenAnswers, isAdmin,
                                  })}
                                  {layer.key === "interview" && renderInterviewLayer({
                                    detail, T,
                                    updateAnswer, saveAnswers, savingAnswers, answersLastSavedAt,
                                    generateCustomProbes, probesGenerating, probesError,
                                    buildInterviewPlan, planBuilding, planError,
                                  })}
                                  {layer.key === "screen" && (
                                    <div>
                                      <div style={{ fontSize: 12, color: T.slate500, fontStyle: "italic", marginBottom: 10 }}>
                                        Screen layer scores the written stint-5 answers below for job-history
                                        candor, accountability, role-interest specificity, and challenge realism.
                                        No capability score — writing quality is never scored here.
                                      </div>
                                      {/* Written screen (stint 5, "Part 2") -- plain-language application
                                          questions moved in-app 2026-08-06. Displayed for read-only review;
                                          writing quality is never scored (Peter directive 2026-08-05 -- see
                                          Hiring Prep manual). Forced-choice gate items (comp structure,
                                          insurance-move) flag GATE FAILED when answer_key does not match;
                                          nothing here auto-declines the candidate. Moved here under the Screen
                                          expander (was previously under Assessment) per Peter directive
                                          2026-08-18. */}
                                      {Array.isArray(screenAnswers) && screenAnswers.length > 0 && (() => {
                                        // Per-item "why this score" tags — maps each stint-5 question to the
                                        // one signal it drives in screen_analysis.signals (set by the scoring
                                        // pass; see hiring_candidates.screen_analysis). Items 4 and 6 are
                                        // forced-choice compliance gates (already flagged via GATE FAILED,
                                        // not signal-scored); item 7 is a reference request, not scored.
                                        // Peter directive 2026-08-18: keep this to a small color tag, not
                                        // the full narrative.
                                        const SCREEN_SIGNAL_BY_ITEM = {
                                          1: { key: "job_history_candor", label: "Job history candor" },
                                          2: { key: "role_interest_specificity", label: "Role interest" },
                                          3: { key: "challenge_realism", label: "Challenge realism" },
                                          5: { key: "accountability", label: "Accountability" },
                                        };
                                        const signals = detail?.screen_analysis?.signals || null;
                                        const sigColor = (v) => v == null ? null : v >= 75 ? T.green : v >= 55 ? T.amber : T.red;
                                        return (
                                          <div>
                                            <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, color: T.slate600, marginBottom: 6 }}>
                                              Written Screen — Part 2
                                            </div>
                                            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                                              {screenAnswers.map((it) => {
                                                const r = it.response;
                                                const isGate = it.answer_key != null;
                                                const gateFailed = isGate && r && r.is_correct === false;
                                                const answered = r != null;
                                                const sig = SCREEN_SIGNAL_BY_ITEM[it.item_number];
                                                const sigVal = sig && signals ? signals[sig.key] : null;
                                                const sigCol = sigColor(sigVal);
                                                return (
                                                  <div key={it.id} style={{
                                                    padding: "8px 10px", background: gateFailed ? T.redLt : T.slate50,
                                                    borderRadius: 6, borderLeft: `3px solid ${gateFailed ? T.red : T.slate200}`,
                                                    boxSizing: "border-box",
                                                  }}>
                                                    <div style={{ fontSize: 11, fontWeight: 600, color: T.slate700, marginBottom: 3 }}>
                                                      {it.item_text}
                                                      {gateFailed && (
                                                        <span style={{ marginLeft: 6, fontSize: 10, fontWeight: 700, color: T.red }}>
                                                          GATE FAILED
                                                        </span>
                                                      )}
                                                    </div>
                                                    <div style={{
                                                      fontSize: 12, color: answered ? T.slate900 : T.slate400,
                                                      fontStyle: answered ? "normal" : "italic", whiteSpace: "pre-wrap",
                                                    }}>
                                                      {answered ? r.response_label : "Not yet answered"}
                                                    </div>
                                                    {answered && sig && sigVal != null && (
                                                      <div style={{ marginTop: 5 }}>
                                                        <span style={{
                                                          display: "inline-block", padding: "1px 6px", borderRadius: 3,
                                                          fontSize: 9, fontWeight: 700, textTransform: "uppercase",
                                                          letterSpacing: 0.3, color: T.white, background: sigCol,
                                                        }}>
                                                          {sig.label} · {Math.round(sigVal)}
                                                        </span>
                                                      </div>
                                                    )}
                                                  </div>
                                                );
                                              })}
                                            </div>
                                          </div>
                                        );
                                      })()}
                                    </div>
                                  )}
                                  {layer.key === "reference" && renderReferenceLayer({
                                    refEmails, refLoadError, openRefs, toggleRef, T, isPhone,
                                  })}
                                </td>
                              </tr>
                            )}
                          </Fragment>
                        );
                      })}
                      {/* Total row — per-construct weighted subtotals (Capability/Character/
                          Commitment) plus the overall blended score + verdict as the 4th
                          column. Used to be two rows (Subtotal + a separate full-width
                          Result row) — merged 2026-08-06 per Peter directive. Confidence
                          tag and @70/@75/@80 threshold previews dropped in the same pass —
                          not useful on this surface. */}
                      <tr style={{ borderTop: `2px solid ${T.slate200}`, background: T.slate50 }}>
                        <td style={{ ...rowLabelBase, background: T.slate100, fontWeight: 700 }}>Total</td>
                        {constructs.map((c) => (
                          <td key={c.key} style={{ padding: isPhone ? "6px 3px" : "10px", background: scoreBg(c.score), borderLeft: `3px solid ${scoreFg(c.score)}`, borderRight: `1px solid ${T.slate100}`, textAlign: "center" }}>
                            <div style={{ fontSize: subtotalFont, fontWeight: 800, color: c.score == null ? T.slate500 : T.slate900 }}>
                              {c.score != null ? Math.round(Number(c.score)) : "—"}
                            </div>
                          </td>
                        ))}
                        <td style={{ padding: isPhone ? "6px 3px" : "10px", background: threeConstruct.verdict ? verdictBg(threeConstruct.verdict) : scoreBg(threeConstruct.score_0_10), borderLeft: `3px solid ${threeConstruct.verdict ? verdictFg(threeConstruct.verdict) : scoreFg(threeConstruct.score_0_10)}`, textAlign: "center" }}>
                          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: isPhone ? 4 : 6, flexWrap: "wrap" }}>
                            <span style={{ fontSize: subtotalFont, fontWeight: 800, color: T.slate900 }}>
                              {threeConstruct.score_0_10 != null ? Math.round(Number(threeConstruct.score_0_10)) : "—"}
                            </span>
                            <span style={{ padding: isPhone ? "1px 4px" : "2px 6px", borderRadius: 3, fontSize: isPhone ? 8 : 9, fontWeight: 700, color: T.white, background: threeConstruct.verdict ? verdictFg(threeConstruct.verdict) : scoreFg(threeConstruct.score_0_10), textTransform: "uppercase", letterSpacing: 0.3 }}>
                              {(threeConstruct.verdict || "insufficient data").replace(/_/g, " ")}
                            </span>
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

      {/* Notes — free-text narrative (Claude's synthesis or manual notes) on
          hiring_candidates.notes. Renders for every candidate, regardless of
          assessment version — same field, same display, no gate. The legacy
          "HireGauge Framework Read" rules-narrative panel (fed by
          hiregauge_composite_recommendation + hiregauge_evaluate_candidate,
          gated to v1/CTS candidates only) was removed 2026-08-16: those RPCs
          were already dropped in the 2026-08-13 CTS purge, so the panel could
          never show real content again for anyone — permanent dead weight
          gated on version, the opposite of what this page should do. The v2
          role-fit + gate display in the Assessment layer above is the verdict
          surface now, for every candidate. */}
      {detail?.notes && detail.notes.trim().length > 0 && (
        <Section title="Notes">
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
        </Section>
      )}

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
