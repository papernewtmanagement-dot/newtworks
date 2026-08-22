-- Batch 3: repeat-pair neutralization, 8 pairs / 16 items, both halves identical
-- Source: planning-thread Batch 3 spec, 2026-08-08. Includes 11/224 correction from Batch 1.

INSERT INTO hiregauge_neutralization_shift_log (batch_label, candidate_id, facet, value_before)
SELECT 'batch3', c.candidate_id, f.hypothesized_trait, f.facet_score
FROM (
  SELECT DISTINCT r.candidate_id
  FROM hiregauge_candidate_responses r
  JOIN hiregauge_instrument_items i ON i.id = r.item_id
  WHERE i.section = 'newtworks_v2_personality' AND r.sitting = 1
) c
CROSS JOIN LATERAL compute_newtworks_v2_facets_as_row(c.candidate_id, NULL, 1) AS f
WHERE f.hypothesized_trait IN ('sincerity','anxiety','cautiousness','competitiveness','compassion','friendliness','self_discipline','self_efficacy','trust');

UPDATE hiregauge_instrument_items SET item_text='There have been times my support for someone shifted once my own situation changed.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=11;
UPDATE hiregauge_instrument_items SET item_text='There have been times my support for someone shifted once my own situation changed.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=224;

UPDATE hiregauge_instrument_items SET item_text='Once something''s bothering me, it''s hard to think about much else until it''s resolved.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=123;
UPDATE hiregauge_instrument_items SET item_text='Once something''s bothering me, it''s hard to think about much else until it''s resolved.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=234;

UPDATE hiregauge_instrument_items SET item_text='There have been times I''ve decided something quickly and regretted not slowing down.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=203;
UPDATE hiregauge_instrument_items SET item_text='There have been times I''ve decided something quickly and regretted not slowing down.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=242;

UPDATE hiregauge_instrument_items SET item_text='When I''m working alongside other people, I keep track of how I''m doing compared to them.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=389;
UPDATE hiregauge_instrument_items SET item_text='When I''m working alongside other people, I keep track of how I''m doing compared to them.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=397;

UPDATE hiregauge_instrument_items SET item_text='When someone around me is down, I usually try to do something about it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=51;
UPDATE hiregauge_instrument_items SET item_text='When someone around me is down, I usually try to do something about it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=238;

UPDATE hiregauge_instrument_items SET item_text='Once I''ve laid out a plan, I usually follow through on it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=193;
UPDATE hiregauge_instrument_items SET item_text='Once I''ve laid out a plan, I usually follow through on it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=241;

UPDATE hiregauge_instrument_items SET item_text='If a plan falls apart at the last minute, I can usually put together another one on the spot.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=63;
UPDATE hiregauge_instrument_items SET item_text='If a plan falls apart at the last minute, I can usually put together another one on the spot.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=229;

UPDATE hiregauge_instrument_items SET item_text='Overall, my view of people is a pretty positive one.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=143;
UPDATE hiregauge_instrument_items SET item_text='Overall, my view of people is a pretty positive one.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=236;

WITH recomputed AS (
  SELECT c.candidate_id, f.hypothesized_trait, f.facet_score
  FROM (
    SELECT DISTINCT r.candidate_id
    FROM hiregauge_candidate_responses r
    JOIN hiregauge_instrument_items i ON i.id = r.item_id
    WHERE i.section = 'newtworks_v2_personality' AND r.sitting = 1
  ) c
  CROSS JOIN LATERAL compute_newtworks_v2_facets_as_row(c.candidate_id, NULL, 1) AS f
  WHERE f.hypothesized_trait IN ('sincerity','anxiety','cautiousness','competitiveness','compassion','friendliness','self_discipline','self_efficacy','trust')
)
UPDATE hiregauge_neutralization_shift_log log
SET value_after = r.facet_score
FROM recomputed r
WHERE log.batch_label = 'batch3' AND log.candidate_id = r.candidate_id AND log.facet = r.hypothesized_trait AND log.value_after IS NULL;

