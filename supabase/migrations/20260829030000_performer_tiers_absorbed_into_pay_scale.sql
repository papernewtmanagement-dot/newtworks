-- Peter 2026-08-28: earnings_projection_tiers folded into pay_scale and
-- dropped. It held four rows — one per performer tier — with the share of
-- applicants at that tier, a production multiplier against the role's
-- weekly target, and a descriptor. compute_role_earnings_projection was its
-- only reader anywhere.
--
-- Each tier maps 1:1 onto a band, exactly as Peter specified for the chart
-- headers, so each tier now lives on the pay_scale row where its band
-- starts. Danger carries no tier.
--
-- This also kills a live contradiction: the chart had the nicknames and
-- percentages HARDCODED in the frontend as Casual 75 / Rock 19 / Rockstar 5
-- / Rock Legend 1, while this table still said Rock 75 / Rock n' Roll 19.
-- Two copies, disagreeing. The keys are renamed to match the labels
-- (rock -> casual, rock_n_roll -> rock) and every jsonb map keyed on them
-- is rewritten in the same migration. Multipliers and percentages are
-- carried over untouched, so no projected figure moves.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS band_tier_key             text,
  ADD COLUMN IF NOT EXISTS band_tier_label           text,
  ADD COLUMN IF NOT EXISTS band_applicant_pct        numeric,
  ADD COLUMN IF NOT EXISTS band_tier_traits          text,
  ADD COLUMN IF NOT EXISTS band_production_multiplier numeric;

COMMENT ON COLUMN public.pay_scale.band_tier_key IS
  'Set on the row where a band begins. That row IS the performer tier for the band: its nickname, share of applicants, traits and production multiplier. Danger has none.';

UPDATE public.pay_scale p
   SET band_tier_key = v.k, band_tier_label = v.l,
       band_applicant_pct = v.pct, band_tier_traits = v.tr,
       band_production_multiplier = v.mult
  FROM (VALUES
    ( 50, 'casual',      'Casual',      75, NULL,                               1.000),
    (150, 'rock',        'Rock',        19, 'Consistent',                       1.610),
    (300, 'rockstar',    'Rockstar',     5, 'Consistent, Having Fun',           2.640),
    (500, 'rock_legend', 'Rock Legend',  1, 'Consistent, Having Fun, Obsessed', 5.090)
  ) AS v(fx, k, l, pct, tr, mult)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.sales_points = v.fx;

-- Rewrite the tier-keyed maps onto the new keys.
UPDATE public.pay_scale
   SET retention_reached_year = jsonb_strip_nulls(jsonb_build_object(
         'casual',      retention_reached_year->'rock',
         'rock',        retention_reached_year->'rock_n_roll',
         'rockstar',    retention_reached_year->'rockstar',
         'rock_legend', retention_reached_year->'rock_legend'))
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND retention_reached_year IS NOT NULL;

UPDATE public.pay_scale
   SET life_specialist_reached_year = jsonb_strip_nulls(jsonb_build_object(
         'casual',      life_specialist_reached_year->'rock',
         'rock',        life_specialist_reached_year->'rock_n_roll',
         'rockstar',    life_specialist_reached_year->'rockstar',
         'rock_legend', life_specialist_reached_year->'rock_legend'))
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND life_specialist_reached_year IS NOT NULL;

