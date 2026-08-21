-- Drop old views (CASCADE handles v_book_growth_summary → v_book_snapshot_with_changes dep)
DROP VIEW IF EXISTS public.v_book_snapshot_with_changes CASCADE;
DROP VIEW IF EXISTS public.v_book_snapshot_metrics;
DROP VIEW IF EXISTS public.v_sf_on_time_snapshot;

CREATE VIEW public.v_agency_snapshot_with_changes AS
WITH base AS (
  SELECT
    a.id, a.agency_id, a.snapshot_date, a.cadence,
    a.auto_new_ytd, a.auto_lost_ytd, a.auto_pif, a.auto_premium,
    a.fire_new_ytd, a.fire_lost_ytd, a.fire_pif, a.fire_premium,
    a.life_new_ytd, a.life_lost_ytd, a.life_pif,
    a.life_paid_for_count_ytd, a.life_paid_for_premium_ytd, a.life_premium,
    a.ips_new_money_ytd,
    a.household_count,
    a.source, a.notes, a.created_at, a.updated_at,
    COALESCE(a.auto_premium,0) + COALESCE(a.fire_premium,0) AS pc_premium
  FROM public.agency_snapshot a
),
anchors AS (
  SELECT DISTINCT ON (agency_id)
    agency_id, snapshot_date AS anchor_date,
    auto_premium AS anchor_auto, fire_premium AS anchor_fire, life_premium AS anchor_life,
    household_count AS anchor_hh
  FROM public.agency_snapshot
  ORDER BY agency_id, snapshot_date
)
SELECT
  b.*,
  CASE WHEN b.household_count > 0 THEN b.pc_premium / b.household_count ELSE NULL END AS pc_per_hh,
  CASE WHEN b.pc_premium > 0 THEN (b.auto_premium / b.pc_premium) * 100 ELSE NULL END AS auto_share_pc_pct,
  wow.snapshot_date AS wow_compare_date,
  mom.snapshot_date AS mom_compare_date,
  qoq.snapshot_date AS qoq_compare_date,
  yoy.snapshot_date AS yoy_compare_date,
  a.anchor_date,
  CASE WHEN b.cadence='weekly' AND wow.auto_premium > 0 THEN ((b.auto_premium - wow.auto_premium) / wow.auto_premium) * 100 ELSE NULL END AS auto_wow_pct,
  CASE WHEN b.cadence='weekly' AND wow.fire_premium > 0 THEN ((b.fire_premium - wow.fire_premium) / wow.fire_premium) * 100 ELSE NULL END AS fire_wow_pct,
  CASE WHEN b.cadence='weekly' AND wow.life_premium > 0 THEN ((b.life_premium - wow.life_premium) / wow.life_premium) * 100 ELSE NULL END AS life_wow_pct,
  CASE WHEN b.cadence='weekly' AND wow.pc_premium > 0 THEN ((b.pc_premium - wow.pc_premium) / wow.pc_premium) * 100 ELSE NULL END AS pc_wow_pct,
  CASE WHEN b.cadence='weekly' AND wow.household_count > 0 THEN ((b.household_count - wow.household_count)::numeric / wow.household_count) * 100 ELSE NULL END AS hh_wow_pct,
  CASE WHEN mom.auto_premium > 0 THEN ((b.auto_premium - mom.auto_premium) / mom.auto_premium) * 100 ELSE NULL END AS auto_mom_pct,
  CASE WHEN mom.fire_premium > 0 THEN ((b.fire_premium - mom.fire_premium) / mom.fire_premium) * 100 ELSE NULL END AS fire_mom_pct,
  CASE WHEN mom.life_premium > 0 THEN ((b.life_premium - mom.life_premium) / mom.life_premium) * 100 ELSE NULL END AS life_mom_pct,
  CASE WHEN mom.pc_premium > 0 THEN ((b.pc_premium - mom.pc_premium) / mom.pc_premium) * 100 ELSE NULL END AS pc_mom_pct,
  CASE WHEN mom.household_count > 0 THEN ((b.household_count - mom.household_count)::numeric / mom.household_count) * 100 ELSE NULL END AS hh_mom_pct,
  CASE WHEN qoq.auto_premium > 0 THEN ((b.auto_premium - qoq.auto_premium) / qoq.auto_premium) * 100 ELSE NULL END AS auto_qoq_pct,
  CASE WHEN qoq.fire_premium > 0 THEN ((b.fire_premium - qoq.fire_premium) / qoq.fire_premium) * 100 ELSE NULL END AS fire_qoq_pct,
  CASE WHEN qoq.life_premium > 0 THEN ((b.life_premium - qoq.life_premium) / qoq.life_premium) * 100 ELSE NULL END AS life_qoq_pct,
  CASE WHEN qoq.pc_premium > 0 THEN ((b.pc_premium - qoq.pc_premium) / qoq.pc_premium) * 100 ELSE NULL END AS pc_qoq_pct,
  CASE WHEN qoq.household_count > 0 THEN ((b.household_count - qoq.household_count)::numeric / qoq.household_count) * 100 ELSE NULL END AS hh_qoq_pct,
  CASE WHEN yoy.auto_premium > 0 THEN ((b.auto_premium - yoy.auto_premium) / yoy.auto_premium) * 100 ELSE NULL END AS auto_yoy_pct,
  CASE WHEN yoy.fire_premium > 0 THEN ((b.fire_premium - yoy.fire_premium) / yoy.fire_premium) * 100 ELSE NULL END AS fire_yoy_pct,
  CASE WHEN yoy.life_premium > 0 THEN ((b.life_premium - yoy.life_premium) / yoy.life_premium) * 100 ELSE NULL END AS life_yoy_pct,
  CASE WHEN yoy.pc_premium > 0 THEN ((b.pc_premium - yoy.pc_premium) / yoy.pc_premium) * 100 ELSE NULL END AS pc_yoy_pct,
  CASE WHEN yoy.household_count > 0 THEN ((b.household_count - yoy.household_count)::numeric / yoy.household_count) * 100 ELSE NULL END AS hh_yoy_pct,
  CASE WHEN a.anchor_auto > 0 THEN ((b.auto_premium - a.anchor_auto) / a.anchor_auto) * 100 ELSE NULL END AS auto_cum_pct,
  CASE WHEN a.anchor_fire > 0 THEN ((b.fire_premium - a.anchor_fire) / a.anchor_fire) * 100 ELSE NULL END AS fire_cum_pct,
  CASE WHEN a.anchor_life > 0 THEN ((b.life_premium - a.anchor_life) / a.anchor_life) * 100 ELSE NULL END AS life_cum_pct,
  CASE WHEN a.anchor_hh > 0 THEN ((b.household_count - a.anchor_hh)::numeric / a.anchor_hh) * 100 ELSE NULL END AS hh_cum_pct
