-- Putting the goals bonus into pay_scale left a second copy behind: the
-- year-by-year grid and the Retention / Life Specialist curves were still
-- reading a hardcoded c_goals_wk map inside compute_role_earnings_projection.
-- Two copies of the same four numbers is exactly the drift the
-- consolidation was for. The tiers helper now carries the weekly goals rate
-- and the hardcoded map is gone.
--
-- The helper gains an OUT column, which Postgres will not do in place, so it
-- is dropped and recreated. Its only caller is the projection, rewired in
-- the same migration.

DROP FUNCTION IF EXISTS public.pay_scale_performer_tiers(uuid);

CREATE FUNCTION public.pay_scale_performer_tiers(p_agency_id uuid)
 RETURNS TABLE(tier_key text, tier_label text, applicant_pct numeric, multiplier numeric,
               descriptor text, goals_weekly numeric, band_from_x numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.band_tier_key, p.band_tier_label, p.band_applicant_pct,
         p.band_production_multiplier, p.band_tier_traits, p.goals_weekly, p.sales_points
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
     AND p.band_tier_key IS NOT NULL
   ORDER BY p.sales_points;
$function$;

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='compute_role_earnings_projection';
  v_new := v_def;

  v_new := replace(v_new,
    $a$        SELECT t.tier_key, t.tier_label, t.applicant_pct, t.multiplier, t.descriptor$a$,
    $b$        SELECT t.tier_key, t.tier_label, t.applicant_pct, t.multiplier, t.descriptor,
               t.goals_weekly$b$);

  v_new := replace(v_new,
    $a$          SELECT t.tier_key, t.tier_label, t.multiplier,$a$,
    $b$          SELECT t.tier_key, t.tier_label, t.multiplier, t.goals_weekly,$b$);

  v_new := replace(v_new,
    $a$          v_goals := (c_goals_wk->>r_tier.tier_key)::numeric * 52$a$,
    $b$          v_goals := COALESCE(r_tier.goals_weekly, 0) * 52$b$);

  v_new := replace(v_new,
    $a$            'goals_weekly', (c_goals_wk->>r_tier.tier_key)::numeric$a$,
    $b$            'goals_weekly', COALESCE(r_tier.goals_weekly, 0)$b$);

  v_new := replace(v_new,
    $a$  c_goals_wk        jsonb := '{"casual":10,"rock":20,"rockstar":30,"rock_legend":40}'::jsonb;
$a$, $b$$b$);

  IF v_new LIKE '%c_goals_wk%' THEN
    RAISE EXCEPTION 'hardcoded goals map still present';
  END IF;
  EXECUTE v_new;
END
$mig$;