CREATE OR REPLACE FUNCTION public.pay_scale_performer_tiers(p_agency_id uuid)
 RETURNS TABLE(tier_key text, tier_label text, applicant_pct numeric, multiplier numeric, descriptor text, band_from_x numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.band_tier_key, p.band_tier_label, p.band_applicant_pct,
         p.band_production_multiplier, p.band_tier_traits, p.sales_points
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
$a$          FROM public.earnings_projection_tiers t
         WHERE t.agency_id = p_agency_id AND t.is_active
         ORDER BY t.sort_order$a$,
$b$          FROM public.pay_scale_performer_tiers(p_agency_id) t$b$);

  v_new := replace(v_new,
$a$            FROM public.earnings_projection_tiers t
           WHERE t.agency_id = p_agency_id AND t.is_active
           ORDER BY t.sort_order$a$,
$b$            FROM public.pay_scale_performer_tiers(p_agency_id) t$b$);

  v_new := replace(v_new,
    $a$'{"rock":10,"rock_n_roll":20,"rockstar":30,"rock_legend":40}'$a$,
    $b$'{"casual":10,"rock":20,"rockstar":30,"rock_legend":40}'$b$);

  -- Sales bands carry their tier annotation so the chart stops hardcoding it.
  v_new := replace(v_new,
$a$                   'tier_key', lower(s.band),
                   'tier_label', s.band,
                   'from_x', s.fx
                 ) ORDER BY s.fx)
            INTO v_bands
            FROM (SELECT p.band, MIN(p.sales_points) AS fx
                    FROM public.pay_scale p
                   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
                     AND p.band IS NOT NULL AND p.sales_points <= v_sales_x_max
                   GROUP BY p.band) s;$a$,
$b$                   'tier_key', lower(s.band),
                   'tier_label', s.band,
                   'from_x', s.fx,
                   'nickname', n.band_tier_label,
                   'applicant_pct', n.band_applicant_pct,
                   'traits', n.band_tier_traits
                 ) ORDER BY s.fx)
            INTO v_bands
            FROM (SELECT p.band, MIN(p.sales_points) AS fx
                    FROM public.pay_scale p
                   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
                     AND p.band IS NOT NULL AND p.sales_points <= v_sales_x_max
                   GROUP BY p.band) s
            LEFT JOIN public.pay_scale n
              ON n.agency_id = p_agency_id AND n.role_key = 'sales'
             AND n.sales_points = s.fx AND n.band_tier_key IS NOT NULL;$b$);

  IF v_new LIKE '%earnings_projection_tiers%' THEN
    RAISE EXCEPTION 'projection still references earnings_projection_tiers';
  END IF;
  IF v_new NOT LIKE '%nickname%' THEN
    RAISE EXCEPTION 'band annotation not added';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- reseed must carry the five new authored columns too.
DO $mig2$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='reseed_pay_scale';
  v_new := v_def;
  v_new := replace(v_new,
    $a$-- The raise ladder lives in this same table$a$,
    $b$-- Band annotations (band_tier_*) sit on band-start rows and are preserved
-- wholesale by re-reading them after the rebuild.
-- The raise ladder lives in this same table$b$);
  v_new := replace(v_new,
    $a$  RETURN v_n;
END;$a$,
    $b$  -- Put the band annotations back onto their band-start rows.
  UPDATE public.pay_scale t
     SET band_tier_key = k.band_tier_key, band_tier_label = k.band_tier_label,
         band_applicant_pct = k.band_applicant_pct, band_tier_traits = k.band_tier_traits,
         band_production_multiplier = k.band_production_multiplier
    FROM jsonb_to_recordset(v_bandkeep) AS k(sales_points int, band_tier_key text,
         band_tier_label text, band_applicant_pct numeric, band_tier_traits text,
         band_production_multiplier numeric)
   WHERE t.agency_id = p_agency_id AND t.role_key = 'sales'
     AND t.sales_points = k.sales_points;

  RETURN v_n;
END;$b$);
  v_new := replace(v_new,
    $a$  v_ladder jsonb;$a$,
    $b$  v_ladder jsonb;
  v_bandkeep jsonb;$b$);
  v_new := replace(v_new,
    $a$  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);$a$,
    $b$  SELECT COALESCE(jsonb_agg(to_jsonb(z)), '[]'::jsonb) INTO v_bandkeep
    FROM (SELECT p.sales_points, p.band_tier_key, p.band_tier_label,
                 p.band_applicant_pct, p.band_tier_traits, p.band_production_multiplier
            FROM public.pay_scale p
           WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
             AND p.band_tier_key IS NOT NULL) z;

  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);$b$);
  IF v_new NOT LIKE '%v_bandkeep%' THEN
    RAISE EXCEPTION 'reseed band-annotation capture not added';
  END IF;
  EXECUTE v_new;
END
$mig2$;

DROP TABLE IF EXISTS public.earnings_projection_tiers;
