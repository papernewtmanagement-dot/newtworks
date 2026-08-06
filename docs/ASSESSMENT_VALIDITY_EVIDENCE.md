# HireGauge Assessment — Validity Evidence

This document compiles the design record behind the Newtworks candidate assessment
(HireGauge) from persistent_memory operational rules, session notes, and live
scoring-function comment blocks. It is a compilation, not new analysis — every
claim below is sourced to a specific named record, and every claim that could not
be sourced verbatim is listed in the GAPS appendix instead of asserted here.

## 1. Purpose & Scope

The assessment covers seven hiring seats: three sales roles (`sales_outbound`,
`sales_inbound`, `sales_in_book`), three retention roles (`retention_reception`,
`retention_escalation`, `retention_support`), and one leadership-track role
(`aspirant`). *(Source: operational_rule "HireGauge role_fit is the sole
role-scoring layer; competency layer is single-source" and operational_rule
"Newtworks competency layer — 12-competency library + role matrix
(confirmed 2026-08-02)".)*

The scoring design treats the instrument as an input to review rather than an
automated decision-maker: every gate in the system (integrity, critical-floor,
reasoning) caps a verdict at "consider" or raises a flag — none auto-declines a
candidate. The integrity gate's own design record states this explicitly: *"Never
an auto-decline... goes to human review, not this gate."* The recalibration
protocol (Section 9) states the same principle at the program level: defensibility
rests in part on "human review of every verdict."

## 2. Instrument Inventory

Live active item counts, by section and stint (queried from
`hiregauge_instrument_items`, live DB, 2026-08-06):

| Section | Stint | Active items |
|---|---|---|
| GMA (general mental ability) | 1 | 16 |
| Personality | 1 | 28 |
| Personality | 2 | 110 |
| Personality | 3 (adaptive/conditional pool) | 96 |
| SJT (situational judgement test) | 4 | 15 |

Unconditional load: 16 + 28 + 110 + 15 = **169 items**, matching the design
target recorded in operational_rule "Assessment aggressive trim 2026-08-05 — 227
to 169 items is DELIBERATE": *"NEW LOAD: 169 unconditional (28 integrity/vocab/IM
+ 16 GMA stint 1, 110 stint 2, 15 SJT) + 4/triggered facet conditional."* The
stint-3 pool (96 items) serves adaptively, up to 4 items per facet, only when a
trait lands in the 45–55 ambiguous band on stints 1–2.

Active facet list (29 distinct `hypothesized_trait` values, live DB): 24
personality facets — `achievement_striving`, `anger`, `anxiety`, `assertiveness`,
`avoid_goal_orientation`, `cautiousness`, `compassion`, `competitiveness`,
`cooperation`, `customer_orientation`, `dispositional_optimism`, `dutifulness`,
`emotional_stability`, `enterprising`, `fairness`, `friendliness`,
`greed_avoidance`, `learning_goal_orientation`, `political_skill_networking`,
`proactive_personality`, `prove_goal_orientation`, `self_discipline`,
`self_efficacy`, `sincerity`, `trust` — plus 5 SJT topics —
`sjt_compliance_licensing_boundary`, `sjt_compliance_outbound_consent`,
`sjt_composure_under_load`, `sjt_escalation_judgment`, `sjt_honesty_integrity`.

**Item provenance.** Per operational_rule "Newtworks v1 assessment v2 build —
public-domain source catalog + Path A principle," personality items draw
primarily from IPIP (International Personality Item Pool, Goldberg / Oregon
Research Institute, public domain), with named published sources for specific
facets: IPIP-HEXACO (Ashton, Lee & Goldberg 2007, *Personality and Individual
Differences* 42, 1515-1526) for Sincerity, Fairness, and Greed-Avoidance; LOT-R
(Scheier, Carver & Bridges 1994, *JPSP* 67(6), 1063-1078) for Dispositional
Optimism; the General Self-Efficacy Scale (Schwarzer & Jerusalem 1995) for
Self-Efficacy; Proactive Personality (Seibert, Kraimer & Crant 2001, *JAP* 86(6),
845-874); the Political Skill Inventory (Ferris et al. 2005, *Journal of
Management* 31(1), 126-152) for the Political Skill / Networking subscale; the
Customer Orientation Scale (Brown, Mowen, Donavan & Licata 2002, *Journal of
Marketing Research* 39(1), 110-119); and Holland RIASEC / O*NET Interest
Profiler (public domain) for Enterprising.

Interim cognitive items (per session note "2026-08-01 — v2 assessment session
5/5") replaced un-sourced legacy math/problem-solving items with cited
public-domain items: 3 CRT (Frederick 2005), 4 CRT-2 (Thomson & Oppenheimer
2016), 4 BNT (Cokely et al. 2012), 3 Schwartz et al. 1997, and 4 Weller ANS 2013
— explicitly not labeled ICAR per Peter's directive, since full ICAR-16 access
was still pending registration approval at that time.

## 3. Competency Model

The scoring architecture is a four-level hierarchy, per operational_rule
"HireGauge role_fit is the sole role-scoring layer" (2026-08-04 addendum):

> level 1 TRAIT — one measured thing from items (dutifulness, orderliness).
> level 2 TRAIT TOTAL — several traits added up (e.g. conscientiousness). A
> READING on the candidate page. Never an input to role fit.
> level 3 COMPETENCY — a job behaviour built from ~4 trait/test inputs
> (accuracy_procedural_discipline). SCORED, weighted and floored per seat.
> level 4 ROLE FIT — the competencies weighted per seat.

Thirteen competencies feed role fit (12 confirmed 2026-08-02, GMA added as the
13th on 2026-08-05):

1. `drive_work_intensity` — achievement_striving, self_discipline, proactive_personality, enterprising
2. `persuasive_influence` — assertiveness, political_skill_networking, self_efficacy, enterprising
3. `rapport_building` — friendliness, political_skill_networking, compassion, trust
4. `needs_discovery` — customer_orientation, compassion, cooperation, gma_total
5. `resilience_under_rejection` — emotional_stability, anxiety (rev), dispositional_optimism, self_efficacy
6. `composure_under_pressure` — anger (rev), anxiety (rev), emotional_stability, sjt_composure_under_load
7. `accuracy_procedural_discipline` — dutifulness, cautiousness, self_discipline, gma_total
8. `rule_compliance_adherence` — dutifulness, cautiousness, sjt_compliance_licensing_boundary, sjt_compliance_outbound_consent
9. `integrity` — sincerity, fairness, greed_avoidance, sjt_honesty_integrity
10. `judgment_escalation` — sjt_escalation_judgment, cautiousness, dutifulness, gma_total
11. `coachability_team_contribution` — cooperation, trust, compassion, anger (rev)
12. `autonomy_ownership` — proactive_personality, self_efficacy, enterprising, achievement_striving
13. `gma` — added 2026-08-05 as a 13th weighted role-fit component (session note
    "2026-08-05 — Assessment accuracy sprint"), weighted per role: critical for
    aspirant; important for the three sales roles and retention_escalation;
    supporting for retention_reception and retention_support.

All 13 competencies are computed and displayed for every candidate regardless of
seat; only weights vary by role.

## 4. Role Weight Matrix

All 91 rows of `hiregauge_competency_weights` (13 competencies × 7 roles), live
DB. Weight 3 = critical (hard floor applies), 2 = important, 1 = supporting (no
hard floor).

| Competency | sales_outbound | sales_inbound | sales_in_book | retention_escalation | retention_reception | retention_support | aspirant |
|---|---|---|---|---|---|---|---|
| accuracy_procedural_discipline | 1 (S) | 2 (I) | 2 (I) | 2 (I) | 3 (C) | 3 (C) | 2 (I) |
| autonomy_ownership | 1 (S) | 1 (S) | 1 (S) | 1 (S) | 1 (S) | 1 (S) | 3 (C) |
| coachability_team_contribution | 1 (S) | 1 (S) | 1 (S) | 1 (S) | 2 (I) | 2 (I) | 2 (I) |
| composure_under_pressure | 1 (S) | 1 (S) | 1 (S) | 3 (C) | 3 (C) | 1 (S) | 2 (I) |
| drive_work_intensity | 3 (C) | 2 (I) | 2 (I) | 1 (S) | 1 (S) | 1 (S) | 3 (C) |
| gma | 2 (I) | 2 (I) | 2 (I) | 2 (I) | 1 (S) | 1 (S) | 3 (C) |
| integrity | 2 (I) | 2 (I) | 2 (I) | 2 (I) | 2 (I) | 2 (I) | 3 (C) |
| judgment_escalation | 1 (S) | 1 (S) | 2 (I) | 3 (C) | 2 (I) | 2 (I) | 3 (C) |
| needs_discovery | 2 (I) | 3 (C) | 3 (C) | 2 (I) | 2 (I) | 1 (S) | 2 (I) |
| persuasive_influence | 3 (C) | 3 (C) | 2 (I) | 1 (S) | 1 (S) | 1 (S) | 2 (I) |
| rapport_building | 3 (C) | 3 (C) | 2 (I) | 2 (I) | 3 (C) | 1 (S) | 2 (I) |
| resilience_under_rejection | 3 (C) | 1 (S) | 1 (S) | 1 (S) | 1 (S) | 1 (S) | 2 (I) |
| rule_compliance_adherence | 2 (I) | 2 (I) | 3 (C) | 3 (C) | 2 (I) | 3 (C) | 2 (I) |

## 5. Floors & Gates

**21 per-role critical floors**, set 2026-08-02 (operational_rule "Newtworks
competency floors — 21 per-role critical floors + rationale"), live DB (rows
where `role_category IS NOT NULL`):

| Role | Competency | Floor |
|---|---|---|
| sales_outbound | drive_work_intensity | 45 |
| sales_outbound | persuasive_influence | 45 |
| sales_outbound | rapport_building | 45 |
| sales_outbound | resilience_under_rejection | 45 |
| sales_inbound | persuasive_influence | 45 |
| sales_inbound | rapport_building | 45 |
| sales_inbound | needs_discovery | 55 |
| sales_in_book | needs_discovery | 55 |
| sales_in_book | rule_compliance_adherence | 55 |
| retention_escalation | composure_under_pressure | 50 |
| retention_escalation | rule_compliance_adherence | 55 |
| retention_escalation | judgment_escalation | 55 |
| retention_reception | rapport_building | 45 |
| retention_reception | composure_under_pressure | 50 |
| retention_reception | accuracy_procedural_discipline | 55 |
| retention_support | accuracy_procedural_discipline | 55 |
| retention_support | rule_compliance_adherence | 55 |
| aspirant | drive_work_intensity | 50 |
| aspirant | integrity | 55 |
| aspirant | judgment_escalation | 60 |
| aspirant | autonomy_ownership | 50 |

**Tier rationale** (same operational_rule): competencies are unit-weighted means
of 0–100 normalized inputs, so the Likert midpoint lands on 50. Three tiers: 45
for pure self-report personality composites, 50 for personality+scenario blends,
55 for cognitive/procedural/compliance hybrids. Aspirant carries +5 on all four
of its criticals — "highest bar, longest commitment, hardest reversal." Floors
sit below what applicant self-report distributions would suggest, because
self-report runs upward (candidates endorse desirable traits) and floors are
compared against the faking-good-dampened value.

**2026-08-05 supersession** (same record): the original "STILL OPEN" global
integrity DECLINE floor paragraph is stale. The gate was rebuilt as
`_newtworks_integrity_decline_gate` in shadow mode per Peter's 2026-08-03
directive — it never hard-declines live. `hiregauge_competency_floors` is not
consulted for this gate; its four thresholds are constants inside the function.
Its full comment block (pulled live via `pg_get_functiondef`, 2026-08-06) is the
design record:

> SHADOW MODE per Peter directive 2026-08-03. This gate NEVER hard-declines
> live — integrity self-report validity is contested, not settled (Ones,
> Viswesvaran & Schmidt 1993: .41 vs supervisor ratings, 665 coefficients;
> Van Iddekinge, Roth, Raymark & Odle-Dusseau 2012 JAP 97(3) 499-530 redid it
> and got .15/.18 corrected; three rebuttals + Sackett & Schmitt 2012 JAP 97(3)
> 550-556 in the same issue, unresolved). Their own moderators point the wrong
> way for a homemade instrument scored against future real outcomes: .27
> publisher-authored vs .12 non-publisher; .42 self-reported misconduct vs .11
> other-reported / .15 employment-record misconduct. Our three self-report
> facets (sincerity, fairness, greed_avoidance) are also the most-faked item
> type in selection — applicant scores compress near the top, so low scorers
> are disproportionately the candid and the careless, not the dishonest.
>
> ARCHITECTURE FIX vs the prior version of this function: compares the RAW
> (undampened) self-report composite to the floor, NOT
> newtworks_competency_integrity's dampened+reliability-shrunk 'adjusted'
> value. Ellingson, Sackett & Hough 1999 (JAP 84 155-166): social-desirability
> corrections do not recover an individual's honest score — later reviews
> found they work at group level but not individual level and do not improve
> prediction. Dampening stays in place for DISPLAY and the compensatory
> role_fit average (newtworks_competency_integrity, untouched by this
> migration) — it must never feed this gate.
>
> CONJUNCTIVE GATE — all four conditions required for even the shadow "would
> decline" record:
>   1. RAW self-report composite (mean of sincerity/fairness/greed_avoidance,
>      not run through the competency-layer dampen+shrink) < 40.
>   2. sjt_honesty_integrity component below its own floor — the
>      contextualised scenario measure, hardest to fake, and per Sackett et
>      al. 2022 contextualised measures show far more stable validity than
>      decontextualised self-report. Floor set at 50% (2 of 4 items) —
>      PROVISIONAL, a build-session judgment call (no published norms exist
>      for a homemade 4-item scenario set), watch and revisit alongside the
>      raw-composite floor at N=25-30.
>   3. Careless-responding / reliability check CLEAN (reliability='high' AND
>      zero methods fired). A low score from a careless responder is a
>      measurement failure, not a red flag — goes to human review, not this
>      gate.
>   4. Faking-good NOT flagged (impression_management_band='typical'). A
>      detected faker's low score is also a measurement failure, not a red
>      flag.
>
> LIVE BEHAVIOUR (the only thing this gate does today): when all four
> conditions hold, cap verdict at 'consider' + set a visible integrity flag —
> same soft treatment as a critical-floor breach. Never an auto-decline.
> 'fired' stays permanently false (no consumer should ever treat this gate as
> a hard-decline source) — 'live_soft_flag' is the real live signal, and
> 'shadow_would_decline' is the recorded-but-inactive full-strength result for
> Peter to review once 25-30 real candidates have been scored. Flipping this
> gate to an actual decline is Peter's call, not a build decision.

**Reasoning gate posture** (session note "2026-08-05 — Assessment accuracy
sprint"): the reasoning (GMA) gate was re-anchored to a provisional floor of
62.5 — chance level plus 2 standard deviations on the 16-item bank — with the
ceiling/churn-risk side held neutral until n≥30 real candidates exist. Per-role
design values remain preserved in `hiregauge_role_ideal_ranges` and are echoed
in the gate detail output; this fix addressed a scale-mismatch finding from an
earlier accuracy check.

## 6. Functional-Form Decisions

**Additive GMA.** The reasoning (GMA) score enters role-fit competencies
additively, never as a multiplier — resolved 2026-08-02 after Peter asked for
the research to be double-checked (operational_rule "Newtworks competency layer
— 12-competency library + role matrix"). The multiplicative
"performance = ability × motivation" model was tested directly and rejected:
Van Iddekinge, Aguinis, Mackey & DeOrtentiis 2018 (*Journal of Management* 44,
249-279) found additive effects account for ~91% of explained variance vs ~9%
for the interaction term, with the interaction non-significant in 90% of
follow-up analyses. Brown, Wai & Chabris 2021 (*Perspectives on Psychological
Science* 16(6), 1337-1359; N=48,558, 4 longitudinal cohorts) found no support
for a performance downside at high ability and no threshold effect. Coward &
Sackett 1990 (*J Appl Psychol* 75, 297-300) is the correctly-attributed source
for ability-performance linearity (replacing a prior misattribution to "Kane
1998"). Per-role floor becomes a gate (below floor caps verdict at "consider"),
not a score penalty; per-role ceiling becomes a churn-risk flag displayed beside
the score, not a score reduction — since the ceiling literature (Ganzach 1998;
Maltarich, Nyberg & Reilly 2010) concerns retention/satisfaction, not
performance.

**Unit weights, with two named double-weight exceptions.** Competency scores
are unit-weighted means of normalized (0–100) inputs — no fitted coefficients,
per operational_rule "Newtworks competency layer — 12-competency library":
"the old LASSO coefficients were fits to vendor report output and cannot
survive vendor retirement in any form. Simple IS more accurate here (Wainer
1976; Dawes 1979)." Exactly two double weights are permitted, each with a named
citation in the function docstring: `proactive_personality` in
`autonomy_ownership` (Fuller & Marler 2009, *J Vocational Behavior* 75,
329-345 — proactive personality predicts supervisor-rated performance better
than any single Big Five factor or all five combined), and
`sjt_honesty_integrity` in `integrity` (Sackett et al. 2022 — contextualised
/at-work personality shows near-zero variation in predictive validity vs
decontextualised self-report).

**Facet-level, not domain-level, measurement.** Competency inputs are
individual personality facets (e.g. `dutifulness`, `cautiousness`), not broad
Big Five domains — per Dudley, Orvis, Lebiecki & Cortina 2006 (*J Appl Psychol*
91(1), 40-57), cited in operational_rule "Newtworks competency layer": narrow
conscientiousness facets add validity over the broad factor. The 2026-08-05
accuracy-sprint note restates the same ruling for conscientiousness
specifically: it "stays as its 4 facets inside 4 competencies... a broad
conscientiousness competency would double-count."

**GMA: single total score is the decision input.** Per operational_rule
"Assessment section names are GMA and SJT — do not rename them": GMA stores
four subtest accuracies (pattern, numerical, deductive, verbal) for
diagnostics, but only `gma_total_accuracy` is a decision input — "the general
factor carries the prediction, subtest profiles add nearly nothing" (Ree,
Earles & Teachout 1994; Schmidt & Hunter 1998; Sackett et al. 2022).

## 7. Dual-Path Policy

Per operational_rule "Assessment scoring is DUAL-PATH by standing instruction —
serving is single-path": every candidate served a new assessment link gets the
current instrument — no per-candidate switch, no legacy fallback. But scoring
is dual-path: the 53 candidates who completed the old (CTS-derived) instrument
keep scoring on the old functions permanently — they are not legacy debris to
be cleaned up, and retiring their scoring path is never implied by the
single-serving rule. Old-path marker: `deadline_motivation IS NOT NULL`.
New-path marker: `achievement_striving IS NOT NULL`. `assertiveness` and
`compassion` serve both instruments and must never be used as a path marker.

## 8. Freeze & Versioning Policy

Per session note "2026-08-04 — Go-live plan: assessment ruled BUILD-COMPLETE":
the instrument is **frozen from first real completion** — any item, threshold,
or weight change thereafter is a formal versioning event, never a routine
tweak. A *real* completion is one with `hiring_candidates.is_test_candidate
= false` (column added 2026-08-06); internal smoke-test rows — owner/family
walkthroughs — carry `is_test_candidate = true` and neither trigger the freeze
nor count toward any calibration N in Section 9. This guard is carried forward
into every subsequent handoff's do-not list.

## 9. Monitoring & Recalibration Protocol

Pasted verbatim, source: this handoff's own governing text (Task instructions,
2026-08-05/06):

---
Owner: open_questions umbrella tracker 12ba414d. Every threshold in this
instrument was set before live data existed — each is a prior, not a
calibration. Nothing below authorizes changing weights, items, or thresholds
outside a formal versioning event.
- At 15 completed real assessments: item-statistics pass — per-item response
  distributions, item-total correlations within each facet, response-speed
  distributions, retest-pair divergence rates, survivor-selection review per
  the aggressive-trim record. Output is a report; no changes without
  main-thread approval.
- At 25-30: revalidate the three stint-1 exit gates, faking-good bands, and
  reliability composite; the 21 critical floors and tier scheme (failure modes:
  nearly every candidate capped at consider = floors too high; no gate ever
  fires = floors inert); the integrity shadow gate (review shadow_would_decline
  records — flipping it to a live decline is the owner's call alone); and the
  provisional 50-percent scenario-integrity floor.
- At 30: decide reasoning ceiling/churn activation (currently neutral) and
  calibrate stint-3 expansion triggers (open_questions 52220bd5).
- At 5 hires with 90+ days tenure: direction-only comparison of hired
  candidates' role-fit scores against manager performance ratings.
  Direction-only means: check the ordering points the right way; do not refit
  weights — fixed rational weights outperform weights fitted to samples this
  small (Dawes 1979), and mechanical combination of scores is preserved
  (Kuncel, Klieger, Connelly & Ones 2013).
- Adverse-impact statistics: not computed, by policy. Agency headcount is
  below the 15-employee threshold at which the federal and Texas
  employment-discrimination statutes attach, no demographic data is collected,
  and at this volume the statistics would be noise. Defensibility rests on:
  documented job-analysis-based weights, published-research grounding,
  identical mechanical scoring for every candidate, and human review of every
  verdict. Revisit only if the agency approaches 15 employees.
---

## 10. GAPS Appendix

**(a) Claims that could not be sourced verbatim from a named record:**

- Section 1's framing that the assessment is explicitly "one screening input"
  is not a verbatim phrase in operational_rules #4 or #8 (the two sources this
  outline named for that section). It is inferred from the gate architecture
  (every gate caps or flags, none auto-declines) and from the "human review of
  every verdict" line in the Section 9 monitoring block, which is a different
  source than #4/#8.
- The outline for Section 6 called for a bullet on "SJT single composite." The
  live design record does not support this: the go-live session note states
  "all 21 facets + 5 SJT topics consumed," and the competency-input list
  (Section 3) shows five separate SJT topic scores (`sjt_composure_under_load`,
  `sjt_compliance_licensing_boundary`, `sjt_compliance_outbound_consent`,
  `sjt_escalation_judgment`, `sjt_honesty_integrity`) feeding five *different*
  competencies — not one combined SJT composite. This claim was omitted from
  Section 6 rather than asserted; flagging the mismatch here per instructions.

**(b) Record-vs-live-DB mismatches found:**

- None found. Stop-gate queries, item counts, facet counts, weight-row counts
  (91), and floor-row counts (21) all matched their governing records exactly
  on the 2026-08-06 live-DB pull.

**(c) The 10 impression-management items, extracted verbatim from
`hiregauge_instrument_items` — source VERIFIED 2026-08-06 by the main thread;
see the verification note below the table:**

| Item # | Text | Reverse-coded |
|---|---|---|
| 19 | "I return extra change when a cashier makes a mistake." | false |
| 301 | "I believe there is never an excuse for lying." | false |
| 302 | "I easily resist temptations." | false |
| 303 | "I have sometimes told a lie." | true |
| 304 | "I am not always what I appear to be." | true |
| 305 | "I am likely to show off if I get the chance." | true |
| 306 | "I would never take things that aren't mine." | false |
| 307 | "I always admit it when I make a mistake." | false |
| 309 | "I use swear words." | true |
| 310 | "I don't always practice what I preach." | true |

**Source verification (2026-08-06, main thread):** all 10 items are drawn from
the **IPIP Impression Management scale** — the International Personality Item
Pool's public-domain analog of the Balanced Inventory of Desirable Responding
(BIDR) impression-management scale (Paulhus, 1991) — published at
`ipip.ori.org/newSingleConstructsKey.htm` with a reported internal-consistency
alpha of .82 for the full 20-item scale. Newtworks uses a balanced half-set: 5
of IPIP's 10 positive-keyed items (19, 301, 302, 306, 307) and 5 of its 10
negative-keyed items (303, 304, 305, 309, 310); keying direction matches the
IPIP key on all 10. Items are presented with an added "I" pronoun and terminal
punctuation (IPIP stems are pronoun-less fragments; IPIP explicitly permits
editing item wording). One deliberate wording deviation: item 303 shortens the
IPIP stem "Have sometimes had to tell a lie" to "I have sometimes told a lie"
(owner decision 2026-08-05, rationale preserved in the item's notes column).
Item 19's sentence appears in both the IPIP-HEXACO Fairness key and the IPIP
Impression Management key, which is why it is legitimately scored on both
(fairness home trait + impression-management extra trait). This closes the
source-verification gap flagged at file creation.
