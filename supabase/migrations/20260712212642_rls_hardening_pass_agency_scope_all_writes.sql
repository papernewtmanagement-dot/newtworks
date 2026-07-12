-- RLS hardening pass: replace wide-open write policies (qual=true) with agency-scoped predicates.
-- Follows the "Newtworks frontend ↔ RLS audit protocol" pattern:
--   SELECT — usually anon+authenticated USING (true) (single-tenant convention preserved)
--   Writes (INSERT/UPDATE/DELETE) — authenticated only, WHERE agency_id = <peter's agency>
-- Anon SELECT preserved where it existed. Anon WRITE stripped everywhere.
-- Exceptions: user_preferences_history + llm_parse_queue drop anon entirely.

DO $mig$
DECLARE
  AGENCY_UUID CONSTANT text := '126794dd-25ff-47d2-a436-724499733365';
BEGIN
  -- ====== book_alpha_split ======
  DROP POLICY IF EXISTS "book_alpha_split_all_anon" ON public.book_alpha_split;
  DROP POLICY IF EXISTS "book_alpha_split_all_authenticated" ON public.book_alpha_split;
  EXECUTE format('CREATE POLICY "book_alpha_split_anon_auth_read" ON public.book_alpha_split FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "book_alpha_split_auth_write" ON public.book_alpha_split FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== book_performance_goals ======
  DROP POLICY IF EXISTS "book_performance_goals_authenticated_all" ON public.book_performance_goals;
  EXECUTE format('CREATE POLICY "book_performance_goals_auth_write" ON public.book_performance_goals FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== core_principles ======
  DROP POLICY IF EXISTS "core_principles_insert" ON public.core_principles;
  DROP POLICY IF EXISTS "core_principles_update" ON public.core_principles;
  DROP POLICY IF EXISTS "core_principles_delete" ON public.core_principles;
  EXECUTE format('CREATE POLICY "core_principles_auth_write" ON public.core_principles FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== cpr_campaigns ======
  DROP POLICY IF EXISTS "cpr_campaigns_authenticated_all" ON public.cpr_campaigns;
  EXECUTE format('CREATE POLICY "cpr_campaigns_auth_write" ON public.cpr_campaigns FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== daily_call_activity ======
  DROP POLICY IF EXISTS "anon_all_daily_call_activity" ON public.daily_call_activity;
  DROP POLICY IF EXISTS "authenticated_all_daily_call_activity" ON public.daily_call_activity;
  EXECUTE format('CREATE POLICY "daily_call_activity_anon_auth_read" ON public.daily_call_activity FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "daily_call_activity_auth_write" ON public.daily_call_activity FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== gbp_reviews ======
  DROP POLICY IF EXISTS "anon_all_gbp_reviews" ON public.gbp_reviews;
  DROP POLICY IF EXISTS "authenticated_all_gbp_reviews" ON public.gbp_reviews;
  EXECUTE format('CREATE POLICY "gbp_reviews_anon_auth_read" ON public.gbp_reviews FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "gbp_reviews_auth_write" ON public.gbp_reviews FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== gl_classification_rules ======
  DROP POLICY IF EXISTS "gl_rules_agency_write" ON public.gl_classification_rules;
  DROP POLICY IF EXISTS "gl_rules_agency_read" ON public.gl_classification_rules;
  EXECUTE format('CREATE POLICY "gl_classification_rules_anon_auth_read" ON public.gl_classification_rules FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "gl_classification_rules_auth_write" ON public.gl_classification_rules FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== job_descriptions ======
  DROP POLICY IF EXISTS "job_descriptions_all_anon" ON public.job_descriptions;
  DROP POLICY IF EXISTS "job_descriptions_all_authenticated" ON public.job_descriptions;
  EXECUTE format('CREATE POLICY "job_descriptions_anon_auth_read" ON public.job_descriptions FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "job_descriptions_auth_write" ON public.job_descriptions FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== lead_source_quarterly ======
  DROP POLICY IF EXISTS "lsq_delete_all" ON public.lead_source_quarterly;
  DROP POLICY IF EXISTS "lsq_insert_all" ON public.lead_source_quarterly;
  DROP POLICY IF EXISTS "lsq_update_all" ON public.lead_source_quarterly;
  EXECUTE format('CREATE POLICY "lead_source_quarterly_auth_write" ON public.lead_source_quarterly FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== llm_parse_queue ======
  -- Internal queue. Only service_role/edge fns should touch it. Anon has no business here.
  DROP POLICY IF EXISTS "llm_queue_all" ON public.llm_parse_queue;

  -- ====== marketing_points ======
  DROP POLICY IF EXISTS "marketing_points_auth_write" ON public.marketing_points;
  DROP POLICY IF EXISTS "marketing_points_anon_read" ON public.marketing_points;
  EXECUTE format('CREATE POLICY "marketing_points_anon_auth_read" ON public.marketing_points FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "marketing_points_auth_write" ON public.marketing_points FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== prize_cart ======
  DROP POLICY IF EXISTS "prize_cart_authenticated_all" ON public.prize_cart;
  EXECUTE format('CREATE POLICY "prize_cart_auth_write" ON public.prize_cart FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== referrals ======
  DROP POLICY IF EXISTS "anon_all_referrals" ON public.referrals;
  DROP POLICY IF EXISTS "authenticated_all_referrals" ON public.referrals;
  EXECUTE format('CREATE POLICY "referrals_anon_auth_read" ON public.referrals FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "referrals_auth_write" ON public.referrals FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== retention_budget_schedule ======
  DROP POLICY IF EXISTS "anon_write_retention_budget_schedule" ON public.retention_budget_schedule;
  DROP POLICY IF EXISTS "anon_read_retention_budget_schedule" ON public.retention_budget_schedule;
  EXECUTE format('CREATE POLICY "retention_budget_schedule_anon_auth_read" ON public.retention_budget_schedule FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "retention_budget_schedule_auth_write" ON public.retention_budget_schedule FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== sf_program_targets ======
  DROP POLICY IF EXISTS "sf_program_targets_auth_all" ON public.sf_program_targets;
  EXECUTE format('CREATE POLICY "sf_program_targets_auth_write" ON public.sf_program_targets FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== team_assessments ======
  DROP POLICY IF EXISTS "staff_assessments_insert" ON public.team_assessments;
  DROP POLICY IF EXISTS "staff_assessments_update" ON public.team_assessments;
  DROP POLICY IF EXISTS "staff_assessments_delete" ON public.team_assessments;
  EXECUTE format('CREATE POLICY "team_assessments_auth_write" ON public.team_assessments FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== team_behavioral_notes ======
  DROP POLICY IF EXISTS "behavioral_notes_insert" ON public.team_behavioral_notes;
  DROP POLICY IF EXISTS "behavioral_notes_update" ON public.team_behavioral_notes;
  DROP POLICY IF EXISTS "behavioral_notes_delete" ON public.team_behavioral_notes;
  EXECUTE format('CREATE POLICY "team_behavioral_notes_auth_write" ON public.team_behavioral_notes FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== time_clock_edit_requests ======
  DROP POLICY IF EXISTS "time_clock_edit_requests_authenticated_write" ON public.time_clock_edit_requests;
  EXECUTE format('CREATE POLICY "time_clock_edit_requests_auth_write" ON public.time_clock_edit_requests FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== time_clock_entries ======
  DROP POLICY IF EXISTS "time_clock_entries_authenticated_write" ON public.time_clock_entries;
  EXECUTE format('CREATE POLICY "time_clock_entries_auth_write" ON public.time_clock_entries FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== user_preferences_history ======
  -- Peter's private drift log. Anon has zero access. Read + write both authenticated + agency-scoped.
  DROP POLICY IF EXISTS "anon_write_user_preferences_history" ON public.user_preferences_history;
  DROP POLICY IF EXISTS "anon_read_user_preferences_history" ON public.user_preferences_history;
  EXECUTE format('CREATE POLICY "user_preferences_history_auth_read" ON public.user_preferences_history FOR SELECT TO authenticated USING (agency_id = %L::uuid)', AGENCY_UUID);
  EXECUTE format('CREATE POLICY "user_preferences_history_auth_write" ON public.user_preferences_history FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== weekly_cpr_reports ======
  DROP POLICY IF EXISTS "weekly_cpr_reports_all_access" ON public.weekly_cpr_reports;
  EXECUTE format('CREATE POLICY "weekly_cpr_reports_anon_auth_read" ON public.weekly_cpr_reports FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "weekly_cpr_reports_auth_write" ON public.weekly_cpr_reports FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

  -- ====== weekly_cpr_team_detail ======
  DROP POLICY IF EXISTS "weekly_cpr_team_detail_all_access" ON public.weekly_cpr_team_detail;
  EXECUTE format('CREATE POLICY "weekly_cpr_team_detail_anon_auth_read" ON public.weekly_cpr_team_detail FOR SELECT TO anon, authenticated USING (true)');
  EXECUTE format('CREATE POLICY "weekly_cpr_team_detail_auth_write" ON public.weekly_cpr_team_detail FOR ALL TO authenticated USING (agency_id = %L::uuid) WITH CHECK (agency_id = %L::uuid)', AGENCY_UUID, AGENCY_UUID);

END $mig$;
