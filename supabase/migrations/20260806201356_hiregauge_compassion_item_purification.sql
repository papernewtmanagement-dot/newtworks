-- Deactivate the 2 compassion items that are exact text duplicates of friendliness (E1) items
UPDATE hiregauge_instrument_items SET is_active = false
WHERE item_number IN (51, 55) AND hypothesized_trait = 'compassion';

-- Cascade: item 238 (friendliness) is a retest child of compassion's item 51 (now deactivated)
UPDATE hiregauge_instrument_items SET is_active = false
WHERE item_number = 238 AND retest_of_item_number = 51;

-- Seed compassion's norm: IPIP-NEO-120 A6_Sympathy (verified against surviving item content)
INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'compassion', 68.94, 19.38,
   'IPIP-NEO-120 A6_Sympathy',
   'Kajonius, P. J., & Johnson, J. A. (2019). Assessing the structure of the Five Factor Model of Personality (IPIP-NEO-120) in the public domain. Europe''s Journal of Psychology, 15(2), 260-275, Table A1 (primary-source PDF, not secondary reproduction).',
   'https://ejop.psychopen.eu/index.php/ejop/article/download/1671/1671.pdf',
   'Source: 4-item facet, N=320,128 combined US sample, raw M=15.03 SD=3.10 on 4-20 scale. item_mean=15.03/4=3.7575, item_sd=3.10/4=0.775. Converted per spec formula. Planning-thread ruling 2026-08-06: compassion items purged of 2 E1-Friendliness duplicates (item 51 "I cheer people up.", item 55 "I am not really interested in others."); 10 surviving items verified as Sympathy-key content (empathic concern / indifference-reversed stems). Distinct from friendliness (E1) norm despite shared v1-era source confusion.',
   'claude_grunt_build_2026-08-06');
