-- Invitation copy said "about 30 minutes"; real completion time after the
-- 2026-08-03 trim is 45-50 minutes (49 + 136 + up-to-32 conditional + 20 items).
-- Understating by ~40% drives mid-assessment dropout and burns candidate trust
-- before the first conversation. Surgical string replace applied to the live
-- definition so nothing else in the function can drift.
DO $do$
DECLARE
  v_def  text;
  v_orig text;
BEGIN
  SELECT pg_get_functiondef('public.send_v1_assessment_invitations(uuid,uuid)'::regprocedure)
    INTO v_def;
  v_orig := v_def;

  v_def := replace(v_def,
    'It takes about 30 minutes',
    'It takes about 45-50 minutes');
  v_def := replace(v_def,
    'please take about 30 minutes to complete it',
    'please set aside about 45-50 minutes to complete it');

  IF v_def = v_orig THEN
    RAISE EXCEPTION 'invite email duration copy not found — function body drifted, aborting';
  END IF;

  EXECUTE v_def;
END
$do$;
