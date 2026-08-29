-- Peter 2026-08-28: the raise ladder becomes real data instead of an array
-- buried in reseed_pay_scale. public.raise_tier_ladder is now the ONE place
-- the ladder is defined; public.pay_scale is generated from it.
--
-- Corrected qualifying rule (Peter, this session). It is a rolling
-- look-back whose window grows and then holds, NOT a tenure-to-date
-- average:
--   Tier 1  -> average over the LAST 1 quarter
--   Tier 2  -> average over the LAST 2 quarters
--   Tier 3  -> average over the LAST 3 quarters
--   Tier 4 and every tier after -> average over the LAST 4 quarters
-- Missing a tier at one close is not a problem: if they do not qualify at
-- the end of quarter one but do at the end of quarter two, they take it
-- then. One tier per quarter close, in order, reviews at quarter close only.

CREATE TABLE IF NOT EXISTS public.raise_tier_ladder (
  agency_id         uuid    NOT NULL,
  role_key          text    NOT NULL,
  tier              int     NOT NULL,
  base_hourly       numeric NOT NULL,
  threshold_points  numeric,          -- weekly Sales Points; NULL = starting rate
  lookback_quarters int,              -- quarters averaged; NULL = starting rate
  is_active         boolean NOT NULL DEFAULT true,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, role_key, tier)
);

COMMENT ON TABLE public.raise_tier_ladder IS
  'The raise ladder: one row per tier. The single source for raise-tier rates, the weekly Sales Points needed, and how many quarters that average is taken over. public.pay_scale is generated from this by reseed_pay_scale. Published on the Earning Potential chart as a projection; not yet locked as live raise policy.';

INSERT INTO public.raise_tier_ladder
  (agency_id, role_key, tier, base_hourly, threshold_points, lookback_quarters, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','sales', 0, 15, NULL, NULL, 'Starting rate'),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 1, 16, 100,  1,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 2, 17, 175,  2,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 3, 18, 250,  3,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 4, 19, 300,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 5, 20, 325,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 6, 21, 355,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 7, 22, 390,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 8, 23, 425,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales', 9, 24, 460,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales',10, 25, 500,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales',11, 26, 545,  4,    NULL),
  ('126794dd-25ff-47d2-a436-724499733365','sales',12, 27, 595,  4,    NULL)
ON CONFLICT (agency_id, role_key, tier) DO UPDATE
  SET base_hourly = EXCLUDED.base_hourly,
      threshold_points = EXCLUDED.threshold_points,
      lookback_quarters = EXCLUDED.lookback_quarters,
      notes = EXCLUDED.notes,
      updated_at = now();

ALTER TABLE public.raise_tier_ladder ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS raise_tier_ladder_read ON public.raise_tier_ladder;
CREATE POLICY raise_tier_ladder_read ON public.raise_tier_ladder
  FOR SELECT USING (public.pay_projection_caller_ok());

-- Ladder helper now reads the table, and carries the pay three ways.
CREATE OR REPLACE FUNCTION public.earnings_raise_ladder(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_agg(jsonb_build_object(
           'tier', l.tier,
           'hourly', l.base_hourly,
           'weekly', round(l.base_hourly * 40, 0),
           'annual', round(l.base_hourly * 2080, 0),
           'threshold', l.threshold_points,
           'lookback_quarters', l.lookback_quarters
         ) ORDER BY l.tier)
    FROM public.raise_tier_ladder l
   WHERE l.agency_id = p_agency_id AND l.role_key = 'sales' AND l.is_active;
$function$;

-- pay_scale is generated FROM the ladder table, not from a literal array.
CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- Rates and thresholds come from public.raise_tier_ladder, the one copy of
-- the ladder. Bonus: mechanical seasoned-book projection
-- (projected_team_bonus) on today's numbers.
DECLARE
  v_x      integer;
  v_tier   integer;
  v_hourly numeric;
  v_next   numeric;
  v_base   numeric;
  v_inputs jsonb;
  v_n      integer := 0;
  c_seat_wh numeric := 8;
BEGIN
  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 10) LOOP
    SELECT l.tier, l.base_hourly INTO v_tier, v_hourly
      FROM public.raise_tier_ladder l
     WHERE l.agency_id = p_agency_id AND l.role_key = 'sales' AND l.is_active
       AND COALESCE(l.threshold_points, 0) <= v_x
     ORDER BY l.tier DESC
     LIMIT 1;

    SELECT MIN(l.threshold_points) INTO v_next
      FROM public.raise_tier_ladder l
     WHERE l.agency_id = p_agency_id AND l.role_key = 'sales' AND l.is_active
       AND l.threshold_points > v_x;

    v_base := round(v_hourly * 2080, 0);

    INSERT INTO public.pay_scale (
      agency_id, role_key, sales_points, band, raise_tier,
      base_hourly, base_annual, next_raise_at,
      expected_commission_annual, expected_team_bonus_annual, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      public.compute_sales_points_rating(p_agency_id, v_x),
      v_tier, v_hourly, v_base, v_next,
      round(v_x * 52.0, 0),
      public.projected_team_bonus(v_inputs, v_x, c_seat_wh, v_base),
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;
