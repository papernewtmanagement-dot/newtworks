// Shared hiring pipeline stage config — single source of truth for stage
// labels, colors and order. Both the Team pipeline board (src/modules/Team.jsx)
// and the candidate detail stepper (src/components/CandidateDetail.jsx) read
// from here so the two can never drift apart.
//
// Status values match the hiring_candidates.status check constraint:
// applied | assessment_sent | assessed | interview | meet_and_greet |
// offer | reference_check | hired | declined | former
// ("archived" was renamed to "former" on 2026-07-24, migration
// 20260724231037 — it is not a valid status and must not be reintroduced.)
//
// TWO THINGS CHANGED 2026-08-20, both Peter directives — do not "correct"
// either one back:
//   1. offer now comes BEFORE reference_check. The offer is written as
//      contingent on references clearing, so references are the last check
//      before Hired rather than a gate before the offer goes out.
//   2. The stage lost the word "Team" in both the label and the stored
//      value. The old stored value team_meet_and_greet was renamed to
//      meet_and_greet on the same date (migrations 20260821 step 1 and 2) —
//      the old spelling is no longer accepted and must not come back.
import { T } from "./theme.js";

export const STAGES = {
  applied:             { label: "Applied",         color: T.slate500, bg: T.slate100, order: 0 },
  assessment_sent:     { label: "Assessment Sent", color: T.slate600, bg: T.slate100, order: 1 },
  assessed:            { label: "Assessed",        color: T.slate500, bg: T.slate100, order: 2 },
  interview:           { label: "Interview",       color: T.amber,    bg: T.amberLt,  order: 3 },
  meet_and_greet:      { label: "Meet & Greet",    color: T.teal,     bg: T.tealLt,   order: 4 },
  offer:               { label: "Offer",           color: T.purple,   bg: T.purpleLt, order: 5 },
  reference_check:     { label: "Ref Check",       color: T.blue,     bg: T.blueLt,   order: 6 },
  hired:               { label: "Hired",           color: T.green,    bg: T.greenLt,  order: 7 },
  declined:            { label: "Declined",        color: T.red,      bg: T.redLt,    order: 8 },
  former:              { label: "Former",          color: T.slate500, bg: T.slate100, order: 9 },
};

// The active pipeline, in order. "declined" and "former" are deliberately
// excluded: declining has its own section on the detail page (it also writes
// decline_reason + final_decision), and "former" is set when a hire later
// leaves the team.
export const PIPELINE_STAGES = [
  "applied",
  "assessment_sent",
  "assessed",
  "interview",
  "meet_and_greet",
  "offer",
  "reference_check",
  "hired",
];

export const stageLabel = (status) => STAGES[status]?.label || status || "—";
