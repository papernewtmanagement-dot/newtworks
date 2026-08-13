-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 01:25:49 UTC (ledger name: plan_a_payroll_gl_dryrun_v2_owner_routing) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718012549.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Fix: route role_level='Owner' to PaperNewt direct too (Peter Story, not just Leslie)
CREATE OR REPLACE FUNCTION public.payroll_gl_writer_plan_a_dryrun(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_pay_period_end date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency_entity  uuid := 'b2222222-2222-2222-2222-222222222222'::uuid;
  v_papernewt_entity uuid := 'b1111111-1111-1111-1111-111111111111'::uuid;
  v_run_id uuid;
  v_period_start date;
  v_period_end date;
  v_pay_date date;
  v_lines_agency jsonb := '[]'::jsonb;
  v_lines_papernewt jsonb := '[]'::jsonb;
  v_dr_agency numeric := 0;
  v_cr_agency numeric := 0;
  v_dr_papernewt numeric := 0;
  v_cr_papernewt numeric := 0;
  v_per_person jsonb := '[]'::jsonb;
  r record;
  v_items jsonb;
  v_salary numeric; v_hourly numeric; v_ot numeric; v_bonus numeric;
  v_commission numeric; v_other numeric; v_reimb numeric;
  v_fixed_loaded numeric;
  v_variable_team numeric;
  v_er_taxes numeric;
  v_weeks_since_start numeric;
  v_growth_pct numeric;
  v_growth_amt numeric;
  v_team_amt numeric;
  v_total_gross numeric;
  v_is_papernewt_person boolean;
BEGIN
  IF p_pay_period_end IS NULL THEN
    SELECT id, pay_period_start, pay_period_end, pay_date
      INTO v_run_id, v_period_start, v_period_end, v_pay_date
    FROM payroll_runs WHERE agency_id = p_agency_id
    ORDER BY pay_period_end DESC LIMIT 1;
  ELSE
    SELECT id, pay_period_start, pay_period_end, pay_date
      INTO v_run_id, v_period_start, v_period_end, v_pay_date
    FROM payroll_runs WHERE agency_id = p_agency_id AND pay_period_end = p_pay_period_end
    LIMIT 1;
  END IF;

  IF v_run_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_run_found');
  END IF;

  FOR r IN
    SELECT pd.gross_pay, pd.employer_taxes, pd.raw_earnings,
           t.first_name, t.last_name, t.start_date,
           t.business_entity_id AS employee_entity,
           t.role_level, t.is_admin_backoffice
    FROM payroll_detail pd
    LEFT JOIN team t ON t.id = pd.team_member_id
    WHERE pd.payroll_run_id = v_run_id
    ORDER BY pd.gross_pay DESC
  LOOP
    v_items := COALESCE(r.raw_earnings->'items', '{}'::jsonb);
    v_salary     := COALESCE((v_items->'SALARY'->>'period')::numeric, 0);
    v_hourly     := COALESCE((v_items->'HOURLY'->>'period')::numeric, 0);
    v_ot         := COALESCE((v_items->'OT'->>'period')::numeric, 0);
    v_bonus      := COALESCE((v_items->'BONUS'->>'period')::numeric, 0);
    v_commission := COALESCE((v_items->'COMMISSION'->>'period')::numeric, 0);
    v_other      := COALESCE((v_items->'OTHER'->>'period')::numeric, 0);
    v_reimb      := COALESCE((v_items->'REIMBURSEMENTS'->>'period')::numeric, 0);
    v_er_taxes   := COALESCE(r.employer_taxes, 0);
    v_fixed_loaded   := v_salary + v_hourly + v_ot + v_bonus;
    v_variable_team  := v_commission + v_other;
    v_total_gross    := v_fixed_loaded + v_variable_team + v_reimb;

    -- Routing rule: PaperNewt direct if Owner OR admin_backoffice OR employee_entity is PaperNewt
    v_is_papernewt_person := (r.role_level = 'Owner')
                          OR (r.is_admin_backoffice = true)
                          OR (r.employee_entity = v_papernewt_entity);

    IF r.start_date IS NOT NULL THEN
      v_weeks_since_start := floor((v_period_end - r.start_date)::numeric / 7.0);
      v_growth_pct := 1.0 - LEAST(1.0, GREATEST(0::numeric, v_weeks_since_start / 52.0));
    ELSE
      v_growth_pct := 0;
    END IF;

    IF v_is_papernewt_person THEN
      v_lines_papernewt := v_lines_papernewt || jsonb_build_object(
        'person', r.first_name || ' ' || r.last_name,
        'DR_account', 'Owner/Officer Payroll Expense (PaperNewt)',
        'DR_amount', v_total_gross + v_er_taxes,
        'CR_account', 'PaperNewt Payroll Cash (placeholder)',
        'CR_amount', v_total_gross + v_er_taxes,
        'note', 'direct PaperNewt expense, no agency involvement'
      );
      v_dr_papernewt := v_dr_papernewt + (v_total_gross + v_er_taxes);
      v_cr_papernewt := v_cr_papernewt + (v_total_gross + v_er_taxes);

      v_per_person := v_per_person || jsonb_build_object(
        'person', r.first_name || ' ' || r.last_name,
        'routing', 'papernewt_direct',
        'reason', CASE WHEN r.role_level='Owner' THEN 'role_level=Owner'
                       WHEN r.is_admin_backoffice=true THEN 'is_admin_backoffice=true'
                       ELSE 'employee_entity=PaperNewt' END,
        'gross', v_total_gross, 'er_taxes', v_er_taxes
      );
    ELSE
      v_growth_amt := round(v_fixed_loaded * v_growth_pct, 2);
      v_team_amt   := round(v_fixed_loaded - v_growth_amt, 2) + v_variable_team;

      IF v_growth_amt > 0 THEN
        v_lines_agency := v_lines_agency || jsonb_build_object(
          'person', r.first_name || ' ' || r.last_name,
          'DR_account', 'Payroll — Growth Budget', 'DR_amount', v_growth_amt,
          'note', 'growth_pct=' || round(v_growth_pct * 100, 1) || '% × fixed-loaded $' || v_fixed_loaded
        );
        v_dr_agency := v_dr_agency + v_growth_amt;
      END IF;
      IF v_team_amt > 0 THEN
        v_lines_agency := v_lines_agency || jsonb_build_object(
          'person', r.first_name || ' ' || r.last_name,
          'DR_account', 'Payroll — Team Budget', 'DR_amount', v_team_amt,
          'note', 'team_pct + commission + other'
        );
        v_dr_agency := v_dr_agency + v_team_amt;
      END IF;
      IF v_reimb > 0 THEN
        v_lines_agency := v_lines_agency || jsonb_build_object(
          'person', r.first_name || ' ' || r.last_name,
          'DR_account', 'Reimbursements — Pending Categorization', 'DR_amount', v_reimb,
          'note', 'awaiting Peter categorization'
        );
        v_dr_agency := v_dr_agency + v_reimb;
      END IF;
      IF v_er_taxes > 0 THEN
        v_lines_agency := v_lines_agency || jsonb_build_object(
          'person', r.first_name || ' ' || r.last_name,
          'DR_account', 'Payroll — Team Budget', 'DR_amount', v_er_taxes,
          'note', 'employer taxes'
        );
        v_dr_agency := v_dr_agency + v_er_taxes;
      END IF;

      v_per_person := v_per_person || jsonb_build_object(
        'person', r.first_name || ' ' || r.last_name,
        'routing', 'agency_split',
        'gross', v_total_gross, 'er_taxes', v_er_taxes,
        'fixed_loaded', v_fixed_loaded,
        'growth_pct', round(v_growth_pct * 100, 1),
        'growth_dollars', v_growth_amt, 'team_dollars', v_team_amt
      );
    END IF;
  END LOOP;

  IF v_dr_agency > 0 THEN
    v_lines_agency := v_lines_agency || jsonb_build_object(
      'person', '(intercompany)',
      'CR_account', 'Due to PaperNewt LLC (intercompany)',
      'CR_amount', v_dr_agency,
      'note', 'assumed cash transfer already made by PaperNewt'
    );
    v_cr_agency := v_dr_agency;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'run_id', v_run_id,
    'pay_period', v_period_start || ' to ' || v_period_end, 'pay_date', v_pay_date,
    'per_person', v_per_person,
    'agency_JE', jsonb_build_object(
      'entity', 'Peter Story State Farm (b2222222)',
      'lines', v_lines_agency,
      'total_DR', v_dr_agency, 'total_CR', v_cr_agency,
      'balanced', v_dr_agency = v_cr_agency),
    'papernewt_JE', jsonb_build_object(
      'entity', 'PaperNewt LLC (b1111111)',
      'lines', v_lines_papernewt,
      'total_DR', v_dr_papernewt, 'total_CR', v_cr_papernewt,
      'balanced', v_dr_papernewt = v_cr_papernewt)
  );
END;
$$;

SELECT jsonb_pretty(public.payroll_gl_writer_plan_a_dryrun(
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  '2026-07-11'::date
)) AS dryrun_output;
