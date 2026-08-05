-- Dead-weight removal per 2026-08-05 audit. Every object verified unreferenced across:
-- pg_cron, triggers, event triggers, function bodies, automation recipes, views,
-- RLS policies, column defaults, check constraints, FKs, pg_depend, and full repo grep.
-- HELD (not dropped): _assessment_apply_reliability_confidence, _assessment_role_fit_apply_gates,
-- _assessment_role_fit_contrib, compute_newtworks_v1_retest_divergence — v1-instrument scoring
-- machinery with 6 live assessment_source='v1' candidates (dual-path scoring rule).

-- 1) Views (drop before the functions/tables they might touch)
DROP VIEW IF EXISTS public.v_balance_sheet;
DROP VIEW IF EXISTS public.v_bank_register_gl_ready;
DROP VIEW IF EXISTS public.v_bank_register_pl_preview;
DROP VIEW IF EXISTS public.v_current_team_pay;
DROP VIEW IF EXISTS public.v_pl_rolled_up;
DROP VIEW IF EXISTS public.v_book_alpha_split_latest;
DROP VIEW IF EXISTS public.v_tasks_with_hierarchy;
DROP VIEW IF EXISTS public.v_team_sales_points_quarterly;

-- 2) Retired CPR email rendering family (compose_weekly_cpr_html inlines all of this now)
DROP FUNCTION IF EXISTS public.render_cpr_campaigns_html(weekly_cpr_reports);
DROP FUNCTION IF EXISTS public.render_cpr_eur_html(weekly_cpr_reports);
DROP FUNCTION IF EXISTS public.render_cpr_marketing_bonus_html(uuid, date);
DROP FUNCTION IF EXISTS public.render_cpr_personal_checklist_html(uuid, date);
DROP FUNCTION IF EXISTS public.render_cpr_prize_cart_html(uuid, date);
DROP FUNCTION IF EXISTS public.render_cpr_section_11_html(uuid, date);
DROP FUNCTION IF EXISTS public.render_cpr_team_checklist_grid_html(weekly_cpr_reports);
DROP FUNCTION IF EXISTS public.cpr_fmt_money(numeric, integer);
DROP FUNCTION IF EXISTS public.cpr_fmt_hours(numeric);
DROP FUNCTION IF EXISTS public.cpr_fmt_int(numeric);
DROP FUNCTION IF EXISTS public.cpr_fmt_signed_int(numeric);
DROP FUNCTION IF EXISTS public.cpr_fmt_signed_money(numeric, integer);

-- 3) Abandoned time-clock PIN system (live path is time_clock_punch_simple)
DROP FUNCTION IF EXISTS public.time_clock_punch(uuid, text);
DROP FUNCTION IF EXISTS public.time_clock_set_pin(uuid, text);
DROP FUNCTION IF EXISTS public.time_clock_hash_pin(uuid, text);

-- 4) Old weekly pay chain (superseded by write_weekly_comp_v2 / residual pool)
DROP FUNCTION IF EXISTS public.write_weekly_pay(uuid, date);
DROP FUNCTION IF EXISTS public.compute_weekly_pay(uuid, date);

-- 5) Superseded one-offs
DROP FUNCTION IF EXISTS public.check_producer_complacency();
DROP FUNCTION IF EXISTS public.get_pnl_history();
DROP FUNCTION IF EXISTS public.compile_onboarding_plan(uuid, date, date, uuid);
DROP FUNCTION IF EXISTS public.mark_cpr_dispatched(uuid);
DROP FUNCTION IF EXISTS public.get_current_bonus_pool(uuid, date);
DROP FUNCTION IF EXISTS public.compute_person_qtd_at_week(uuid, uuid, integer, integer, integer);
DROP FUNCTION IF EXISTS public.payroll_gl_writer_plan_a_dryrun(uuid, date);
DROP FUNCTION IF EXISTS public.test_residual_pool_v2(date);
DROP FUNCTION IF EXISTS public.classify_and_post_bank_txns(uuid, uuid, text, jsonb);

-- 6) Finished GL-cleanup utilities
DROP FUNCTION IF EXISTS public.apply_coding_rules_backfill(uuid);
DROP FUNCTION IF EXISTS public.heal_misflagged_pending_jes(uuid, boolean);
DROP FUNCTION IF EXISTS public.classify_personal_cc_txn(text, numeric);
DROP FUNCTION IF EXISTS public.reclassify_pending_je(uuid, text, uuid, boolean);

-- 7) USPS address validation (feature never launched; table dropped below)
DROP FUNCTION IF EXISTS public.validate_address(text, text, text, text, text);

-- 8) Unused entity helper (direct_children is the live one)
DROP FUNCTION IF EXISTS public.get_entity_descendants(uuid);

-- 9) Dead compute_renewal_stack overloads (the 3-arg version stays: compute_warning_trigger uses it)
DROP FUNCTION IF EXISTS public.compute_renewal_stack(uuid, date);
DROP FUNCTION IF EXISTS public.compute_renewal_stack(uuid, uuid, date, numeric, numeric, numeric);

-- 10) Dead tables
DROP TABLE IF EXISTS public.usps_oauth_cache;
DROP TABLE IF EXISTS public.pending_prize_research;
DROP TABLE IF EXISTS public.agency_cc_yearly_status;
DROP TABLE IF EXISTS public.daily_briefing_log;
DROP TABLE IF EXISTS public.cpr_campaigns;
DROP TABLE IF EXISTS public.prior_year_pl_account_map;
DROP TABLE IF EXISTS public.positions;
DROP TABLE IF EXISTS public.commission_structures;
DROP TABLE IF EXISTS public.notification_preferences;
DROP TABLE IF EXISTS public.producer_activity;
DROP TABLE IF EXISTS public.prior_year_pl_archive_20260727;

-- 11) Dead recipe: Amazon Order Notice Ingestor (inactive; output table no longer exists)
DELETE FROM public.automation_run_log
WHERE recipe_id IN (SELECT id FROM public.automation_recipes WHERE recipe_name = 'Amazon Order Notice Ingestor');
DELETE FROM public.automation_recipes WHERE recipe_name = 'Amazon Order Notice Ingestor';
