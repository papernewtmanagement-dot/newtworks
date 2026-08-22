INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'sincerity', 74.00, 14.75,
   'IPIP-HEXACO Sincerity',
   'Ashton, M. C., Lee, K., & Goldberg, L. R. (2007). The IPIP-HEXACO scales: An alternative, public-domain measure of the personality constructs in the HEXACO model. Personality and Individual Differences, 42(8), 1515-1526. Table 1.',
   'https://projects.ori.org/lrg/PDFs_papers/Ashton_Lee_Goldberg_2007_PAID.pdf',
   'Source: 10-item facet, N=411 Eugene-Springfield Community Sample (adults), value already reported as per-item mean on 1-5 scale: M=3.96, SD=0.59 (not sum-scored -- used directly per spec formula for per-item-mean sources). ref_mean=(3.96-1)/4*100=74.0, ref_sd=0.59/4*100=14.75.',
   'claude_grunt_build_2026-08-06'),
  ('126794dd-25ff-47d2-a436-724499733365', 'fairness', 83.00, 13.50,
   'IPIP-HEXACO Fairness',
   'Ashton, M. C., Lee, K., & Goldberg, L. R. (2007). The IPIP-HEXACO scales: An alternative, public-domain measure of the personality constructs in the HEXACO model. Personality and Individual Differences, 42(8), 1515-1526. Table 1.',
   'https://projects.ori.org/lrg/PDFs_papers/Ashton_Lee_Goldberg_2007_PAID.pdf',
   'Source: 10-item facet, N=411 Eugene-Springfield Community Sample (adults), per-item mean on 1-5 scale: M=4.32, SD=0.54. ref_mean=(4.32-1)/4*100=83.0, ref_sd=0.54/4*100=13.5.',
   'claude_grunt_build_2026-08-06'),
  ('126794dd-25ff-47d2-a436-724499733365', 'greed_avoidance', 64.25, 14.75,
   'IPIP-HEXACO Greed-Avoidance',
   'Ashton, M. C., Lee, K., & Goldberg, L. R. (2007). The IPIP-HEXACO scales: An alternative, public-domain measure of the personality constructs in the HEXACO model. Personality and Individual Differences, 42(8), 1515-1526. Table 1.',
   'https://projects.ori.org/lrg/PDFs_papers/Ashton_Lee_Goldberg_2007_PAID.pdf',
   'Source: 10-item facet, N=411 Eugene-Springfield Community Sample (adults), per-item mean on 1-5 scale: M=3.57, SD=0.59. ref_mean=(3.57-1)/4*100=64.25, ref_sd=0.59/4*100=14.75.',
   'claude_grunt_build_2026-08-06')
ON CONFLICT (agency_id, facet) DO NOTHING;

INSERT INTO public.alerts (agency_id, alert_type, severity, title, module_reference, is_resolved, message)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
   'HireGauge norm missing: prove_goal_orientation',
   'hiring_assessment', false,
   'Source confirmed as VandeWalle 1997, Educational and Psychological Measurement 57(6):995-1015, performance-prove subscale, matches item bank and catalog. Two genuine retrieval attempts made this session -- found reliability (alpha=.85, Sample C) and item content but not the paper''s own descriptive statistics table (means/SDs by subscale). Needs a direct fetch of the original paper''s Table for Sample C or D.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
   'HireGauge norm missing: avoid_goal_orientation',
   'hiring_assessment', false,
   'Source confirmed as VandeWalle 1997, Educational and Psychological Measurement 57(6):995-1015, performance-avoid subscale, matches item bank and catalog. Same retrieval attempts and same gap as prove_goal_orientation (see that alert) -- reliability found (alpha=.88), descriptive stats table not retrieved this session.');

UPDATE public.alerts
SET message = message || ' UPDATE 2026-08-06 (2nd session touching this facet): additional search attempted, still no descriptive-stats table for the original VandeWalle 1997 paper -- same gap as prove_goal_orientation and avoid_goal_orientation, filed same session.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND alert_type = 'hiregauge_norm_missing'
  AND title = 'HireGauge norm missing: learning_goal_orientation'
  AND is_resolved = false;
