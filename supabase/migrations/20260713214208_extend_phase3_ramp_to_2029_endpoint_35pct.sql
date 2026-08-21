-- Extend Phase 3 ramp: 42.785% (2028-01-01) → 35.000% (2029-12-29), 104 weekly steps.
-- Was: 42.785% → 34.400% over 52 weeks (endpoint drifted from Peter's 40% intent via 2026-07-08 anchor rescale).
-- Now: shallower endpoint (35% by end of 2029) + longer runway (104 weeks) so per-week decline pace lands closer to Phase 1 shape.

DELETE FROM public.team_comp_pool_schedule
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND phase = 'phase_3_aa28_rampdown';

INSERT INTO public.team_comp_pool_schedule (agency_id, week_end_date, pool_pct, phase, basis_regime, plan_note)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  ('2028-01-01'::date + (n * 7))::date,
  ROUND(42.785::numeric - (7.785::numeric / 104) * n, 5),
  'phase_3_aa28_rampdown',
  'AA28',
  CASE
    WHEN n = 0 THEN 'Bridge start; pool_pct lifted to hold envelope $/wk constant across AA28 Auto rate compression (~9.5% basis compression). 43% Week 1 anchor as of 2026-07-08. Phase 3 endpoint locked 2026-07-13: 35% by 2029-12-29 (extended from 34.4% by 2028-12-30). RECOMPUTE late 2027 when SF finalizes AA28 VC mechanics.'
    WHEN n = 104 THEN 'Phase 3 endpoint: 35% by end of 2029.'
    ELSE NULL
  END
FROM generate_series(0, 104) n;
