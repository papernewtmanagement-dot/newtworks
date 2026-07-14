-- Hourly base pay: sum per-day-rounded hours (match get_weekly_cpr_hours),
-- not week-total-rounded raw seconds. Fixes 1-2 cent divergence between
-- displayed hours × rate and stored base_salary (Cassie 2026-07-11:
-- 39.60 raw sum × $16 = $633.60 stored vs 39.61 displayed × $16 = $633.76).

DO $mig$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_count int;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'compute_weekly_comp_residual_pool';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found';
  END IF;

  -- Edit 1: base_by_week HOURLY branch (uses pwp.wk_pay_rate + cw.week_end_date)
  v_old := $$          WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN
            (SELECT COALESCE(
              ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) * pwp.wk_pay_rate,
              NULL
            )
             FROM public.time_clock_entries tce
             WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id
               AND tce.clock_out_at IS NOT NULL
               AND tce.clock_in_at::date >= (cw.week_end_date - 6)
               AND tce.clock_in_at::date <= cw.week_end_date)$$;

  v_new := $$          WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN
            -- Sum PER-DAY-ROUNDED hours × rate, so base pay reconciles with
            -- get_weekly_cpr_hours display (which rounds each day to 2dp).
            -- Round the dollar result to 2dp for currency cleanliness.
            (SELECT ROUND(SUM(daily_hrs) * pwp.wk_pay_rate, 2)
             FROM (
               SELECT ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) AS daily_hrs
               FROM public.time_clock_entries tce
               WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id
                 AND tce.clock_out_at IS NOT NULL
                 AND tce.clock_in_at::date >= (cw.week_end_date - 6)
                 AND tce.clock_in_at::date <= cw.week_end_date
               GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')
             ) daily)$$;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / GREATEST(length(v_old), 1);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Edit 1: expected 1 match in base_by_week hourly branch, got %', v_count;
  END IF;
  v_def := replace(v_def, v_old, v_new);

  -- Edit 2: actual_base_this_week HOURLY branch (uses r.pay_rate + p_week_end_date)
  v_old := $$          WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN
            (SELECT COALESCE(
              ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) * r.pay_rate,
              NULL
            )
             FROM public.time_clock_entries tce
             WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id
               AND tce.clock_out_at IS NOT NULL
               AND tce.clock_in_at::date >= (p_week_end_date - 6)
               AND tce.clock_in_at::date <= p_week_end_date)$$;

  v_new := $$          WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN
            -- Sum PER-DAY-ROUNDED hours × rate, so base pay reconciles with
            -- get_weekly_cpr_hours display (which rounds each day to 2dp).
            -- Round the dollar result to 2dp for currency cleanliness.
            (SELECT ROUND(SUM(daily_hrs) * r.pay_rate, 2)
             FROM (
               SELECT ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) AS daily_hrs
               FROM public.time_clock_entries tce
               WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id
                 AND tce.clock_out_at IS NOT NULL
                 AND tce.clock_in_at::date >= (p_week_end_date - 6)
                 AND tce.clock_in_at::date <= p_week_end_date
               GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')
             ) daily)$$;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / GREATEST(length(v_old), 1);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Edit 2: expected 1 match in actual_base_this_week hourly branch, got %', v_count;
  END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
END $mig$;
