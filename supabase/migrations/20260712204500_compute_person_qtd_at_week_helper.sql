-- Tier-aware SP walk helper: cumulative SP for (person, year, quarter) at end-of-week W (1..13).
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

  v_scale := LEAST(1.0, p_week::numeric / 13.0);
  v_cum_auto_apps  := FLOOR(v_auto_apps  * v_scale)::int;
  v_cum_fire_apps  := FLOOR(v_fire_apps  * v_scale)::int;
  v_cum_auto_prem  := v_auto_prem  * v_scale;
  v_cum_fire_prem  := v_fire_prem  * v_scale;
  v_cum_life_prem  := v_life_prem  * v_scale;
  v_cum_health_prem := v_health_prem * v_scale;

  v_pc_tiers := FLOOR(v_cum_auto_apps / 6.0)::int
              + FLOOR(v_cum_fire_apps / 3.0)::int
              + FLOOR(v_cum_life_prem / 200.0)::int;
  v_lh_tiers := FLOOR(v_cum_life_prem / 200.0)::int;

  v_pc_rate := LEAST(0.06, 0.01 + 0.0005 * v_pc_tiers);
  v_lh_rate := LEAST(0.18, 0.03 + 0.0015 * v_lh_tiers);

  v_pc_comm := v_pc_rate * (v_cum_auto_prem + v_cum_fire_prem);
  v_lh_comm := v_lh_rate * (v_cum_life_prem + v_cum_health_prem);

  RETURN ROUND((v_pc_comm + v_lh_comm)::numeric, 2);
END;
$function$;
