-- Reverts the pay_scale part of mvp_first_draw_at_100_and_owner_out_of_goals (2026-09-26).
-- Peter set the prize-cart draws onto the Good / Great / Elite band starts on 2026-08-28
-- ("mvp_draw_tiers can line up with good, great, elite band starts"): 150 / 300 / 500.
-- The handbook table was never updated and still says 100 / 300 / 500; the handbook is what is out of date.
UPDATE public.pay_scale SET mvp_draws = NULL
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales' AND sales_points = 100 AND mvp_draws = 1;
UPDATE public.pay_scale SET mvp_draws = 1
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales' AND sales_points = 150;

CREATE OR REPLACE FUNCTION public.compute_mvp_prize_draws(p_agency_id uuid, p_new_sp numeric)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  /* Draws sit on the Good / Great / Elite band starts: 150 / 300 / 500 new sales points = 1 / 2 / 3 (Peter 2026-08-28). */
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
