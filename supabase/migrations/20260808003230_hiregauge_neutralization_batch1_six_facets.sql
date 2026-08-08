-- Batch 1: six-facet item-text neutralization + item 366 deletion + reverse-coding flips
-- Facets: customer_orientation, fairness, sincerity, dutifulness, achievement_striving, learning_goal_orientation
-- Source: planning-thread Batch 1 spec, 2026-08-07

-- S2 step 1: scratch diagnostic table
CREATE TABLE IF NOT EXISTS hiregauge_neutralization_shift_log (
  batch_label text,
  candidate_id uuid,
  facet text,
  value_before numeric,
  value_after numeric,
  captured_at timestamptz DEFAULT NOW()
);

-- S2 step 2: baseline snapshot BEFORE any writes
INSERT INTO hiregauge_neutralization_shift_log (batch_label, candidate_id, facet, value_before)
SELECT 'batch1', c.candidate_id, f.hypothesized_trait, f.facet_score
FROM (
  SELECT DISTINCT r.candidate_id
  FROM hiregauge_candidate_responses r
  JOIN hiregauge_instrument_items i ON i.id = r.item_id
  WHERE i.section = 'newtworks_v2_personality' AND r.sitting = 1
) c
CROSS JOIN LATERAL compute_newtworks_v2_facets_as_row(c.candidate_id, NULL, 1) AS f
WHERE f.hypothesized_trait IN ('customer_orientation','fairness','sincerity','dutifulness','achievement_striving','learning_goal_orientation');

-- ITEM TEXT UPDATES (44 items) — customer orientation
UPDATE hiregauge_instrument_items SET item_text = 'I''d rather spend the first half of a conversation asking than explaining.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 365;
UPDATE hiregauge_instrument_items SET item_text = 'I match what I offer to the problem in front of me rather than to what I happen to have available.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 367;
UPDATE hiregauge_instrument_items SET item_text = 'I''ll point someone toward the smaller option when it''s the one that actually fits.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 368;
UPDATE hiregauge_instrument_items SET item_text = 'Before I recommend anything, I want to know what the person is actually worried about.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 369;
UPDATE hiregauge_instrument_items SET item_text = 'When a customer wants less coverage than I''d recommend, I go with their read rather than push.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 370;
UPDATE hiregauge_instrument_items SET item_text = 'Most salespeople have to describe a product a bit more favorably than it really is to keep a conversation going.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 371;
UPDATE hiregauge_instrument_items SET item_text = 'There are times when what a customer can be talked into is more than what they actually need.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 372;
UPDATE hiregauge_instrument_items SET item_text = 'When I describe what something covers, I lead with the strong parts and let the gaps come up later.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 373;
UPDATE hiregauge_instrument_items SET item_text = 'What I recommend is shaped by what people tend to say yes to.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 374;

-- fairness (18 and 171 and 183 also flip reverse_coded, handled below with text)
UPDATE hiregauge_instrument_items SET item_text = 'When a tax deduction sits in a gray area, I take it.', reverse_coded = true, updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 18;
UPDATE hiregauge_instrument_items SET item_text = 'If a cashier hands me too much change and I only notice after I''ve left, I go back in.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 19;
UPDATE hiregauge_instrument_items SET item_text = 'When a rule and the obvious shortcut point in different directions, I take the rule.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 21;
UPDATE hiregauge_instrument_items SET item_text = 'I''ve taken small things from a workplace — supplies, time on the clock — without thinking much about it.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 24;
UPDATE hiregauge_instrument_items SET item_text = 'I''ve let down someone who was counting on me and not owned up to it.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 25;

-- sincerity
UPDATE hiregauge_instrument_items SET item_text = 'I''d rather come across as less impressive than I am than oversell myself.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 7;
UPDATE hiregauge_instrument_items SET item_text = 'Getting someone to move usually means leading with the part they already agree with.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 9;
UPDATE hiregauge_instrument_items SET item_text = 'Who I back has changed when my own situation changed.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 11;
UPDATE hiregauge_instrument_items SET item_text = 'I can show interest in someone''s situation without actually feeling much about it.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 13;
UPDATE hiregauge_instrument_items SET item_text = 'Reading what the person in charge wants is part of doing the job well.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 15;
UPDATE hiregauge_instrument_items SET item_text = 'Who I back has changed when my own situation changed.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 224;

