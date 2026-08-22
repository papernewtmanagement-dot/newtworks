-- Screen layer backfill, tier 4: Alvi (Marie) Story.
-- Peter directive 2026-08-13: her assessment row counts as real candidate data,
-- so she is scored on the same rubric as everyone else. Supersedes the earlier
-- backfill decision to skip internal placements.

BEGIN;

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', NULL,
    'accountability', 72,
    'role_interest_specificity', 25,
    'challenge_realism', 55),
  'narrative', 'Scored on Peter directive that this row is real candidate data. Item 1 is scored NULL rather than low: she answered that she has not left any job, which is true of her situation, so there is no departure history to be candid or evasive about. The rubric measures candor about leaving jobs and that question does not apply here - a zero would penalize her for a fact rather than an answer. Character therefore rests on item 5 alone, which the scoring function handles correctly by averaging only the non-null signal. Item 5 is a clean, fully owned mistake: she rushed a layout, pasted supplied text without verifying it, and it went to reprint. Named consequence, unambiguous ownership with no deflection, and a direct statement of the correction - take the time to proofread. Concise rather than thin; everything the anchor asks for is present and the cost was real money. Held below the top band only because the correction is the obvious one rather than a durable process change. Item 3 names sales and time management in four words. Sales is a real hard part of the work and time management is the honest constraint for someone splitting back-office duties, so this scores mid rather than low despite the brevity - substance over length is the standing rule, and the two things named are the right two. Item 2 is the generic helping-people answer with nothing tied to her own history, which is what drags commitment down. Item 7 names Peter, which is accurate for her and not evaluable as an external reference. Read this file as calibration data, not as a hiring decision - she is already in the back-office seat.',
  'scored_at', '2026-08-13T23:26:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '328ef95c-a308-483c-8c1c-a50c75b925e2';

COMMIT;
