-- Update the two doc rows to reflect the research-aligned rule set
-- (multi-indicator convergence for reliability MODERATE, between-scale check
-- added, look-good cutoff tightened, convergence-HIGH for distortion).
UPDATE public.hiregauge_trait_documentation
SET construct_notes = 'Rating produced by compute_newtworks_v1_bands from signals in compute_newtworks_v1_distortion_signals and compute_newtworks_v1_reliability_per_candidate. LOW fires on any one strong indicator: same Likert answer 8+ times in a row OR overall Likert SD below 0.5 (Meade & Craig 2012); OR 5+ timed items averaging under 2 seconds each (Huang et al. 2012); OR fewer than 20 Likert items answered. MODERATE requires TWO OR MORE mild indicators converging (Curran 2016 multi-indicator careless-responding rule): (1) max same-answer run 5-7 (Meade & Craig 2012 secondary); (2) acquiescence — mean Likert response deviates more than 0.75 points from the scale midpoint (Podsakoff et al. 2003); (3) within-scale non-differentiation — 5 or more of 9 personality traits show within-trait SD below 0.4 (Curran 2016 majority-of-scales rule); (4) between-scale non-differentiation — SD across the 9 stored trait scores below 5 on the 0-100 scale (Ehrhart et al. 2009); (5) fewer than 50 Likert items answered — under 50% of typical expected count (Curran 2016 minimum-density direction). HIGH: 20+ items and neither LOW nor MODERATE fires.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND trait_name = 'reliability';

UPDATE public.hiregauge_trait_documentation
SET construct_notes = 'Rating produced by compute_newtworks_v1_bands from two signals. Fake-vocab signal (Paulhus et al. 2003 over-claiming technique): 2+ made-up words endorsed → high (bias ≥0.25); 1 → moderate; 0 → clean. Look-good signal (Booth-Kewley et al. 1992 impression-management cutoffs; gated at 10+ items per Sackett & Lievens 2008): score 75+ → high (+1.5 SD above normative mean); score 65-74 → moderate (+0.75 SD above normative mean); below 65 → clean. Under 10 items the look-good signal is silent. Combined: HIGH if either signal is high, OR if both signals fire at moderate simultaneously (Paulhus 2002 multi-indicator convergence). MODERATE: exactly one signal at moderate. LOW: both signals clean, or one clean and the other silent.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND trait_name = 'response_distortion';
