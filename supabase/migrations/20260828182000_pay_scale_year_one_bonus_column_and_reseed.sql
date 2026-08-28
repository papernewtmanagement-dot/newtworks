-- Peter 2026-08-28: two horizons, two bonus figures.
-- The chart shows the seasoned book, so its bonus uses the three-year
-- forward average of the scheduled pool percentage. The first-year table
-- is a promise about the next twelve months, so its bonus uses the
-- fifty-two-week forward average. The pay scale now carries both, seeded
-- in one pass, and the first-year path reads the twelve-month figure.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS expected_team_bonus_annual_y1 numeric;

COMMENT ON COLUMN public.pay_scale.expected_team_bonus_annual_y1 IS
  'Projected team bonus using the 52-week forward average of the scheduled bonus pool percentage. Used by the first-year path. expected_team_bonus_annual is the same projection over a 156-week forward window and is what the chart draws.';

CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- Ladder + research record: migration pay_scale_table_and_curve_from_table.
-- Bonus: mechanical seasoned-book projection (projected_team_bonus) --
-- migration pay_scale_bonus_mechanical_projection. Pool percentage is the
-- forward average off the dated schedule -- migration
-- pay_scale_bonus_inputs_forward_pool_schedule. Two horizons are seeded:
-- 156 weeks for the chart's seasoned book, 52 weeks for the first year.
DECLARE
  v_inputs    jsonb;
  v_inputs_y1 jsonb;
  v_x      integer;
  v_i      integer;
  v_tier   integer;
  v_hourly numeric;
  v_next   integer;
  v_base   numeric;
  v_n      integer := 0;
  c_thresholds  integer[] := ARRAY[0,100,175,250,300,325,355,390,425,460,500,545,595];
  c_hourly      numeric[] := ARRAY[15,16,17,18,19,20,21,22,23,24,25,26,27];
  c_seat_wh     numeric   := 8;
BEGIN
  v_inputs    := public.pay_scale_bonus_inputs(p_agency_id, 156);
  v_inputs_y1 := public.pay_scale_bonus_inputs(p_agency_id, 52);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 10) LOOP
    v_tier := 0; v_hourly := c_hourly[1]; v_next := NULL;
    FOR v_i IN 1..array_length(c_thresholds, 1) LOOP
      IF v_x >= c_thresholds[v_i] THEN
        v_tier := v_i - 1;
        v_hourly := c_hourly[v_i];
        v_next := CASE WHEN v_i < array_length(c_thresholds, 1) THEN c_thresholds[v_i + 1] ELSE NULL END;
      END IF;
    END LOOP;
    v_base := round(v_hourly * 2080, 0);

    INSERT INTO public.pay_scale (
      agency_id, role_key, sales_points, band, raise_tier,
      base_hourly, base_annual, next_raise_at,
      expected_commission_annual, expected_team_bonus_annual,
      expected_team_bonus_annual_y1, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      public.compute_sales_points_rating(p_agency_id, v_x),
      v_tier,
      v_hourly,
      v_base,
      v_next,
      round(v_x * 52.0, 0),
      public.projected_team_bonus(v_inputs, v_x, c_seat_wh, v_base),
      public.projected_team_bonus(v_inputs_y1, v_x, c_seat_wh, v_base),
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.year_one_path_to_100k(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- First-year progression for a Sales seat, read live off public.pay_scale.
-- Rungs (Peter 2026-08-28): end of quarter one on pace for $40,000, quarter
-- two $60,000, quarter three $80,000, end of year at a weekly pace worth
-- $100,000 over the following twelve months if held steady. Each rung is
-- the lowest published 10-point row whose base + commission + team bonus
-- reaches the target, so the path moves whenever the scale is reseeded.
-- Bonus here is the TWELVE-MONTH figure: this table is a statement about
-- the next year, so it uses the 52-week forward average of the scheduled
-- pool percentage, not the chart's three-year seasoned-book figure.
DECLARE
  v_rungs   jsonb := '[]'::jsonb;
  v_targets numeric[] := ARRAY[40000, 60000, 80000, 100000];
  v_labels  text[] := ARRAY['End of quarter one','End of quarter two',
                            'End of quarter three','End of year one'];
  v_when    text[] := ARRAY['on pace for','on pace for','on pace for',
                            'holding a pace worth'];
  i         int;
  r         record;
BEGIN
  IF NOT public.pay_projection_caller_ok() THEN
    RAISE EXCEPTION 'Not authorized: pay projections are admin only';
  END IF;

  FOR i IN 1..array_length(v_targets, 1) LOOP
    SELECT p.sales_points, p.band, p.raise_tier, p.base_hourly, p.base_annual,
           p.expected_commission_annual AS comm,
           COALESCE(p.expected_team_bonus_annual_y1, p.expected_team_bonus_annual) AS bonus,
           p.base_annual + COALESCE(p.expected_commission_annual,0)
                         + COALESCE(p.expected_team_bonus_annual_y1,
                                    p.expected_team_bonus_annual, 0) AS total
      INTO r
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
       AND p.base_annual + COALESCE(p.expected_commission_annual,0)
                         + COALESCE(p.expected_team_bonus_annual_y1,
                                    p.expected_team_bonus_annual, 0) >= v_targets[i]
     ORDER BY p.sales_points
     LIMIT 1;

    IF FOUND THEN
      v_rungs := v_rungs || jsonb_build_object(
        'step', i,
        'step_label', v_labels[i],
        'pace_label', v_when[i],
        'target_annual', v_targets[i],
        'weekly_sales_points', r.sales_points,
        'band', r.band,
        'base_hourly', r.base_hourly,
        'base_annual', round(r.base_annual, 0),
        'commission', round(COALESCE(r.comm,0), 0),
        'bonus', round(COALESCE(r.bonus,0), 0),
        'total', round(r.total, 0),
        'rate_label', '$' || to_char(r.base_hourly, 'FM990.00') || '/hr'
                      || CASE WHEN COALESCE(r.raise_tier,0) > 0
                              THEN ' — raise tier ' || r.raise_tier
                              ELSE ' — starting rate' END
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'computed_at', now(),
    'role_key', 'sales',
    'rungs', v_rungs,
    'headline', 'One way a first year can go — from starting rate to a '
             || 'hundred thousand dollar pace inside twelve months.',
    'note', 'Every rung is a weekly sales-point pace, taken straight off the '
         || 'published pay scale: hold that pace for a year and the pay is '
         || 'what the row says. What decides whether a person climbs the '
         || 'rungs on this timeline is drive — how many people they talk to, '
         || 'how fast they get back to them, how hard they work the follow '
         || 'up. Someone with real drive can move quicker than this. Plenty '
         || 'of people take two years or three to reach the top rung, and '
         || 'someone who stops pushing stops climbing. The agency supplies '
         || 'the leads, the training and the pay scale. The pace is the '
         || 'person.'
  );
END;
$function$;
