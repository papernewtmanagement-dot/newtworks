-- Drop first because we're adding a new column to the return type
DROP FUNCTION IF EXISTS public.get_weekly_cpr_requirements(uuid, date);

-- 1) Writer: snapshot team at week start + per-week SP increment + cumulative SP target
CREATE OR REPLACE FUNCTION public.weekly_cpr_compute_outcome(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_local_time text;
  v_today date;
  v_cycle record;
  v_week_start date;
  v_week_end date;
  v_count_am_sales int := 0;
  v_count_am_retention int := 0;
  v_quotes_fresh_needed int;
  v_carryover int := 0;
  v_quotes_total_net int := 0;
  v_sales_points_qtd numeric := 0;
  v_quotes_target_total int;
  v_this_week_sp_increment numeric;
  v_prior_sp_cumulative numeric;
  v_sp_target numeric;
  v_quotes_owed_next int;
  v_won boolean;
  v_quotes_pass boolean;
  v_sp_pass boolean;
  v_result_id uuid;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_today);
  v_week_end := v_cycle.week_ending_saturday;
  v_week_start := v_week_end - 6;

  -- SNAPSHOT TEAM AT WEEK START
  SELECT
    count(*) FILTER (WHERE role_level IN ('Account Manager', 'Unit Manager') AND role_category = 'Sales'),
    count(*) FILTER (WHERE role_level IN ('Account Manager', 'Unit Manager') AND role_category = 'Retention')
  INTO v_count_am_sales, v_count_am_retention
  FROM public.team
  WHERE agency_id = p_agency_id
    AND (archived_at IS NULL OR archived_at > v_week_start::timestamptz)
    AND is_test_user IS NOT TRUE
    AND (include_in_team_checkins = true OR
         (include_in_team_checkins IS NULL AND category = 'agency' AND role != 'Owner'));

  v_quotes_fresh_needed := (15 * v_count_am_sales) + (8 * v_count_am_retention);
  v_this_week_sp_increment := (1000 * v_count_am_sales) + (500 * v_count_am_retention);

  SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
  v_carryover := COALESCE(v_carryover, 0);

  IF v_cycle.week_of_cycle <= 1 THEN
    v_prior_sp_cumulative := 0;
  ELSE
    SELECT quarterly_sales_points_target INTO v_prior_sp_cumulative
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    IF v_prior_sp_cumulative IS NULL THEN
      v_prior_sp_cumulative := (v_cycle.week_of_cycle - 1) * v_this_week_sp_increment;
    END IF;
  END IF;

  SELECT COALESCE(SUM(latest_q), 0) INTO v_quotes_total_net
  FROM (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id, tc.quotes_week AS latest_q
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_week_start AND v_week_end
      AND tc.checkin_type IN ('midday', 'eod')
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;

  SELECT COALESCE(SUM(latest_sp), 0) INTO v_sales_points_qtd
  FROM (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id, tc.sales_points_quarter AS latest_sp
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle.cycle_start AND v_week_end
      AND tc.checkin_type IN ('midday', 'eod')
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;

  v_quotes_target_total := v_quotes_fresh_needed + v_carryover;
  v_sp_target := v_prior_sp_cumulative + v_this_week_sp_increment;

  v_quotes_pass := v_quotes_total_net >= v_quotes_target_total;
  v_sp_pass := v_sales_points_qtd >= v_sp_target;
  v_won := v_quotes_pass AND v_sp_pass;
  v_quotes_owed_next := GREATEST(0, v_quotes_target_total - v_quotes_total_net);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, v_week_end,
    v_carryover, v_quotes_fresh_needed, v_quotes_total_net, v_quotes_owed_next,
    v_sp_target, v_this_week_sp_increment,
    v_sales_points_qtd, v_won,
    now(), now()
  )
  ON CONFLICT (agency_id, week_ending_date) DO UPDATE
    SET quotes_owed_carryover = EXCLUDED.quotes_owed_carryover,
        quotes_fresh_needed = EXCLUDED.quotes_fresh_needed,
        quotes_total_net = EXCLUDED.quotes_total_net,
        quotes_owed_next_week = EXCLUDED.quotes_owed_next_week,
        quarterly_sales_points_target = EXCLUDED.quarterly_sales_points_target,
        sales_points_target_this_week = EXCLUDED.sales_points_target_this_week,
        quarterly_sales_points_qtd = EXCLUDED.quarterly_sales_points_qtd,
        won_the_week = EXCLUDED.won_the_week,
        updated_at = now()
  RETURNING id INTO v_result_id;

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('Week %s of 13 (ending %s): quotes %s/%s, SP %s/%s (+%s on prior %s), won=%s',
      v_cycle.week_of_cycle, v_week_end,
      v_quotes_total_net, v_quotes_target_total,
      v_sales_points_qtd, v_sp_target,
      v_this_week_sp_increment, v_prior_sp_cumulative,
      v_won)
  );
