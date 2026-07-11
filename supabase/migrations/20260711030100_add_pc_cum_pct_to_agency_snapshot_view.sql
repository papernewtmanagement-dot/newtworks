-- Add pc_cum_pct (P&C premium change since anchor/appointment date) to
-- v_agency_snapshot_with_changes. The anchors CTE already carries anchor_auto
-- and anchor_fire; pc_anchor = anchor_auto + anchor_fire.
--
-- CREATE OR REPLACE VIEW requires appended columns only; pc_cum_pct goes last.
CREATE OR REPLACE VIEW public.v_agency_snapshot_with_changes AS
WITH base AS (
  SELECT
    a_1.id, a_1.agency_id, a_1.snapshot_date, a_1.cadence,
    a_1.auto_new_ytd, a_1.auto_lost_ytd, a_1.auto_pif, a_1.auto_premium,
    a_1.fire_new_ytd, a_1.fire_lost_ytd, a_1.fire_pif, a_1.fire_premium,
    a_1.life_new_ytd, a_1.life_lost_ytd, a_1.life_pif,
    a_1.life_paid_for_count_ytd, a_1.life_paid_for_premium_ytd, a_1.life_premium,
    a_1.ips_new_money_ytd, a_1.household_count,
    a_1.source, a_1.notes, a_1.created_at, a_1.updated_at,
    COALESCE(a_1.auto_premium, 0::numeric) + COALESCE(a_1.fire_premium, 0::numeric) AS pc_premium
  FROM agency_snapshot a_1
), anchors AS (
  SELECT DISTINCT ON (agency_snapshot.agency_id)
    agency_snapshot.agency_id,
    agency_snapshot.snapshot_date  AS anchor_date,
    agency_snapshot.auto_premium   AS anchor_auto,
    agency_snapshot.fire_premium   AS anchor_fire,
    agency_snapshot.life_premium   AS anchor_life,
    agency_snapshot.household_count AS anchor_hh
  FROM agency_snapshot
  ORDER BY agency_snapshot.agency_id, agency_snapshot.snapshot_date
)
SELECT
  b.id, b.agency_id, b.snapshot_date, b.cadence,
  b.auto_new_ytd, b.auto_lost_ytd, b.auto_pif, b.auto_premium,
  b.fire_new_ytd, b.fire_lost_ytd, b.fire_pif, b.fire_premium,
  b.life_new_ytd, b.life_lost_ytd, b.life_pif,
  b.life_paid_for_count_ytd, b.life_paid_for_premium_ytd, b.life_premium,
  b.ips_new_money_ytd, b.household_count,
  b.source, b.notes, b.created_at, b.updated_at,
  b.pc_premium,
  CASE WHEN b.household_count > 0 THEN b.pc_premium / b.household_count::numeric ELSE NULL END AS pc_per_hh,
  CASE WHEN b.pc_premium > 0 THEN b.auto_premium / b.pc_premium * 100 ELSE NULL END AS auto_share_pc_pct,
  wow.snapshot_date AS wow_compare_date,
  mom.snapshot_date AS mom_compare_date,
  qoq.snapshot_date AS qoq_compare_date,
  yoy.snapshot_date AS yoy_compare_date,
  a.anchor_date,
  CASE WHEN b.cadence = 'weekly' AND wow.auto_premium > 0 THEN (b.auto_premium - wow.auto_premium) / wow.auto_premium * 100 ELSE NULL END AS auto_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.fire_premium > 0 THEN (b.fire_premium - wow.fire_premium) / wow.fire_premium * 100 ELSE NULL END AS fire_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.life_premium > 0 THEN (b.life_premium - wow.life_premium) / wow.life_premium * 100 ELSE NULL END AS life_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.pc_premium   > 0 THEN (b.pc_premium   - wow.pc_premium)   / wow.pc_premium   * 100 ELSE NULL END AS pc_wow_pct,
  CASE WHEN b.cadence = 'weekly' AND wow.household_count > 0 THEN (b.household_count - wow.household_count)::numeric / wow.household_count * 100 ELSE NULL END AS hh_wow_pct,
  CASE WHEN mom.auto_premium > 0 THEN (b.auto_premium - mom.auto_premium) / mom.auto_premium * 100 ELSE NULL END AS auto_mom_pct,
  CASE WHEN mom.fire_premium > 0 THEN (b.fire_premium - mom.fire_premium) / mom.fire_premium * 100 ELSE NULL END AS fire_mom_pct,
  CASE WHEN mom.life_premium > 0 THEN (b.life_premium - mom.life_premium) / mom.life_premium * 100 ELSE NULL END AS life_mom_pct,
  CASE WHEN mom.pc_premium   > 0 THEN (b.pc_premium   - mom.pc_premium)   / mom.pc_premium   * 100 ELSE NULL END AS pc_mom_pct,
  CASE WHEN mom.household_count > 0 THEN (b.household_count - mom.household_count)::numeric / mom.household_count * 100 ELSE NULL END AS hh_mom_pct,
  CASE WHEN qoq.auto_premium > 0 THEN (b.auto_premium - qoq.auto_premium) / qoq.auto_premium * 100 ELSE NULL END AS auto_qoq_pct,
  CASE WHEN qoq.fire_premium > 0 THEN (b.fire_premium - qoq.fire_premium) / qoq.fire_premium * 100 ELSE NULL END AS fire_qoq_pct,
  CASE WHEN qoq.life_premium > 0 THEN (b.life_premium - qoq.life_premium) / qoq.life_premium * 100 ELSE NULL END AS life_qoq_pct,
  CASE WHEN qoq.pc_premium   > 0 THEN (b.pc_premium   - qoq.pc_premium)   / qoq.pc_premium   * 100 ELSE NULL END AS pc_qoq_pct,
  CASE WHEN qoq.household_count > 0 THEN (b.household_count - qoq.household_count)::numeric / qoq.household_count * 100 ELSE NULL END AS hh_qoq_pct,
  CASE WHEN yoy.auto_premium > 0 THEN (b.auto_premium - yoy.auto_premium) / yoy.auto_premium * 100 ELSE NULL END AS auto_yoy_pct,
  CASE WHEN yoy.fire_premium > 0 THEN (b.fire_premium - yoy.fire_premium) / yoy.fire_premium * 100 ELSE NULL END AS fire_yoy_pct,
  CASE WHEN yoy.life_premium > 0 THEN (b.life_premium - yoy.life_premium) / yoy.life_premium * 100 ELSE NULL END AS life_yoy_pct,
  CASE WHEN yoy.pc_premium   > 0 THEN (b.pc_premium   - yoy.pc_premium)   / yoy.pc_premium   * 100 ELSE NULL END AS pc_yoy_pct,
  CASE WHEN yoy.household_count > 0 THEN (b.household_count - yoy.household_count)::numeric / yoy.household_count * 100 ELSE NULL END AS hh_yoy_pct,
  CASE WHEN a.anchor_auto > 0 THEN (b.auto_premium - a.anchor_auto) / a.anchor_auto * 100 ELSE NULL END AS auto_cum_pct,
  CASE WHEN a.anchor_fire > 0 THEN (b.fire_premium - a.anchor_fire) / a.anchor_fire * 100 ELSE NULL END AS fire_cum_pct,
  CASE WHEN a.anchor_life > 0 THEN (b.life_premium - a.anchor_life) / a.anchor_life * 100 ELSE NULL END AS life_cum_pct,
  CASE WHEN a.anchor_hh > 0 THEN (b.household_count - a.anchor_hh)::numeric / a.anchor_hh * 100 ELSE NULL END AS hh_cum_pct,
  CASE WHEN (COALESCE(a.anchor_auto, 0) + COALESCE(a.anchor_fire, 0)) > 0
       THEN (b.pc_premium - (COALESCE(a.anchor_auto, 0) + COALESCE(a.anchor_fire, 0)))
            / (COALESCE(a.anchor_auto, 0) + COALESCE(a.anchor_fire, 0)) * 100
       ELSE NULL END AS pc_cum_pct
