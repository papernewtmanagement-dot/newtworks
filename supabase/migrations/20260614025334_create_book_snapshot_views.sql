-- View 1: book_snapshot with all derived % change metrics
-- Computes period-over-period and cumulative-from-anchor deltas at query time.
-- Anchor = earliest snapshot per agency per cadence.

CREATE OR REPLACE VIEW public.v_book_snapshot_with_changes AS
WITH ranked AS (
  SELECT
    bs.*,
    -- P&C total
    COALESCE(auto_premium, 0) + COALESCE(fire_premium, 0) AS pc_premium,
    -- L&H total
    COALESCE(life_premium, 0) + COALESCE(health_premium, 0) AS lh_premium,
    -- prior-period values (one row back within same agency + cadence)
    LAG(auto_premium)    OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_auto,
    LAG(fire_premium)    OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_fire,
    LAG(life_premium)    OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_life,
    LAG(health_premium)  OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_health,
    LAG(household_count) OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_hh,
    LAG(auto_pif)        OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_auto_pif,
    LAG(fire_pif)        OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_fire_pif,
    LAG(life_pif)        OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_life_pif,
    LAG(health_pif)      OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS prev_health_pif,
    -- 12-period-ago values (YoY for monthly, ~quarterly for weekly — interpret with cadence)
    LAG(auto_premium, 12)   OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS yoy_auto,
    LAG(fire_premium, 12)   OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS yoy_fire,
    LAG(life_premium, 12)   OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS yoy_life,
    LAG(health_premium, 12) OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS yoy_health,
    LAG(household_count, 12)OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS yoy_hh,
    -- first-row anchors for cumulative-from-start
    FIRST_VALUE(auto_premium)    OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS anchor_auto,
    FIRST_VALUE(fire_premium)    OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS anchor_fire,
    FIRST_VALUE(life_premium)    OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS anchor_life,
    FIRST_VALUE(health_premium)  OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS anchor_health,
    FIRST_VALUE(household_count) OVER (PARTITION BY agency_id, cadence ORDER BY snapshot_date) AS anchor_hh
  FROM public.book_snapshot bs
)
SELECT
  id, agency_id, snapshot_date, cadence,
  auto_premium, fire_premium, life_premium, health_premium,
  pc_premium, lh_premium,
  auto_pif, fire_pif, life_pif, health_pif,
  household_count,

  -- Period-over-period % changes
  CASE WHEN prev_auto    > 0 THEN (auto_premium    - prev_auto)    / prev_auto    * 100 END AS auto_change_pop_pct,
  CASE WHEN prev_fire    > 0 THEN (fire_premium    - prev_fire)    / prev_fire    * 100 END AS fire_change_pop_pct,
  CASE WHEN prev_life    > 0 THEN (life_premium    - prev_life)    / prev_life    * 100 END AS life_change_pop_pct,
  CASE WHEN prev_health  > 0 THEN (health_premium  - prev_health)  / prev_health  * 100 END AS health_change_pop_pct,
  CASE WHEN prev_hh      > 0 THEN (household_count - prev_hh)::numeric / prev_hh * 100 END AS hh_change_pop_pct,

  -- Year-over-year % changes (12 periods back)
  CASE WHEN yoy_auto    > 0 THEN (auto_premium    - yoy_auto)    / yoy_auto    * 100 END AS auto_change_yoy_pct,
  CASE WHEN yoy_fire    > 0 THEN (fire_premium    - yoy_fire)    / yoy_fire    * 100 END AS fire_change_yoy_pct,
  CASE WHEN yoy_life    > 0 THEN (life_premium    - yoy_life)    / yoy_life    * 100 END AS life_change_yoy_pct,
  CASE WHEN yoy_health  > 0 THEN (health_premium  - yoy_health)  / yoy_health  * 100 END AS health_change_yoy_pct,
  CASE WHEN yoy_hh      > 0 THEN (household_count - yoy_hh)::numeric / yoy_hh * 100 END AS hh_change_yoy_pct,

  -- Cumulative-from-anchor % changes (since SF appointment 10/1/2018)
  CASE WHEN anchor_auto   > 0 THEN (auto_premium    - anchor_auto)   / anchor_auto   * 100 END AS auto_change_cum_pct,
  CASE WHEN anchor_fire   > 0 THEN (fire_premium    - anchor_fire)   / anchor_fire   * 100 END AS fire_change_cum_pct,
  CASE WHEN anchor_life   > 0 THEN (life_premium    - anchor_life)   / anchor_life   * 100 END AS life_change_cum_pct,
  CASE WHEN anchor_health > 0 THEN (health_premium  - anchor_health) / anchor_health * 100 END AS health_change_cum_pct,
  CASE WHEN anchor_hh     > 0 THEN (household_count - anchor_hh)::numeric / anchor_hh * 100 END AS hh_change_cum_pct,

  -- Per-household figures
  CASE WHEN household_count > 0 THEN pc_premium / household_count END AS pc_per_hh,
  CASE WHEN household_count > 0 THEN lh_premium / household_count END AS lh_per_hh,

  -- Auto share of P&C
  CASE WHEN pc_premium > 0 THEN auto_premium / pc_premium * 100 END AS auto_share_pc_pct,

  source, source_document_id, notes, created_at, updated_at
FROM ranked
ORDER BY agency_id, cadence, snapshot_date;

GRANT SELECT ON public.v_book_snapshot_with_changes TO anon, authenticated;

COMMENT ON VIEW public.v_book_snapshot_with_changes IS 'book_snapshot with computed period-over-period, year-over-year (12 periods back), and cumulative-from-anchor % changes, plus P&C/LH totals and per-household derived metrics.';
