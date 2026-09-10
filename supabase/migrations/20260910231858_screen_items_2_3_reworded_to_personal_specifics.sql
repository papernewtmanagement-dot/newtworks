-- Reword written items 2 and 3 (section newtworks_v2_screen, stint 5) so the
-- answer must contain the candidate's own facts. Peter ruling 2026-09-10:
-- "Keep 5, reword 2 and 3 as shown."
--
-- WHY: the old items 2 (what caused your interest) and 3 (greatest challenges)
-- were job-knowledge questions. An AI tool can write a specific, realistic
-- answer to them from the job title alone, so the specificity / realism
-- signals would end up measuring tool use rather than the person. Asking for
-- elaboration and personal examples cuts inflation on written selection items
-- (Schmitt & Kunce 2002 Personnel Psychology 55:569-587; Schmitt, Oswald, Kim,
-- Gillespie, Ramsay & Yoo 2003 J Appl Psychol 88:979-988); accounts of real past
-- events predict performance (Hough 1984 J Appl Psychol 69:135-146). AI-writing
-- detection is NOT the defense (unreliable, biased against non-native English
-- writers: Liang et al. 2023 Patterns 4:100779). Item 5 already asks for a past
-- event and is unchanged.
--
-- Responses stay attached by item_id; anything answered before this migration
-- was to the old wording (rubric notes say so). The endpoint serves item_text
-- from the table, so no deploy. The screen_score_rubric anchors are updated to
-- the new questions in the same migration so the in-chat scorer reads the
-- right bar.

UPDATE public.hiregauge_instrument_items
SET item_text = 'Which past job of yours is most like this one, and what did you do there that makes you want this job?',
    notes = coalesce(notes || E'\n', '') || 'Reworded 2026-09-10 (Peter): was "What caused you to have an interest in this job?" -- answers saved before 2026-09-10 are to the old wording.'
WHERE section = 'newtworks_v2_screen' AND item_number = 2;

UPDATE public.hiregauge_instrument_items
SET item_text = 'Which part of this job do you expect to be hardest for you personally, and what have you done before that tells you that?',
    notes = coalesce(notes || E'\n', '') || 'Reworded 2026-09-10 (Peter): was "What do you think will be the greatest challenges of this job?" -- answers saved before 2026-09-10 are to the old wording.'
WHERE section = 'newtworks_v2_screen' AND item_number = 3;

UPDATE public.hiregauge_rules
SET description = 'Scores stint-5 item 2 (which past job of yours is most like this one, and what did you do there that makes you want this job -- reworded 2026-09-10; pre-2026-09-10 answers were to "what caused your interest in this job"). Commitment construct (attitude toward the position). 0-100.',
    notes = 'HIGH (75-100): names a specific past job of their own that is plausibly like this one AND says what they actually did there that connects to this work (checkable against the resume and in reference calls). MID (40-74): a named job but a thin or generic link, or a real link but no named job. LOW (0-39): could be pasted into any application ("I love helping people"), no job named, or a job named that is not on the resume. Polish earns nothing; only the candidate''s own facts score.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'screen_score_rubric' AND rule_name = 'role_interest_specificity';

UPDATE public.hiregauge_rules
SET description = 'Scores stint-5 item 3 (which part of this job do you expect to be hardest for you personally, and what have you done before that tells you that -- reworded 2026-09-10; pre-2026-09-10 answers were to "greatest challenges of this job"). Commitment construct (realistic understanding of the position plus self-knowledge). 0-100.',
    notes = 'HIGH (75-100): names a genuinely hard part of this job (rejection, licensing, pace, product learning, commission timing) AND backs it with a specific past experience of their own. MID (40-74): a realistic hard part with no personal evidence, or a personal story attached to a softball. LOW (0-39): softballs ("learning the computer system"), claims of no real challenge, or nothing personal at all. Polish earns nothing; only the candidate''s own facts score.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'screen_score_rubric' AND rule_name = 'challenge_realism';
