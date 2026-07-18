-- Agency parent renumber (insert 0002 GROWTH) + payroll Growth/Team split rebuild for Jan-Jun 2026
-- Peter directive 2026-07-18: GROWTH is 2nd parent, cascade rename others (TEAM 0002->0003, MARKETING 0003->0004, DISCRETIONARY 0004->0005, PERSONAL 0005->0006).
-- Payroll: retire duplicate COA-SUB-087 "Payroll — Team Budget"; reclass existing JEs to COA-SUB-078 "6005 Payroll Costs" (unchanged).
-- Reparent COA-SUB-086 to new GROWTH parent; rename "6005a Payroll Costs - Growth".
-- New: COA-SUB-089 "7030a Dues & Licenses - Growth" under GROWTH (for new-hire team licensing reimbursements).
-- prior_year_pl: rename section labels across all years; rebuild Jan-Jun 2026 payroll rows using per-person tenure-ramp split from payroll_gl_writer logic.
-- Reimb backfill: Stephanie 2026-06-12 $79.00 + Jason 2026-06-22 $311.26 = $390.26 -> new-hire licensing -> 7030a Growth June 2026.
-- KNOWN LIMITATION: Jan-Apr 2026 payroll_detail.raw_earnings items JSON not populated -> fixed_pay = 0 for those rows -> whole gross+ER_taxes falls into Team (correct behavior per writer, but doesn't reflect true ramp split). Requires raw_earnings backfill from SurePayroll XLS to redo split.

DO $mig$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_ent uuid := 'b2222222-2222-2222-2222-222222222222';
  v_growth_parent uuid;
  v_old_growth_child uuid;
  v_old_team_child uuid;
  v_team_payroll uuid;
  v_growth_licenses uuid;
  v_reclass_count int;
  v_check_before numeric;
  v_check_after_growth numeric;
  v_check_after_team numeric;
  v_check_after_reimb numeric;
  v_check_after_total numeric;
BEGIN
  UPDATE chart_of_accounts SET account_name = '0003 TEAM'
    WHERE agency_id = v_agency AND account_code = 'COA-020';
  UPDATE chart_of_accounts SET account_name = '0004 MARKETING'
    WHERE agency_id = v_agency AND account_code = 'COA-021';
  UPDATE chart_of_accounts SET account_name = '0005 DISCRETIONARY'
    WHERE agency_id = v_agency AND account_code = 'COA-031';
  UPDATE chart_of_accounts SET account_name = '0006 PERSONAL'
    WHERE agency_id = v_agency AND account_code = 'COA-022';

  INSERT INTO chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type)
  VALUES (v_agency, v_ent, 'COA-032', '0002 GROWTH', 'expense')
  RETURNING id INTO v_growth_parent;

  SELECT id INTO v_old_growth_child
    FROM chart_of_accounts WHERE agency_id = v_agency AND account_code = 'COA-SUB-086';
  UPDATE chart_of_accounts
    SET parent_account_id = v_growth_parent,
        account_name = '6005a Payroll Costs - Growth'
    WHERE id = v_old_growth_child;

  SELECT id INTO v_team_payroll
    FROM chart_of_accounts WHERE agency_id = v_agency AND account_code = 'COA-SUB-078';
  SELECT id INTO v_old_team_child
    FROM chart_of_accounts WHERE agency_id = v_agency AND account_code = 'COA-SUB-087';

  UPDATE journal_lines SET account_id = v_team_payroll WHERE account_id = v_old_team_child;
  GET DIAGNOSTICS v_reclass_count = ROW_COUNT;
  RAISE NOTICE 'Reclassified % journal_lines from COA-SUB-087 to COA-SUB-078', v_reclass_count;

  DELETE FROM chart_of_accounts WHERE id = v_old_team_child;

  INSERT INTO chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, parent_account_id)
  VALUES (v_agency, v_ent, 'COA-SUB-089', '7030a Dues & Licenses - Growth', 'expense', v_growth_parent)
  RETURNING id INTO v_growth_licenses;

  UPDATE prior_year_pl SET section = '0003 TEAM'
    WHERE agency_id = v_agency AND business_entity_id = v_ent AND section = '0002 TEAM';
  UPDATE prior_year_pl SET section = '0004 MARKETING'
    WHERE agency_id = v_agency AND business_entity_id = v_ent AND section = '0003 MARKETING';
  UPDATE prior_year_pl SET section = '0005 DISCRETIONARY'
    WHERE agency_id = v_agency AND business_entity_id = v_ent AND section = '0004 DISCRETIONARY';
  UPDATE prior_year_pl SET section = '0006 PERSONAL'
    WHERE agency_id = v_agency AND business_entity_id = v_ent AND section = '0005 PERSONAL';

  SELECT COALESCE(SUM(amount), 0) INTO v_check_before
    FROM prior_year_pl
    WHERE agency_id = v_agency AND business_entity_id = v_ent
      AND period_year = 2026 AND period_month BETWEEN 1 AND 6
      AND account_name = '6005 Payroll Costs';

  DELETE FROM prior_year_pl
    WHERE agency_id = v_agency AND business_entity_id = v_ent
      AND period_year = 2026 AND period_month BETWEEN 1 AND 6
      AND account_name = '6005 Payroll Costs';

  WITH per_person AS (
    SELECT
      pr.id AS run_id,
      pr.pay_date,
      EXTRACT(YEAR FROM pr.pay_date)::int AS yy,
      EXTRACT(MONTH FROM pr.pay_date)::int AS mm,
      pd.team_member_id,
      pd.gross_pay,
      COALESCE(pd.employer_taxes, 0) AS er_taxes,
      COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'PTO'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'OT'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'- O/TIME'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'1Health'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'5Goals'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'LIFE *'->>'period')::numeric, 0)
        AS fixed_pay,
      COALESCE((pd.raw_earnings->'items'->'BONUS'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'COMMISSION'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'OTHER'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'0Advnce'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'2Serve'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'3True'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'4Manage'->>'period')::numeric, 0)
        AS variable_pay,
      COALESCE((pd.raw_earnings->'items'->'REIMBURSEMENTS'->>'period')::numeric, 0)
        + COALESCE((pd.raw_earnings->'items'->'REIMB.'->>'period')::numeric, 0)
        AS reimb,
      t.start_date,
      CASE
        WHEN t.start_date IS NULL THEN 0::numeric
        ELSE 1.0 - LEAST(1.0, GREATEST(0::numeric,
          FLOOR((pr.pay_period_end - t.start_date) / 7.0)::int / 52.0))
      END AS ramp
    FROM payroll_runs pr
    JOIN payroll_detail pd ON pd.payroll_run_id = pr.id
    JOIN team t ON t.id = pd.team_member_id
    WHERE pr.agency_id = v_agency
      AND pr.pay_period_end >= '2026-01-01' AND pr.pay_period_end < '2026-07-01'
      AND t.role_level IS DISTINCT FROM 'Owner'
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND t.business_entity_id = v_ent
  ),
  split AS (
    SELECT
      yy, mm,
      ROUND(SUM(fixed_pay * ramp), 2) AS growth_share,
      ROUND(SUM(
        fixed_pay * (1.0 - ramp)
        + variable_pay
        + GREATEST(0, gross_pay - fixed_pay - variable_pay - reimb)
        + er_taxes
      ), 2) AS team_share
    FROM per_person
    GROUP BY yy, mm
  )
  INSERT INTO prior_year_pl (
    agency_id, business_entity_id,
    period_year, period_month, is_partial_period,
    section, section_type, account_name, amount, source_entity, imported_at
  )
  SELECT
    v_agency, v_ent, s.yy, s.mm, false,
    '0002 GROWTH', 'Expense', '6005a Payroll Costs - Growth',
    s.growth_share, 'Peter Story State Farm', NOW()
  FROM split s
  WHERE s.growth_share > 0
  UNION ALL
  SELECT
    v_agency, v_ent, s.yy, s.mm, false,
    '0003 TEAM', 'Expense', '6005 Payroll Costs',
    s.team_share, 'Peter Story State Farm', NOW()
  FROM split s
  WHERE s.team_share > 0;

  INSERT INTO prior_year_pl (
    agency_id, business_entity_id,
    period_year, period_month, is_partial_period,
    section, section_type, account_name, amount, source_entity, imported_at
  )
  VALUES (
    v_agency, v_ent, 2026, 6, false,
    '0002 GROWTH', 'Expense', '7030a Dues & Licenses - Growth',
    390.26, 'Peter Story State Farm', NOW()
  );

  SELECT COALESCE(SUM(amount), 0) INTO v_check_after_growth
    FROM prior_year_pl
    WHERE agency_id = v_agency AND business_entity_id = v_ent
      AND period_year = 2026 AND period_month BETWEEN 1 AND 6
      AND account_name = '6005a Payroll Costs - Growth';

  SELECT COALESCE(SUM(amount), 0) INTO v_check_after_team
    FROM prior_year_pl
    WHERE agency_id = v_agency AND business_entity_id = v_ent
      AND period_year = 2026 AND period_month BETWEEN 1 AND 6
      AND account_name = '6005 Payroll Costs';

  SELECT COALESCE(SUM(amount), 0) INTO v_check_after_reimb
    FROM prior_year_pl
    WHERE agency_id = v_agency AND business_entity_id = v_ent
      AND period_year = 2026 AND period_month BETWEEN 1 AND 6
      AND account_name = '7030a Dues & Licenses - Growth';

  v_check_after_total := v_check_after_growth + v_check_after_team + v_check_after_reimb;

  IF ABS(v_check_after_total - v_check_before) > 0.10 THEN
    RAISE EXCEPTION 'Reconciliation FAILED: Growth+Team+Reimb=% vs Before=%',
      v_check_after_total, v_check_before;
  END IF;
END $mig$;
