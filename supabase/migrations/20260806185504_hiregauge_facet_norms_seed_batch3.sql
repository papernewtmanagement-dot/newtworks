INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'assertiveness', 66.00, 21.44,
   'IPIP-NEO-120 E3_Assertive',
   'Kajonius, P. J., & Johnson, J. A. (2019). Assessing the structure of the Five Factor Model of Personality (IPIP-NEO-120) in the public domain. Europe''s Journal of Psychology, 15(2), 260-275. Table A1.',
   'https://doi.org/10.5964/ejop.v15i2.1671',
   'Source: 4-item facet, N=320,128 combined US sample, raw M=14.56 SD=3.43 on 4-20 scale. item_mean=14.56/4=3.64, item_sd=3.43/4=0.8575. Converted per spec formula. Accepted imprecision: item-count mismatch vs our facet (11 items).',
   'claude_grunt_build_2026-08-06'),
  ('126794dd-25ff-47d2-a436-724499733365', 'self_efficacy', 65.17, 17.73,
   'General Self-Efficacy Scale (GSE), Schwarzer & Jerusalem 1995',
   'Scholz, U., Gutierrez-Dona, B., Sud, S., & Schwarzer, R. (2002). Is general self-efficacy a universal construct? Psychometric findings from 25 countries. European Journal of Psychological Assessment, 18(3), 242-251.',
   'https://www.testable.org/scale/gse-generalized-self-efficacy-scale',
   'Source: 10-item scale, N=19,120 combined sample across 25 countries, raw M=29.55 SD=5.32 on 10-40 scale (1-4 Likert x10 items). item_mean=29.55/10=2.955, item_sd=5.32/10=0.532. ref_mean=(2.955-1)/3*100=65.1667, ref_sd=0.532/3*100=17.7333. Note: source scale is 1-4, our item bank now runs 1-5 (2026-08-05 standardization) — conversion formula uses OUR facet''s scale_max (5) is NOT applied here; this row stores the SOURCE-scale-derived 0-100 position, which is scale-invariant by construction (item position is already normalized 0-100 regardless of original Likert width). No further adjustment needed.',
   'claude_grunt_build_2026-08-06')
ON CONFLICT (agency_id, facet) DO NOTHING;

INSERT INTO public.alerts (agency_id, alert_type, severity, title, module_reference, is_resolved, message)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
   'HireGauge norm missing: compassion',
   'hiring_assessment', false,
   'HireGauge norms seed: no row inserted for facet "compassion". Item bank notes mark its source as "IPIP Warmth" — this is the SAME underlying facet as "friendliness" (IPIP-NEO-120 E1, which Johnson 2014 renamed from the original NEO-PI-R "Warmth" label to "Friendliness"; confirmed via Grokipedia IPIP summary showing E1/Warmth example item "Make friends easily", identical example used for E1_Friendliness in Kajonius & Johnson 2019). R2 bars reusing another facet''s norm numbers. Needs Peter''s call: either compassion and friendliness are genuinely meant to share one instrument (in which case the norm can be copied deliberately, not "reused" by omission), or compassion''s items should map to a different published scale (e.g. HEXACO Sympathy/A6, or a distinct instrument) — item-bank review needed, not a norms-lookup problem.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
   'HireGauge norm missing: customer_orientation',
   'hiring_assessment', false,
   'HireGauge norms seed: no row inserted for facet "customer_orientation". persistent_memory catalog names Brown, Mowen, Donavan & Licata 2002 (12-item CO scale) as the source, but the live item bank (hiregauge_instrument_items) shows the actual items are the 24-item Saxe & Weitz 1982 SOCO scale (items 85-108) PLUS a separate 10-item SOCO short form from Periatt, LeMay & Chakrabarty 2004 (items 365-374) — a different instrument than the catalog says, and two instruments merged rather than one. No single published mean/SD exists for this specific merged 34-item set; computing one would mean averaging two different scales'' norms, barred by R2. Needs Peter''s call on which published norm(s) to treat as authoritative, or whether to treat the two blocks as separate sub-scores.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
   'HireGauge norm missing: proactive_personality',
   'hiring_assessment', false,
   'HireGauge norms seed: no row inserted for facet "proactive_personality". Source confirmed as Seibert, Crant & Kraimer (1999), Journal of Applied Psychology 84(3):416-427, 10-item PPS subset of Bateman & Crant 1993 (matches item bank notes and catalog). Could not retrieve a clean combined-sample mean/SD for the original 10-item, 7-point-Likert PPS from this paper in this pass — secondary sources report alpha (.86) and item examples but not the descriptive table. Needs a direct fetch of Seibert et al. 1999 Table 1/2, or a different verified secondary source reporting the original scale''s descriptive statistics.');
