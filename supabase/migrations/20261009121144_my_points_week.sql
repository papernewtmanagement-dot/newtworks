CREATE OR REPLACE FUNCTION public.rp_my_points_week(p_week_end date DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD;
  v_end date; v_start date; v_cycle date;
  b jsonb; bp jsonb; me jsonb; mep jsonb; v_show jsonb;
  v_has_prior boolean;
  m_prior numeric := 0; m_logs int := NULL;
  q_prior int := 0;
  s_prior numeric := 0; s_logs int := 0;
  r_prior numeric := 0; r_logs int := 0;
  r jsonb; r_paid jsonb; r_later jsonb; r_adjust numeric := 0;
  v_first text;
BEGIN
  PERFORM public.require_login('staff');
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  v_end := public.rp_week_end(COALESCE(p_week_end, public.rp_today_central()));
  v_start := v_end - 6;

  b := public.rp_week_scoreboard_for(a.agency_id, v_end);
  IF COALESCE((b->>'ok')::boolean, false) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', COALESCE(b->>'error', 'Could not load the week.'));
  END IF;
  v_cycle := (b->>'cycle_start')::date;
  v_show := COALESCE(b->'show', '{}'::jsonb);

  SELECT x INTO me FROM jsonb_array_elements(COALESCE(b->'people', '[]'::jsonb)) x
   WHERE (x->>'team_member_id')::uuid = a.actor_id LIMIT 1;
  IF me IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'on_board', false, 'week_end', v_end, 'week_start', v_start,
                              'cycle_start', v_cycle);
  END IF;
  v_first := me->>'first_name';

  v_has_prior := (v_end - 7) >= v_cycle;

  IF v_has_prior THEN
    bp := public.rp_week_scoreboard_for(a.agency_id, v_end - 7);
    SELECT x INTO mep FROM jsonb_array_elements(COALESCE(bp->'people', '[]'::jsonb)) x
     WHERE (x->>'team_member_id')::uuid = a.actor_id LIMIT 1;
    m_prior := COALESCE((mep->'marketing'->>'qtd_points')::numeric, 0);
    IF jsonb_typeof(mep->'marketing'->'qtd_mix') = 'array' THEN
      SELECT COALESCE(SUM((g->>'n')::int), 0) INTO m_logs FROM jsonb_array_elements(mep->'marketing'->'qtd_mix') g;
    END IF;
  ELSE
    m_logs := 0;
  END IF;

  SELECT count(*) INTO q_prior FROM (
    SELECT DISTINCT q.week_end_date, q.customer_label, COALESCE(q.phone_last4, '')
      FROM public.quote_log q
     WHERE q.agency_id = a.agency_id AND q.status = 'active' AND q.team_member_id = a.actor_id
       AND q.week_end_date >= v_cycle AND q.week_end_date < v_end
  ) z;

  s_prior := ROUND(COALESCE((me->'sales'->>'qtd_points')::numeric, 0) - COALESCE((me->'sales'->>'points')::numeric, 0), 2);
  SELECT count(*) INTO s_logs FROM public.production_rows_for(a.agency_id, v_cycle, v_start - 1) x
   WHERE x.tm = a.actor_id AND x.units > 0;

  IF COALESCE((v_show->>'retention')::boolean, false) THEN
    SELECT COALESCE(SUM(c.net_points), 0) INTO r_prior
      FROM generate_series(1, 14) k,
           LATERAL public.compute_weekly_retention_points(a.agency_id, v_end - 7 * k) c
     WHERE (v_end - 7 * k) >= v_cycle AND c.team_member_id = a.actor_id;
    SELECT count(*) INTO r_logs FROM public.retention_activity_now l
     WHERE l.agency_id = a.agency_id AND l.team_member_id = a.actor_id AND l.status = 'credited'
       AND COALESCE(l.credited_week_end_date, l.week_end_date) >= v_cycle
       AND COALESCE(l.credited_week_end_date, l.week_end_date) < v_end;

    r := me->'retention';
    SELECT COALESCE(jsonb_agg(i ORDER BY i->>'on_date' DESC), '[]'::jsonb) INTO r_paid
      FROM jsonb_array_elements(COALESCE(r->'items', '[]'::jsonb)) i WHERE i->>'clears_on' IS NULL;
    SELECT COALESCE(jsonb_agg(i ORDER BY i->>'on_date' DESC), '[]'::jsonb) INTO r_later
      FROM jsonb_array_elements(COALESCE(r->'items', '[]'::jsonb)) i WHERE i->>'clears_on' IS NOT NULL;
    r_adjust := ROUND(COALESCE((r->>'gross')::numeric, 0) - COALESCE((r->>'hour_points')::numeric, 0)
                - COALESCE((r->>'call_points')::numeric, 0)
                - COALESCE((SELECT SUM((i->>'points')::numeric) FROM jsonb_array_elements(r_paid) i), 0), 2);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'on_board', true, 'first_name', v_first,
    'week_end', v_end, 'week_start', v_start, 'cycle_start', v_cycle,
    'mode', b->>'mode', 'show', v_show, 'has_prior', v_has_prior,
    'marketing', jsonb_build_object(
      'week_points', COALESCE((me->'marketing'->>'points')::numeric, 0),
      'qtd_points', COALESCE((me->'marketing'->>'qtd_points')::numeric, 0),
      'prior_points', m_prior, 'prior_logs', m_logs,
      'items', COALESCE(me->'marketing'->'items', '[]'::jsonb)),
    'quotes', jsonb_build_object(
      'week_count', COALESCE((me->'quotes'->>'count')::int, 0),
      'prior_count', q_prior,
      'items', COALESCE(me->'quotes'->'items', '[]'::jsonb)),
    'sales', jsonb_build_object(
      'week_points', COALESCE((me->'sales'->>'points')::numeric, 0),
      'qtd_points', COALESCE((me->'sales'->>'qtd_points')::numeric, 0),
      'prior_points', s_prior, 'prior_logs', s_logs,
      'items', COALESCE(me->'sales'->'items', '[]'::jsonb)),
    'retention', CASE WHEN COALESCE((v_show->>'retention')::boolean, false) THEN jsonb_build_object(
      'net', COALESCE((r->>'net')::numeric, 0), 'gross', COALESCE((r->>'gross')::numeric, 0),
      'reduction_pct', COALESCE((r->>'reduction_pct')::numeric, 0), 'missed_pct', COALESCE((r->>'missed_pct')::numeric, 0),
      'hours', COALESCE((r->>'hours_in_office')::numeric, 0), 'hour_points', COALESCE((r->>'hour_points')::numeric, 0),
      'calls', COALESCE((r->>'calls_answered')::int, 0), 'call_points', COALESCE((r->>'call_points')::numeric, 0),
      'adjust', r_adjust, 'paid_items', r_paid, 'later_items', r_later,
      'prior_points', r_prior, 'prior_logs', r_logs) END
  );
END $function$;

REVOKE ALL ON FUNCTION public.rp_my_points_week(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_my_points_week(date) TO authenticated;
