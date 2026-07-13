-- Fix: encouragement pools on the WtW panel selected on ABSOLUTE end-of-week
-- pass/fail. On Mon midday of a 5-day work week, this meant almost always
-- "both behind" tone (since 0/38 and 262/450 are both below endpoint) with
-- lines like "today and tomorrow are where the week gets won." Nonsense
-- when 90%+ of the work week is still ahead.
--
-- Solution: compute a pace fraction from day-of-work-week and time-of-day,
-- and select encouragement based on progress-vs-pace, not progress-vs-endpoint.
-- The absolute 🔻N delta indicator stays — still useful information.
--
-- Pool contents also rewritten to be day-of-week neutral: no "today and
-- tomorrow", no "week's not done", no time-specific urgency phrasing.
-- The pace booleans handle when to sound urgent; language stays consistent.
--
-- Pace math:
--   work_days_per_week = 5 (Mon-Fri; Sat/Sun not work days for this team)
--   intra_day fraction from CT wall clock: <12 → 0.0, 12-15 → 0.5, ≥16 → 1.0
--   day_of_workweek from ISO DOW of v_wtw_date (1=Mon ... 5=Fri; Sat=post-work=1.0; Sun=pre-work=0.0)
--   pace = clamp(0, 1, (day_offset + intra_day) / 5)

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
  v_targets record;
  v_q_pass boolean;
  v_sp_pass boolean;
  v_q_short int;
  v_sp_short numeric;
  v_encouragement text;
  v_carry_type_label text;
  v_display_quotes int;
  v_carry_label text;

  -- Pace-aware fields
  v_hour_ct int;
  v_dow int;
  v_intra_day numeric;
  v_pace numeric;
  v_this_week_sp_increment numeric;
  v_prior_sp_cumulative numeric;
  v_q_pace_pass boolean;
  v_sp_pace_pass boolean;

  -- Encouragement pools (day-of-week neutral; pace booleans handle tone)
  v_pool_both_at_pace text[] := ARRAY[
    'Both conditions running at pace. Trust the process.',
    'Team''s stacking on both. Keep the tempo.',
    'Ahead on both. Guard the lead.'
  ];
  v_pool_quotes_at_pace_sp_behind text[] := ARRAY[
    'Quote flow''s healthy — now the conversion has to follow. Close work.',
    'Activity strong, SP catching up next. Focus the closes.',
    'Plenty of at-bats. Drive some in.'
  ];
  v_pool_sp_at_pace_quotes_behind text[] := ARRAY[
    'SP running ahead on light quotes — efficient, but feed the pipeline.',
    'Closes landing. Push quote count to protect next week.',
    'Quality''s there. Now widen the funnel.'
  ];
  v_pool_both_behind_pace text[] := ARRAY[
    'Behind pace on both. Focus what''s in front of you — one strong conversation resets the tone.',
    'Ground to make up on both. Steady push.',
    'Both open. Every conversation counts.'
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

  -- Derive this-week SP increment and prior-week cumulative for pace math.
  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);
  v_this_week_sp_increment := v_targets.this_week_sp_increment;
  v_prior_sp_cumulative := v_wtw.sp_target - v_this_week_sp_increment;

  -- Compute pace fraction: elapsed portion of the 5-day work week.
  v_hour_ct := extract(hour FROM (now() AT TIME ZONE 'America/Chicago'))::int;
  v_dow := extract(isodow FROM v_wtw_date)::int;
  v_intra_day := CASE
    WHEN v_hour_ct < 12 THEN 0.0
    WHEN v_hour_ct < 16 THEN 0.5
    ELSE 1.0
  END;
  IF v_dow BETWEEN 1 AND 5 THEN
    v_pace := LEAST(1.0, ((v_dow - 1)::numeric + v_intra_day) / 5.0);
  ELSIF v_dow = 6 THEN  -- Sat, week close
    v_pace := 1.0;
  ELSE  -- Sun, pre-work
    v_pace := 0.0;
  END IF;

  -- Absolute end-of-week pass/fail (drives ✅ / 🔻N indicator).
  v_q_pass := v_ttq >= v_wtw.quotes_target_total;
  v_sp_pass := v_tts >= v_wtw.sp_target;
  v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_ttq::int);
  v_sp_short := GREATEST(0, v_wtw.sp_target - v_tts);

  -- Pace-adjusted pass/fail (drives encouragement pool selection).
  v_q_pace_pass := v_ttq >= (v_wtw.quotes_target_total::numeric * v_pace);
  v_sp_pace_pass := v_tts >= (v_prior_sp_cumulative + v_this_week_sp_increment * v_pace);

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

  IF v_q_pace_pass AND v_sp_pace_pass THEN
    v_encouragement := v_pool_both_at_pace[1 + floor(random() * array_length(v_pool_both_at_pace, 1))::int];
  ELSIF v_q_pace_pass AND NOT v_sp_pace_pass THEN
    v_encouragement := v_pool_quotes_at_pace_sp_behind[1 + floor(random() * array_length(v_pool_quotes_at_pace_sp_behind, 1))::int];
  ELSIF v_sp_pace_pass AND NOT v_q_pace_pass THEN
    v_encouragement := v_pool_sp_at_pace_quotes_behind[1 + floor(random() * array_length(v_pool_sp_at_pace_quotes_behind, 1))::int];
  ELSE
    v_encouragement := v_pool_both_behind_pace[1 + floor(random() * array_length(v_pool_both_behind_pace, 1))::int];
  END IF;

  RETURN QUERY SELECT v_text, v_encouragement, v_ttq, v_tts, v_fresh, v_carried, v_nodata, v_expected;
END;
$function$;

COMMENT ON FUNCTION public.render_team_status_block(uuid, date, text, text, date) IS
'Renders per-person + WtW panel block for Telegram. Weekly quotes reset for prior-week carryovers (SP still carries as QTD). Encouragement selected on PACE-adjusted pass/fail (progress vs elapsed-portion-of-5-day-work-week), not end-of-week absolute — so Monday midday with 262/450 SP is treated as ahead-of-pace, not behind. The visual 🔻N indicator remains end-of-week absolute delta.';
