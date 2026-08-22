-- Documentation rows so a future session sees the mapping without hunting through code.
-- match_status='match' — the implementation matches the intent described here.
INSERT INTO public.hiregauge_trait_documentation
  (agency_id, trait_name, strategic_label, psychometric_construct, ipip_facet,
   interpretation_warning, construct_notes, match_status, created_at, updated_at)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'reliability',
   'Reliability',
   'Response engagement / data quality (careless-responding detection)',
   null,
   'Data quality index, not a personality trait. Describes how much to trust the rest of the assessment for this candidate. Does not describe the candidate.',
   'Rating produced by compute_newtworks_v1_bands from four signals in compute_newtworks_v1_distortion_signals: (1) straight-lining — same Likert answer 8+ times in a row OR overall Likert SD below 0.5 (Meade & Craig 2012); (2) speed-through — 5+ timed items answered under 2 seconds each on average (Huang et al. 2012); (3) low item count — fewer than 20 Likert items answered; (4) acquiescence — mean Likert response drifted more than 0.75 points from the scale midpoint. LOW fires on straight-lining OR speed-through OR <20 items. MODERATE fires on acquiescence OR 20-29 items. HIGH is 30+ items with none of the above.',
   'match',
   NOW(), NOW()),
  ('126794dd-25ff-47d2-a436-724499733365',
   'response_distortion',
   'Response Distortion',
   'Impression management + over-claiming (faking-good bias detection)',
   null,
   'Faking-good index, not a personality trait. Describes whether the candidate tried to look better than they are. Does not describe the candidate itself.',
   'Rating produced by compute_newtworks_v1_bands from two signals. Fake-vocab signal (count-based, works at any pool size): 2+ made-up words endorsed → high; 1 → moderate; 0 → clean. Paulhus et al. 2003 over-claiming technique. Look-good signal (gated at 10+ impression-management items per Sackett & Lievens 2008): score 75+ → high; 60-74 → moderate; below 60 → clean. Under 10 items, look-good is silent. Combined via worst-concern-wins: HIGH if either signal is high; MODERATE if either signal is moderate; LOW if both signals are clean or one is clean and the other silent.',
   'match',
   NOW(), NOW());
