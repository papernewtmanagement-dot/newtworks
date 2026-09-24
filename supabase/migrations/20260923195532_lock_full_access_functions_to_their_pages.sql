-- Signed-in lockdown, part 2 (task 1fd46cb0).
-- Each login runs only the full-access functions its pages need, and each of those checks the login itself.
-- Family logins never reach business data: the same gap is closed on full-access views and one table.
-- Page map built 2026-09-23 from every function name in src string literals, row rules, views,
-- column defaults, and functions that run with the caller's own access (called from those or from triggers).
-- A helper reached from a wider page (through any chain of calls or a trigger) takes the wider audience.

-- 0. New public functions no longer open to every login. A function a page calls gets its own
--    GRANT EXECUTE ... TO authenticated in the migration that creates it.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM authenticated;

-- 1. The login check. staff = any team login, admin = owner and admin, family = the family login plus
--    the owner and admin (the parents), any = any login with a users row. Calls without a login
--    (server key, scheduled jobs, the automation runner, migrations) pass, because only the server holds those.
CREATE OR REPLACE FUNCTION public.require_login(p_audience text)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
-- Runs with the rights of the full-access function that calls it, so it reads users past the
-- row rules. Logins cannot call it directly. No SECURITY DEFINER or SET clause on purpose: it
-- runs once per row inside views like v_hiring_candidates, and those two roughly double its cost.
DECLARE
  v_jwt_role text := auth.role();
  v_role text;
BEGIN
  IF v_jwt_role IS NULL OR v_jwt_role = 'service_role' THEN
    RETURN;
  END IF;
  IF v_jwt_role = 'authenticated' THEN
    SELECT u.role INTO v_role FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
    IF (p_audience = 'staff'  AND v_role IN ('owner','admin','staff','readonly','accountant'))
    OR (p_audience = 'admin'  AND v_role IN ('owner','admin'))
    OR (p_audience = 'family' AND v_role IN ('owner','admin','family'))
    OR (p_audience = 'any'    AND v_role IS NOT NULL) THEN
      RETURN;
    END IF;
  END IF;
  RAISE EXCEPTION 'This login cannot use this.' USING ERRCODE = '42501';
END;
$$;

-- 2. The one tool that puts the check at the top of a full-access function. Used below and by any
--    later migration: SELECT public.add_login_guard('public.fn(argtypes)'::regprocedure, 'staff');
CREATE OR REPLACE FUNCTION public.add_login_guard(p_fn regprocedure, p_audience text)
RETURNS text
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_src text; v_lang text; v_new text; v_def text;
  v_c text[]; v_n int; v_i int := 1; v_pos int := 0; v_j int; v_dq text; v_at int; v_b int;
