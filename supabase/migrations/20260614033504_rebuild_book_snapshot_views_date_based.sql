-- Rebuild v_book_snapshot_with_changes using date-based lookback instead of LAG(N).
-- Reason: future weekly rows will mix with monthly rows; LAG(N) means different things
-- in different cadences. Date-based lookback returns the right comparison row regardless
-- of how the cadences interleave.
--
-- Lookback windows:
--   WoW = closest row 5+ days back (only computed for cadence='weekly')
--   MoM = closest row 25+ days back
--   YoY = closest row 350+ days back (2-week tolerance)
--   Cum = earliest row per agency (= appointment date)

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
    agency_id,
    snapshot_date     AS anchor_date,
    auto_premium      AS anchor_auto,
    fire_premium      AS anchor_fire,
    life_premium      AS anchor_life,
    health_premium    AS anchor_health,
    household_count   AS anchor_hh
  FROM public.book_snapshot
  ORDER BY agency_id, snapshot_date ASC
)
SELECT
  b.id, b.agency_id, b.snapshot_date, b.cadence,
  -- Stored values
  b.auto_premium, b.fire_premium, b.life_premium, b.health_premium,
  b.auto_pif, b.fire_pif, b.life_pif, b.health_pif,
  b.household_count,
  -- Derived totals
  b.pc_premium, b.lh_premium,
  -- Per-household derived
  CASE WHEN b.household_count > 0 THEN b.pc_premium / b.household_count END AS pc_per_hh,
  CASE WHEN b.household_count > 0 THEN b.lh_premium / b.household_count END AS lh_per_hh,
  -- Auto share of P&C
  CASE WHEN b.pc_premium > 0 THEN b.auto_premium / b.pc_premium * 100 END AS auto_share_pc_pct,

  -- Reference dates used for each comparison (transparency)
  wow.snapshot_date AS wow_compare_date,
  mom.snapshot_date AS mom_compare_date,
  yoy.snapshot_date AS yoy_compare_date,
  a.anchor_date,

  -- WoW % changes (weekly cadence only)
  CASE WHEN b.cadence = 'weekly' AND wow.auto_premium   > 0 THEN (b.auto_premium   - wow.auto_premium)   / wow.auto_premium   * 100 END AS auto_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.fire_premium   > 0 THEN (b.fire_premium   - wow.fire_premium)   / wow.fire_premium   * 100 END AS fire_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.life_premium   > 0 THEN (b.life_premium   - wow.life_premium)   / wow.life_premium   * 100 END AS life_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.health_premium > 0 THEN (b.health_premium - wow.health_premium) / wow.health_premium * 100 END AS health_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.pc_premium     > 0 THEN (b.pc_premium     - wow.pc_premium)     / wow.pc_premium     * 100 END AS pc_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.lh_premium     > 0 THEN (b.lh_premium     - wow.lh_premium)     / wow.lh_premium     * 100 END AS lh_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.household_count > 0 THEN (b.household_count - wow.household_count)::numeric / wow.household_count * 100 END AS hh_wow_pct,

  -- MoM % changes
  CASE WHEN mom.auto_premium   > 0 THEN (b.auto_premium   - mom.auto_premium)   / mom.auto_premium   * 100 END AS auto_mom_pct,
  CASE WHEN mom.fire_premium   > 0 THEN (b.fire_premium   - mom.fire_premium)   / mom.fire_premium   * 100 END AS fire_mom_pct,
  CASE WHEN mom.life_premium   > 0 THEN (b.life_premium   - mom.life_premium)   / mom.life_premium   * 100 END AS life_mom_pct,
  CASE WHEN mom.health_premium > 0 THEN (b.health_premium - mom.health_premium) / mom.health_premium * 100 END AS health_mom_pct,
  CASE WHEN mom.pc_premium     > 0 THEN (b.pc_premium     - mom.pc_premium)     / mom.pc_premium     * 100 END AS pc_mom_pct,
  CASE WHEN mom.lh_premium     > 0 THEN (b.lh_premium     - mom.lh_premium)     / mom.lh_premium     * 100 END AS lh_mom_pct,
  CASE WHEN mom.household_count > 0 THEN (b.household_count - mom.household_count)::numeric / mom.household_count * 100 END AS hh_mom_pct,

  -- YoY % changes
  CASE WHEN yoy.auto_premium   > 0 THEN (b.auto_premium   - yoy.auto_premium)   / yoy.auto_premium   * 100 END AS auto_yoy_pct,
  CASE WHEN yoy.fire_premium   > 0 THEN (b.fire_premium   - yoy.fire_premium)   / yoy.fire_premium   * 100 END AS fire_yoy_pct,
  CASE WHEN yoy.life_premium   > 0 THEN (b.life_premium   - yoy.life_premium)   / yoy.life_premium   * 100 END AS life_yoy_pct,
  CASE WHEN yoy.health_premium > 0 THEN (b.health_premium - yoy.health_premium) / yoy.health_premium * 100 END AS health_yoy_pct,
  CASE WHEN yoy.pc_premium     > 0 THEN (b.pc_premium     - yoy.pc_premium)     / yoy.pc_premium     * 100 END AS pc_yoy_pct,
  CASE WHEN yoy.lh_premium     > 0 THEN (b.lh_premium     - yoy.lh_premium)     / yoy.lh_premium     * 100 END AS lh_yoy_pct,
  CASE WHEN yoy.household_count > 0 THEN (b.household_count - yoy.household_count)::numeric / yoy.household_count * 100 END AS hh_yoy_pct,

  -- Cumulative-from-anchor % changes (since appointment date)
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
    AND bs2.snapshot_date <= b.snapshot_date - INTERVAL '5 days'
  ORDER BY bs2.snapshot_date DESC
  LIMIT 1
) wow ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium, bs2.health_premium,
         COALESCE(bs2.auto_premium,0) + COALESCE(bs2.fire_premium,0) AS pc_premium,
         COALESCE(bs2.life_premium,0) + COALESCE(bs2.health_premium,0) AS lh_premium,
         bs2.household_count, bs2.snapshot_date
  FROM public.book_snapshot bs2
  WHERE bs2.agency_id = b.agency_id
    AND bs2.snapshot_date <= b.snapshot_date - INTERVAL '25 days'
  ORDER BY bs2.snapshot_date DESC
  LIMIT 1
) mom ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium, bs2.health_premium,
         COALESCE(bs2.auto_premium,0) + COALESCE(bs2.fire_premium,0) AS pc_premium,
         COALESCE(bs2.life_premium,0) + COALESCE(bs2.health_premium,0) AS lh_premium,
         bs2.household_count, bs2.snapshot_date
  FROM public.book_snapshot bs2
  WHERE bs2.agency_id = b.agency_id
    AND bs2.snapshot_date <= b.snapshot_date - INTERVAL '350 days'
  ORDER BY bs2.snapshot_date DESC
  LIMIT 1
) yoy ON true
LEFT JOIN anchors a ON a.agency_id = b.agency_id
ORDER BY b.agency_id, b.cadence, b.snapshot_date;

GRANT SELECT ON public.v_book_snapshot_with_changes TO anon, authenticated;

COMMENT ON VIEW public.v_book_snapshot_with_changes IS 'book_snapshot with date-based lookback for WoW (weekly only), MoM, YoY, and cumulative-from-appointment. Returns the closest available row at or before each target date, so weekly and monthly cadences interleave cleanly. PIF totals (P&C, L&H) intentionally omitted — meaningless across LOBs.';
