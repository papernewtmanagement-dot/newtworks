-- Rebuild v_book_growth_summary as a thin selector over v_book_snapshot_with_changes.
-- Returns the most recent row per agency per cadence. All change % already computed upstream.

DROP VIEW IF EXISTS public.v_book_growth_summary CASCADE;

CREATE VIEW public.v_book_growth_summary AS
SELECT DISTINCT ON (agency_id, cadence)
  agency_id,
  cadence,
  snapshot_date AS current_snapshot_date,
  -- Current values
  auto_premium, fire_premium, life_premium, health_premium,
  pc_premium, lh_premium,
  auto_pif, fire_pif, life_pif, health_pif,
  household_count,
  pc_per_hh, lh_per_hh, auto_share_pc_pct,
  -- Reference dates
  wow_compare_date, mom_compare_date, yoy_compare_date, anchor_date,
  -- WoW (weekly only)
  auto_wow_pct, fire_wow_pct, life_wow_pct, health_wow_pct, pc_wow_pct, lh_wow_pct, hh_wow_pct,
  -- MoM
  auto_mom_pct, fire_mom_pct, life_mom_pct, health_mom_pct, pc_mom_pct, lh_mom_pct, hh_mom_pct,
  -- YoY
  auto_yoy_pct, fire_yoy_pct, life_yoy_pct, health_yoy_pct, pc_yoy_pct, lh_yoy_pct, hh_yoy_pct,
  -- Cumulative since appointment
  auto_cum_pct, fire_cum_pct, life_cum_pct, health_cum_pct, hh_cum_pct,
  notes
FROM public.v_book_snapshot_with_changes
ORDER BY agency_id, cadence, snapshot_date DESC;

GRANT SELECT ON public.v_book_growth_summary TO anon, authenticated;

COMMENT ON VIEW public.v_book_growth_summary IS 'Most recent snapshot per agency per cadence with all change % already computed. Headline numbers for Dashboard.';
