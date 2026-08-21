-- Rebuild Jan-Apr 2026 agency (b2222222) payroll rows in prior_year_pl using payroll_gl_writer's Growth/Team split formula.
-- Applies now that raw_earnings backfill (mig 20260719010829) populated the required item breakdowns.
-- Formula (from payroll_gl_writer):
--   fixed_bundle = SALARY + HOURLY-family + OT
--   ramp = 1.0 - min(1.0, max(0, weeks_since_start / 52.0))
--   grow_share = fixed_bundle * ramp (per person per run)
--   team_share = (gross_pay + employer_taxes) - grow_share
-- Reimb rolled into team (matches May-Jun rebuild convention).
-- Excludes Owner (Peter → PN-side) + admin_bo (Marie → PN-side) + PaperNewt-entity employees.

DO $$
DECLARE
  v_agency_entity uuid := 'b2222222-2222-2222-2222-222222222222';
  v_papernewt_entity uuid := 'b1111111-1111-1111-1111-111111111111';
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
BEGIN

  -- Wipe existing Jan-Apr agency-side payroll rows
  DELETE FROM public.prior_year_pl
  WHERE business_entity_id = v_agency_entity
    AND period_year = 2026
    AND period_month BETWEEN 1 AND 4
    AND account_name IN ('6005 Payroll Costs', '6005a Payroll Costs - Growth');

  -- Insert new Growth + Team split rows
  WITH per_person_run AS (
    SELECT
      EXTRACT(month FROM pr.pay_date)::int AS m,
      pd.gross_pay,
      COALESCE(pd.employer_taxes, 0) AS er_taxes,
      pd.raw_earnings->'items' AS items,
      pr.pay_period_end,
      t.start_date
    FROM public.payroll_runs pr
    JOIN public.payroll_detail pd ON pd.payroll_run_id = pr.id
    JOIN public.team t ON t.id = pd.team_member_id
    WHERE pr.agency_id = v_agency_id
      AND pr.pay_date >= '2026-01-01' AND pr.pay_date < '2026-05-01'
      AND pd.raw_earnings IS NOT NULL
      AND t.role_level IS DISTINCT FROM 'Owner'
      AND t.is_admin_backoffice IS NOT TRUE
      AND t.business_entity_id IS DISTINCT FROM v_papernewt_entity
  ),
  fixed_calc AS (
    SELECT
      m,
      gross_pay + er_taxes AS gross_plus_er,
      (COALESCE((items->'SALARY'->>'period')::numeric, 0)
       + COALESCE((items->'HOURLY'->>'period')::numeric, 0)
       + COALESCE((items->'REGULAR'->>'period')::numeric, 0)
       + COALESCE((items->'PTO'->>'period')::numeric, 0)
       + COALESCE((items->'1Health'->>'period')::numeric, 0)
       + COALESCE((items->'5Goals'->>'period')::numeric, 0)
       + COALESCE((items->'LIFE *'->>'period')::numeric, 0)
       + COALESCE((items->'OT'->>'period')::numeric, 0)
       + COALESCE((items->'- O/TIME'->>'period')::numeric, 0)) AS fixed_bundle,
      CASE
        WHEN start_date IS NULL THEN 0::numeric
        ELSE 1.0 - LEAST(1.0, GREATEST(0::numeric, FLOOR((pay_period_end - start_date) / 7.0)::numeric / 52.0))
      END AS ramp
    FROM per_person_run
  ),
  shares AS (
    SELECT
      m,
      gross_plus_er,
      ROUND((fixed_bundle * ramp)::numeric, 2) AS grow_share
    FROM fixed_calc
  ),
  agg AS (
    SELECT
      m,
      ROUND(SUM(grow_share)::numeric, 2) AS growth_total,
      ROUND(SUM(gross_plus_er - grow_share)::numeric, 2) AS team_total
    FROM shares
    GROUP BY m
  )
  INSERT INTO public.prior_year_pl (
    agency_id, business_entity_id, period_year, period_month,
    section, section_type, account_name, amount, source_entity
  )
  SELECT
    v_agency_id, v_agency_entity, 2026, m,
    '0002 GROWTH', 'Expense', '6005a Payroll Costs - Growth',
    growth_total,
    'Peter Story State Farm'
  FROM agg
  WHERE growth_total > 0

  UNION ALL

  SELECT
    v_agency_id, v_agency_entity, 2026, m,
    '0003 TEAM', 'Expense', '6005 Payroll Costs',
    team_total,
    'Peter Story State Farm'
  FROM agg
  WHERE team_total > 0;
END $$;
