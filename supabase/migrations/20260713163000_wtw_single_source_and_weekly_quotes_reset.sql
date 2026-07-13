-- WtW math single-source-of-truth refactor + weekly quotes reset in display.
--
-- Problem 1: Three functions hardcoded the constants (15/8 quotes, 100/50 SP):
--   get_win_the_week_state, weekly_cpr_compute_outcome, compute_cumulative_sp_target.
--   Changing WtW rules meant patching three places. Fragile.
--
-- Fix 1: Introduce compute_wtw_week_targets(agency, week_start) — THE only place
--   the constants live. All three refactored to call it.
--
-- Problem 2: When rendering per-person block on Mon midday/EOD (before anyone
--   has submitted this week), the "carried" fallback shows last Friday's quotes
--   as if they still count. Quotes reset weekly, so last week's 30 shouldn't
--   render on this week's compile.
--
-- Fix 2: In render_team_status_block, when the carried check-in's date is
--   before v_week_start, reset quotes to 0. SP still carries (it's QTD).

CREATE OR REPLACE FUNCTION public.compute_wtw_week_targets(
  p_agency_id uuid,
  p_week_start date
) RETURNS TABLE(
  quotes_fresh_needed int,
  this_week_sp_increment numeric,
  am_sales int,
  am_retention int
)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT
    ((15 * c.am_sales) + (8 * c.am_retention))::int,
    ((100::numeric * c.am_sales) + (50::numeric * c.am_retention))::numeric,
    c.am_sales,
    c.am_retention
  FROM public.get_wtw_am_counts(p_agency_id, p_week_start) c;
$function$;

COMMENT ON FUNCTION public.compute_wtw_week_targets(uuid, date) IS
'SINGLE SOURCE OF TRUTH for WtW per-week target math. Constants (15/8 quotes, 100/50 SP) live ONLY here. Any change to WtW rules must be made in this function; all consumers derive from it.';


CREATE OR REPLACE FUNCTION public.get_win_the_week_state(p_agency_id uuid, p_today date DEFAULT NULL::date)
 RETURNS TABLE(week_of_cycle integer, week_ending_saturday date, count_am_sales integer, count_am_retention integer, quotes_fresh_needed integer, quotes_carryover integer, quotes_target_total integer, sp_target numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_today date;
  v_cycle record;
  v_week_start date;
  v_carryover int := 0;
  v_this_week_sp_increment numeric;
  v_prior_sp_cumulative numeric;
  v_targets record;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_today);
  v_week_start := v_cycle.week_ending_saturday - 6;

  -- Single source: pulls quotes_fresh_needed + this_week_sp_increment + AM counts
  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);
  v_this_week_sp_increment := v_targets.this_week_sp_increment;

  -- Quotes carryover resets at cycle boundary (mirrors SP reset below and weekly_cpr_compute_outcome).
  IF v_cycle.week_of_cycle <= 1 THEN
    v_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_carryover := COALESCE(v_carryover, 0);
  END IF;

  IF v_cycle.week_of_cycle <= 1 THEN
    v_prior_sp_cumulative := 0;
  ELSE
    SELECT quarterly_sales_points_target INTO v_prior_sp_cumulative
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    IF v_prior_sp_cumulative IS NULL THEN
      -- Fallback via authoritative helper (cheap on n<=13)
      v_prior_sp_cumulative := public.compute_cumulative_sp_target(p_agency_id, v_cycle.week_of_cycle - 1, v_cycle.cycle_start);
    END IF;
  END IF;

  week_of_cycle := v_cycle.week_of_cycle;
  week_ending_saturday := v_cycle.week_ending_saturday;
  count_am_sales := v_targets.am_sales;
  count_am_retention := v_targets.am_retention;
  quotes_fresh_needed := v_targets.quotes_fresh_needed;
  quotes_carryover := v_carryover;
  quotes_target_total := quotes_fresh_needed + v_carryover;
  sp_target := v_prior_sp_cumulative + v_this_week_sp_increment;

  RETURN NEXT;
