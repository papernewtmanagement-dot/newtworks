-- Once a new hire fills in their own team record at offer-acceptance time, that
-- row exists weeks before they start. work_checkin and work_display both key
-- off include_in_team_checkins with no check on whether the person has actually
-- started, so the row would put them on the daily check-in nag list and on the
-- team status block from the day it is created. Their own comments already say
-- "every ACTIVE agency teammate", so this was an oversight, not a decision.
-- Guard both on start date. No effect today: every current agency teammate
-- started in the past. The guard reads today's date, never the as-of date, so
-- historical CPR snapshots are unchanged.
DO $mig$
DECLARE
  v_src text;
  v_out text;
  v_hits int;
  v_old_checkin CONSTANT text :=
    '      (p_purpose = ''work_checkin''
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = ''agency'' AND r.role != ''Owner''))
        AND COALESCE(r.tag_in_team_reminders, true) = true';
  v_new_checkin CONSTANT text :=
    '      (p_purpose = ''work_checkin''
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = ''agency'' AND r.role != ''Owner''))
        AND (r.start_date IS NULL OR r.start_date <= v_today_ct)
        AND COALESCE(r.tag_in_team_reminders, true) = true';
  v_old_display CONSTANT text :=
    '      (p_purpose = ''work_display''
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = ''agency'' AND r.role != ''Owner'')))';
  v_new_display CONSTANT text :=
    '      (p_purpose = ''work_display''
        AND (r.start_date IS NULL OR r.start_date <= v_today_ct)
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = ''agency'' AND r.role != ''Owner'')))';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_expected_teammates' AND p.pronargs = 4;

  IF v_src IS NULL THEN RAISE EXCEPTION 'get_expected_teammates not found'; END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_old_checkin, ''))) / length(v_old_checkin);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'work_checkin block matched % times, expected 1', v_hits; END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_old_display, ''))) / length(v_old_display);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'work_display block matched % times, expected 1', v_hits; END IF;

  v_out := replace(v_src, v_old_checkin, v_new_checkin);
  v_out := replace(v_out, v_old_display, v_new_display);

  EXECUTE v_out;
END
$mig$;
