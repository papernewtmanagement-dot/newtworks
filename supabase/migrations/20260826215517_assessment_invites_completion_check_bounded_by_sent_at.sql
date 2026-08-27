-- send_v1_assessment_invitations: the completion sweep (step 1a) and the no-response
-- sweep (step 3) treated ANY v1/v2_assessment_complete alert for the candidate as
-- "this invitation was completed". Re-inviting someone who completed an earlier
-- version (2026-08-25: 19 candidates re-sent the new quad assessment) would have
-- been marked completed instantly by their OLD alert, killing reminders and lying
-- about the outcome. Both checks now only count alerts created at or after the
-- invitation's sent_at. Applied as an in-place text patch of the live definition so
-- the rest of the function is byte-identical.
DO $$
DECLARE
  v_def text;
  v_n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'send_v1_assessment_invitations';

  v_n := (length(v_def) - length(replace(v_def, 'AND a.related_id = ai.candidate_id', ''))) / length('AND a.related_id = ai.candidate_id');
  IF v_n <> 2 OR v_def ILIKE '%a.created_at >= ai.sent_at%' THEN
    RAISE EXCEPTION 'unexpected function shape (% matches, already_fixed=%); refusing to patch',
      v_n, (v_def ILIKE '%a.created_at >= ai.sent_at%');
  END IF;

  v_def := replace(v_def,
    'AND a.related_id = ai.candidate_id',
    'AND a.related_id = ai.candidate_id' || E'\n          AND a.created_at >= ai.sent_at');

  EXECUTE v_def;
END $$;