END;
$function$;


CREATE OR REPLACE FUNCTION public.compute_cumulative_sp_target(p_agency_id uuid, p_through_week integer, p_cycle_start date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_total numeric := 0;
  v_week_start date;
  v_targets record;
  w int;
BEGIN
  IF p_through_week < 1 THEN RETURN 0; END IF;

  FOR w IN 1..p_through_week LOOP
    v_week_start := p_cycle_start + ((w - 1) * 7);
    SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);
    v_total := v_total + v_targets.this_week_sp_increment;
  END LOOP;

  RETURN v_total;
END;
$function$;


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
  v_targets record;
  v_quotes_fresh_needed int;
  v_team_carryover int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_sales_points_qtd numeric := 0;
  v_this_week_sp_increment numeric;
  v_sp_target numeric;
  v_won boolean;
  v_quotes_pass boolean;
  v_sp_pass boolean;
  v_result_id uuid;
  v_pay_write jsonb;
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

  -- Single source: quotes_fresh_needed + this_week_sp_increment
  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);
  v_quotes_fresh_needed := v_targets.quotes_fresh_needed;
  v_this_week_sp_increment := v_targets.this_week_sp_increment;

  SELECT
    COALESCE(SUM(net_quotes),       0)::int,
    COALESCE(SUM(quotes_discussed), 0)::int
  INTO
    v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  IF v_cycle.week_of_cycle <= 1 THEN
    v_team_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_team_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_team_carryover := COALESCE(v_team_carryover, 0);
  END IF;

  v_sp_target := public.compute_cumulative_sp_target(p_agency_id, v_cycle.week_of_cycle, v_cycle.cycle_start);

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

  v_quotes_pass := v_team_net_quotes >= (v_quotes_fresh_needed + v_team_carryover);
  v_sp_pass := v_sales_points_qtd >= v_sp_target;
  v_won := v_quotes_pass AND v_sp_pass;

  v_quotes_owed_next := GREATEST(0, v_quotes_fresh_needed + v_team_carryover - v_team_net_quotes);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_quotes_owed_next,
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

  v_pay_write := public.write_weekly_pay(p_agency_id, v_week_end);

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format(
      'Week %s of 13 (ending %s): carryover=%s, fresh=%s, net=%s, gross_pool=%s, owed_fwd=%s, SP %s/%s, q_pass=%s, sp_pass=%s, won=%s, payroll_rows=%s',
      v_cycle.week_of_cycle, v_week_end,
      v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_team_quotes_pool,
      v_quotes_owed_next,
      v_sales_points_qtd, v_sp_target,
      v_quotes_pass, v_sp_pass, v_won,
      v_pay_write->>'rows_updated')
  );
END;
$function$;


