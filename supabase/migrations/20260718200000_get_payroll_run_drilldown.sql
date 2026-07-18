-- Migration: get_payroll_run_drilldown RPC
-- Read-only mirror of payroll_gl_writer classification, for the Financials Payroll tab drill-in.
-- Returns per-person routing (papernewt_direct vs agency_split), Growth/Team split
-- when agency-split, and the three live (non-VOIDED) JE reference_numbers per run.

CREATE OR REPLACE FUNCTION public.get_payroll_run_drilldown(p_run_id uuid)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY INVOKER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_papernewt_entity uuid := 'b1111111-1111-1111-1111-111111111111';
  v_agency_id uuid;
  v_pay_period_start date;
  v_pay_period_end date;
  v_pay_date date;
  v_gross numeric;
  v_er_taxes numeric;
  v_net numeric;
  v_provider text;
  v_status text;
  v_run_entity uuid;
  v_run_je uuid;

  v_pd_id uuid;
  v_tm_id uuid;
  v_tm_first text;
  v_tm_last text;
  v_tm_entity uuid;
  v_tm_entity_name text;
  v_tm_start date;
  v_tm_role_level text;
  v_tm_admin_bo boolean;
  v_p_gross numeric;
  v_p_er_taxes numeric;
  v_p_net numeric;
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
  v_grow_share numeric;
  v_team_share numeric;
  v_route_papernewt boolean;
  v_route_reason text;
  v_key text;
  v_val numeric;

  v_people jsonb := '[]'::jsonb;
  v_jes jsonb := '[]'::jsonb;
