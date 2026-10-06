-- CPR page speed (2026-10-06).
-- 1. Frozen weeks stop redoing the pay math on every page open. A week is frozen when
--    payroll locked it (weekly_pool_lock row) or the CPR went to the team. The page used
--    to run recompute_cpr_outcome (about 3.5 seconds, and it rewrites the payroll rows)
--    on every open of any week in the current quarter, frozen or not. Now a frozen week
--    gets one final write the first time it is opened after the freeze, stamped in
--    weekly_cpr_reports.comp_final_at, and is read from the stored rows after that.
-- 2. get_cpr_page_bundle returns every computed read the page needs for one week in a
--    single trip instead of about fifteen.

ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS comp_final_at timestamptz;

COMMENT ON COLUMN public.weekly_cpr_reports.comp_final_at IS
  'When the CPR page ran its one final pay write after the week froze (payroll lock or sent to team). Set means the page reads stored values and no longer recomputes this week.';

CREATE OR REPLACE FUNCTION public.cpr_recompute_on_open(p_agency_id uuid, p_week_end_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_report_id uuid;
  v_sent_at   timestamptz;
  v_final_at  timestamptz;
  v_frozen    boolean;
BEGIN
  PERFORM public.require_login('staff');
  -- Recomputing is owner or manager only (recompute_cpr_outcome enforces it). Staff
  -- viewers just read what is stored, same as before.
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RETURN 'read_only_viewer';
  END IF;

  SELECT id, sent_to_team_at, comp_final_at INTO v_report_id, v_sent_at, v_final_at
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;
  IF v_report_id IS NULL THEN
    RETURN 'no_report';
  END IF;

  v_frozen := v_sent_at IS NOT NULL OR EXISTS (
    SELECT 1 FROM public.weekly_pool_lock l
    WHERE l.agency_id = p_agency_id AND l.week_end_date = p_week_end_date);

  IF NOT v_frozen THEN
    PERFORM public.recompute_cpr_outcome(p_agency_id, p_week_end_date);
    RETURN 'recomputed';
  END IF;

  IF v_final_at IS NULL THEN
    PERFORM public.recompute_cpr_outcome(p_agency_id, p_week_end_date);
    UPDATE public.weekly_cpr_reports SET comp_final_at = now() WHERE id = v_report_id;
    RETURN 'finalized';
  END IF;

  RETURN 'frozen';
END
$function$;

REVOKE ALL ON FUNCTION public.cpr_recompute_on_open(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cpr_recompute_on_open(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_cpr_page_bundle(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Security invoker on purpose: every function called here runs its own staff check
-- against the caller, exactly as when the page called them one by one.
DECLARE
  w      date := p_week_end_date;
  pw     date := p_week_end_date - 7;
  v_out    jsonb := '{}'::jsonb;
  errs   jsonb := '{}'::jsonb;
  v      jsonb;
  cs     date;
  ce     date;
  cur    date;
  r      record;
  pq     jsonb := '[]'::jsonb;
  i      int;
BEGIN
  PERFORM public.require_login('staff');

  BEGIN
    SELECT cycle_start, cycle_end INTO cs, ce FROM public.current_cycle_info(p_agency_id, w);
    v_out := v_out || jsonb_build_object('cycle_start', cs, 'cycle_end', ce);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('cycle_week', SQLERRM); END;

  -- Last four completed quarters before this week, walking back one cycle at a time.
  BEGIN
    cur := cs;
    i := 0;
    WHILE cur IS NOT NULL AND i < 4 LOOP
      SELECT cycle_start, cycle_end, quarter_label INTO r
      FROM public.current_cycle_info(p_agency_id, cur - 1);
      EXIT WHEN r.cycle_end IS NULL OR r.cycle_start IS NULL;
      IF r.cycle_end < w THEN
        pq := pq || jsonb_build_array(jsonb_build_object('close_date', r.cycle_end, 'quarter_label', r.quarter_label));
      END IF;
      cur := r.cycle_start;
      i := i + 1;
    END LOOP;
    v_out := v_out || jsonb_build_object('prior_quarters', pq);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('prior_quarters', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.compute_lapse_rate(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('lapse', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('lapse', SQLERRM); END;

  IF cs IS NOT NULL THEN
    BEGIN
      SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.production_by_week_for(p_agency_id, cs, w) x;
      v_out := v_out || jsonb_build_object('live_production', v);
    EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('live_production', SQLERRM); END;
  END IF;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.get_sales_points_qtd(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('sales_points_now', v);
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.get_sales_points_qtd(p_agency_id, pw) x;
    v_out := v_out || jsonb_build_object('sales_points_prev', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('sales_points', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.get_weekly_cpr_hours(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('hours', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('hours', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.get_weekly_cpr_requirements(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('requirements', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('requirements', SQLERRM); END;

  BEGIN
    v_out := v_out || jsonb_build_object('section11', public.get_cpr_section_11(p_agency_id, w));
    v_out := v_out || jsonb_build_object('section11_prior', public.get_cpr_section_11(p_agency_id, pw));
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('section11', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.get_weekly_crossings_live(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('crossings', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('crossings', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.compute_weekly_retention_points(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('retention_points', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('retention_points', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.marketing_points_weekly(p_agency_id, w) x;
    v_out := v_out || jsonb_build_object('marketing_points', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('marketing_points', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.team_sales_points_ratings(p_agency_id) x;
    v_out := v_out || jsonb_build_object('sp_ratings', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('sp_ratings', SQLERRM); END;

  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v FROM public.team_raise_progress(p_agency_id => p_agency_id) x;
    v_out := v_out || jsonb_build_object('raise_progress', v);
  EXCEPTION WHEN OTHERS THEN errs := errs || jsonb_build_object('raise_progress', SQLERRM); END;

  RETURN v_out || jsonb_build_object('errors', errs);
END
$function$;

REVOKE ALL ON FUNCTION public.get_cpr_page_bundle(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_cpr_page_bundle(uuid, date) TO authenticated, service_role;

