-- Retire the alerts table, part 2b of 3.
-- The three people watchers now open a task assigned to Peter instead of
-- writing an alert, and close that task when the person recovers. Task
-- shaping lives in ensure_watcher_task / close_watcher_task so all three
-- move together.

CREATE OR REPLACE FUNCTION public.producer_complacency_check(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_inserted integer := 0;
  v_names    text[]  := '{}';
  v_summary  text;
  r          RECORD;
BEGIN
  FOR r IN
    SELECT v.team_member_id, v.producer_name, v.pct_change,
           v.avg_premium_recent_2mo, v.avg_premium_baseline_4mo
    FROM public.v_producer_complacency v
    WHERE v.agency_id = p_agency_id AND v.complacency_alert = true
  LOOP
    IF public.ensure_watcher_task(
         p_agency_id,
         'producer_complacency',
         r.team_member_id,
         'Check in with ' || r.producer_name || ' — new business slipping',
         r.producer_name || ' trailing 2-month average new P&C premium is '
           || ABS(r.pct_change) || '% below their trailing 4-month baseline ($'
           || r.avg_premium_recent_2mo || ' vs $' || r.avg_premium_baseline_4mo
           || '). Time for a check-in before the slip deepens into a full bad quarter.',
         'medium')
    THEN
      v_inserted := v_inserted + 1;
      v_names := v_names || r.producer_name;
    END IF;
  END LOOP;

  v_summary := CASE WHEN v_inserted = 0
    THEN 'No new complacency tasks. All producers within 10% of baseline (or already have an open task).'
    ELSE 'Opened complacency tasks for: ' || array_to_string(v_names, ', ')
  END;

  RETURN jsonb_build_object('records_processed', v_inserted, 'output_summary', v_summary);
END;
$function$;

CREATE OR REPLACE FUNCTION public.producer_underperformance_watcher(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_today DATE := CURRENT_DATE;
  v_curr_year INT := EXTRACT(YEAR FROM v_today)::INT;
  v_curr_month INT := EXTRACT(MONTH FROM v_today)::INT;
  v_day_of_month INT := EXTRACT(DAY FROM v_today)::INT;
  v_days_in_month INT := EXTRACT(DAY FROM (date_trunc('month', v_today) + INTERVAL '1 month - 1 day'))::INT;
  v_pace_factor NUMERIC := v_day_of_month::numeric / NULLIF(v_days_in_month, 0)::numeric;
  v_count INTEGER := 0;
  v_producer RECORD;
  v_mtd_premium NUMERIC;
  v_3mra_premium NUMERIC;
  v_pace_ratio NUMERIC;
BEGIN
  IF v_day_of_month < 5 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'Skipped: too early in month');
  END IF;

  FOR v_producer IN
    SELECT id, first_name, last_name, role FROM public.team
    WHERE agency_id = p_agency_id AND COALESCE(is_active, true) = true
      AND role IS NOT NULL
      AND (role ILIKE '%LSP%' OR role ILIKE '%Producer%' OR role ILIKE '%Financial Services%')
  LOOP
    SELECT COALESCE(SUM(premium_issued), 0) INTO v_mtd_premium
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND team_member_id = v_producer.id
      AND period_year = v_curr_year AND period_month = v_curr_month;

    SELECT COALESCE(AVG(monthly_total), 0) INTO v_3mra_premium
    FROM (
      SELECT period_year, period_month, SUM(premium_issued) AS monthly_total
      FROM public.producer_production
      WHERE agency_id = p_agency_id AND team_member_id = v_producer.id
        AND (period_year, period_month) IN (
          SELECT EXTRACT(YEAR FROM (v_today - INTERVAL '1 month'))::int,
                 EXTRACT(MONTH FROM (v_today - INTERVAL '1 month'))::int
          UNION ALL SELECT EXTRACT(YEAR FROM (v_today - INTERVAL '2 month'))::int,
                 EXTRACT(MONTH FROM (v_today - INTERVAL '2 month'))::int
          UNION ALL SELECT EXTRACT(YEAR FROM (v_today - INTERVAL '3 month'))::int,
                 EXTRACT(MONTH FROM (v_today - INTERVAL '3 month'))::int
        )
      GROUP BY period_year, period_month
    ) prior_months;

    IF v_3mra_premium <= 0 THEN CONTINUE; END IF;

    v_pace_ratio := CASE
      WHEN v_3mra_premium * v_pace_factor > 0 THEN v_mtd_premium / (v_3mra_premium * v_pace_factor)
      ELSE NULL
    END;

    IF v_pace_ratio IS NOT NULL AND v_pace_ratio < 0.70 THEN
      IF public.ensure_watcher_task(
           p_agency_id,
           'producer_underperformance',
           v_producer.id,
           v_producer.first_name || ' ' || v_producer.last_name
             || ' is at ' || ROUND(v_pace_ratio * 100, 0) || '% of their three-month pace',
           'Through day ' || v_day_of_month || ' of ' || v_days_in_month
             || ', this producer has issued $' || ROUND(v_mtd_premium, 0)
             || ' in premium. That is ' || ROUND(v_pace_ratio * 100, 0)
             || '% of where their last three months would put them by now.',
           'medium')
      THEN
        v_count := v_count + 1;
      END IF;
    ELSIF v_pace_ratio IS NOT NULL AND v_pace_ratio >= 1.0 THEN
      PERFORM public.close_watcher_task(p_agency_id, 'producer_underperformance', v_producer.id);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('records_processed', v_count,
                            'output_summary', v_count || ' producer task(s) opened for month-to-date pace');
END;
$function$;

CREATE OR REPLACE FUNCTION public.sales_points_band_drop_watcher(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_member        RECORD;
  v_avg           numeric;
  v_weight        numeric;
  v_rel           numeric;
  v_rating        text;
  v_prior         text;
  v_dropped       integer := 0;
  v_recovered     integer := 0;
  v_dropped_names text[] := '{}';
  v_recov_names   text[] := '{}';
  v_summary       text;
BEGIN
  FOR v_member IN
    SELECT t.id, t.first_name, t.last_name, t.role_level, t.role_category, t.hire_date
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.archived_at IS NULL
      AND t.role_level IN ('Account Manager','Unit Manager','Section Manager','Office Manager')
      AND t.hire_date IS NOT NULL
      AND FLOOR((CURRENT_DATE - t.hire_date) / 7.0) >= 13
  LOOP
    v_avg := public.team_member_sales_points_avg_13wk(v_member.id);
    CONTINUE WHEN v_avg IS NULL;

    v_weight := CASE WHEN v_member.role_category = 'Retention' THEN 0.5 ELSE 1.0 END;
    v_rel    := ROUND(v_avg / v_weight, 2);
    v_rating := public.compute_sales_points_rating(p_agency_id, v_rel);
    CONTINUE WHEN v_rating IS NULL;

    SELECT s.rating INTO v_prior
    FROM public.team_sales_points_rating_state s
    WHERE s.agency_id = p_agency_id AND s.team_member_id = v_member.id;

    IF v_rating IN ('Danger','Caution')
       AND (v_prior IS NULL
            OR public.sales_points_rating_ordinal(v_rating)
               < public.sales_points_rating_ordinal(v_prior))
    THEN
      IF public.ensure_watcher_task(
           p_agency_id,
           'sales_points_band',
           v_member.id,
           v_member.first_name || ' ' || v_member.last_name
             || ' dropped to ' || v_rating || ' on Sales Points',
           v_member.first_name || '''s thirteen-week Sales Points average is '
             || ROUND(v_avg, 0) || ' a week'
             || CASE WHEN v_weight <> 1.0
                     THEN ' (' || ROUND(v_rel, 0) || ' against the retention half-scale)'
                     ELSE '' END
             || ', a ' || v_rating || ' rating'
             || CASE WHEN v_prior IS NOT NULL THEN ', down from ' || v_prior ELSE '' END
             || '. '
             || CASE WHEN v_rating = 'Danger'
                     THEN 'Handbook: signed improvement plan, measured on getting back to Good within thirteen weeks. Unlimited paid time off pauses until the rating recovers. Pay is not cut.'
                     ELSE 'Handbook: documented coaching conversation plus a weekly one-on-one until the rating recovers.' END,
           CASE WHEN v_rating = 'Danger' THEN 'high' ELSE 'medium' END)
      THEN
        v_dropped := v_dropped + 1;
        v_dropped_names := v_dropped_names || (v_member.first_name || ' (' || v_rating || ')');
      END IF;
    END IF;

    IF v_rating IN ('Good','Great','Elite') THEN
      IF public.close_watcher_task(p_agency_id, 'sales_points_band', v_member.id) > 0 THEN
        v_recovered := v_recovered + 1;
        v_recov_names := v_recov_names || (v_member.first_name || ' (' || v_rating || ')');
      END IF;
    END IF;

    INSERT INTO public.team_sales_points_rating_state
      (agency_id, team_member_id, rating, avg_13wk, rel_13wk, updated_at)
    VALUES (p_agency_id, v_member.id, v_rating, ROUND(v_avg, 2), v_rel, now())
    ON CONFLICT (agency_id, team_member_id) DO UPDATE
      SET rating = EXCLUDED.rating,
          avg_13wk = EXCLUDED.avg_13wk,
          rel_13wk = EXCLUDED.rel_13wk,
          updated_at = now();
  END LOOP;

  v_summary := CASE
    WHEN v_dropped = 0 AND v_recovered = 0 THEN 'No Sales Points band changes this week.'
    ELSE trim(both ' ' FROM
         CASE WHEN v_dropped > 0
              THEN 'Dropped: ' || array_to_string(v_dropped_names, ', ') || '. ' ELSE '' END
      || CASE WHEN v_recovered > 0
              THEN 'Recovered to Good or better: ' || array_to_string(v_recov_names, ', ') || '.' ELSE '' END)
  END;

  RETURN jsonb_build_object(
    'records_processed', v_dropped + v_recovered,
    'dropped', v_dropped,
    'recovered', v_recovered,
    'output_summary', v_summary
  );
END;
$function$;
