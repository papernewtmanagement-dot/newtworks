-- Chain write_weekly_comp_v2 -> write_weekly_marketing_bonus (non-destructive append)
CREATE OR REPLACE FUNCTION public.write_weekly_comp_v2(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows_updated int := 0;
  v_wt_rows int := 0;
  v_report_id    uuid;
  v_mktg_result  jsonb;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0,
      'note', 'no weekly_cpr_reports row exists for this week',
      'written_at', now()
    );
  END IF;

  WITH src AS (
    SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)
  ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      base_salary_paid   = s.weekly_base_salary,
      commission_paid    = s.weekly_commission_projected,
      bonus_gross        = ROUND(s.annual_bonus_gross / 52.0, 2),
      health_subtracted  = ROUND(s.annual_health_subtracted / 52.0, 2),
      bonus_net          = s.weekly_bonus_net,
      residual_pool_diag = s.diagnostics
                           || jsonb_build_object(
                                'annual_base_salary',          s.annual_base_salary,
                                'annual_commission_projected', s.annual_commission_projected,
                                'annual_bonus_gross',          s.annual_bonus_gross,
                                'annual_health_subtracted',    s.annual_health_subtracted,
                                'annual_bonus_net',            s.annual_bonus_net,
                                'annual_total_comp',           s.annual_total_comp,
                                'ytd_sales_points',            s.ytd_sales_points,
                                'sales_points_share_pct',      s.sales_points_share_pct,
                                'weighted_hours_at_40',        s.weighted_hours_at_40,
                                'retention_hours_share_pct',   s.retention_hours_share_pct,
                                'person_share_pct',            s.person_share_pct),
      updated_at = now()
    FROM src s
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = s.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  WITH wt AS (
    SELECT * FROM public.compute_warning_trigger(p_agency_id, p_week_end_date)
  ),
  wt_upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      warning_bar           = w.warning_bar,
      warning_actual_annual = w.warning_actual_annual,
      warning_pct           = w.warning_pct,
      warning_status        = w.warning_status,
      warning_diag          = w.diag,
      updated_at            = now()
    FROM wt w
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = w.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_wt_rows FROM wt_upd;

  BEGIN
    v_mktg_result := public.write_weekly_marketing_bonus(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN
    v_mktg_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
    'weekly_cpr_report_id', v_report_id,
    'rows_updated', v_rows_updated,
    'warning_trigger_rows_updated', v_wt_rows,
    'marketing_bonus_result', v_mktg_result,
    'written_at', now()
  );
END;
$function$;
