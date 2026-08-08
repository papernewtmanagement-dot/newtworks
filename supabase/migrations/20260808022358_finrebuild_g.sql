CREATE OR REPLACE FUNCTION public.payroll_gl_writer(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_dry_run boolean DEFAULT false, p_only_pay_period_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cutover_date date;
  v_papernewt_entity uuid := 'b1111111-1111-1111-1111-111111111111';
  v_agency_entity uuid := 'b2222222-2222-2222-2222-222222222222';
  v_wages_acct uuid;
  v_er_tax_acct uuid;
  v_reimb_pending_acct uuid;
  v_intercompany_acct uuid;
  v_pn_expense_acct uuid;
  v_pn_cash_acct uuid;
  v_pn_ic_asset_acct uuid;
  v_run_id uuid;
  v_pay_date date;
  v_pay_period_start date;
  v_pay_period_end date;
  v_provider text;
  v_posted_at timestamptz;
  v_already_posted boolean;
  v_wages_growth_total numeric;
  v_wages_team_total numeric;
  v_er_growth_total numeric;
  v_er_team_total numeric;
  v_reimb_total numeric;
  v_pn_total numeric;
  v_ic_credit numeric;
  v_desc text;
  v_person_lines jsonb;
  v_line_id uuid;
  v_pd_id uuid;
  v_tm_id uuid;
  v_tm_first text;
  v_tm_last text;
  v_tm_entity uuid;
  v_tm_start date;
  v_tm_role_level text;
  v_tm_admin_bo boolean;
  v_gross numeric;
  v_er_taxes numeric;
  v_earnings jsonb;
  v_items jsonb;
  v_salary numeric;
  v_hourly numeric;
  v_ot numeric;
  v_bonus numeric;
  v_commission numeric;
  v_other numeric;
  v_reimb numeric;
  v_fixed numeric;
  v_variable numeric;
  v_recognized numeric;
  v_gap numeric;
  v_weeks_in int;
  v_ramp numeric;
  v_wages_growth numeric;
  v_wages_team numeric;
  v_wages_person_total numeric;
  v_er_growth numeric;
  v_er_team numeric;
  v_route_papernewt boolean;
  v_route_reason text;
  v_key text;
  v_val numeric;
  v_count_elig int := 0;
  v_count_skip_cutover int := 0;
  v_count_skip_have_je int := 0;
  v_count_posted int := 0;
  v_count_err int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_runs_out jsonb := '[]'::jsonb;
  v_agency_ref text; v_pn_ref text; v_pn_ic_ref text;
  v_wrote_agency boolean; v_wrote_pn boolean; v_wrote_pn_ic boolean;
BEGIN
  SELECT setting_value::date INTO v_cutover_date
    FROM settings WHERE agency_id=p_agency_id AND setting_key='gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '1900-01-01'::date; END IF;

  SELECT id INTO v_wages_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='6010'
      AND business_entity_id=v_agency_entity AND is_active=true;
  SELECT id INTO v_er_tax_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='6030'
      AND business_entity_id=v_agency_entity AND is_active=true;
  SELECT id INTO v_reimb_pending_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='0003'
      AND business_entity_id=v_agency_entity AND is_active=true;
  SELECT id INTO v_intercompany_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='2902'
      AND business_entity_id=v_agency_entity AND is_active=true;
  SELECT id INTO v_pn_expense_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='6020'
      AND business_entity_id=v_papernewt_entity AND is_active=true;
  SELECT id INTO v_pn_cash_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='1050'
      AND business_entity_id=v_papernewt_entity AND is_active=true;
  SELECT id INTO v_pn_ic_asset_acct FROM chart_of_accounts
    WHERE agency_id=p_agency_id AND account_code='1901'
      AND business_entity_id=v_papernewt_entity AND is_active=true;

  IF v_wages_acct IS NULL OR v_er_tax_acct IS NULL OR v_reimb_pending_acct IS NULL
     OR v_intercompany_acct IS NULL OR v_pn_expense_acct IS NULL OR v_pn_cash_acct IS NULL
     OR v_pn_ic_asset_acct IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'coa_lookup_failed',
      'wages', v_wages_acct, 'er_tax', v_er_tax_acct, 'reimb_pending', v_reimb_pending_acct,
      'ic', v_intercompany_acct, 'pn_exp', v_pn_expense_acct, 'pn_cash', v_pn_cash_acct,
      'pn_ic_asset', v_pn_ic_asset_acct);
  END IF;

  FOR v_run_id, v_pay_date, v_pay_period_start, v_pay_period_end,
      v_provider, v_posted_at IN
    SELECT id, pay_date, pay_period_start, pay_period_end,
           payroll_provider, posted_at
    FROM payroll_runs
    WHERE agency_id=p_agency_id
      AND (p_only_pay_period_end IS NULL OR pay_period_end=p_only_pay_period_end)
    ORDER BY pay_date
  LOOP
    v_count_elig := v_count_elig + 1;

    IF v_pay_date < v_cutover_date THEN
      v_count_skip_cutover := v_count_skip_cutover + 1;
      IF NOT p_dry_run AND v_posted_at IS NULL THEN
        UPDATE payroll_runs
        SET posted_at=NOW(),
            notes=COALESCE(notes,'') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id=v_run_id;
      END IF;
      CONTINUE;
    END IF;

    SELECT EXISTS(SELECT 1 FROM ledger WHERE payroll_run_id = v_run_id) INTO v_already_posted;
    IF v_already_posted THEN
      v_count_skip_have_je := v_count_skip_have_je + 1;
      CONTINUE;
    END IF;

    v_wages_growth_total := 0;
    v_wages_team_total := 0;
    v_er_growth_total := 0;
    v_er_team_total := 0;
    v_reimb_total := 0;
    v_pn_total := 0;
    v_person_lines := '[]'::jsonb;
    v_wrote_agency := false; v_wrote_pn := false; v_wrote_pn_ic := false;

    v_desc := 'Payroll run ' || v_pay_period_start || ' to ' || v_pay_period_end ||
              ' (check ' || v_pay_date || ') — ' || COALESCE(v_provider, 'Payroll');
    v_agency_ref := 'PAYROLL-' || v_run_id::text || '-AGENCY';
    v_pn_ref := 'PAYROLL-' || v_run_id::text || '-PAPERNEWT';
    v_pn_ic_ref := 'PAYROLL-' || v_run_id::text || '-PAPERNEWT-IC-RECON';

    FOR v_pd_id, v_tm_id, v_gross, v_er_taxes, v_earnings IN
      SELECT id, team_member_id, gross_pay, employer_taxes, raw_earnings
      FROM payroll_detail
      WHERE payroll_run_id=v_run_id
    LOOP
      IF v_tm_id IS NULL THEN
        v_count_err := v_count_err + 1;
        v_errors := v_errors || jsonb_build_object('run_id', v_run_id, 'pd_id', v_pd_id, 'reason', 'null_team_member');
        CONTINUE;
      END IF;

      SELECT first_name, last_name, business_entity_id, start_date, role_level, is_admin_backoffice
        INTO v_tm_first, v_tm_last, v_tm_entity, v_tm_start, v_tm_role_level, v_tm_admin_bo
        FROM team WHERE id=v_tm_id;

      v_items := COALESCE(v_earnings->'items', '{}'::jsonb);
      v_salary := 0; v_hourly := 0; v_ot := 0; v_bonus := 0;
      v_commission := 0; v_other := 0; v_reimb := 0;

      FOR v_key IN SELECT jsonb_object_keys(v_items) LOOP
        v_val := COALESCE((v_items->v_key->>'period')::numeric, 0);
        IF v_val = 0 THEN CONTINUE; END IF;
        CASE v_key
          WHEN 'SALARY' THEN v_salary := v_salary + v_val;
          WHEN 'HOURLY' THEN v_hourly := v_hourly + v_val;
          WHEN 'REGULAR' THEN v_hourly := v_hourly + v_val;
          WHEN 'PTO' THEN v_hourly := v_hourly + v_val;
          WHEN 'OT' THEN v_ot := v_ot + v_val;
          WHEN '- O/TIME' THEN v_ot := v_ot + v_val;
          WHEN '1Health' THEN v_hourly := v_hourly + v_val;
          WHEN '5Goals' THEN v_hourly := v_hourly + v_val;
          WHEN 'LIFE *' THEN v_hourly := v_hourly + v_val;
          WHEN 'BONUS' THEN v_bonus := v_bonus + v_val;
          WHEN 'COMMISSION' THEN v_commission := v_commission + v_val;
          WHEN 'OTHER' THEN v_other := v_other + v_val;
          WHEN '0Advnce' THEN v_other := v_other + v_val;
          WHEN '2Serve' THEN v_other := v_other + v_val;
          WHEN '3True' THEN v_other := v_other + v_val;
          WHEN '4Manage' THEN v_other := v_other + v_val;
          WHEN 'REIMBURSEMENTS' THEN v_reimb := v_reimb + v_val;
          WHEN 'REIMB.' THEN v_reimb := v_reimb + v_val;
          WHEN 'blank3' THEN NULL;
          ELSE NULL;
        END CASE;
      END LOOP;

      v_route_papernewt := (v_tm_role_level = 'Owner')
                        OR (v_tm_admin_bo = true)
                        OR (v_tm_entity = v_papernewt_entity);
      v_route_reason := CASE
        WHEN v_tm_role_level = 'Owner' THEN 'role_level=Owner'
        WHEN v_tm_admin_bo = true THEN 'is_admin_backoffice=true'
        WHEN v_tm_entity = v_papernewt_entity THEN 'team.business_entity_id=PaperNewt'
        ELSE 'agency_split'
      END;

      IF v_route_papernewt THEN
        v_pn_total := v_pn_total + v_gross + COALESCE(v_er_taxes, 0);
        v_person_lines := v_person_lines || jsonb_build_object(
          'name', v_tm_first || ' ' || v_tm_last,
          'route', 'papernewt_direct',
          'reason', v_route_reason,
          'gross_pay', v_gross,
          'employer_taxes', v_er_taxes,
          'pn_expense', v_gross + COALESCE(v_er_taxes, 0)
        );
      ELSE
        v_fixed := v_salary + v_hourly + v_ot;
        v_variable := v_bonus + v_commission + v_other;
        v_recognized := v_fixed + v_variable + v_reimb;
        v_gap := GREATEST(0, v_gross - v_recognized);

        IF v_tm_start IS NULL THEN
          v_ramp := 0;
          v_weeks_in := NULL;
        ELSE
          v_weeks_in := GREATEST(0, FLOOR((v_pay_period_end - v_tm_start) / 7.0)::int);
          v_ramp := 1.0 - LEAST(1.0, GREATEST(0::numeric, v_weeks_in / 52.0));
        END IF;

        v_wages_growth := ROUND(v_fixed * v_ramp, 2);
        v_wages_team := ROUND((v_fixed - v_wages_growth) + v_variable + v_gap, 2);
        v_wages_person_total := v_wages_growth + v_wages_team;

        IF v_wages_person_total > 0 AND COALESCE(v_er_taxes, 0) > 0 THEN
          v_er_growth := ROUND(COALESCE(v_er_taxes, 0) * v_wages_growth / v_wages_person_total, 2);
          v_er_team := ROUND(COALESCE(v_er_taxes, 0) - v_er_growth, 2);
        ELSE
          v_er_growth := 0;
          v_er_team := COALESCE(v_er_taxes, 0);
        END IF;

        v_wages_growth_total := v_wages_growth_total + v_wages_growth;
        v_wages_team_total := v_wages_team_total + v_wages_team;
        v_er_growth_total := v_er_growth_total + v_er_growth;
        v_er_team_total := v_er_team_total + v_er_team;
        v_reimb_total := v_reimb_total + v_reimb;

        v_person_lines := v_person_lines || jsonb_build_object(
          'name', v_tm_first || ' ' || v_tm_last,
          'route', 'agency_split',
          'start_date', v_tm_start,
          'weeks_in', v_weeks_in,
          'ramp_frac', ROUND(v_ramp, 4),
          'fixed_bundle', v_fixed,
          'variable', v_variable,
          'unrecognized_gap', v_gap,
          'employer_taxes', v_er_taxes,
          'reimb', v_reimb,
          'wages_growth', v_wages_growth,
          'wages_team', v_wages_team,
          'er_growth', v_er_growth,
          'er_team', v_er_team
        );
      END IF;
    END LOOP;

    v_ic_credit := v_wages_growth_total + v_wages_team_total
                 + v_er_growth_total + v_er_team_total
                 + v_reimb_total;

    IF p_dry_run THEN
      v_runs_out := v_runs_out || jsonb_build_object(
        'run_id', v_run_id,
        'pay_period_end', v_pay_period_end,
        'pay_date', v_pay_date,
        'agency_wages_growth', v_wages_growth_total,
        'agency_wages_team', v_wages_team_total,
        'agency_er_growth', v_er_growth_total,
        'agency_er_team', v_er_team_total,
        'agency_reimb', v_reimb_total,
        'agency_intercompany_credit', v_ic_credit,
        'papernewt_expense_and_cash', v_pn_total,
        'papernewt_ic_recon_amount', v_ic_credit,
        'people', v_person_lines
      );
      v_count_posted := v_count_posted + 1;
      CONTINUE;
    END IF;

    IF v_ic_credit > 0 THEN
      v_wrote_agency := true;

      IF v_wages_growth_total > 0 THEN
        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
          source, reference_number, payroll_run_id, entry_type)
        VALUES (p_agency_id, v_pay_date, v_wages_acct, v_wages_growth_total, 0,
                'Growth Budget share of team fixed pay — ' || v_desc,
                'payroll_gl_writer', v_agency_ref, v_run_id, 'payroll')
        RETURNING id INTO v_line_id;
        INSERT INTO transaction_tags (agency_id, journal_line_id, tag_key, tag_value, created_by)
        VALUES (p_agency_id, v_line_id, 'budget_category', 'growth', 'payroll_gl_writer');
      END IF;

      IF v_wages_team_total > 0 THEN
        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
          source, reference_number, payroll_run_id, entry_type)
        VALUES (p_agency_id, v_pay_date, v_wages_acct, v_wages_team_total, 0,
                'Team Budget: post-ramp fixed pay + bonus/commission/other + unclassified legacy items — ' || v_desc,
                'payroll_gl_writer', v_agency_ref, v_run_id, 'payroll')
        RETURNING id INTO v_line_id;
        INSERT INTO transaction_tags (agency_id, journal_line_id, tag_key, tag_value, created_by)
        VALUES (p_agency_id, v_line_id, 'budget_category', 'team', 'payroll_gl_writer');
      END IF;

      IF v_er_growth_total > 0 THEN
        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
          source, reference_number, payroll_run_id, entry_type)
        VALUES (p_agency_id, v_pay_date, v_er_tax_acct, v_er_growth_total, 0,
                'Employer payroll taxes — growth bucket (pro-rata to growth wages) — ' || v_desc,
                'payroll_gl_writer', v_agency_ref, v_run_id, 'payroll')
        RETURNING id INTO v_line_id;
        INSERT INTO transaction_tags (agency_id, journal_line_id, tag_key, tag_value, created_by)
        VALUES (p_agency_id, v_line_id, 'budget_category', 'growth', 'payroll_gl_writer');
      END IF;

      IF v_er_team_total > 0 THEN
        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
          source, reference_number, payroll_run_id, entry_type)
        VALUES (p_agency_id, v_pay_date, v_er_tax_acct, v_er_team_total, 0,
                'Employer payroll taxes — team bucket (pro-rata to team wages) — ' || v_desc,
                'payroll_gl_writer', v_agency_ref, v_run_id, 'payroll')
        RETURNING id INTO v_line_id;
        INSERT INTO transaction_tags (agency_id, journal_line_id, tag_key, tag_value, created_by)
        VALUES (p_agency_id, v_line_id, 'budget_category', 'team', 'payroll_gl_writer');
      END IF;

      IF v_reimb_total > 0 THEN
        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
          source, reference_number, payroll_run_id, entry_type)
        VALUES (p_agency_id, v_pay_date, v_reimb_pending_acct, v_reimb_total, 0,
                'Reimbursements (pending categorization — walk into real bucket at year-end) — ' || v_desc,
                'payroll_gl_writer', v_agency_ref, v_run_id, 'payroll');
      END IF;

      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, payroll_run_id, entry_type)
      VALUES (p_agency_id, v_pay_date, v_intercompany_acct, 0, v_ic_credit,
              'Owed to PaperNewt LLC — team pay for ' || v_pay_period_start || ' to ' || v_pay_period_end,
              'payroll_gl_writer', v_agency_ref, v_run_id, 'payroll');
    END IF;

    IF v_pn_total > 0 THEN
      v_wrote_pn := true;
      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, payroll_run_id, entry_type)
      VALUES (p_agency_id, v_pay_date, v_pn_expense_acct, v_pn_total, 0,
              'PaperNewt payroll expense (owner/officer/PN-direct W-2 wages + ER taxes) — ' || v_desc,
              'payroll_gl_writer', v_pn_ref, v_run_id, 'payroll');
      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, payroll_run_id, entry_type)
      VALUES (p_agency_id, v_pay_date, v_pn_cash_acct, 0, v_pn_total,
              'PaperNewt cash paid (owner/officer/PN-direct) — ' || v_desc,
              'payroll_gl_writer', v_pn_ref, v_run_id, 'payroll');
    END IF;

    IF v_ic_credit > 0 THEN
      v_wrote_pn_ic := true;
      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, payroll_run_id, entry_type)
      VALUES (p_agency_id, v_pay_date, v_pn_ic_asset_acct, v_ic_credit, 0,
              'Due from Story Agency — agency-side team pay ' || v_pay_period_start || ' to ' || v_pay_period_end,
              'payroll_gl_writer', v_pn_ic_ref, v_run_id, 'payroll');
      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, payroll_run_id, entry_type)
      VALUES (p_agency_id, v_pay_date, v_pn_cash_acct, 0, v_ic_credit,
              'PaperNewt cash paid out for agency-side team pay ' || v_pay_period_start || ' to ' || v_pay_period_end,
              'payroll_gl_writer', v_pn_ic_ref, v_run_id, 'payroll');
    END IF;

    UPDATE payroll_runs
    SET posted_at=NOW(),
        notes=COALESCE(notes,'') || ' [posted by payroll_gl_writer er_split ' || NOW()::text ||
              CASE WHEN v_wrote_pn THEN '; pn_ref=' || v_pn_ref ELSE '' END ||
              CASE WHEN v_wrote_pn_ic THEN '; pn_ic_ref=' || v_pn_ic_ref ELSE '' END || ']'
    WHERE id=v_run_id;

    v_count_posted := v_count_posted + 1;
    v_runs_out := v_runs_out || jsonb_build_object(
      'run_id', v_run_id,
      'agency_ref', CASE WHEN v_wrote_agency THEN v_agency_ref ELSE NULL END,
      'papernewt_ref', CASE WHEN v_wrote_pn THEN v_pn_ref ELSE NULL END,
      'papernewt_ic_recon_ref', CASE WHEN v_wrote_pn_ic THEN v_pn_ic_ref ELSE NULL END,
      'agency_intercompany_credit', v_ic_credit,
      'papernewt_total', v_pn_total,
      'papernewt_ic_recon_amount', v_ic_credit
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'cutover_date', v_cutover_date,
    'filter_pay_period_end', p_only_pay_period_end,
    'eligible', v_count_elig,
    'skipped_pre_cutover', v_count_skip_cutover,
    'skipped_already_has_je', v_count_skip_have_je,
    'posted', v_count_posted,
    'errors', v_count_err,
    'error_details', v_errors,
    'runs', v_runs_out
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.payroll_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.payroll_gl_writer(p_agency_id, FALSE, NULL::date);
END;
$function$;