BEGIN
  SELECT agency_id, pay_period_start, pay_period_end, pay_date,
         gross_payroll, employer_taxes, net_payroll, payroll_provider, status,
         business_entity_id, journal_entry_id
    INTO v_agency_id, v_pay_period_start, v_pay_period_end, v_pay_date,
         v_gross, v_er_taxes, v_net, v_provider, v_status, v_run_entity, v_run_je
    FROM payroll_runs
   WHERE id = p_run_id;

  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'run_not_found', 'run_id', p_run_id);
  END IF;

  -- Per-person breakdown (mirrors payroll_gl_writer key classification exactly)
  FOR v_pd_id, v_tm_id, v_p_gross, v_p_er_taxes, v_p_net, v_earnings IN
    SELECT id, team_member_id, gross_pay, employer_taxes, net_pay, raw_earnings
      FROM payroll_detail
     WHERE payroll_run_id = p_run_id
     ORDER BY team_member_id
  LOOP
    IF v_tm_id IS NULL THEN
      CONTINUE;
    END IF;

    SELECT first_name, last_name, business_entity_id, start_date, role_level, is_admin_backoffice
      INTO v_tm_first, v_tm_last, v_tm_entity, v_tm_start, v_tm_role_level, v_tm_admin_bo
      FROM team WHERE id = v_tm_id;

    SELECT name INTO v_tm_entity_name
      FROM business_entities WHERE id = v_tm_entity;

    v_items := COALESCE(v_earnings->'items', '{}'::jsonb);
    v_salary := 0; v_hourly := 0; v_ot := 0; v_bonus := 0;
    v_commission := 0; v_other := 0; v_reimb := 0;

    -- Same CASE dispatcher as payroll_gl_writer. Keep in sync if writer changes.
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
      WHEN v_tm_entity = v_papernewt_entity THEN 'business_entity_id=PaperNewt'
      ELSE 'agency_split'
    END;

    IF v_route_papernewt THEN
      v_people := v_people || jsonb_build_object(
        'team_member_id', v_tm_id,
        'name', COALESCE(v_tm_first || ' ' || v_tm_last, '(unknown)'),
        'role_level', v_tm_role_level,
        'is_admin_backoffice', v_tm_admin_bo,
        'team_entity_id', v_tm_entity,
        'team_entity_name', v_tm_entity_name,
        'route', 'papernewt_direct',
        'reason', v_route_reason,
        'gross_pay', v_p_gross,
        'employer_taxes', v_p_er_taxes,
        'net_pay', v_p_net,
        'pn_expense', v_p_gross + COALESCE(v_p_er_taxes, 0)
      );
    ELSE
      v_fixed := v_salary + v_hourly + v_ot;
      v_variable := v_bonus + v_commission + v_other;
      v_recognized := v_fixed + v_variable + v_reimb;
      v_gap := GREATEST(0, v_p_gross - v_recognized);

      IF v_tm_start IS NULL THEN
        v_ramp := 0;
        v_weeks_in := NULL;
      ELSE
        v_weeks_in := GREATEST(0, FLOOR((v_pay_period_end - v_tm_start) / 7.0)::int);
        v_ramp := 1.0 - LEAST(1.0, GREATEST(0::numeric, v_weeks_in / 52.0));
      END IF;
      v_grow_share := ROUND(v_fixed * v_ramp, 2);
      v_team_share := ROUND((v_fixed - v_grow_share) + v_variable + v_gap + COALESCE(v_p_er_taxes, 0), 2);

      v_people := v_people || jsonb_build_object(
        'team_member_id', v_tm_id,
        'name', COALESCE(v_tm_first || ' ' || v_tm_last, '(unknown)'),
        'role_level', v_tm_role_level,
        'is_admin_backoffice', v_tm_admin_bo,
        'team_entity_id', v_tm_entity,
        'team_entity_name', v_tm_entity_name,
        'route', 'agency_split',
        'reason', v_route_reason,
        'gross_pay', v_p_gross,
        'employer_taxes', v_p_er_taxes,
        'net_pay', v_p_net,
        'start_date', v_tm_start,
        'weeks_in', v_weeks_in,
        'ramp_frac', ROUND(v_ramp, 4),
        'fixed_bundle', v_fixed,
        'variable', v_variable,
        'reimb', v_reimb,
        'unrecognized_gap', v_gap,
        'growth_share', v_grow_share,
        'team_share', v_team_share
      );
    END IF;
  END LOOP;

  -- Live JEs (non-VOIDED). reference_number is exactly:
  --   PAYROLL-{run_id}-AGENCY
  --   PAYROLL-{run_id}-PAPERNEWT
  --   PAYROLL-{run_id}-PAPERNEWT-IC-RECON
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'id', je.id,
             'reference_number', je.reference_number,
             'description', je.description,
             'business_entity_id', je.business_entity_id,
             'entry_date', je.entry_date,
             'leg', CASE
                      WHEN je.reference_number = 'PAYROLL-' || p_run_id::text || '-AGENCY' THEN 'AGENCY'
                      WHEN je.reference_number = 'PAYROLL-' || p_run_id::text || '-PAPERNEWT' THEN 'PAPERNEWT'
                      WHEN je.reference_number = 'PAYROLL-' || p_run_id::text || '-PAPERNEWT-IC-RECON' THEN 'PAPERNEWT-IC-RECON'
                      ELSE 'OTHER'
                    END
           )
           ORDER BY je.reference_number
         ), '[]'::jsonb)
    INTO v_jes
    FROM journal_entries je
   WHERE je.reference_number IN (
           'PAYROLL-' || p_run_id::text || '-AGENCY',
           'PAYROLL-' || p_run_id::text || '-PAPERNEWT',
           'PAYROLL-' || p_run_id::text || '-PAPERNEWT-IC-RECON'
         );

  RETURN jsonb_build_object(
    'ok', true,
    'run', jsonb_build_object(
      'id', p_run_id,
      'pay_period_start', v_pay_period_start,
      'pay_period_end', v_pay_period_end,
      'pay_date', v_pay_date,
      'gross', v_gross,
      'employer_taxes', v_er_taxes,
      'net', v_net,
      'provider', v_provider,
      'status', v_status,
      'business_entity_id', v_run_entity,
      'journal_entry_id', v_run_je
    ),
    'people', v_people,
    'jes', v_jes
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_payroll_run_drilldown(uuid) TO anon, authenticated;
