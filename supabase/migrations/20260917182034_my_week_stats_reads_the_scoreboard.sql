-- The day-done panel shows the same five the Scoreboard shows, in the same
-- order: Marketing Points, HH Quotes, Sales Points, Retention Points,
-- Conversations. So it reads the Scoreboard itself and picks out this one
-- person. Nothing is worked out here, which is the only way the panel and
-- the board can never disagree.
--
-- The board roster leaves the Owner out, so an owner gets on_board false
-- and the panel says so rather than printing zeros.
CREATE OR REPLACE FUNCTION public.my_week_stats(p_week_ending date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_me       uuid := public.current_team_member_id();
  v_agency   uuid;
  v_today    date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
  v_board    jsonb;
  v_me_row   jsonb;
BEGIN
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_team_member');
  END IF;

  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));

  v_board := public.rp_week_scoreboard_for(v_agency, v_week_end);

  SELECT p INTO v_me_row
  FROM jsonb_array_elements(COALESCE(v_board->'people', '[]'::jsonb)) p
  WHERE (p->>'team_member_id')::uuid = v_me;

  IF v_me_row IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'on_board', false, 'week_ending', v_week_end);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'on_board', true,
    'week_ending', v_week_end,
    'show', COALESCE(v_board->'show', '{}'::jsonb),
    'marketing_points',  COALESCE((v_me_row->'marketing'->>'points')::numeric, 0),
    'marketing_qtd',     COALESCE((v_me_row->'marketing'->>'qtd_points')::numeric, 0),
    'quotes',            COALESCE((v_me_row->'quotes'->>'count')::int, 0),
    'sales_points',      COALESCE((v_me_row->'sales'->>'points')::numeric, 0),
    'sales_qtd',         COALESCE((v_me_row->'sales'->>'qtd_points')::numeric, 0),
    'retention_net',     COALESCE((v_me_row->'retention'->>'net')::numeric, 0),
    'retention_gross',   COALESCE((v_me_row->'retention'->>'gross')::numeric, 0),
    'conversation_avg',  (v_me_row->'conversations'->>'avg')::numeric,
    'conversations',     COALESCE((v_me_row->'conversations'->>'scorecards')::int, 0),
    'pivots',            COALESCE((v_me_row->'conversations'->>'pivots')::int, 0)
  );
END $$;

GRANT EXECUTE ON FUNCTION public.my_week_stats(date) TO authenticated;
