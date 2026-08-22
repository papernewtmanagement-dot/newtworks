INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'dutifulness', 77.00, 16.06,
   'IPIP-NEO-120 C3_Dutifulness',
   'Kajonius, P. J., & Johnson, J. A. (2019). Assessing the structure of the Five Factor Model of Personality (IPIP-NEO-120) in the public domain. Europe''s Journal of Psychology, 15(2), 260-275. Table A1.',
   'https://doi.org/10.5964/ejop.v15i2.1671',
   'Source: 4-item facet, N=320,128 combined US sample, raw M=16.32 SD=2.57 on 4-20 scale (1-5 Likert x4 items). item_mean=16.32/4=4.08, item_sd=2.57/4=0.6425. Converted per spec formula. Accepted imprecision: our facet uses 10 items vs source''s 4.',
   'claude_grunt_build_2026-08-06'),
  ('126794dd-25ff-47d2-a436-724499733365', 'achievement_striving', 75.38, 19.31,
   'IPIP-NEO-120 C4_Achievement',
   'Kajonius, P. J., & Johnson, J. A. (2019). Assessing the structure of the Five Factor Model of Personality (IPIP-NEO-120) in the public domain. Europe''s Journal of Psychology, 15(2), 260-275. Table A1.',
   'https://doi.org/10.5964/ejop.v15i2.1671',
   'Source: 4-item facet, N=320,128 combined US sample, raw M=16.06 SD=3.09 on 4-20 scale. item_mean=16.06/4=4.015, item_sd=3.09/4=0.7725. Converted per spec formula. Accepted imprecision: item-count mismatch vs our facet.',
   'claude_grunt_build_2026-08-06'),
  ('126794dd-25ff-47d2-a436-724499733365', 'self_discipline', 62.94, 19.75,
   'IPIP-NEO-120 C5_Self-discipline',
   'Kajonius, P. J., & Johnson, J. A. (2019). Assessing the structure of the Five Factor Model of Personality (IPIP-NEO-120) in the public domain. Europe''s Journal of Psychology, 15(2), 260-275. Table A1.',
   'https://doi.org/10.5964/ejop.v15i2.1671',
   'Source: 4-item facet, N=320,128 combined US sample, raw M=14.07 SD=3.16 on 4-20 scale. item_mean=14.07/4=3.5175, item_sd=3.16/4=0.79. Converted per spec formula. Accepted imprecision: item-count mismatch vs our facet.',
   'claude_grunt_build_2026-08-06'),
  ('126794dd-25ff-47d2-a436-724499733365', 'friendliness', 65.50, 22.50,
   'IPIP-NEO-120 E1_Friendliness',
   'Kajonius, P. J., & Johnson, J. A. (2019). Assessing the structure of the Five Factor Model of Personality (IPIP-NEO-120) in the public domain. Europe''s Journal of Psychology, 15(2), 260-275. Table A1.',
   'https://doi.org/10.5964/ejop.v15i2.1671',
   'Source: 4-item facet, N=320,128 combined US sample, raw M=14.48 SD=3.60 on 4-20 scale. item_mean=14.48/4=3.62, item_sd=3.60/4=0.90. Converted per spec formula. Accepted imprecision: item-count mismatch vs our facet.',
   'claude_grunt_build_2026-08-06')
ON CONFLICT (agency_id, facet) DO NOTHING;
