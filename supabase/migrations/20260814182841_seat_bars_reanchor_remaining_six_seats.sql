-- Seat bars re-anchoring under pool-percentile scale (v5.2 side effect), continued.
-- Planning-thread decisions 2026-08-14, Peter approved (successor to *Ass Confirm).
-- Staircase preserves original relative tier ordering (retention_support lowest,
-- aspirant highest) while landing on floors that actually bind against the real
-- pool distribution (breakpoints at pool percentiles 9, 26, 51, 80 among n=31).
-- Ceilings untouched -- only the floor side broke under the rescale.

UPDATE hiregauge_role_ideal_ranges
SET intelligence_ideal_min = 27, updated_at = now(),
    updated_by = 'claude_planning_thread_2026-08-14',
    notes = notes || E'\n\n2026-08-14 RE-ANCHOR (v5.2 pool-percentile side effect): floor moved 55->27. ' ||
      'Preserves original modest lift over retention_support (25): catches same bottom-5 ' ||
      'tail at full penalty, plus applies a mild (~0.90x) discount to the pctl-26 cluster ' ||
      'that retention_support lets through clean -- differentiates the two tiers using real ' ||
      'math instead of an arbitrary point gap. Peter approved 2026-08-14.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND role_category IN ('sales_outbound','sales_inbound','retention_reception')
  AND role_level = 'default';

UPDATE hiregauge_role_ideal_ranges
SET intelligence_ideal_min = 35, updated_at = now(),
    updated_by = 'claude_planning_thread_2026-08-14',
    notes = notes || E'\n\n2026-08-14 RE-ANCHOR (v5.2 pool-percentile side effect): floor moved 58->35. ' ||
      'One tier above the 55-cluster (27): pctl-26 cluster now takes the full penalty ' ||
      '(0.5x) rather than the mild discount those seats apply, reflecting sales_in_book''s ' ||
      'top-of-medium-complexity cross-LOB demand. Peter approved 2026-08-14.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND role_category = 'sales_in_book'
  AND role_level = 'default';

UPDATE hiregauge_role_ideal_ranges
SET intelligence_ideal_min = 52, updated_at = now(),
    updated_by = 'claude_planning_thread_2026-08-14',
    notes = notes || E'\n\n2026-08-14 RE-ANCHOR (v5.2 pool-percentile side effect): floor moved 62->52. ' ||
      'Just above the pctl-51 pool cluster -- that cluster now takes a light (~0.95x) ' ||
      'discount instead of passing clean, reflecting retention_escalation''s standing as ' ||
      'the highest-complexity retention seat. Peter approved 2026-08-14.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND role_category = 'retention_escalation'
  AND role_level = 'default';

UPDATE hiregauge_role_ideal_ranges
SET intelligence_ideal_min = 55, updated_at = now(),
    updated_by = 'claude_planning_thread_2026-08-14',
    notes = notes || E'\n\n2026-08-14 RE-ANCHOR (v5.2 pool-percentile side effect): floor moved 70->55. ' ||
      'This seat''s own authored notes state the floor should signal "genuine ' ||
      'above-cohort-median cognitive capability." Under pool-percentile scale that intent ' ||
      'has a literal meaning -- the 50th percentile -- so 55 instantiates the original ' ||
      'design language directly rather than approximating it. pctl-51 cluster takes a real ' ||
      '(~0.80x) discount; highest floor of all seven seats, preserving aspirant''s standing ' ||
      'as the most demanding role. Peter approved 2026-08-14.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND role_category = 'aspirant'
  AND role_level = 'default';
