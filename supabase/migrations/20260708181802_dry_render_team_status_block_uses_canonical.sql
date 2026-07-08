-- Tier-3 DRY (Q1): render_team_status_block uses get_expected_teammates('work_checkin').
--
-- Verified 2026-07-08 before shipping: all 4 currently-active teammates have
-- tag_in_team_reminders=true, so the tag_in_team_reminders filter drift is a
-- zero-impact convergence today. It sets up correct behavior for anyone
-- flipped to tag_in_team_reminders=false in the future -- they'll properly
-- drop out of the "expected" denominator (since they're not being pinged).
--
-- Body unchanged apart from both roster queries (count + WITH clause).

CREATE OR REPLACE FUNCTION public.render_team_status_block(
  p_agency_id UUID,
  p_as_of_date DATE,
  p_fresh_type TEXT,
  p_header_label TEXT
) RETURNS TABLE(
  block_text text, team_total_quotes numeric, team_total_sales numeric,
  fresh_count integer, carried_count integer, no_data_count integer, expected_count integer
)
LANGUAGE plpgsql
AS $fn$
DECLARE
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
  v_pool_both_clear text[] := ARRAY[
    'Both conditions clear. That''s a Win the Week if it holds.',
    'Team''s running its own pace -- quotes and SP both ahead. Keep stacking.',
    'On track on both. Don''t let the foot off the gas.'
  ];
  v_pool_quotes_pass_sp_behind text[] := ARRAY[
    'Quotes are flowing -- now turn them into closes. The conversation''s happening, the conversion''s the gap.',
    'Activity strong, conversion needs love. Focus the close work.',
    'Plenty of at-bats. Time to drive a few in.'
  ];
  v_pool_sp_pass_quotes_behind text[] := ARRAY[
    'Closes are landing without the activity volume -- efficient, but the pipeline thins fast. Feed it with quotes.',
    'SP looks great. Light quotes mean a leaner next week -- push the conversations.',
    'Hitting on quality. Now widen the funnel before next week notices.'
  ];
  v_pool_both_behind text[] := ARRAY[
    'Real ground to make up on both. The week''s not done -- push the rest hard.',
    'Behind on both. Today and tomorrow are where the week gets won.',
    'Both conditions still open. One conversation can start a streak.'
  ];
BEGIN
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_as_of_date);
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
        tc.team_id, tc.quotes_week, tc.sales_points_quarter,
        tc.checkin_date AS last_date, tc.checkin_type AS last_type
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
      c.last_date, c.last_type
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
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_row.carry_quotes::text || '/'
        || to_char(COALESCE(v_row.carry_sales, 0), 'FM999G999G999')
        || ' (carried from ' || to_char(v_row.last_date, 'Mon DD')
        || ' ' || v_row.last_type || ')' || E'\n';
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

  v_text := v_text || E'\nTeam total: ' || v_ttq::text || '/' || to_char(v_tts, 'FM999G999G999');
  v_text := v_text || '  •  ' || v_fresh || ' of ' || v_expected || ' reporting';

  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_as_of_date);
  v_q_pass := v_ttq >= v_wtw.quotes_target_total;
  v_sp_pass := v_tts >= v_wtw.sp_target;
  v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_ttq::int);
  v_sp_short := GREATEST(0, v_wtw.sp_target - v_tts);

  v_text := v_text || E'\n\n📈 Win the Week -- Week ' || v_wtw.week_of_cycle
    || ' of 13 (ends ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E')\n';
  v_text := v_text || '  Quotes: ' || v_ttq::text || ' of ' || v_wtw.quotes_target_total::text;
  IF v_q_pass THEN v_text := v_text || '  ✅ cleared';
  ELSE v_text := v_text || '  --  ' || v_q_short::text || ' to clear';
  END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (carryover: ' || v_wtw.quotes_carryover::text || ' from prior week)';
  END IF;
  v_text := v_text || E'\n';
  v_text := v_text || '  SP pace: ' || to_char(v_tts, 'FM999G999G999')
    || ' of ' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_sp_pass THEN v_text := v_text || '  ✅ cleared';
  ELSE v_text := v_text || '  --  ' || to_char(v_sp_short, 'FM999G999G999') || ' to clear';
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
  v_text := v_text || E'\n' || v_encouragement;

  RETURN QUERY SELECT v_text, v_ttq, v_tts, v_fresh, v_carried, v_nodata, v_expected;
END;
$fn$;
