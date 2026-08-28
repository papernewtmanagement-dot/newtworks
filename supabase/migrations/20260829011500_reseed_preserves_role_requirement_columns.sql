-- reseed_pay_scale carries the raise ladder across a rebuild but was
-- dropping the two role requirement columns with it — a reseed silently
-- blanked retention_requirement and life_specialist_requirement, and with
-- them the amounts the role_pay_ranges view hands the offer letter. The
-- ladder capture now takes those columns too and writes them back.

CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- The raise ladder lives in this same table, on the rows flagged
-- tier_starts_here; those rows define the rates, thresholds, look-back
-- windows and the retention / life specialist requirements, and are read
-- back out before the grid is rebuilt around them.
DECLARE
  v_ladder jsonb;
  v_x      integer;
  v_tier   integer;
  v_hourly numeric;
  v_next   numeric;
  v_lb     integer;
  v_starts boolean;
  v_ret    text;
  v_ls     text;
  v_base   numeric;
  v_inputs jsonb;
  v_n      integer := 0;
  c_seat_wh numeric := 8;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
           'tier', p.raise_tier, 'hourly', p.base_hourly,
           'threshold', p.sales_points, 'lookback', p.lookback_quarters,
           'retention', p.retention_requirement,
           'life', p.life_specialist_requirement
         ) ORDER BY p.raise_tier)
    INTO v_ladder
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here;

  IF v_ladder IS NULL THEN
    RAISE EXCEPTION 'No raise ladder found in pay_scale for this agency — seed the tier_starts_here rows first';
  END IF;

  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 10) LOOP
    SELECT (e->>'tier')::int, (e->>'hourly')::numeric, (e->>'lookback')::int,
           ((e->>'threshold')::int = v_x), e->>'retention', e->>'life'
      INTO v_tier, v_hourly, v_lb, v_starts, v_ret, v_ls
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
      tier_starts_here, lookback_quarters,
      retention_requirement, life_specialist_requirement, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      public.compute_sales_points_rating(p_agency_id, v_x),
      v_tier, v_hourly, v_base, v_next,
      round(v_x * 52.0, 0),
      public.projected_team_bonus(v_inputs, v_x, c_seat_wh, v_base),
      v_starts,
      CASE WHEN v_starts THEN v_lb  ELSE NULL END,
      CASE WHEN v_starts THEN v_ret ELSE NULL END,
      CASE WHEN v_starts THEN v_ls  ELSE NULL END,
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

-- Put back the retention requirements a reseed had already blanked.
UPDATE public.pay_scale p SET retention_requirement = v.req
  FROM (VALUES
    (16, 'Starting pay — no licence yet'),
    (18, 'Property & Casualty licence issued and authorised to use it'),
    (20, 'Property & Casualty plus Life & Health')
  ) AS v(hr, req)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.tier_starts_here AND p.base_hourly = v.hr;
