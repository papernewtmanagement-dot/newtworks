CREATE OR REPLACE FUNCTION public.cancel_counts_on(p_agency uuid, p_at timestamptz)
 RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $f$
  SELECT CASE WHEN public.cpr_week_for(p_agency, p_at) < public.rp_week_end((p_at AT TIME ZONE 'America/Chicago')::date)
              THEN public.cpr_week_for(p_agency, p_at)
              ELSE (p_at AT TIME ZONE 'America/Chicago')::date END
$f$;

DO $mig$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.production_rows_for'::regproc);
  a := 'CASE WHEN public.cpr_week_for(c.agency_id, c.created_at) < public.rp_week_end(rd.d)
                THEN public.cpr_week_for(c.agency_id, c.created_at) ELSE rd.d END AS recorded_on';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'production_rows_for shape changed'; END IF;
  d := replace(d, a, 'public.cancel_counts_on(c.agency_id, c.created_at) AS recorded_on');
  d := replace(d, E'\n      CROSS JOIN LATERAL (SELECT (c.created_at AT TIME ZONE ''America/Chicago'')::date AS d) rd', '');
  EXECUTE d;

  d := pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure);
  a := '(c.created_at AT TIME ZONE ''America/Chicago'')::date AS recorded_on';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'change log shape changed (recorded_on)'; END IF;
  d := replace(d, a, 'public.cancel_counts_on(c.agency_id, c.created_at) AS recorded_on');
  a := 'floor((((c.created_at AT TIME ZONE ''America/Chicago'')::date) - b.anchor) / 91.0)';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'change log shape changed (effect)'; END IF;
  d := replace(d, a, 'floor((public.cancel_counts_on(c.agency_id, c.created_at) - b.anchor) / 91.0)');
  EXECUTE d;

  d := pg_get_functiondef('public.reset_open_week_snapshots'::regproc);
  a := '  IF v_sent_at IS NOT NULL THEN
    RETURN jsonb_build_object(''reset'', false, ''reason'', ''week is frozen - CPR already sent to the team'',
                              ''sent_to_team_at'', v_sent_at);
  END IF;
';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'reset_open_week_snapshots shape changed'; END IF;
  d := replace(d, a, '');
  EXECUTE d;
END
$mig$;