FROM base b
LEFT JOIN LATERAL (
  SELECT auto_premium, fire_premium, life_premium,
         COALESCE(auto_premium,0)+COALESCE(fire_premium,0) AS pc_premium,
         household_count, snapshot_date
  FROM public.agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '7 days')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) wow ON true
LEFT JOIN LATERAL (
  SELECT auto_premium, fire_premium, life_premium,
         COALESCE(auto_premium,0)+COALESCE(fire_premium,0) AS pc_premium,
         household_count, snapshot_date
  FROM public.agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 month')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) mom ON true
LEFT JOIN LATERAL (
  SELECT auto_premium, fire_premium, life_premium,
         COALESCE(auto_premium,0)+COALESCE(fire_premium,0) AS pc_premium,
         household_count, snapshot_date
  FROM public.agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '91 days')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) qoq ON true
LEFT JOIN LATERAL (
  SELECT auto_premium, fire_premium, life_premium,
         COALESCE(auto_premium,0)+COALESCE(fire_premium,0) AS pc_premium,
         household_count, snapshot_date
  FROM public.agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 year')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) yoy ON true
LEFT JOIN anchors a ON a.agency_id = b.agency_id
ORDER BY b.agency_id, b.cadence, b.snapshot_date;

CREATE VIEW public.v_agency_growth_summary AS
SELECT DISTINCT ON (agency_id, cadence)
  agency_id, cadence,
  snapshot_date AS current_snapshot_date,
  auto_premium, fire_premium, life_premium,
  pc_premium,
  auto_pif, fire_pif, life_pif,
  household_count,
  pc_per_hh, auto_share_pc_pct,
  wow_compare_date, mom_compare_date, qoq_compare_date, yoy_compare_date, anchor_date,
  auto_wow_pct, fire_wow_pct, life_wow_pct, pc_wow_pct, hh_wow_pct,
  auto_mom_pct, fire_mom_pct, life_mom_pct, pc_mom_pct, hh_mom_pct,
  auto_qoq_pct, fire_qoq_pct, life_qoq_pct, pc_qoq_pct, hh_qoq_pct,
  auto_yoy_pct, fire_yoy_pct, life_yoy_pct, pc_yoy_pct, hh_yoy_pct,
  auto_cum_pct, fire_cum_pct, life_cum_pct, hh_cum_pct,
  notes
FROM public.v_agency_snapshot_with_changes
ORDER BY agency_id, cadence, snapshot_date DESC;