-- dutifulness (171 also flips reverse_coded)
UPDATE hiregauge_instrument_items SET item_text = 'If I''ve said I''ll do something, it gets done even after it stops being convenient.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 170;
UPDATE hiregauge_instrument_items SET item_text = 'There have been stretches where a bill went past due before I got to it.', reverse_coded = true, updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 171;
UPDATE hiregauge_instrument_items SET item_text = 'There are things I''d rather not say out loud, and I say them anyway.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 172;
UPDATE hiregauge_instrument_items SET item_text = 'When something feels off to me, that''s usually enough to stop me.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 173;
UPDATE hiregauge_instrument_items SET item_text = 'When a rule is slowing down something that clearly needs doing, I work around it.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 174;
UPDATE hiregauge_instrument_items SET item_text = 'I''ve committed to something and then quietly let it slide.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 175;
UPDATE hiregauge_instrument_items SET item_text = 'When my plate is full, I hand off the parts of my job someone else could cover.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 176;
UPDATE hiregauge_instrument_items SET item_text = 'When I think an instruction is wrong, I do it my way instead.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 177;
UPDATE hiregauge_instrument_items SET item_text = 'I''ve presented a situation in the light that suited me best.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 178;

-- achievement striving (183 also flips reverse_coded)
UPDATE hiregauge_instrument_items SET item_text = 'I''d rather move at the target directly than take the route that keeps everyone comfortable.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 179;
UPDATE hiregauge_instrument_items SET item_text = 'People who''ve worked next to me would put my effort above the group average.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 180;
UPDATE hiregauge_instrument_items SET item_text = 'Plans I make tend to actually get started, not just written down.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 181;
UPDATE hiregauge_instrument_items SET item_text = 'I get absorbed enough in a task that other things slide.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 182;
UPDATE hiregauge_instrument_items SET item_text = 'I usually stop at what was asked rather than adding to it on my own.', reverse_coded = true, updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 183;
UPDATE hiregauge_instrument_items SET item_text = 'I expect more of the people around me than they''re used to being asked for.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 184;
UPDATE hiregauge_instrument_items SET item_text = 'I''d rather send something back for another pass than let it go out at acceptable.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 185;
UPDATE hiregauge_instrument_items SET item_text = 'Next to getting the work right, moving up isn''t something I spend much thought on.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 186;
UPDATE hiregauge_instrument_items SET item_text = 'On work nobody is checking, I settle for good enough rather than pushing further.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 187;
UPDATE hiregauge_instrument_items SET item_text = 'The amount of effort I put in tracks how much the work interests me.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 188;

-- learning goal orientation
UPDATE hiregauge_instrument_items SET item_text = 'I''ll take an assignment I might not be good at yet if there''s something to learn in it.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 376;
UPDATE hiregauge_instrument_items SET item_text = 'I go looking for skills to pick up rather than waiting for training to be offered.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 377;
UPDATE hiregauge_instrument_items SET item_text = 'Work that''s hard enough to make me look inexperienced for a while is still work I want.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 378;
UPDATE hiregauge_instrument_items SET item_text = 'Getting better at my job is worth looking bad in the short run.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 379;
UPDATE hiregauge_instrument_items SET item_text = 'I''d rather be in a role that stretches past what I can currently do than one I''ve already mastered.', updated_at = NOW() WHERE section='newtworks_v2_personality' AND item_number = 380;

-- S3: delete item 366 (verified: zero hiregauge_item_extra_traits rows, zero retest_of_item_number refs, zero candidate_responses)
DELETE FROM hiregauge_instrument_items WHERE section='newtworks_v2_personality' AND item_number = 366;

-- S2 step 3: recompute value_after
WITH recomputed AS (
  SELECT c.candidate_id, f.hypothesized_trait, f.facet_score
  FROM (
    SELECT DISTINCT r.candidate_id
    FROM hiregauge_candidate_responses r
    JOIN hiregauge_instrument_items i ON i.id = r.item_id
    WHERE i.section = 'newtworks_v2_personality' AND r.sitting = 1
  ) c
  CROSS JOIN LATERAL compute_newtworks_v2_facets_as_row(c.candidate_id, NULL, 1) AS f
  WHERE f.hypothesized_trait IN ('customer_orientation','fairness','sincerity','dutifulness','achievement_striving','learning_goal_orientation')
)
UPDATE hiregauge_neutralization_shift_log log
SET value_after = r.facet_score
FROM recomputed r
WHERE log.batch_label = 'batch1' AND log.candidate_id = r.candidate_id AND log.facet = r.hypothesized_trait AND log.value_after IS NULL;

-- S4: norm flag (existing column on hiregauge_facet_norms)
UPDATE public.hiregauge_facet_norms
  SET items_reworded_after_norm = true,
      updated_at = NOW(),
      updated_by = 'claude_grunt_neutralization_batch1'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND facet IN ('customer_orientation','fairness','sincerity','dutifulness','achievement_striving','learning_goal_orientation');
