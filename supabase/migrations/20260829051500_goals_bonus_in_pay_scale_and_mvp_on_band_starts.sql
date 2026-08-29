-- Peter 2026-08-28.
--
-- 1. GOALS BONUS onto pay_scale. It is the weekly goals money — health
--    development, the one percent, and the leaderboard buckets — and it is
--    set by performer tier: $10 Casual, $20 Rock, $30 Rockstar, $40 Rock
--    Legend a week. Every pay_scale row knows its band, and the band carries
--    the tier, so the annual figure can be worked out per row instead of
--    only inside the projection.
--
--    This also settles a disagreement between the three charts on the tab:
--    the Retention and Life Specialist curves already added the goals money
--    into their totals while the Sales curve left it out. All three now
--    include it.
--
-- 2. MVP DRAWS moved onto the Good, Great and Elite band starts —
--    150 / 300 / 500 for 1 / 2 / 3 draws. They previously sat at
--    100 / 300 / 500, which lined up with nothing.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS goals_weekly              numeric,
  ADD COLUMN IF NOT EXISTS expected_goals_bonus_annual numeric;

COMMENT ON COLUMN public.pay_scale.goals_weekly IS
  'Weekly goals bonus at this band: health development, the one percent, and the leaderboard buckets. Authored on the band-start rows and spread across the band by reseed.';
COMMENT ON COLUMN public.pay_scale.expected_goals_bonus_annual IS
  'goals_weekly x 52. Derived. Included in the chart total alongside commission and the team bonus.';

UPDATE public.pay_scale p SET goals_weekly = v.wk
  FROM (VALUES ('casual',10),('rock',20),('rockstar',30),('rock_legend',40)) AS v(k, wk)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.band_tier_key = v.k;

UPDATE public.pay_scale
   SET mvp_draws = NULL
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales';

UPDATE public.pay_scale p SET mvp_draws = v.n
  FROM (VALUES (150,1),(300,2),(500,3)) AS v(fx, n)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.sales_points = v.fx;

COMMENT ON COLUMN public.pay_scale.mvp_draws IS
  'Prize-cart draws earned at this weekly Sales Points level, on the Good / Great / Elite band starts (150 / 300 / 500).';

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='reseed_pay_scale';
  v_new := v_def;

  v_new := replace(v_new, $a$  v_bounds   jsonb;$a$,
                          $b$  v_bounds   jsonb;
  v_goals    jsonb;$b$);

  v_new := replace(v_new,
    $a$  SELECT COALESCE(jsonb_object_agg(p.sales_points::text, p.mvp_draws), '{}'::jsonb)$a$,
    $b$  SELECT COALESCE(jsonb_agg(jsonb_build_object('fx', p.sales_points, 'wk', p.goals_weekly)
                                ORDER BY p.sales_points), '[]'::jsonb)
    INTO v_goals
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.goals_weekly IS NOT NULL;

  SELECT COALESCE(jsonb_object_agg(p.sales_points::text, p.mvp_draws), '{}'::jsonb)$b$);

  v_new := replace(v_new,
    $a$      round(v_x * 52.0, 0),$a$,
    $b$      round(v_x * 52.0, 0),
      (SELECT (e->>'wk')::numeric FROM jsonb_array_elements(v_goals) e
        WHERE (e->>'fx')::int <= v_x ORDER BY (e->>'fx')::int DESC LIMIT 1),
      round(COALESCE((SELECT (e->>'wk')::numeric FROM jsonb_array_elements(v_goals) e
        WHERE (e->>'fx')::int <= v_x ORDER BY (e->>'fx')::int DESC LIMIT 1), 0) * 52.0, 0),$b$);

  v_new := replace(v_new,
    $a$      expected_commission_annual, expected_team_bonus_annual,$a$,
    $b$      expected_commission_annual, goals_weekly, expected_goals_bonus_annual,
      expected_team_bonus_annual,$b$);

  IF v_new NOT LIKE '%v_goals%' THEN
    RAISE EXCEPTION 'goals capture not wired into reseed';
  END IF;
  EXECUTE v_new;
END
$mig$;

DO $mig2$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='compute_role_earnings_projection';
  v_new := v_def;

  v_new := replace(v_new,
$a$                 'bonus', round(COALESCE(p.expected_team_bonus_annual,0), 0),
                 'total', round(p.base_annual + COALESCE(p.expected_commission_annual,0)
                                              + COALESCE(p.expected_team_bonus_annual,0), 0)$a$,
$b$                 'bonus', round(COALESCE(p.expected_team_bonus_annual,0)
                               + COALESCE(p.expected_goals_bonus_annual,0), 0),
                 'goals', round(COALESCE(p.expected_goals_bonus_annual,0), 0),
                 'total', round(p.base_annual + COALESCE(p.expected_commission_annual,0)
                                              + COALESCE(p.expected_team_bonus_annual,0)
                                              + COALESCE(p.expected_goals_bonus_annual,0), 0)$b$);

  v_new := replace(v_new,
    $a$           || 'not in the chart total. The chart holds a steady production pace; '$a$,
    $b$           || 'in the chart total, alongside the team bonus. The chart holds a '
           || 'steady production pace; '$b$);

  IF v_new NOT LIKE '%expected_goals_bonus_annual%' THEN
    RAISE EXCEPTION 'sales curve not updated for goals';
  END IF;
  EXECUTE v_new;
END
$mig2$;
