-- Add quarter-over-quarter lookback: most recent snapshot at or before (current - INTERVAL '3 months').
-- Calendar-aware, matches the MoM / YoY pattern.

DROP VIEW IF EXISTS public.v_book_growth_summary CASCADE;
DROP VIEW IF EXISTS public.v_book_snapshot_with_changes CASCADE;

CREATE VIEW public.v_book_snapshot_with_changes AS
WITH base AS (
  SELECT
    bs.*,
    COALESCE(auto_premium, 0) + COALESCE(fire_premium, 0)   AS pc_premium,
    COALESCE(life_premium, 0) + COALESCE(health_premium, 0) AS lh_premium
  FROM public.book_snapshot bs
),
anchors AS (
  SELECT DISTINCT ON (agency_id)
    agency_id, snapshot_date AS anchor_date,
    auto_premium AS anchor_auto, fire_premium AS anchor_fire,
    life_premium AS anchor_life, health_premium AS anchor_health,
    household_count AS anchor_hh
  FROM public.book_snapshot
  ORDER BY agency_id, snapshot_date ASC
)
SELECT
  b.id, b.agency_id, b.snapshot_date, b.cadence,
  b.auto_premium, b.fire_premium, b.life_premium, b.health_premium,
  b.auto_pif, b.fire_pif, b.life_pif, b.health_pif,
  b.household_count,
  b.pc_premium, b.lh_premium,
  CASE WHEN b.household_count > 0 THEN b.pc_premium / b.household_count END AS pc_per_hh,
  CASE WHEN b.household_count > 0 THEN b.lh_premium / b.household_count END AS lh_per_hh,
  CASE WHEN b.pc_premium > 0 THEN b.auto_premium / b.pc_premium * 100 END AS auto_share_pc_pct,

  wow.snapshot_date AS wow_compare_date,
  mom.snapshot_date AS mom_compare_date,
  qoq.snapshot_date AS qoq_compare_date,
  yoy.snapshot_date AS yoy_compare_date,
  a.anchor_date,

  -- WoW (only for weekly cadence)
  CASE WHEN b.cadence = 'weekly' AND wow.auto_premium   > 0 THEN (b.auto_premium   - wow.auto_premium)   / wow.auto_premium   * 100 END AS auto_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.fire_premium   > 0 THEN (b.fire_premium   - wow.fire_premium)   / wow.fire_premium   * 100 END AS fire_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.life_premium   > 0 THEN (b.life_premium   - wow.life_premium)   / wow.life_premium   * 100 END AS life_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.health_premium > 0 THEN (b.health_premium - wow.health_premium) / wow.health_premium * 100 END AS health_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.pc_premium     > 0 THEN (b.pc_premium     - wow.pc_premium)     / wow.pc_premium     * 100 END AS pc_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.lh_premium     > 0 THEN (b.lh_premium     - wow.lh_premium)     / wow.lh_premium     * 100 END AS lh_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.household_count > 0 THEN (b.household_count - wow.household_count)::numeric / wow.household_count * 100 END AS hh_wow_pct,

  -- MoM
  CASE WHEN mom.auto_premium   > 0 THEN (b.auto_premium   - mom.auto_premium)   / mom.auto_premium   * 100 END AS auto_mom_pct,
  CASE WHEN mom.fire_premium   > 0 THEN (b.fire_premium   - mom.fire_premium)   / mom.fire_premium   * 100 END AS fire_mom_pct,
  CASE WHEN mom.life_premium   > 0 THEN (b.life_premium   - mom.life_premium)   / mom.life_premium   * 100 END AS life_mom_pct,
  CASE WHEN mom.health_premium > 0 THEN (b.health_premium - mom.health_premium) / mom.health_premium * 100 END AS health_mom_pct,
  CASE WHEN mom.pc_premium     > 0 THEN (b.pc_premium     - mom.pc_premium)     / mom.pc_premium     * 100 END AS pc_mom_pct,
  CASE WHEN mom.lh_premium     > 0 THEN (b.lh_premium     - mom.lh_premium)     / mom.lh_premium     * 100 END AS lh_mom_pct,
  CASE WHEN mom.household_count > 0 THEN (b.household_count - mom.household_count)::numeric / mom.household_count * 100 END AS hh_mom_pct,

  -- QoQ (NEW)
  CASE WHEN qoq.auto_premium   > 0 THEN (b.auto_premium   - qoq.auto_premium)   / qoq.auto_premium   * 100 END AS auto_qoq_pct,
  CASE WHEN qoq.fire_premium   > 0 THEN (b.fire_premium   - qoq.fire_premium)   / qoq.fire_premium   * 100 END AS fire_qoq_pct,
  CASE WHEN qoq.life_premium   > 0 THEN (b.life_premium   - qoq.life_premium)   / qoq.life_premium   * 100 END AS life_qoq_pct,
  CASE WHEN qoq.health_premium > 0 THEN (b.health_premium - qoq.health_premium) / qoq.health_premium * 100 END AS health_qoq_pct,
  CASE WHEN qoq.pc_premium     > 0 THEN (b.pc_premium     - qoq.pc_premium)     / qoq.pc_premium     * 100 END AS pc_qoq_pct,
  CASE WHEN qoq.lh_premium     > 0 THEN (b.lh_premium     - qoq.lh_premium)     / qoq.lh_premium     * 100 END AS lh_qoq_pct,
  CASE WHEN qoq.household_count > 0 THEN (b.household_count - qoq.household_count)::numeric / qoq.household_count * 100 END AS hh_qoq_pct,

  -- YoY
  CASE WHEN yoy.auto_premium   > 0 THEN (b.auto_premium   - yoy.auto_premium)   / yoy.auto_premium   * 100 END AS auto_yoy_pct,
  CASE WHEN yoy.fire_premium   > 0 THEN (b.fire_premium   - yoy.fire_premium)   / yoy.fire_premium   * 100 END AS fire_yoy_pct,
  CASE WHEN yoy.life_premium   > 0 THEN (b.life_premium   - yoy.life_premium)   / yoy.life_premium   * 100 END AS life_yoy_pct,
  CASE WHEN yoy.health_premium > 0 THEN (b.health_premium - yoy.health_premium) / yoy.health_premium * 100 END AS health_yoy_pct,
  CASE WHEN yoy.pc_premium     > 0 THEN (b.pc_premium     - yoy.pc_premium)     / yoy.pc_premium     * 100 END AS pc_yoy_pct,
  CASE WHEN yoy.lh_premium     > 0 THEN (b.lh_premium     - yoy.lh_premium)     / yoy.lh_premium     * 100 END AS lh_yoy_pct,
  CASE WHEN yoy.household_count > 0 THEN (b.household_count - yoy.household_count)::numeric / yoy.household_count * 100 END AS hh_yoy_pct,

  -- Cumulative since appointment
  CASE WHEN a.anchor_auto   > 0 THEN (b.auto_premium   - a.anchor_auto)   / a.anchor_auto   * 100 END AS auto_cum_pct,
  CASE WHEN a.anchor_fire   > 0 THEN (b.fire_premium   - a.anchor_fire)   / a.anchor_fire   * 100 END AS fire_cum_pct,
  CASE WHEN a.anchor_life   > 0 THEN (b.life_premium   - a.anchor_life)   / a.anchor_life   * 100 END AS life_cum_pct,
  CASE WHEN a.anchor_health > 0 THEN (b.health_premium - a.anchor_health) / a.anchor_health * 100 END AS health_cum_pct,
  CASE WHEN a.anchor_hh     > 0 THEN (b.household_count - a.anchor_hh)::numeric / a.anchor_hh * 100 END AS hh_cum_pct,

  b.source, b.source_document_id, b.notes, b.created_at, b.updated_at
