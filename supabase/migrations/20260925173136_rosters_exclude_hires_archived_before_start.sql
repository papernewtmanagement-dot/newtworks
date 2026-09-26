-- An incoming hire who withdraws before day one gets archived. The central
-- roster let every archived person back in as "active then", so Rodney
-- (start 2026-10-05, archived 2026-09-25) became a second sales seat on
-- WtW 12 and the quotes target went 23 -> 38 (SP 2,590 -> 2,690) on the
-- 5 pm check-in. The same hole put him on the compensation, manager-tier
-- and health rosters for this week. Fix: an archived person counts only if
-- they had started by the end of the week asked about. Verified in a
-- rolled-back run against 450 purpose/date rosters: only Rodney drops,
-- only this week, every other roster and every past week unchanged.
-- One surgical edit; it must match exactly once or the migration aborts.
DO $mig$
DECLARE
  v_def  text;
  v_old  text;
  v_new  text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef('public.get_expected_teammates(uuid,text,date,text)'::regprocedure) INTO STRICT v_def;
  v_old := E'    -- active then, and the cutoff below still handles them.\n    AND (p_purpose = ''agency_calendar_invite''\n         OR COALESCE(r.is_active, false) = true\n         OR r.archived_at IS NOT NULL)\n';
  v_new := E'    -- active then, and the cutoff below still handles them. That holds only for\n    -- someone who had started by the end of that week. An incoming hire who\n    -- withdraws before day one is archived too, and was never on the team\n    -- (Rodney 2026-09-25: counted as a second sales seat, WtW 12 target 23 -> 38).\n    AND (p_purpose = ''agency_calendar_invite''\n         OR COALESCE(r.is_active, false) = true\n         OR (r.archived_at IS NOT NULL\n             AND r.start_date IS NOT NULL\n             AND r.start_date <= COALESCE(v_week_ending, v_today_ct)))\n';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'get_expected_teammates: expected 1 match, found %', v_hits;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$mig$;
