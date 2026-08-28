-- Peter 2026-08-28.
--
-- 1. LIFE SPECIALIST fitted to the closest existing rows. Its levels are
--    $40,000 / $45,000 / $50,000; the nearest whole-dollar hourly rows are
--    $19 = $39,520 (480 under), $22 = $45,760 (760 over) and $24 = $49,920
--    (80 under). Those three rows now carry the requirement.
--
-- 2. ROLE_PAY_RANGES now reads its dollars from pay_scale instead of
--    holding a second copy. The table keeps everything that is genuinely
--    its own — tier wording, licence flags, notes, placement factors, sort
--    order — and is renamed role_pay_ranges_meta. A view of the original
--    name puts the amounts back on, pulled from the pay_scale rows the
--    range is pinned to, so the offer letter (the only reader, and it only
--    reads) keeps working with no change.
--
--    Pinned rows, chosen as the closest amount to what the table held:
--      retention, no licence      $16       -> tier 1
--      retention, P&C             $18       -> tier 3
--      retention, P&C plus L&H    $20       -> tier 5
--      sales base       $30,000-$40,000     -> tiers 0 ($31,200) to 4 ($39,520)
--      life specialist  $40,000-$50,000     -> tiers 4 ($39,520) to 9 ($49,920)
--
--    The view is security_invoker so the existing admin-only gate on both
--    underlying tables still applies exactly as before.

UPDATE public.pay_scale p SET life_specialist_requirement = v.req
  FROM (VALUES
    (4, 'Year one'),
    (7, 'Year two'),
    (9, 'Year three onward — Rock n'' Roll and above; a Rock performer holds at the year-two rate')
  ) AS v(tier, req)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.tier_starts_here AND p.raise_tier = v.tier;

ALTER TABLE public.role_pay_ranges RENAME TO role_pay_ranges_meta;

ALTER TABLE public.role_pay_ranges_meta
  ADD COLUMN IF NOT EXISTS pay_scale_tier_min int,
  ADD COLUMN IF NOT EXISTS pay_scale_tier_max int;

UPDATE public.role_pay_ranges_meta m SET pay_scale_tier_min = v.lo, pay_scale_tier_max = v.hi
  FROM (VALUES
    ('retention',       'unlicensed', 1, 1),
    ('retention',       'pc',         3, 3),
    ('retention',       'pc_lh',      5, 5),
    ('sales',           'base',       0, 4),
    ('life_specialist', 'base',       4, 9)
  ) AS v(rk, tk, lo, hi)
 WHERE m.role_key = v.rk AND m.tier_key = v.tk;

ALTER TABLE public.role_pay_ranges_meta
  DROP COLUMN amount_min,
  DROP COLUMN amount_max;

COMMENT ON TABLE public.role_pay_ranges_meta IS
  'Hiring pay bands for the offer letter: wording, licence flags, notes, placement factors. The dollars are NOT here — they come from public.pay_scale via the tiers named in pay_scale_tier_min/max. Read through the role_pay_ranges view.';

CREATE OR REPLACE VIEW public.role_pay_ranges
WITH (security_invoker = true) AS
SELECT m.id,
       m.agency_id,
       m.role_key,
       m.role_label,
       m.tier_key,
       m.tier_label,
       m.pay_type,
       m.pay_period,
       lo.amt AS amount_min,
       hi.amt AS amount_max,
       m.currency,
       m.requires_license_pc,
       m.requires_license_lh,
       m.placement_factors,
       m.notes,
       m.sort_order,
       m.is_active,
       m.created_at,
       m.updated_at
  FROM public.role_pay_ranges_meta m
  LEFT JOIN LATERAL (
    SELECT CASE WHEN m.pay_period = 'hour' THEN p.base_hourly ELSE p.base_annual END AS amt
      FROM public.pay_scale p
     WHERE p.agency_id = m.agency_id AND p.role_key = 'sales'
       AND p.tier_starts_here AND p.raise_tier = m.pay_scale_tier_min
     LIMIT 1
  ) lo ON true
  LEFT JOIN LATERAL (
    SELECT CASE WHEN m.pay_period = 'hour' THEN p.base_hourly ELSE p.base_annual END AS amt
      FROM public.pay_scale p
     WHERE p.agency_id = m.agency_id AND p.role_key = 'sales'
       AND p.tier_starts_here AND p.raise_tier = m.pay_scale_tier_max
     LIMIT 1
  ) hi ON true;

COMMENT ON VIEW public.role_pay_ranges IS
  'Hiring pay bands as the offer letter expects them. Same columns as the old table; the amounts are read live from public.pay_scale so there is only one set of dollar figures in the system.';

GRANT SELECT ON public.role_pay_ranges TO anon, authenticated;
