-- Tier-aware SP walk helper: cumulative SP for (person, year, quarter) at end-of-week W (1..13)
-- Mirrors the SF Builder 2026-07-07 rate rules used in compute_person_commissions_quarterly.
-- Distributes quarterly LOB totals evenly across 13 weeks (steady pace) — same assumption used
-- for the week_sp leaderboard seed 2026-07-12.
-- Under steady pace, cumulative apps/premium at week W = Q_total × W/13, then tier ladders
-- reset per quarter and rate rebounds retroactively when a tier crosses.
CREATE OR REPLACE FUNCTION public.compute_person_qtd_at_week(
  p_agency_id uuid, p_team_member_id uuid, p_year int, p_quarter int, p_week int
) RETURNS numeric
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_auto_apps int; v_fire_apps int;
  v_auto_prem numeric; v_fire_prem numeric; v_life_prem numeric; v_health_prem numeric;
  v_cum_auto_apps int; v_cum_fire_apps int;
  v_cum_auto_prem numeric; v_cum_fire_prem numeric;
  v_cum_life_prem numeric; v_cum_health_prem numeric;
  v_pc_tiers int; v_lh_tiers int;
  v_pc_rate numeric; v_lh_rate numeric;
  v_pc_comm numeric; v_lh_comm numeric;
  v_scale numeric;
BEGIN
  IF p_week <= 0 THEN RETURN 0; END IF;

  -- Quarterly LOB totals from producer_production (monthly grain rolled up to quarter)
  SELECT
    COALESCE(SUM(policies_issued) FILTER (WHERE lower(line_of_business) = 'auto'), 0)::int,
    COALESCE(SUM(policies_issued) FILTER (WHERE lower(line_of_business) = 'fire'), 0)::int,
    COALESCE(SUM(premium_issued)  FILTER (WHERE lower(line_of_business) = 'auto'), 0),
    COALESCE(SUM(premium_issued)  FILTER (WHERE lower(line_of_business) = 'fire'), 0),
    COALESCE(SUM(premium_issued)  FILTER (WHERE lower(line_of_business) = 'life'), 0),
    COALESCE(SUM(premium_issued)  FILTER (WHERE lower(line_of_business) = 'health'), 0)
  INTO v_auto_apps, v_fire_apps, v_auto_prem, v_fire_prem, v_life_prem, v_health_prem
  FROM public.producer_production
  WHERE agency_id = p_agency_id
    AND team_member_id = p_team_member_id
    AND period_year = p_year
    AND period_month BETWEEN (p_quarter-1)*3+1 AND p_quarter*3;

  -- Steady weekly pace scaling (cap at 1.0 for W>=13)
  v_scale := LEAST(1.0, p_week::numeric / 13.0);

  -- Cumulative apps: FLOOR so a tier crosses when apps threshold is discretely met
  v_cum_auto_apps  := FLOOR(v_auto_apps  * v_scale)::int;
  v_cum_fire_apps  := FLOOR(v_fire_apps  * v_scale)::int;
  v_cum_auto_prem  := v_auto_prem  * v_scale;
  v_cum_fire_prem  := v_fire_prem  * v_scale;
  v_cum_life_prem  := v_life_prem  * v_scale;
  v_cum_health_prem := v_health_prem * v_scale;

  -- Tier ladders (SF Builder: Auto every 6 apps, Fire every 3 apps, Life every $200 premium)
  -- PC tier count = auto_tiers + fire_tiers + life_tiers (Life contributes to PC ladder too)
  -- LH tier count = life_tiers only
  v_pc_tiers := FLOOR(v_cum_auto_apps / 6.0)::int
              + FLOOR(v_cum_fire_apps / 3.0)::int
              + FLOOR(v_cum_life_prem / 200.0)::int;
  v_lh_tiers := FLOOR(v_cum_life_prem / 200.0)::int;

  -- Rates (SF Builder 2026-07-07): PC starts 1% + 0.05%/tier cap 6%; LH starts 3% + 0.15%/tier cap 18%
  v_pc_rate := LEAST(0.06, 0.01 + 0.0005 * v_pc_tiers);
  v_lh_rate := LEAST(0.18, 0.03 + 0.0015 * v_lh_tiers);

  -- Cumulative commission at end of week W (tier-aware, retroactive to premium base)
  v_pc_comm := v_pc_rate * (v_cum_auto_prem + v_cum_fire_prem);
  v_lh_comm := v_lh_rate * (v_cum_life_prem + v_cum_health_prem);

  RETURN ROUND((v_pc_comm + v_lh_comm)::numeric, 2);
END;
$function$;

-- Sanity check: cumulative at W=13 must equal stored quarter total (validation criteria from week_sp seed)
DO $$
DECLARE
  v_walk numeric;
  v_stored numeric;
BEGIN
  -- John Q1 2026: expected 7347.76
  v_walk := public.compute_person_qtd_at_week(
    '126794dd-25ff-47d2-a436-724499733365',
    (SELECT id FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND first_name='John' LIMIT 1),
    2026, 1, 13
  );
  RAISE NOTICE 'John Q1 2026 walk @ wk13: %, expected 7347.76', v_walk;

  -- Thomas Q2 2026: expected ~5179.24 (Q2 QTD at wk 12 was 5179.24; wk13 might be slightly higher)
  v_walk := public.compute_person_qtd_at_week(
    '126794dd-25ff-47d2-a436-724499733365',
    (SELECT id FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND first_name='Thomas' LIMIT 1),
    2026, 2, 13
  );
  RAISE NOTICE 'Thomas Q2 2026 walk @ wk13: %, expected ~5179.24', v_walk;
END$$;
