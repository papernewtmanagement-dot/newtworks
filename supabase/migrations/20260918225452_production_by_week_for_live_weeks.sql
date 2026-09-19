-- Peter 2026-09-18: the Team Activity per-person expanders show no production
-- for this week.
--
-- The expander reads the prod_* columns on weekly_cpr_team_detail. Those come
-- from the State Farm producer production report, which only reaches through
-- rp_reported_through(). Weeks past that point have no imported row, so the
-- expander showed nothing even though the production log is full of this week's
-- work. This returns the same shape from the live log, for those weeks only.
--
-- Line columns follow the log's own counting: auto counts one app per vehicle,
-- everything else counts policies. Premium is issued premium.
CREATE OR REPLACE FUNCTION public.production_by_week_for(p_agency_id uuid, p_from date, p_through date)
RETURNS TABLE(team_member_id uuid, week_ending_date date, issued_count integer,
              issued_premium numeric, auto integer, fire integer, life integer,
              health integer, bank integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT x.tm,
         (x.issued_date + (6 - EXTRACT(DOW FROM x.issued_date)::int))::date AS wk,
         SUM(x.policy_count)::int,
         ROUND(SUM(x.premium), 2),
         COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.units        END), 0)::int,
         COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.policy_count END), 0)::int,
         COALESCE(SUM(CASE WHEN x.lob = 'life'   THEN x.policy_count END), 0)::int,
         COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.policy_count END), 0)::int,
         COALESCE(SUM(CASE WHEN x.lob = 'bank'   THEN x.policy_count END), 0)::int
  FROM public.production_rows_for(p_agency_id, p_from, p_through) x
  WHERE (x.issued_date + (6 - EXTRACT(DOW FROM x.issued_date)::int))::date
        > public.rp_reported_through()
  GROUP BY x.tm, 2;
$function$;