FROM base b
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium,
         COALESCE(bs2.auto_premium, 0) + COALESCE(bs2.fire_premium, 0) AS pc_premium,
         bs2.household_count, bs2.snapshot_date
  FROM agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '7 days')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) wow ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium,
         COALESCE(bs2.auto_premium, 0) + COALESCE(bs2.fire_premium, 0) AS pc_premium,
         bs2.household_count, bs2.snapshot_date
  FROM agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 month')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) mom ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium,
         COALESCE(bs2.auto_premium, 0) + COALESCE(bs2.fire_premium, 0) AS pc_premium,
         bs2.household_count, bs2.snapshot_date
  FROM agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '91 days')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) qoq ON true
LEFT JOIN LATERAL (
  SELECT bs2.auto_premium, bs2.fire_premium, bs2.life_premium,
         COALESCE(bs2.auto_premium, 0) + COALESCE(bs2.fire_premium, 0) AS pc_premium,
         bs2.household_count, bs2.snapshot_date
  FROM agency_snapshot bs2
  WHERE bs2.agency_id = b.agency_id AND bs2.snapshot_date <= (b.snapshot_date - INTERVAL '1 year')::date
  ORDER BY bs2.snapshot_date DESC LIMIT 1
) yoy ON true
LEFT JOIN anchors a ON a.agency_id = b.agency_id
ORDER BY b.agency_id, b.cadence, b.snapshot_date;