END;
$function$;

-- 2) Requirements function: snapshot team filter + quotes_modified column
CREATE FUNCTION public.get_weekly_cpr_requirements(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, carryover integer, personal_misses integer, team_misses integer, missed integer, cost integer, total integer, modified integer, quotes_discussed integer, paid integer, owed integer, net_quotes integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH
  this_report AS (
    SELECT
      id AS report_id,
      (CASE WHEN COALESCE(shareds_done,       true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(texts_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(deposits_done,      true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(appts_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(tasks_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(cases_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(no_fu_task_done,    true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(new_opps_done,      true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(no_onboarding_done, true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(no_phone_done,      true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(bad_data_done,      true) THEN 0 ELSE 1 END
      )::integer AS team_misses
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = p_week_ending_date
  ),
  prior_report AS (
    SELECT id AS report_id
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = p_week_ending_date - 7
  ),
  per_person AS (
    SELECT
      t.id AS team_member_id,
      COALESCE(prior_d.owed, 0)::integer AS carryover,
      (CASE WHEN COALESCE(d.cpr_reply_done, true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(d.wrapup_done,    true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(d.inbox_done,     true) THEN 0 ELSE 1 END
      )::integer AS personal_misses,
      COALESCE((SELECT team_misses FROM this_report), 0)::integer AS team_misses,
      COALESCE(d.quotes_discussed, 0)::integer AS quotes_discussed,
      COALESCE(d.quotes_modified, 0)::integer  AS modified
    FROM public.team t
    LEFT JOIN public.weekly_cpr_team_detail d
      ON d.weekly_cpr_report_id = (SELECT report_id FROM this_report)
     AND d.team_member_id       = t.id
    LEFT JOIN public.weekly_cpr_team_detail prior_d
      ON prior_d.weekly_cpr_report_id = (SELECT report_id FROM prior_report)
     AND prior_d.team_member_id       = t.id
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND (
        (t.is_active = true AND t.archived_at IS NULL)
        OR EXISTS (
          SELECT 1 FROM public.weekly_cpr_team_detail dd
          WHERE dd.weekly_cpr_report_id = (SELECT report_id FROM this_report)
            AND dd.team_member_id = t.id
        )
      )
  ),
  per_person_derived AS (
    SELECT
      team_member_id,
      carryover,
      personal_misses,
      team_misses,
      modified,
      (team_misses + personal_misses)::integer AS missed,
      1::integer AS cost,
      (carryover + (team_misses + personal_misses) * 1)::integer AS total,
      quotes_discussed
    FROM per_person
  ),
  team_totals AS (
    SELECT
      SUM(quotes_discussed)::integer       AS team_quotes,
      SUM(carryover)::integer              AS team_carryover,
      SUM(missed * cost)::integer          AS team_missed_cost,
      (SUM(carryover) + SUM(missed * cost))::integer AS team_total_debt
    FROM per_person_derived
  ),
  allocated AS (
    SELECT
      ppd.team_member_id,
      ppd.carryover,
      ppd.personal_misses,
      ppd.team_misses,
      ppd.missed,
      ppd.cost,
      ppd.total,
      ppd.modified,
      ppd.quotes_discussed,
      CASE
        WHEN tt.team_quotes >= tt.team_total_debt
          THEN ppd.total
        WHEN tt.team_quotes >= tt.team_carryover
          THEN ppd.carryover +
               CASE WHEN tt.team_missed_cost > 0
                    THEN ROUND((tt.team_quotes - tt.team_carryover)::numeric * (ppd.missed * ppd.cost)::numeric / tt.team_missed_cost)::integer
                    ELSE 0 END
        ELSE
          CASE WHEN tt.team_carryover > 0
               THEN ROUND(tt.team_quotes::numeric * ppd.carryover::numeric / tt.team_carryover)::integer
               ELSE 0 END
      END::integer AS paid
    FROM per_person_derived ppd
    CROSS JOIN team_totals tt
  )
SELECT
  team_member_id,
  carryover,
  personal_misses,
  team_misses,
  missed,
  cost,
  total,
  modified,
  quotes_discussed,
  paid,
  (total + modified - paid)::integer AS owed,
  (quotes_discussed - total - modified)::integer AS net_quotes
FROM allocated;
$function$;
