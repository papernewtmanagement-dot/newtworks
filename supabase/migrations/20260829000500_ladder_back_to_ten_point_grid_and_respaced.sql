-- Peter 2026-08-28: back to 10-point steps. The 5-point grain was my idea
-- to make the thresholds land exactly; the right fix was to put the
-- thresholds on 10s in the first place.
--
-- Ladder re-spaced so every rung sits on a multiple of 10 AND the gap never
-- shrinks — the shrink-then-grow Peter flagged was an artifact of rounding
-- 425 and 545 onto the grid. After year one the gaps now run three at 30,
-- three at 40, three at 50, then 60, which holds the roughly 9% per tier
-- the ladder is built on:
--   300 -> 330 -> 360 -> 390 -> 430 -> 470 -> 510 -> 560 -> 610 -> 660 -> 720
-- Year-one rungs (100, 180, 250, 300) keep their calibration against
-- Thomas Lynch's real first-year quarterly averages; those four are
-- measured on growing look-back windows so their spacing is not comparable
-- to the rest.
--
-- Also: a retention raise column set, and role_pace_targets corrected.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS retention_base_hourly       numeric,
  ADD COLUMN IF NOT EXISTS retention_raise_tier        int,
  ADD COLUMN IF NOT EXISTS retention_tier_starts_here  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS retention_lookback_quarters int;

COMMENT ON COLUMN public.pay_scale.retention_base_hourly IS
  'Retention seat base rate at this weekly Sales Points pace. The unprefixed raise columns (base_hourly, raise_tier, tier_starts_here, lookback_quarters) are the SALES ladder. Empty until the retention thresholds are set — the only retention pay data that exists today is licence-driven, not pace-driven.';

-- Clear the 5-point rows BEFORE tightening the constraint back to 10s.
DELETE FROM public.pay_scale
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales';

ALTER TABLE public.pay_scale DROP CONSTRAINT IF EXISTS pay_scale_sales_points_check;
ALTER TABLE public.pay_scale ADD CONSTRAINT pay_scale_sales_points_check
  CHECK (sales_points >= 0 AND sales_points <= 1000 AND (sales_points % 10) = 0);

CREATE TEMP TABLE _ladder (tier int, hourly numeric, threshold int, lookback int) ON COMMIT DROP;
INSERT INTO _ladder VALUES
  (0,15,   0, NULL),
  (1,16, 100, 1), (2,17, 180, 2), (3,18, 250, 3), (4,19, 300, 4),
  (5,20, 330, 4), (6,21, 360, 4), (7,22, 390, 4),
  (8,23, 430, 4), (9,24, 470, 4), (10,25, 510, 4),
  (11,26, 560, 4), (12,27, 610, 4), (13,28, 660, 4),
  (14,29, 720, 4);

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
  FROM generate_series(0, 1000, 10) AS g(x)
  CROSS JOIN LATERAL (
    SELECT l.tier, l.hourly, l.threshold, l.lookback
      FROM _ladder l WHERE l.threshold <= g.x ORDER BY l.tier DESC LIMIT 1
  ) t;

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='reseed_pay_scale';
  v_new := replace(v_def, 'generate_series(0, 1000, 5)', 'generate_series(0, 1000, 10)');
  v_new := replace(v_new, '201 rows, 0-1000 weekly Sales Points by 5', '101 rows, 0-1000 weekly Sales Points by 10');
  IF v_new = v_def THEN RAISE EXCEPTION 'reseed grain not found'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='compute_role_earnings_projection';
  v_new := replace(v_def,
    'floor((v_sp_annual / 52.0) / 5.0) * 5))::int;',
    'floor((v_sp_annual / 52.0) / 10.0) * 10))::int;');
  IF v_new = v_def THEN RAISE EXCEPTION '5-point grain lookup not found'; END IF;
  EXECUTE v_new;
END
$mig$;

-- role_pace_targets: the Sales weekly Sales Points target read 1000, which
-- is ten times the real target. Peter: 100 is correct. Retention's 500 is
-- the same ten-times error against the 50 the projection uses, corrected to
-- match. Nothing in the database or the app reads this table today.
UPDATE public.role_pace_targets
   SET sales_points_per_week_target = 100, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_category = 'Sales';

UPDATE public.role_pace_targets
   SET sales_points_per_week_target = 50, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_category = 'Retention';