-- render_team_status_block: reset carried quotes to 0 when the source check-in
-- is from a prior week. SP still carries (QTD). Label makes source explicit
-- so readers know which value survived vs reset.
CREATE OR REPLACE FUNCTION public.render_team_status_block(
  p_agency_id uuid,
  p_as_of_date date,
  p_fresh_type text,
  p_header_label text,
  p_wtw_as_of_date date DEFAULT NULL
)
 RETURNS TABLE(block_text text, encouragement_text text, team_total_quotes numeric, team_total_sales numeric, fresh_count integer, carried_count integer, no_data_count integer, expected_count integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_wtw_date date;
  v_cycle record;
  v_week_start date;
  v_row record;
  v_text text := '';
  v_ttq numeric := 0;
  v_tts numeric := 0;
  v_fresh int := 0;
  v_carried int := 0;
  v_nodata int := 0;
  v_expected int := 0;
  v_wtw record;
  v_q_pass boolean;
  v_sp_pass boolean;
  v_q_short int;
  v_sp_short numeric;
  v_encouragement text;
  v_carry_type_label text;
  v_display_quotes int;
  v_carry_label text;
  v_pool_both_clear text[] := ARRAY[
    'Both conditions clear. That''s a Win the Week if it holds.',
    'Team''s running its own pace — quotes and SP both ahead. Keep stacking.',
    'On track on both. Don''t let the foot off the gas.'
  ];
  v_pool_quotes_pass_sp_behind text[] := ARRAY[
    'Quotes are flowing — now turn them into closes. The conversation''s happening, the conversion''s the gap.',
    'Activity strong, conversion needs love. Focus the close work.',
    'Plenty of at-bats. Time to drive a few in.'
  ];
  v_pool_sp_pass_quotes_behind text[] := ARRAY[
    'Closes are landing without the activity volume — efficient, but the pipeline thins fast. Feed it with quotes.',
    'SP looks great. Light quotes mean a leaner next week — push the conversations.',
    'Hitting on quality. Now widen the funnel before next week notices.'
  ];
  v_pool_both_behind text[] := ARRAY[
    'Real ground to make up on both. The week''s not done — push the rest hard.',
    'Behind on both. Today and tomorrow are where the week gets won.',
    'Both conditions still open. One conversation can start a streak.'
  ];
BEGIN
  v_wtw_date := COALESCE(p_wtw_as_of_date, p_as_of_date);

  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_wtw_date);
  v_week_start := v_cycle.week_ending_saturday - 6;

  v_text := p_header_label || E'\n\n';

  SELECT count(*) INTO v_expected
  FROM public.get_expected_teammates(p_agency_id, 'work_checkin', p_as_of_date);

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, display_name, first_name
      FROM public.get_expected_teammates(p_agency_id, 'work_checkin', p_as_of_date)
    ),
    current_period AS (
      SELECT tc.team_id, tc.quotes_week, tc.sales_points_quarter, tc.is_proxy_submission,
             sub.first_name AS submitted_by_first_name
      FROM public.team_checkins tc
      LEFT JOIN public.team sub ON sub.id = tc.submitted_by_team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = p_as_of_date
        AND tc.checkin_type = p_fresh_type
    ),
    carried AS (
      SELECT DISTINCT ON (tc.team_id)
        tc.team_id,
        tc.quotes_week,
        tc.sales_points_quarter,
        tc.checkin_date AS last_date,
        tc.checkin_type AS last_type,
        (tc.checkin_date < v_week_start) AS is_prior_week
      FROM public.team_checkins tc
      WHERE tc.agency_id = p_agency_id
        AND NOT (tc.checkin_date = p_as_of_date AND tc.checkin_type = p_fresh_type)
      ORDER BY tc.team_id, tc.received_at DESC
    )
    SELECT e.team_id, e.display_name, e.first_name,
      cp.quotes_week AS cur_quotes, cp.sales_points_quarter AS cur_sales,
      COALESCE(cp.is_proxy_submission, false) AS is_proxy_submission,
      cp.submitted_by_first_name,
      c.quotes_week AS carry_quotes, c.sales_points_quarter AS carry_sales,
      c.last_date, c.last_type, c.is_prior_week
    FROM expected e
    LEFT JOIN current_period cp ON cp.team_id = e.team_id
    LEFT JOIN carried c ON c.team_id = e.team_id
    ORDER BY e.first_name
  LOOP
    IF v_row.cur_quotes IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_row.cur_quotes::text || '/'
        || to_char(COALESCE(v_row.cur_sales, 0), 'FM999G999G999');
      IF v_row.is_proxy_submission THEN
        v_text := v_text || ' (via ' || v_row.submitted_by_first_name || ')';
      END IF;
      v_text := v_text || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.carry_quotes IS NOT NULL THEN
      v_carry_type_label := CASE v_row.last_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_row.last_type) END;
      -- Weekly quotes reset: if the carried check-in is from a prior week,
      -- quotes reset to 0. SP still carries (QTD tracking).
      IF COALESCE(v_row.is_prior_week, false) THEN
        v_display_quotes := 0;
        v_carry_label := 'SP from ' || v_carry_type_label || ' ' || to_char(v_row.last_date, 'Mon DD');
      ELSE
        v_display_quotes := v_row.carry_quotes;
        v_carry_label := v_carry_type_label || ' ' || to_char(v_row.last_date, 'Mon DD');
      END IF;
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_display_quotes::text || '/'
        || to_char(COALESCE(v_row.carry_sales, 0), 'FM999G999G999')
        || ' (' || v_carry_label || ')' || E'\n';
      v_carried := v_carried + 1;
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0' || E'\n';
      v_nodata := v_nodata + 1;
    END IF;
  END LOOP;

  SELECT COALESCE(SUM(latest_q), 0) INTO v_ttq
  FROM (
    SELECT DISTINCT ON (tc.team_id) tc.quotes_week AS latest_q
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_week_start AND v_cycle.week_ending_saturday
      AND tc.checkin_type IN ('midday', 'eod')
      AND tc.quotes_week IS NOT NULL
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member_week;

  SELECT COALESCE(SUM(latest_sp), 0) INTO v_tts
  FROM (
    SELECT DISTINCT ON (tc.team_id) tc.sales_points_quarter AS latest_sp
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle.cycle_start AND v_cycle.week_ending_saturday
      AND tc.checkin_type IN ('midday', 'eod')
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member_qtr;

  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, v_wtw_date);
  v_q_pass := v_ttq >= v_wtw.quotes_target_total;
  v_sp_pass := v_tts >= v_wtw.sp_target;
  v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_ttq::int);
  v_sp_short := GREATEST(0, v_wtw.sp_target - v_tts);

  v_text := v_text || E'\n📈 WtW ' || v_wtw.week_of_cycle
    || ' ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E'\n';
  v_text := v_text || '  Quotes: ' || v_ttq::text || '/' || v_wtw.quotes_target_total::text;
  IF v_q_pass THEN
    v_text := v_text || ' ✅';
  ELSE
    v_text := v_text || ' 🔻' || v_q_short::text;
  END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (+' || v_wtw.quotes_carryover::text || ' carryover)';
  END IF;
  v_text := v_text || E'\n';
  v_text := v_text || '  Sales: ' || to_char(v_tts, 'FM999G999G999')
    || '/' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_sp_pass THEN
    v_text := v_text || ' ✅';
  ELSE
    v_text := v_text || ' 🔻' || to_char(v_sp_short, 'FM999G999G999');
  END IF;
  v_text := v_text || E'\n';

  IF v_q_pass AND v_sp_pass THEN
    v_encouragement := v_pool_both_clear[1 + floor(random() * array_length(v_pool_both_clear, 1))::int];
  ELSIF v_q_pass AND NOT v_sp_pass THEN
    v_encouragement := v_pool_quotes_pass_sp_behind[1 + floor(random() * array_length(v_pool_quotes_pass_sp_behind, 1))::int];
  ELSIF v_sp_pass AND NOT v_q_pass THEN
    v_encouragement := v_pool_sp_pass_quotes_behind[1 + floor(random() * array_length(v_pool_sp_pass_quotes_behind, 1))::int];
  ELSE
    v_encouragement := v_pool_both_behind[1 + floor(random() * array_length(v_pool_both_behind, 1))::int];
  END IF;

  RETURN QUERY SELECT v_text, v_encouragement, v_ttq, v_tts, v_fresh, v_carried, v_nodata, v_expected;
END;
$function$;

COMMENT ON FUNCTION public.render_team_status_block(uuid, date, text, text, date) IS
'Renders per-person + WtW panel block for Telegram messages. Weekly quotes reset: when a person''s last check-in is from a prior week, their quotes display as 0 for the current week (SP still carries as QTD). WtW targets sourced from get_win_the_week_state (which uses compute_wtw_week_targets — single source of truth for 15/8/100/50 constants).'
