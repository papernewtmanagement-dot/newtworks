-- Peter 2026-08-28, three changes.
--
-- 1. LADDER RE-SPACED to fifty points a rung: 100, 150, 200 ... 750.
--    Fourteen raises from $16 to $29, and the last rung lands exactly on
--    the edge of the chart (750). Peter's reasoning: each rung has to be
--    sustained over a four-quarter average, so the sustaining is what makes
--    it hard, not the size of the jump.
--    NOTE FOR ANYONE READING LATER: an earlier design thread rejected flat
--    point steps on the grounds that a constant increment gets easier as a
--    share of the current bar (50 on top of 100 is a 50% lift; 50 on top of
--    700 is 7%). Peter has weighed that and chosen flat fifties anyway.
--    Do not silently revert this to percentage scaling.
--
-- 2. pay_scale is about the DOLLAR AMOUNTS. The row is a pay level; the
--    columns say what each seat has to do to reach it. Sales is points
--    based and already there. The four retention columns I added were
--    wrong — retention_base_hourly duplicated the rate the row already
--    carries. They are dropped and replaced by a plain requirement column
--    per role. Retention's real requirement is a licence, and its three
--    steps ($16, $18, $20 — the whole of role_pay_ranges' retention rows,
--    and also exactly what earnings_projection_base_ladder's retention rows
--    reduce to) land on rows that already exist.
--
-- 3. role_pace_targets dropped. Nothing in the database, no view and no
--    line of frontend code read it, and both its numbers were ten times
--    the real weekly targets.

DROP TABLE IF EXISTS public.role_pace_targets;

ALTER TABLE public.pay_scale
  DROP COLUMN IF EXISTS retention_base_hourly,
  DROP COLUMN IF EXISTS retention_raise_tier,
  DROP COLUMN IF EXISTS retention_tier_starts_here,
  DROP COLUMN IF EXISTS retention_lookback_quarters;

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS retention_requirement       text,
  ADD COLUMN IF NOT EXISTS life_specialist_requirement text;

COMMENT ON COLUMN public.pay_scale.retention_requirement IS
  'What a Retention seat has to do to be paid this row''s rate. Licence driven, not pace driven. Set only on the rows where a rate begins.';
COMMENT ON COLUMN public.pay_scale.life_specialist_requirement IS
  'What a Life Specialist has to do to be paid this row''s rate. Empty until the Life Specialist pay levels are reconciled — they are salaries of $40,000 / $45,000 / $50,000 and none of them is a whole-dollar hourly rate, so none of them is a row here yet.';

DELETE FROM public.pay_scale
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND role_key = 'sales';

CREATE TEMP TABLE _ladder (tier int, hourly numeric, threshold int, lookback int) ON COMMIT DROP;
INSERT INTO _ladder
SELECT t, 15 + t,
       CASE WHEN t = 0 THEN 0 ELSE 100 + (t - 1) * 50 END,
       CASE WHEN t = 0 THEN NULL ELSE LEAST(t, 4) END
  FROM generate_series(0, 14) AS t;

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

UPDATE public.pay_scale p SET retention_requirement = v.req
  FROM (VALUES
    (16, 'Starting pay — no licence yet'),
    (18, 'Property & Casualty licence issued and authorised to use it'),
    (20, 'Property & Casualty plus Life & Health')
  ) AS v(hr, req)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales'
   AND p.tier_starts_here
   AND p.base_hourly = v.hr;