BEGIN
  IF p_audience NOT IN ('staff','admin','family','any') THEN
    RAISE EXCEPTION 'unknown audience %', p_audience;
  END IF;
  SELECT p.prosrc, l.lanname INTO v_src, v_lang
  FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang WHERE p.oid = p_fn AND p.prosecdef;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% is not a full-access function; it runs with the caller''s own rights and needs no check', p_fn;
  END IF;
  IF v_src ~ 'public\.require_login\(' THEN
    RETURN 'already checked';
  END IF;
  IF coalesce(v_src, '') = '' THEN
    RAISE EXCEPTION '% has no editable body', p_fn;
  END IF;
  IF v_lang = 'sql' THEN
    v_new := format(E'\nSELECT public.require_login(%L);', p_audience) || v_src;
  ELSIF v_lang = 'plpgsql' THEN
    -- first BEGIN outside comments, quoted text and dollar-quoted text = the top-level block
    v_c := string_to_array(v_src, NULL);
    v_n := array_length(v_c, 1);
    WHILE v_i <= v_n LOOP
      IF v_c[v_i] = '-' AND v_c[v_i + 1] = '-' THEN
        v_i := v_i + 2;
        WHILE v_i <= v_n AND v_c[v_i] <> E'\n' LOOP v_i := v_i + 1; END LOOP;
      ELSIF v_c[v_i] = '/' AND v_c[v_i + 1] = '*' THEN
        v_i := v_i + 2;
        WHILE v_i < v_n AND NOT (v_c[v_i] = '*' AND v_c[v_i + 1] = '/') LOOP v_i := v_i + 1; END LOOP;
        v_i := v_i + 2;
      ELSIF v_c[v_i] = '''' THEN
        v_i := v_i + 1;
        WHILE v_i <= v_n LOOP
          IF v_c[v_i] = '''' THEN
            IF v_c[v_i + 1] = '''' THEN v_i := v_i + 2; CONTINUE; END IF;
            EXIT;
          END IF;
          v_i := v_i + 1;
        END LOOP;
        v_i := v_i + 1;
      ELSIF v_c[v_i] = '"' THEN
        v_i := v_i + 1;
        WHILE v_i <= v_n AND v_c[v_i] <> '"' LOOP v_i := v_i + 1; END LOOP;
        v_i := v_i + 1;
      ELSIF v_c[v_i] = '$' THEN
        v_dq := substring(substr(v_src, v_i, 64) FROM '^\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$');
        IF v_dq IS NULL THEN
          v_i := v_i + 1;
        ELSE
          v_j := strpos(substr(v_src, v_i + length(v_dq)), v_dq);
          EXIT WHEN v_j = 0;
          v_i := v_i + length(v_dq) + v_j - 1 + length(v_dq);
        END IF;
      ELSIF v_c[v_i] IN ('b','B')
        AND upper(array_to_string(v_c[v_i:v_i + 4], '')) = 'BEGIN'
        AND (v_i = 1 OR v_c[v_i - 1] !~ '[A-Za-z0-9_]')
        AND coalesce(v_c[v_i + 5], ' ') !~ '[A-Za-z0-9_]' THEN
        v_pos := v_i;
        EXIT;
      ELSE
        v_i := v_i + 1;
      END IF;
    END LOOP;
    IF v_pos = 0 THEN
      RAISE EXCEPTION 'no top-level BEGIN found in %', p_fn;
    END IF;
    v_new := left(v_src, v_pos + 4) || format(E'\n  PERFORM public.require_login(%L);', p_audience) || substr(v_src, v_pos + 5);
  ELSE
    RAISE EXCEPTION '% is written in %, only sql and plpgsql are handled', p_fn, v_lang;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  v_at := strpos(v_def, E'\nAS $function');
  v_b := CASE WHEN v_at > 0 THEN strpos(substr(v_def, v_at), v_src) ELSE 0 END;
  IF v_b = 0 THEN
    RAISE EXCEPTION 'could not find the body of %', p_fn;
  END IF;
  EXECUTE overlay(v_def PLACING v_new FROM v_at + v_b - 1 FOR length(v_src));
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = p_fn AND prosrc ~ 'public\.require_login\(') THEN
    RAISE EXCEPTION 'check did not land in %', p_fn;
  END IF;
  RETURN 'added';
END;
$$;

-- 3. The audit. Must return no rows after any function, view or table work.
CREATE OR REPLACE FUNCTION public.login_guard_audit()
RETURNS TABLE(object text, problem text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  -- The only full-access functions open to logins with no check: the yes/no checks the row rules call.
  -- They answer only about the person signed in.
  SELECT p.oid::regprocedure::text, 'full-access function open to logins with no login check'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND p.prosrc !~ 'public\.require_login\('
    AND p.proname <> ALL (ARRAY['auth_is_family','current_app_user_role','current_team_member_id','family_is_parent','is_agency_admin','onboarding_can_see_plan','onboarding_can_see_step','rp_appt_can_mark','rp_entry_can_change','rp_entry_can_note','rp_issue_can_change','rp_sale_can_edit','rpg_can_play'])
  UNION ALL
  SELECT p.oid::regprocedure::text, 'function open to callers with no login'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND has_function_privilege('anon', p.oid, 'EXECUTE')
  UNION ALL
  SELECT c.oid::regclass::text, 'full-access view readable by logins with no family block'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false)
    AND has_table_privilege('authenticated', c.oid, 'SELECT')
    AND pg_get_viewdef(c.oid) !~ 'auth_is_family\(\)'
  UNION ALL
  SELECT c.oid::regclass::text, 'full-access view open to writes by logins'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false)
    AND (has_table_privilege('authenticated', c.oid, 'INSERT') OR has_table_privilege('authenticated', c.oid, 'UPDATE')
         OR has_table_privilege('authenticated', c.oid, 'DELETE'))
  UNION ALL
  SELECT c.oid::regclass::text, 'materialized view readable by logins'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'm' AND has_table_privilege('authenticated', c.oid, 'SELECT')
  UNION ALL
  SELECT c.oid::regclass::text, 'table readable by logins with no family block'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
    AND has_table_privilege('authenticated', c.oid, 'SELECT')
    AND c.relname !~ '^(family_|rpg_)' AND c.relname NOT IN ('users','agency','manuals')
    AND (NOT c.relrowsecurity OR NOT EXISTS (
          SELECT 1 FROM pg_policy pol WHERE pol.polrelid = c.oid AND pol.polname = 'zz_block_family_login'));
$$;

REVOKE ALL ON FUNCTION public.require_login(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.add_login_guard(regprocedure, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.login_guard_audit() FROM PUBLIC, anon, authenticated;

-- 4. Functions: close what no page needs, put the check in everything that stays.
DO $lock$
DECLARE
  v_keep jsonb := '{"admin":["_newtworks_protocol_validity","assessment_commitment","build_weekly_focus","hiregauge_refresh_candidate_cache_if_stale","learn_gl_rule_from_ledger","mint_v1_assessment_link","record_cts_result","rp_book_alpha_save","score_tasks","team_payroll_line_delete","team_payroll_line_save","team_payroll_week","team_trajectory_recompute","verdict_assessment"],"staff":["approve_time_clock_edit","cancel_time_clock_edit","change_current_phone","change_current_subject","change_items","checklist_item_move","checklist_item_save","claim_mvp_prize","code_flag_add","code_flag_delete","code_flags_mine","compute_role_earnings_projection","compute_sales_points_rating","compute_scorecard_done_for_cpr_week","compute_weekly_marketing_bonus","compute_weekly_retention_points","cpr_checklist_get","cpr_checklist_save","create_onboarding_plan","daily_checklist_state","daily_checklist_tick","deny_time_clock_edit","earnings_curve_positions","fit_scorecard_tenure_tier","get_agency_perf_monthly_series","get_cpr_section_11","get_mvp_draw_state","get_sales_points_qtd","get_weekly_cpr_hours","get_weekly_cpr_requirements","get_weekly_crossings_live","handbook_live_formulas","kickoff_commit_mark","kickoff_commit_save","kickoff_commits_mine","kickoff_commits_today","kickoff_morning_message","log_time_off_for","mark_license_complete","marketing_points_weekly","my_pay_type","my_week_stats","my_wrapup_finish","my_wrapup_get","my_wrapup_hide_set","my_wrapup_save","onboarding_phase_first_weeks","onboarding_team_list_names","onboarding_visible_plan_names","pfa_close_day","pfa_recompute_reconciliation","pfa_record_customer_deposit","pfa_resend_close_telegram","pfa_send_reconciliation","pfa_today_summary","pfa_void_deposit","production_by_week_for","production_changes_for_range","purge_team_form_secure","quiz_accept_duel","quiz_duel_opponents","quiz_duel_result","quiz_finish_attempt","quiz_hangman_finish","quiz_hangman_guess","quiz_hangman_my_active_session","quiz_hangman_next_round","quiz_hangman_solve","quiz_hangman_start","quiz_hangman_state","quiz_hunt_answer","quiz_hunt_available","quiz_hunt_my_active_session","quiz_hunt_start","quiz_hunt_state","quiz_mode_day_standings","quiz_my_gates","quiz_night_abandon","quiz_night_active","quiz_night_advance","quiz_night_answer","quiz_night_create_session","quiz_night_join","quiz_night_standings","quiz_night_start","quiz_night_state","quiz_pending_duels","quiz_phrase_give_up","quiz_phrase_guess","quiz_phrase_solve","quiz_play_availability","quiz_play_state","quiz_room_join","quiz_room_leave","quiz_room_list_open","quiz_room_my_active","quiz_room_my_finish","quiz_room_open","quiz_room_start_daily_five","quiz_room_start_spin_and_solve","quiz_room_state","quiz_shared_grid_end","quiz_shared_grid_lock_wagers","quiz_shared_grid_my_active_session","quiz_shared_grid_pick","quiz_shared_grid_reveal","quiz_shared_grid_score","quiz_shared_grid_score_final","quiz_shared_grid_set_wager","quiz_shared_grid_start","quiz_shared_grid_start_round2","quiz_shared_grid_start_round3","quiz_shared_grid_state","quiz_start_daily_attempt","quiz_start_duel_challenge","quiz_start_gated_attempt","quiz_start_grid_attempt","quiz_start_spin_attempt","quiz_submit_answer","quiz_topic_set_pool","quiz_wheel_buy_vowel","quiz_wheel_spin","recompute_cpr_outcome","record_mvp_prize_draw","rp_add_note","rp_attach_entry_to_appointment","rp_autopay_ok","rp_backfill_cancelations","rp_backfill_mark_charged_back","rp_backfill_queue","rp_backfill_save","rp_book_alpha","rp_cancel_word_review","rp_convert_activity_to_cancelation","rp_customer_account","rp_customer_suggest2","rp_delete_record","rp_edit_activity","rp_edit_appointment","rp_edit_cancelation","rp_edit_quote","rp_edit_sale","rp_edit_scorecard","rp_entry_for_edit","rp_log_appointment","rp_log_entry","rp_mark_issued","rp_reassign_record","rp_recent_entries","rp_reference_calls","rp_reference_log_call","rp_reference_save_writeup","rp_reinstatable_cancelations","rp_reinstate_cancelation","rp_restore_record","rp_set_appointment_state","rp_set_sale_autopay","rp_sold_on_file2","rp_spot_check_note","rp_spot_check_remove","rp_spot_check_sample","rp_spot_check_verify","rp_spot_check_weeks","rp_undo_entry","rp_unmark_issued","rp_void_cancelation","rp_void_quote","rp_week_scoreboard","save_onboarding_secure","send_mvp_prize_win_telegram","team_account_alpha","team_raise_progress","team_sales_points_ratings","time_clock_punch_simple","week_pay_lock","year_one_path_to_100k","compute_scorecard_bonus","hiregauge_refresh_scoring_cache","sales_points_week_delta","send_signature_email","team_week_base_fraction"],"predicate":["auth_is_family","current_app_user_role","current_team_member_id","family_is_parent","is_agency_admin","onboarding_can_see_plan","onboarding_can_see_step","rp_appt_can_mark","rp_entry_can_change","rp_entry_can_note","rp_issue_can_change","rp_sale_can_edit","rpg_can_play"],"family":["family_inventory_mark_left","family_inventory_mark_low","family_inventory_mark_ordered","family_inventory_unmark_low","family_math_done","family_school_step","family_timer_cancel","family_timer_start","family_timer_stop","rpg_adjust_vitality","rpg_character_list","rpg_level_cost","rpg_needed","rpg_new_character","rpg_recent_rolls","rpg_reroll_character","rpg_roll","rpg_roll_extra","rpg_roll_inputs","rpg_set_input","rpg_setting","rpg_sheet"]}';
  v_names text[];
  r record;
  v_closed int := 0;
  v_checked int := 0;
BEGIN
  SELECT array_agg(e.name) INTO v_names
  FROM jsonb_each(v_keep) g CROSS JOIN LATERAL jsonb_array_elements_text(g.value) AS e(name);

  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.prosecdef
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND (p.prorettype IN ('trigger'::regtype, 'event_trigger'::regtype) OR p.proname <> ALL (v_names))
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.fn);
    v_closed := v_closed + 1;
  END LOOP;
  IF v_closed <> 233 THEN
    RAISE EXCEPTION 'expected to close 233 full-access functions, found %. The function list changed after it was mapped.', v_closed;
  END IF;

  FOR r IN
    SELECT p.oid::regprocedure AS fn, g.key AS audience
    FROM jsonb_each(v_keep) g
    CROSS JOIN LATERAL jsonb_array_elements_text(g.value) AS e(name)
    JOIN pg_proc p ON p.proname = e.name
    JOIN pg_namespace ns ON ns.oid = p.pronamespace AND ns.nspname = 'public'
    WHERE g.key <> 'predicate' AND p.prosecdef
    ORDER BY p.oid
  LOOP
    PERFORM public.add_login_guard(r.fn, r.audience);
    v_checked := v_checked + 1;
  END LOOP;
  IF v_checked <> 218 THEN
    RAISE EXCEPTION 'expected to add the check to 218 functions, did %', v_checked;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.prosecdef AND p.proname = ANY (v_names)
      AND p.prorettype <> 'trigger'::regtype
      AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'a function a page needs lost login access';
  END IF;
END
$lock$;

-- 5. Views. No page writes through a view, and a full-access view takes writes as its owner, past
--    every row rule. Views no page, row rule or caller-access function reads close to logins.
--    Views pages read keep working for everyone but the family login.
DO $views$
DECLARE
  v text;
  v_def text;
BEGIN
  FOR v IN
    SELECT c.oid::regclass::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
      AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false)
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON %s FROM authenticated, anon', v);
  END LOOP;

  FOREACH v IN ARRAY ARRAY['v_agency_rates','v_amazon_charge_matches','v_migration_ledger_fingerprints','v_producer_complacency','v_producer_roi_inputs','v_statement_lines_unposted','v_tithe_giving_by_month','v_tithe_pool_activity'] LOOP
    EXECUTE format('REVOKE ALL ON public.%I FROM authenticated, anon', v);
  END LOOP;

  FOREACH v IN ARRAY ARRAY['rp_saves_clearing_soon','team_directory','v_agency_growth_summary','v_agency_snapshot_with_changes','v_aipp_projection','v_bank_balances','v_card_balances','v_departure_recapture_ytd','v_dormant_gl_rules','v_growth_budget_full_ytd','v_hiring_candidates','v_lapse_rate_current','v_ledger_confirmation','v_not_on_statement','v_statement_reconciliation','v_time_off_pending_votes','v_tithe_pool_balance','weekly_cpr_team_detail_activity'] LOOP
    v_def := pg_get_viewdef(format('public.%I', v)::regclass);
    CONTINUE WHEN v_def ~ 'family_block';
    EXECUTE format('CREATE OR REPLACE VIEW public.%I AS SELECT * FROM (%s) family_block WHERE NOT public.auth_is_family()',
                   v, rtrim(rtrim(v_def), ';'));
  END LOOP;
END
$views$;

-- 6. The one table readable by logins that never got the family block.
CREATE POLICY zz_block_family_login ON public.termination_checklist
  AS RESTRICTIVE FOR ALL TO authenticated
  USING (NOT (SELECT public.auth_is_family()))
  WITH CHECK (NOT (SELECT public.auth_is_family()));

-- 7. Nothing left open.
DO $audit$
BEGIN
  IF EXISTS (SELECT 1 FROM public.login_guard_audit()) THEN
    RAISE EXCEPTION 'audit still finds: %', (SELECT string_agg(object || ' (' || problem || ')', '; ') FROM public.login_guard_audit());
  END IF;
END
$audit$;