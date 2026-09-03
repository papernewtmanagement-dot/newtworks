-- Once payroll has frozen a week, the weekly run must leave its commission row
-- alone. Without this the weekly run would recalculate over the frozen numbers and
-- undo the freeze. Unpaid weeks still get a live projection each run.

DO $mig$
DECLARE
  d text;
  a_call CONSTANT text := E'  v_comm_proj_result := public.write_commission_projection(p_agency_id, p_week_end_date, v_pool_cumulative);\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.proname = 'write_weekly_comp_v2';

  IF (length(d) - length(replace(d, a_call, ''))) / length(a_call) <> 1 THEN
    RAISE EXCEPTION 'projection call anchor not unique';
  END IF;

  d := replace(d, a_call,
    E'  IF EXISTS (SELECT 1 FROM public.weekly_pool_lock wl\n'
    || E'             WHERE wl.agency_id = p_agency_id AND wl.week_end_date = p_week_end_date) THEN\n'
    || E'    v_comm_proj_result := jsonb_build_object(''skipped'', true, ''reason'', ''week frozen by payroll'');\n'
    || E'  ELSE\n'
    || E'  ' || a_call
    || E'  END IF;\n');

  EXECUTE d;
END
$mig$;
