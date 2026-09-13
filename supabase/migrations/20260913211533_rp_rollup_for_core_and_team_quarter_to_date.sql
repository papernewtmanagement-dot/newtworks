-- Peter 2026-09-13.
-- 1. "Scorecard average" is renamed CONVERSATION SCORE everywhere new. Peter's only
--    scorecard is his annual corporate bonus; this is the graded call (fit_scorecards:
--    demeanor, FROGS, intro, eligibility, GNC, gap, bridge, close, follow-up, review ask).
--    rp_week_rollup keeps its old output column names so the app does not break; the
--    frontend rename is a separate pass.
-- 2. rp_week_rollup only worked for a signed-in person: it resolved the agency from
--    auth.uid() and ended WHERE auth.uid() IS NOT NULL, so a scheduled job got nothing
--    back and the conversation score posted blank. Body is split into rp_rollup_for(),
--    which takes the agency and a date range. rp_week_rollup is now a thin wrapper over
--    it. One copy of the math, two callers.
-- 3. team_quarter_to_date() is the single place the quarter numbers come from. The
--    check-in summaries, the kickoff and My Week all read it, so they cannot drift.
--    Quotes are THIS WEEK; everything else is quarter to date (Peter, locked).

CREATE OR REPLACE FUNCTION public.rp_rollup_for(
  p_agency_id uuid, p_from date, p_to date, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(team_member_id uuid, conversations integer, conversation_score numeric,
               pivots integer, review_asks integer, referral_asks integer,
               policy_reviews integer, online_reviews integer, referrals_sold integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cards AS (
    SELECT f.team_member_id AS tm, count(*)::integer AS n, round(avg(f.average_score), 2) AS avg
    FROM public.fit_scorecards f
    WHERE f.agency_id = p_agency_id AND f.scorecard_date BETWEEN p_from AND p_to
    GROUP BY f.team_member_id
  ),
  acts AS (
    SELECT l.team_member_id AS tm,
      count(*) FILTER (WHERE l.activity_key = 'pivot')::integer AS pivots,
      count(*) FILTER (WHERE l.activity_key = 'review_ask')::integer AS review_asks,
      count(*) FILTER (WHERE l.activity_key = 'referral_ask')::integer AS referral_asks,
      count(*) FILTER (WHERE l.activity_key = 'policy_review')::integer AS policy_reviews,
      count(*) FILTER (WHERE l.activity_key IN ('google_review','online_review'))::integer AS online_reviews,
      count(*) FILTER (WHERE l.activity_key = 'referral_sold')::integer AS referrals_sold
    FROM public.retention_activity_log l
    WHERE l.agency_id = p_agency_id AND l.week_end_date BETWEEN p_from AND p_to AND l.status = 'credited'
    GROUP BY l.team_member_id
  ),
  -- Peter 2026-09-11: contributions are never gated by employment. Active people, plus
  -- anyone who has anything inside the window, whenever they left.
  members AS (
    SELECT t.id FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND (t.archived_at IS NULL
           OR t.id IN (SELECT tm FROM cards) OR t.id IN (SELECT tm FROM acts))
      AND (p_team_member_id IS NULL OR t.id = p_team_member_id)
  )
  SELECT m.id, COALESCE(c.n, 0), c.avg,
         COALESCE(a.pivots, 0), COALESCE(a.review_asks, 0), COALESCE(a.referral_asks, 0),
         COALESCE(a.policy_reviews, 0), COALESCE(a.online_reviews, 0), COALESCE(a.referrals_sold, 0)
  FROM members m
  LEFT JOIN cards c ON c.tm = m.id
  LEFT JOIN acts  a ON a.tm = m.id;
$function$;

-- Wrapper. Same output column names as before so nothing in the app breaks.
CREATE OR REPLACE FUNCTION public.rp_week_rollup(p_week_end date, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(team_member_id uuid, scorecards integer, scorecard_avg numeric, pivots integer,
               review_asks integer, referral_asks integer, policy_reviews integer,
               google_reviews integer, referrals_sold integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT r.team_member_id, r.conversations, r.conversation_score, r.pivots,
         r.review_asks, r.referral_asks, r.policy_reviews, r.online_reviews, r.referrals_sold
  FROM public.users u
  CROSS JOIN LATERAL public.rp_rollup_for(u.agency_id, p_week_end - 6, p_week_end, p_team_member_id) r
  WHERE u.auth_user_id = auth.uid();
$function$;

-- The single quarter-to-date source.
CREATE OR REPLACE FUNCTION public.team_quarter_to_date(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(team_member_id uuid, first_name text,
               marketing_points numeric, household_quotes_week integer, sales_points numeric,
               retention_points numeric, conversation_score numeric, conversations integer,
               cycle_start date, week_end date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cycle_start date; v_week_end date; v_board jsonb;
BEGIN
  SELECT cci.cycle_start, cci.week_ending_saturday
    INTO v_cycle_start, v_week_end
  FROM public.current_cycle_info(p_agency_id, p_as_of) cci;

  -- Sales points quarter to date come from the existing scoreboard, not a second copy
  -- of the maths. It already runs compute_sp_from_production over issued policies.
  v_board := public.rp_week_scoreboard_for(p_agency_id, v_week_end);

  RETURN QUERY
  WITH board AS (
    SELECT (p->>'team_member_id')::uuid AS tm,
           COALESCE((p->'sales'->>'qtd_points')::numeric, 0) AS sp
    FROM jsonb_array_elements(v_board -> 'people') p
  ),
  mkt AS (
    SELECT m.team_member_id AS tm, SUM(m.points) AS pts
    FROM public.marketing_points m
    WHERE m.agency_id = p_agency_id AND m.week_end_date BETWEEN v_cycle_start AND v_week_end
    GROUP BY m.team_member_id
  ),
  -- Quotes are THIS WEEK only. Peter corrected this explicitly; do not re-scope.
  qw AS (
    SELECT q.team_member_id AS tm, count(*)::integer AS n
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.week_end_date = v_week_end
    GROUP BY q.team_member_id
  ),
  ret AS (
    SELECT r.team_member_id AS tm, SUM(r.net_points) AS pts
    FROM generate_series(v_cycle_start + 6, v_week_end, '7 days'::interval) g
    CROSS JOIN LATERAL public.compute_weekly_retention_points(p_agency_id, g::date) r
    GROUP BY r.team_member_id
  ),
  conv AS (
    SELECT c.team_member_id AS tm, c.conversation_score AS score, c.conversations AS n
    FROM public.rp_rollup_for(p_agency_id, v_cycle_start, v_week_end) c
  ),
  roster AS (
    SELECT t.id, t.first_name FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.category = 'agency'
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND COALESCE(t.is_test_user, false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner')
      AND (t.archived_at IS NULL
           OR t.id IN (SELECT tm FROM mkt) OR t.id IN (SELECT tm FROM board WHERE sp > 0))
  )
  SELECT r.id, r.first_name,
         COALESCE(mkt.pts, 0), COALESCE(qw.n, 0), COALESCE(board.sp, 0),
         COALESCE(ret.pts, 0), conv.score, COALESCE(conv.n, 0),
         v_cycle_start, v_week_end
  FROM roster r
  LEFT JOIN mkt   ON mkt.tm   = r.id
  LEFT JOIN qw    ON qw.tm    = r.id
  LEFT JOIN board ON board.tm = r.id
  LEFT JOIN ret   ON ret.tm   = r.id
  LEFT JOIN conv  ON conv.tm  = r.id
  ORDER BY r.first_name;
END;
$function$;