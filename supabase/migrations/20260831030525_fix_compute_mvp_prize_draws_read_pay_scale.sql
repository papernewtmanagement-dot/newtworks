-- compute_mvp_prize_draws still pointed at public.mvp_draw_tiers, which was dropped on
-- 2026-08-29 when the draw tiers were absorbed into pay_scale. The function has been
-- raising undefined_table ever since; write_weekly_comp_v2 swallows it in its exception
-- block, so MVP detection has been failing silently rather than loudly.
-- Tiers now live on pay_scale band starts: 150 -> 1 draw, 300 -> 2, 500 -> 3.

CREATE OR REPLACE FUNCTION public.compute_mvp_prize_draws(p_agency_id uuid, p_new_sp numeric)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT ps.mvp_draws
       FROM public.pay_scale ps
      WHERE ps.agency_id = p_agency_id
        AND ps.mvp_draws IS NOT NULL
        AND ps.band_starts_here
        AND ps.sales_points <= p_new_sp
      ORDER BY ps.sales_points DESC
      LIMIT 1),
    0
  );
$function$;

COMMENT ON FUNCTION public.compute_mvp_prize_draws(uuid, numeric) IS
'MVP weekly prize draws from the new sales points earned that week. Reads the band-start rows on pay_scale (mvp_draws), which replaced the dropped mvp_draw_tiers table on 2026-08-29. Agency-wide award, so the lookup is deliberately not scoped to a role_key - only the sales ladder carries mvp_draws.';