FROM base b
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium, bs2.health_premium,
         COALESCE(bs2.auto_premium,0) + COALESCE(bs2.fire_premium,0) AS pc_premium,
         COALESCE(bs2.life_premium,0) + COALESCE(bs2.health_premium,0) AS lh_premium,
         bs2.household_count, bs2.snapshot_date
  FROM public.book_snapshot bs2
  WHERE bs2.agency_id = b.agency_id
    AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 week')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) wow ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium, bs2.health_premium,
         COALESCE(bs2.auto_premium,0) + COALESCE(bs2.fire_premium,0) AS pc_premium,
         COALESCE(bs2.life_premium,0) + COALESCE(bs2.health_premium,0) AS lh_premium,
         bs2.household_count, bs2.snapshot_date
  FROM public.book_snapshot bs2
  WHERE bs2.agency_id = b.agency_id
    AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 month')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) mom ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium, bs2.health_premium,
         COALESCE(bs2.auto_premium,0) + COALESCE(bs2.fire_premium,0) AS pc_premium,
         COALESCE(bs2.life_premium,0) + COALESCE(bs2.health_premium,0) AS lh_premium,
         bs2.household_count, bs2.snapshot_date
  FROM public.book_snapshot bs2
  WHERE bs2.agency_id = b.agency_id
    AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '3 months')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) qoq ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium, bs2.health_premium,
         COALESCE(bs2.auto_premium,0) + COALESCE(bs2.fire_premium,0) AS pc_premium,
         COALESCE(bs2.life_premium,0) + COALESCE(bs2.health_premium,0) AS lh_premium,
         bs2.household_count, bs2.snapshot_date
  FROM public.book_snapshot bs2
  WHERE bs2.agency_id = b.agency_id
    AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 year')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) yoy ON true
