-- Peter 2026-09-13, decision 1A: freeze before Production goes into the resolver.
-- Reason: the CPR-override source is naturally frozen (those rows are history and
-- never move), but Production is live and moves BACKWARDS -- a backfill landing today
-- changes what a paid week computes to. Proven the same day: a household inserted with
-- an 08/26 issue date changed John's Production figure for the already-paid week ending
-- 08/29. So a paid week has to keep the number it was paid on.
-- sales_points stays exactly what it is: Peter's typed override. Never repurposed.

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS sales_points_frozen        numeric,
  ADD COLUMN IF NOT EXISTS sales_points_frozen_at     timestamptz,
  ADD COLUMN IF NOT EXISTS sales_points_frozen_source text;

COMMENT ON COLUMN public.weekly_cpr_team_detail.sales_points_frozen IS
  'Quarter-to-date sales points as resolved at the moment this CPR week went to the team. Write once, never overwrite. Read by get_sales_points_qtd ahead of the live sources.';

CREATE OR REPLACE FUNCTION public.freeze_sales_points_for_week(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_member_id uuid, frozen_points numeric, frozen_source text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end date := p_week_end;
BEGIN
  -- Write once. A week already frozen is never touched again, so reruns are safe
  -- and a later backfill can never move a number the team was already paid on.
  RETURN QUERY
  UPDATE public.weekly_cpr_team_detail d
     SET sales_points_frozen        = g.sales_points,
         sales_points_frozen_at     = now(),
         sales_points_frozen_source = g.source
    FROM public.weekly_cpr_reports r,
         public.get_sales_points_qtd(p_agency_id, v_week_end) g
   WHERE d.weekly_cpr_report_id = r.id
     AND r.agency_id = p_agency_id
     AND r.week_ending_date = v_week_end
     AND d.team_member_id = g.team_id
     AND d.sales_points_frozen IS NULL
  RETURNING d.team_member_id, d.sales_points_frozen, d.sales_points_frozen_source;
END $function$;

-- The single resolver now checks the freeze first. Precedence per person per week:
-- frozen -> Peter's CPR override -> self-reported check-in. Production becomes a
-- fourth source INSIDE THIS FUNCTION and nowhere else, once the freeze is in place.
CREATE OR REPLACE FUNCTION public.get_sales_points_qtd(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_id uuid, sales_points numeric, source text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_end date;
  v_cycle_start date;
BEGIN
  SELECT c.week_ending_saturday, c.cycle_start INTO v_week_end, v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_end) c;

  RETURN QUERY
  WITH override AS (
    -- Per week, a frozen figure wins over the typed override. Then, as before,
    -- take the most recent week in the cycle that has either.
    SELECT DISTINCT ON (d.team_member_id)
      d.team_member_id AS tm,
      COALESCE(d.sales_points_frozen, d.sales_points) AS pts,
      (d.sales_points_frozen IS NOT NULL) AS was_frozen
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date BETWEEN v_cycle_start AND v_week_end
      AND COALESCE(d.sales_points_frozen, d.sales_points) IS NOT NULL
    ORDER BY d.team_member_id, r.week_ending_date DESC
  ),
  reported AS (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id AS tm, tc.sales_points_quarter AS pts
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle_start AND v_week_end
      AND tc.sales_points_quarter IS NOT NULL
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ),
  everyone AS (
    SELECT tm FROM override UNION SELECT tm FROM reported
  )
  SELECT e.tm,
         COALESCE(o.pts, rp.pts, 0)::numeric,
         CASE WHEN o.pts IS NOT NULL AND o.was_frozen THEN 'frozen'
              WHEN o.pts IS NOT NULL THEN 'cpr_override'
              WHEN rp.pts IS NOT NULL THEN 'self_reported'
              ELSE 'none' END
  FROM everyone e
  LEFT JOIN override o ON o.tm = e.tm
  LEFT JOIN reported rp ON rp.tm = e.tm;
END;
$function$;
