-- ═════════════════════════════════════════════════════════════════════════════
-- Take the back-office machinery away from signed-in staff too.
-- ═════════════════════════════════════════════════════════════════════════════
-- Signed-out access is already closed. This pass handles the other half: a
-- signed-in teammate could still call the four ledger writers, the automation
-- runner, every outbound email and Telegram sender, the pay-recompute
-- functions, the log-pruning functions, and the one that sets another person's
-- time-clock code. None of those are reachable from any screen — they are run
-- by the scheduler and by edge functions, both of which hold the service key
-- and are unaffected by this.
--
-- Three safety rails, because a wrong revoke here breaks the app silently:
--   1. An explicit list of every function the browser calls, including the two
--      call sites that pass the name through a variable rather than a literal
--      (TimeClockEditRequests.jsx builds approve_time_clock_edit /
--      deny_time_clock_edit at runtime; a name-only search misses them).
--   2. Anything nested inside a browser-called function that runs with CALLER
--      rights is spared — the caller's permission is what gets checked there.
--   3. Anything nested inside a trigger function that runs with caller rights
--      is spared, or ordinary inserts and updates would start failing.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TEMP TABLE _fn_backoffice (routine text);

DO $$
DECLARE
  r record;
  v_frontend text[] := ARRAY[
    'assessment_all_competencies','assessment_best_fit_role','assessment_intelligence_composite',
    'assessment_intelligence_fit','cancel_time_clock_edit','compute_lapse_rate',
    'compute_newtworks_v1_traits_as_row','compute_newtworks_v2_facets_as_row',
    'compute_seat_projections_for_agency','compute_warning_trigger','compute_weekly_marketing_bonus',
    'create_onboarding_plan_from_templates','fit_scorecard_tenure_tier','get_agency_perf_monthly_series',
    'get_cpr_section_11','get_entity_direct_children','get_growth_budget_ceiling',
    'get_growth_budget_forecast','get_payroll_run_drilldown','get_pnl_history_for_entity',
    'get_pnl_history_own_only','get_weekly_cpr_hours','get_weekly_cpr_requirements',
    'hiregauge_composite_recommendation','hiregauge_evaluate_candidate','log_time_off_for',
    'mark_license_complete','mint_v1_assessment_link','newtworks_all_role_fits','pfa_close_day',
    'pfa_recompute_reconciliation','pfa_record_customer_deposit','pfa_resend_close_telegram',
    'pfa_send_reconciliation','pfa_today_summary','pfa_void_deposit','pnl_drill_transactions',
    'recompute_cpr_outcome','send_mvp_prize_win_telegram','send_signature_email',
    'team_trajectory_recompute','time_clock_punch_simple','time_off_check_coverage',
    'time_off_check_eligibility','time_off_check_notice','time_off_vote_status','verdict_overall',
    -- resolved from variable-named call sites:
    'approve_time_clock_edit','deny_time_clock_edit','compute_scorecard_done_for_cpr_week'
  ];
BEGIN
  FOR r IN
    WITH pub AS (
      SELECT p.oid, p.proname, p.prosecdef,
             p.oid::regprocedure::text AS sig,
             p.prorettype::regtype::text AS ret,
             pg_get_functiondef(p.oid) AS def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
    ),
    caller_rights_reachable AS (
      SELECT def FROM pub
      WHERE NOT prosecdef
        AND (proname = ANY(v_frontend) OR ret = 'trigger')
    ),
    spared AS (
      SELECT DISTINCT p.proname
      FROM pub p, caller_rights_reachable c
      WHERE c.def ~ ('\y' || p.proname || '\s*\(')
    )
    SELECT sig FROM pub
    WHERE prosecdef
      AND ret <> 'trigger'
      AND NOT (proname = ANY(v_frontend))
      AND proname NOT IN (SELECT proname FROM spared)
      AND def ~* '(insert into|update |delete from|truncate)'
    ORDER BY sig
  LOOP
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM authenticated', r.sig);
    INSERT INTO _fn_backoffice VALUES (r.sig);
  END LOOP;
END $$;