LEFT JOIN anchors a ON a.agency_id = b.agency_id
ORDER BY b.agency_id, b.cadence, b.snapshot_date;

GRANT SELECT ON public.v_book_snapshot_with_changes TO anon, authenticated;

COMMENT ON VIEW public.v_book_snapshot_with_changes IS 'book_snapshot with calendar-interval lookback: WoW=1 week, MoM=1 month, QoQ=3 months, YoY=1 year. Calendar-aware (handles Feb and leap years). WoW only computed for cadence=weekly.';

CREATE VIEW public.v_book_growth_summary AS
SELECT DISTINCT ON (agency_id, cadence)
  agency_id, cadence,
  snapshot_date AS current_snapshot_date,
  auto_premium, fire_premium, life_premium, health_premium,
  pc_premium, lh_premium,
  auto_pif, fire_pif, life_pif, health_pif,
  household_count,
  pc_per_hh, lh_per_hh, auto_share_pc_pct,
  wow_compare_date, mom_compare_date, qoq_compare_date, yoy_compare_date, anchor_date,
  auto_wow_pct, fire_wow_pct, life_wow_pct, health_wow_pct, pc_wow_pct, lh_wow_pct, hh_wow_pct,
  auto_mom_pct, fire_mom_pct, life_mom_pct, health_mom_pct, pc_mom_pct, lh_mom_pct, hh_mom_pct,
  auto_qoq_pct, fire_qoq_pct, life_qoq_pct, health_qoq_pct, pc_qoq_pct, lh_qoq_pct, hh_qoq_pct,
  auto_yoy_pct, fire_yoy_pct, life_yoy_pct, health_yoy_pct, pc_yoy_pct, lh_yoy_pct, hh_yoy_pct,
  auto_cum_pct, fire_cum_pct, life_cum_pct, health_cum_pct, hh_cum_pct,
  notes
FROM public.v_book_snapshot_with_changes
ORDER BY agency_id, cadence, snapshot_date DESC;

GRANT SELECT ON public.v_book_growth_summary TO anon, authenticated;
