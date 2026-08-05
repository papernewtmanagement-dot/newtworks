-- Peter directive 2026-08-05: after the item trims (retests 25->8, SJT 20->15,
-- facet/stint trims same day), the assessment now actually runs about 30
-- minutes. The "45-50 minutes" copy from earlier today (20260805002956) is
-- now the stale one. Surgical string replace on the live definition, same
-- pattern as before, so nothing else in the function can drift.
DO $do$
DECLARE
  v_def  text;
  v_orig text;
BEGIN
  SELECT pg_get_functiondef('public.send_v1_assessment_invitations(uuid,uuid)'::regprocedure)
    INTO v_def;
  v_orig := v_def;

  v_def := replace(v_def,
    'It takes about 45-50 minutes',
    'It takes about 30 minutes');
  v_def := replace(v_def,
    'please set aside about 45-50 minutes to complete it',
    'please take about 30 minutes to complete it');

  IF v_def = v_orig THEN
    RAISE EXCEPTION 'invite email duration copy not found — function body drifted, aborting';
  END IF;

  EXECUTE v_def;
END
$do$;
