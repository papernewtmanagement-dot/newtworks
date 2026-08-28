-- Peter 2026-08-28: the raise ladder belongs IN pay_scale. I put it in a
-- separate table an hour ago; that was wrong and it is undone here.
--
-- Two changes make pay_scale able to hold it honestly:
--   1. The grid moves from 10-point steps to 5-point steps. Every raise
--      threshold (100, 175, 250, 300, 325, 355, 390, 425, 460, 500, 545,
--      595, 650, 710) is a multiple of 5, so each tier now lands exactly on
--      a row. On the 10-point grid a 425 threshold surfaced as 430 and the
--      page published the wrong number. The check constraint that pinned
--      sales_points to multiples of 10 moves to multiples of 5.
--   2. Two new columns carry the ladder: tier_starts_here marks the row a
--      tier begins on, and lookback_quarters says how many quarters the
--      average is taken over to earn it.
--
-- Ladder extended to the edge of the chart (750) at the same ~9% per tier
-- the rest of the ladder uses: 595 -> 650 (+9.2%) at $28, 650 -> 710
-- (+9.2%) at $29.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS tier_starts_here  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS lookback_quarters int;

COMMENT ON COLUMN public.pay_scale.tier_starts_here IS
  'True on the row where a raise tier begins. These rows ARE the raise ladder — the rate, the weekly Sales Points needed, and the look-back window all read off them.';
COMMENT ON COLUMN public.pay_scale.lookback_quarters IS
  'How many quarters the weekly average is taken over to earn this tier: 1 for the first raise, 2 for the second, 3 for the third, 4 from there on. NULL on the starting rate.';

ALTER TABLE public.pay_scale DROP CONSTRAINT IF EXISTS pay_scale_sales_points_check;
ALTER TABLE public.pay_scale ADD CONSTRAINT pay_scale_sales_points_check
  CHECK (sales_points >= 0 AND sales_points <= 1000 AND (sales_points % 5) = 0);

CREATE TEMP TABLE _ladder (tier int, hourly numeric, threshold int, lookback int) ON COMMIT DROP;
INSERT INTO _ladder VALUES
  (0,15,   0, NULL), (1,16, 100, 1), (2,17, 175, 2), (3,18, 250, 3),
  (4,19, 300, 4), (5,20, 325, 4), (6,21, 355, 4), (7,22, 390, 4),
  (8,23, 425, 4), (9,24, 460, 4), (10,25, 500, 4), (11,26, 545, 4),
  (12,27, 595, 4), (13,28, 650, 4), (14,29, 710, 4);

DELETE FROM public.pay_scale
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales';

INSERT INTO public.pay_scale (
  agency_id, role_key, sales_points, band, raise_tier, base_hourly, base_annual,
  next_raise_at, expected_commission_annual, expected_team_bonus_annual,
  tier_starts_here, lookback_quarters, updated_at)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'sales', g.x,
       public.compute_sales_points_rating('126794dd-25ff-47d2-a436-724499733365', g.x),
       t.tier, t.hourly, round(t.hourly * 2080, 0),
       (SELECT MIN(n.threshold) FROM _ladder n WHERE n.threshold > g.x),
       round(g.x * 52.0, 0),
       0,
       (t.threshold = g.x),
       CASE WHEN t.threshold = g.x THEN t.lookback ELSE NULL END,
       now()
  FROM generate_series(0, 1000, 5) AS g(x)
  CROSS JOIN LATERAL (
    SELECT l.tier, l.hourly, l.threshold, l.lookback
      FROM _ladder l WHERE l.threshold <= g.x ORDER BY l.tier DESC LIMIT 1
  ) t;

DROP TABLE IF EXISTS public.raise_tier_ladder;

CREATE OR REPLACE FUNCTION public.earnings_raise_ladder(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_agg(jsonb_build_object(
           'tier', p.raise_tier,
           'hourly', p.base_hourly,
           'weekly', round(p.base_hourly * 40, 0),
           'annual', round(p.base_hourly * 2080, 0),
           'threshold', NULLIF(p.sales_points, 0),
           'lookback_quarters', p.lookback_quarters
         ) ORDER BY p.raise_tier)
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here;
$function$;

CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 201 rows, 0-1000 weekly Sales Points by 5.
-- The raise ladder lives in this same table, on the rows flagged
-- tier_starts_here; those rows define the rates, thresholds and look-back
-- windows and are read back out before the grid is rebuilt around them.
DECLARE
  v_ladder jsonb;
  v_x      integer;
  v_tier   integer;
  v_hourly numeric;
  v_next   numeric;
  v_lb     integer;
  v_starts boolean;
  v_base   numeric;
  v_inputs jsonb;
  v_n      integer := 0;
  c_seat_wh numeric := 8;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
           'tier', p.raise_tier, 'hourly', p.base_hourly,
           'threshold', p.sales_points, 'lookback', p.lookback_quarters
         ) ORDER BY p.raise_tier)
    INTO v_ladder
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here;

  IF v_ladder IS NULL THEN
    RAISE EXCEPTION 'No raise ladder found in pay_scale for this agency — seed the tier_starts_here rows first';
  END IF;

  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 5) LOOP
    SELECT (e->>'tier')::int, (e->>'hourly')::numeric, (e->>'lookback')::int,
           ((e->>'threshold')::int = v_x)
      INTO v_tier, v_hourly, v_lb, v_starts
      FROM jsonb_array_elements(v_ladder) e
     WHERE (e->>'threshold')::int <= v_x
     ORDER BY (e->>'tier')::int DESC
     LIMIT 1;

    SELECT MIN((e->>'threshold')::numeric) INTO v_next
      FROM jsonb_array_elements(v_ladder) e
     WHERE (e->>'threshold')::int > v_x;

    v_base := round(v_hourly * 2080, 0);

    INSERT INTO public.pay_scale (
      agency_id, role_key, sales_points, band, raise_tier,
      base_hourly, base_annual, next_raise_at,
      expected_commission_annual, expected_team_bonus_annual,
      tier_starts_here, lookback_quarters, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      public.compute_sales_points_rating(p_agency_id, v_x),
      v_tier, v_hourly, v_base, v_next,
      round(v_x * 52.0, 0),
      public.projected_team_bonus(v_inputs, v_x, c_seat_wh, v_base),
      v_starts,
      CASE WHEN v_starts THEN v_lb ELSE NULL END,
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'compute_role_earnings_projection';
  v_new := replace(v_def,
    'floor((v_sp_annual / 52.0) / 10.0) * 10))::int;',
    'floor((v_sp_annual / 52.0) / 5.0) * 5))::int;');
  IF v_new = v_def THEN RAISE EXCEPTION '10-point grain lookup not found'; END IF;
  EXECUTE v_new;
END
$mig$;
