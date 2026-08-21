-- View 2: book_growth_summary
-- Most-recent snapshot vs N periods ago. One row per agency per cadence.
-- Useful for Growth Advisor cadence and dashboard headline numbers.

CREATE OR REPLACE VIEW public.v_book_growth_summary AS
WITH latest AS (
  SELECT DISTINCT ON (agency_id, cadence)
    agency_id, cadence, snapshot_date,
    auto_premium, fire_premium, life_premium, health_premium,
    auto_pif, fire_pif, life_pif, health_pif,
    household_count
  FROM public.book_snapshot
  ORDER BY agency_id, cadence, snapshot_date DESC
),
snap_1ago AS (
  SELECT DISTINCT ON (agency_id, cadence)
    agency_id, cadence, snapshot_date,
    auto_premium, fire_premium, life_premium, health_premium, household_count
  FROM public.book_snapshot
  WHERE (agency_id, cadence, snapshot_date) NOT IN (SELECT agency_id, cadence, snapshot_date FROM latest)
  ORDER BY agency_id, cadence, snapshot_date DESC
),
snap_12ago AS (
  SELECT bs.agency_id, bs.cadence, bs.snapshot_date,
         bs.auto_premium, bs.fire_premium, bs.life_premium, bs.health_premium, bs.household_count
  FROM public.book_snapshot bs
  JOIN latest l ON l.agency_id = bs.agency_id AND l.cadence = bs.cadence
  WHERE bs.snapshot_date = (
    SELECT snapshot_date FROM public.book_snapshot
    WHERE agency_id = bs.agency_id AND cadence = bs.cadence
    ORDER BY snapshot_date DESC
    OFFSET 12 LIMIT 1
  )
),
anchor AS (
  SELECT DISTINCT ON (agency_id, cadence)
    agency_id, cadence, snapshot_date AS anchor_date,
    auto_premium AS anchor_auto, fire_premium AS anchor_fire,
    life_premium AS anchor_life, health_premium AS anchor_health,
    household_count AS anchor_hh
  FROM public.book_snapshot
  ORDER BY agency_id, cadence, snapshot_date ASC
)
SELECT
  l.agency_id,
  l.cadence,
  l.snapshot_date                  AS current_date_actual,
  -- current values
  l.auto_premium                   AS auto_current,
  l.fire_premium                   AS fire_current,
  l.life_premium                   AS life_current,
  l.health_premium                 AS health_current,
  COALESCE(l.auto_premium,0) + COALESCE(l.fire_premium,0)     AS pc_current,
  COALESCE(l.life_premium,0) + COALESCE(l.health_premium,0)   AS lh_current,
  l.household_count                AS hh_current,
  l.auto_pif, l.fire_pif, l.life_pif, l.health_pif,

  -- last period
  p1.snapshot_date                 AS prior_period_date,
  CASE WHEN p1.auto_premium > 0   THEN (l.auto_premium    - p1.auto_premium)   / p1.auto_premium   * 100 END AS auto_chg_pop_pct,
  CASE WHEN p1.fire_premium > 0   THEN (l.fire_premium    - p1.fire_premium)   / p1.fire_premium   * 100 END AS fire_chg_pop_pct,
  CASE WHEN p1.life_premium > 0   THEN (l.life_premium    - p1.life_premium)   / p1.life_premium   * 100 END AS life_chg_pop_pct,
  CASE WHEN p1.health_premium > 0 THEN (l.health_premium  - p1.health_premium) / p1.health_premium * 100 END AS health_chg_pop_pct,
  CASE WHEN p1.household_count > 0 THEN (l.household_count - p1.household_count)::numeric / p1.household_count * 100 END AS hh_chg_pop_pct,

  -- 12 periods ago
  p12.snapshot_date                AS yoy_period_date,
  CASE WHEN p12.auto_premium > 0   THEN (l.auto_premium    - p12.auto_premium)   / p12.auto_premium   * 100 END AS auto_chg_yoy_pct,
  CASE WHEN p12.fire_premium > 0   THEN (l.fire_premium    - p12.fire_premium)   / p12.fire_premium   * 100 END AS fire_chg_yoy_pct,
  CASE WHEN p12.life_premium > 0   THEN (l.life_premium    - p12.life_premium)   / p12.life_premium   * 100 END AS life_chg_yoy_pct,
  CASE WHEN p12.health_premium > 0 THEN (l.health_premium  - p12.health_premium) / p12.health_premium * 100 END AS health_chg_yoy_pct,
  CASE WHEN p12.household_count > 0 THEN (l.household_count - p12.household_count)::numeric / p12.household_count * 100 END AS hh_chg_yoy_pct,

  -- since anchor (appointment)
  a.anchor_date,
  CASE WHEN a.anchor_auto > 0   THEN (l.auto_premium    - a.anchor_auto)   / a.anchor_auto   * 100 END AS auto_chg_cum_pct,
  CASE WHEN a.anchor_fire > 0   THEN (l.fire_premium    - a.anchor_fire)   / a.anchor_fire   * 100 END AS fire_chg_cum_pct,
  CASE WHEN a.anchor_life > 0   THEN (l.life_premium    - a.anchor_life)   / a.anchor_life   * 100 END AS life_chg_cum_pct,
  CASE WHEN a.anchor_health > 0 THEN (l.health_premium  - a.anchor_health) / a.anchor_health * 100 END AS health_chg_cum_pct,
  CASE WHEN a.anchor_hh > 0     THEN (l.household_count - a.anchor_hh)::numeric / a.anchor_hh * 100 END AS hh_chg_cum_pct
FROM latest l
LEFT JOIN snap_1ago p1 ON p1.agency_id = l.agency_id AND p1.cadence = l.cadence
LEFT JOIN snap_12ago p12 ON p12.agency_id = l.agency_id AND p12.cadence = l.cadence
LEFT JOIN anchor a ON a.agency_id = l.agency_id AND a.cadence = l.cadence;

GRANT SELECT ON public.v_book_growth_summary TO anon, authenticated;

COMMENT ON VIEW public.v_book_growth_summary IS 'Most-recent snapshot vs 1-period-ago, 12-periods-ago, and anchor (appointment date) — one row per agency per cadence. Powers dashboard headline numbers and Growth Advisor cadence.';
