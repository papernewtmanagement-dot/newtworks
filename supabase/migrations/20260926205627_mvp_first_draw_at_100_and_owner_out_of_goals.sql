-- Handbook (Winning & Learning > Most Valuable Player): 100 new sales points = 1 draw, 300 = 2, 500 = 3.
-- The first draw had been sitting on the 150 row (the Good band start) and the function only read band-start rows,
-- so an MVP between 100 and 149 got 0 draws. Draw thresholds are deliberately separate from band starts.
UPDATE public.pay_scale SET mvp_draws = NULL
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales' AND sales_points = 150 AND mvp_draws = 1;
UPDATE public.pay_scale SET mvp_draws = 1
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales' AND sales_points = 100;

CREATE OR REPLACE FUNCTION public.compute_mvp_prize_draws(p_agency_id uuid, p_new_sp numeric)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  /* Draw thresholds (100/300/500) are their own measure, NOT the band starts (50/150/300/500). */
  SELECT COALESCE(
    (SELECT ps.mvp_draws
       FROM public.pay_scale ps
      WHERE ps.agency_id = p_agency_id
        AND ps.role_key = 'sales'
        AND ps.mvp_draws IS NOT NULL
        AND ps.sales_points <= p_new_sp
      ORDER BY ps.sales_points DESC
      LIMIT 1),
    0
  );
$function$;

-- The owner has a CPR detail row only for his own wrap-up/inbox; he never earns a goals bonus or MVP.
DO $mig$
DECLARE v_src text;
BEGIN
  v_src := pg_get_functiondef('public.write_weekly_comp_v2(uuid,date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    '(CASE WHEN EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = p.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date) THEN 0 ELSE 10 END',
    '(CASE WHEN EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = p.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date) OR public.team_is_owner(p.team_member_id) /* owner row is only for his wrap-up: no goals bonus */ THEN 0 ELSE 10 END', 1);
  v_src := public.fn_source_replace_exact(v_src,
    'AND NOT EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = d.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date))',
    'AND NOT EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = d.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date)
          AND NOT public.team_is_owner(d.team_member_id))', 1);
  EXECUTE v_src;
END $mig$;
