-- Standard anon,authenticated SELECT policy sweep for tables that had RLS on
-- but no anon SELECT policy — same pattern as chart_of_accounts / journal_entries /
-- journal_lines / payroll_runs / team / etc. already had.
--
-- SKIPPED (deliberately, do NOT include):
--   usps_oauth_cache                              — stores access_token; opening
--                                                    anon read would expose OAuth
--                                                    credentials via public anon key
--   _bak_hiring_candidates_resume_text_2026_07_17 — one-off backup; not consumed by
--                                                    the app; keep walled off

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'agency_cc_yearly_status','agency_huddle_config','bank_account_map','bot_prompts',
    'briefings','comp_category_map','comp_deduction_map','envelope_budget_targets',
    'everquote_review_metrics','everquote_reviews','gmail_label_classification_map',
    'hiregauge_rules','leslie_monthly_checkin','llm_parse_queue','open_questions',
    'opening_balances','paper_newt_ventures','payroll_label_map',
    'personal_register_preliminary','pfa_accounts','pfa_bank_statements',
    'pfa_daily_closes','pfa_reconciliations','pfa_transactions',
    'prior_year_pl_account_map','producer_activity','role_pace_targets',
    'sales_points_band_config','sops','standing_time_off_preferences','tasks',
    'team_checkin_runs','team_checkins','team_profile','telegram_group_messages',
    'time_off_coverage_rules','time_off_email_vote_replies','time_off_notification_log',
    'time_off_requests','time_off_votes','user_preferences_history'
  ];
  policy_name text;
BEGIN
  FOREACH t IN ARRAY tables
  LOOP
    policy_name := 'anon_read_' || t;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND policyname=policy_name
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR SELECT TO anon, authenticated USING (true)',
        policy_name, t
      );
    END IF;
  END LOOP;
END $$;
