-- Seed hiregauge_facet_norms for 'competitiveness' -- previously a parked
-- facet with no norm (percentile always null). Peter directive 2026-08-13:
-- find a legitimately-cited comparable scale rather than leaving it parked.
-- Source: Houston, Harris, McIntire & Francis (2002) Revised Competitiveness
-- Index, 14-item 5-point Likert, format-matched to our own 5-item facet.
-- See notes column for full mean/SD conversion math and caveats.

INSERT INTO hiregauge_facet_norms (
  agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation,
  retrieved_from, notes, updated_at, updated_by, items_reworded_after_norm
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'competitiveness',
  61.59,
  17.82,
  '14-item Revised Competitiveness Index (RCI), 5-point Likert scale (1=strongly disagree..5=strongly agree) -- FORMAT-MATCHED to our 5-point item bank',
  'Houston, J. M., Harris, P. B., McIntire, S., & Francis, D. (2002). Revising the Competitiveness Index Using Factor Analysis. Psychological Reports, 90(1), 31-34. https://doi.org/10.2466/pr0.2002.90.1.31',
  'https://journals.sagepub.com/doi/10.2466/pr0.2002.90.1.31 (abstract + reported M/SD); corroborated via ResearchGate PDF preview and PubMed abstract (PMID 11899003)',
  'Total-scale M=48.49, SD=9.98 across 14 items (5-pt Likert, sum range 14-70), N=213 undergraduates. item_mean=48.49/14=3.4636, item_sd=9.98/14=0.7129 on a 1-5 scale. Converted per spec formula: ref_mean_0_100=(item_mean-1)/4*100=61.59, ref_sd_0_100=item_sd/4*100=17.82. This is the revised, factor-analyzed successor to the original 20-item true-false Competitiveness Index (Smither & Houston 1992); the revision exists specifically because the original format did not match a graded response scale -- same rationale already applied to the enterprising row (Rounds et al. 2016 superseding a paper-and-pencil count-format source). Population/format caveat: N=213 college undergraduates, not a general working-adult sample -- same class of caveat already accepted on the prove_goal_orientation row (translated-instrument, non-US-adult population) and treated as accepted imprecision rather than a blocker. Two correlated factors underlie the total (Enjoyment of Competition, Contentiousness); our 5-item facet does not split those, so the norm is applied against the combined 14-item total, consistent with how our facet was built as a single undifferentiated competitiveness measure. UPGRADE CANDIDATE: a general-population (non-student) M/SD for the RCI specifically, if one is ever published with a readable table.',
  NOW(),
  'claude_conversation',
  false
)
ON CONFLICT DO NOTHING;
