-- Enable RLS on all eight quiz tables. Default deny (no policy = no access),
-- then explicit allow policies per handoff spec.

ALTER TABLE public.quiz_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_item_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_modes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_topic_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_topic_set_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_item_reports ENABLE ROW LEVEL SECURITY;

-- ── quiz_items ──────────────────────────────────────────────
DROP POLICY IF EXISTS quiz_items_team_select ON public.quiz_items;
CREATE POLICY quiz_items_team_select ON public.quiz_items
  FOR SELECT
  USING (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND status = 'approved' AND report_blocked = false
  );

DROP POLICY IF EXISTS quiz_items_admin_select ON public.quiz_items;
CREATE POLICY quiz_items_admin_select ON public.quiz_items
  FOR SELECT USING (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_items_admin_insert ON public.quiz_items;
CREATE POLICY quiz_items_admin_insert ON public.quiz_items
  FOR INSERT WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_items_admin_update ON public.quiz_items;
CREATE POLICY quiz_items_admin_update ON public.quiz_items
  FOR UPDATE USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_items_admin_delete ON public.quiz_items;
CREATE POLICY quiz_items_admin_delete ON public.quiz_items
  FOR DELETE USING (public.is_agency_admin());

-- ── quiz_item_options ───────────────────────────────────────
DROP POLICY IF EXISTS quiz_item_options_team_select ON public.quiz_item_options;
CREATE POLICY quiz_item_options_team_select ON public.quiz_item_options
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.quiz_items qi
      WHERE qi.id = quiz_item_options.item_id
        AND qi.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
        AND qi.status = 'approved' AND qi.report_blocked = false
    )
  );

DROP POLICY IF EXISTS quiz_item_options_admin_select ON public.quiz_item_options;
CREATE POLICY quiz_item_options_admin_select ON public.quiz_item_options
  FOR SELECT USING (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_item_options_admin_insert ON public.quiz_item_options;
CREATE POLICY quiz_item_options_admin_insert ON public.quiz_item_options
  FOR INSERT WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_item_options_admin_update ON public.quiz_item_options;
CREATE POLICY quiz_item_options_admin_update ON public.quiz_item_options
  FOR UPDATE USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_item_options_admin_delete ON public.quiz_item_options;
CREATE POLICY quiz_item_options_admin_delete ON public.quiz_item_options
  FOR DELETE USING (public.is_agency_admin());

-- ── quiz_modes ──────────────────────────────────────────────
DROP POLICY IF EXISTS quiz_modes_team_select ON public.quiz_modes;
CREATE POLICY quiz_modes_team_select ON public.quiz_modes
  FOR SELECT
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

DROP POLICY IF EXISTS quiz_modes_admin_insert ON public.quiz_modes;
CREATE POLICY quiz_modes_admin_insert ON public.quiz_modes
  FOR INSERT WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_modes_admin_update ON public.quiz_modes;
CREATE POLICY quiz_modes_admin_update ON public.quiz_modes
  FOR UPDATE USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_modes_admin_delete ON public.quiz_modes;
CREATE POLICY quiz_modes_admin_delete ON public.quiz_modes
  FOR DELETE USING (public.is_agency_admin());

-- ── quiz_topic_sets ─────────────────────────────────────────
DROP POLICY IF EXISTS quiz_topic_sets_team_select ON public.quiz_topic_sets;
CREATE POLICY quiz_topic_sets_team_select ON public.quiz_topic_sets
  FOR SELECT
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

DROP POLICY IF EXISTS quiz_topic_sets_admin_insert ON public.quiz_topic_sets;
CREATE POLICY quiz_topic_sets_admin_insert ON public.quiz_topic_sets
  FOR INSERT WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_topic_sets_admin_update ON public.quiz_topic_sets;
CREATE POLICY quiz_topic_sets_admin_update ON public.quiz_topic_sets
  FOR UPDATE USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_topic_sets_admin_delete ON public.quiz_topic_sets;
CREATE POLICY quiz_topic_sets_admin_delete ON public.quiz_topic_sets
  FOR DELETE USING (public.is_agency_admin());

-- ── quiz_topic_set_rules ────────────────────────────────────
-- No agency_id column on this table (per spec) — scope through parent quiz_topic_sets.
DROP POLICY IF EXISTS quiz_topic_set_rules_team_select ON public.quiz_topic_set_rules;
CREATE POLICY quiz_topic_set_rules_team_select ON public.quiz_topic_set_rules
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.quiz_topic_sets qts
      WHERE qts.id = quiz_topic_set_rules.set_id
        AND qts.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS quiz_topic_set_rules_admin_insert ON public.quiz_topic_set_rules;
CREATE POLICY quiz_topic_set_rules_admin_insert ON public.quiz_topic_set_rules
  FOR INSERT WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_topic_set_rules_admin_update ON public.quiz_topic_set_rules;
CREATE POLICY quiz_topic_set_rules_admin_update ON public.quiz_topic_set_rules
  FOR UPDATE USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_topic_set_rules_admin_delete ON public.quiz_topic_set_rules;
CREATE POLICY quiz_topic_set_rules_admin_delete ON public.quiz_topic_set_rules
  FOR DELETE USING (public.is_agency_admin());

-- ── quiz_attempts (own rows) ────────────────────────────────
DROP POLICY IF EXISTS quiz_attempts_own_select ON public.quiz_attempts;
CREATE POLICY quiz_attempts_own_select ON public.quiz_attempts
  FOR SELECT USING (team_member_id = public.current_team_member_id());

DROP POLICY IF EXISTS quiz_attempts_admin_select ON public.quiz_attempts;
CREATE POLICY quiz_attempts_admin_select ON public.quiz_attempts
  FOR SELECT USING (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_attempts_own_insert ON public.quiz_attempts;
CREATE POLICY quiz_attempts_own_insert ON public.quiz_attempts
  FOR INSERT WITH CHECK (team_member_id = public.current_team_member_id());

DROP POLICY IF EXISTS quiz_attempts_own_update ON public.quiz_attempts;
CREATE POLICY quiz_attempts_own_update ON public.quiz_attempts
  FOR UPDATE USING (team_member_id = public.current_team_member_id())
  WITH CHECK (team_member_id = public.current_team_member_id());
-- No DELETE policy for anyone (default deny handles it).

-- ── quiz_answers (own rows, via parent attempt) ─────────────
DROP POLICY IF EXISTS quiz_answers_own_select ON public.quiz_answers;
CREATE POLICY quiz_answers_own_select ON public.quiz_answers
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.quiz_attempts qa WHERE qa.id = quiz_answers.attempt_id AND qa.team_member_id = public.current_team_member_id())
  );

DROP POLICY IF EXISTS quiz_answers_admin_select ON public.quiz_answers;
CREATE POLICY quiz_answers_admin_select ON public.quiz_answers
  FOR SELECT USING (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_answers_own_insert ON public.quiz_answers;
CREATE POLICY quiz_answers_own_insert ON public.quiz_answers
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM public.quiz_attempts qa WHERE qa.id = quiz_answers.attempt_id AND qa.team_member_id = public.current_team_member_id())
  );

DROP POLICY IF EXISTS quiz_answers_own_update ON public.quiz_answers;
CREATE POLICY quiz_answers_own_update ON public.quiz_answers
  FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM public.quiz_attempts qa WHERE qa.id = quiz_answers.attempt_id AND qa.team_member_id = public.current_team_member_id())
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.quiz_attempts qa WHERE qa.id = quiz_answers.attempt_id AND qa.team_member_id = public.current_team_member_id())
  );
-- No DELETE policy for anyone.

-- ── quiz_item_reports ────────────────────────────────────────
DROP POLICY IF EXISTS quiz_item_reports_insert ON public.quiz_item_reports;
CREATE POLICY quiz_item_reports_insert ON public.quiz_item_reports
  FOR INSERT WITH CHECK (reported_by = public.current_team_member_id());

DROP POLICY IF EXISTS quiz_item_reports_own_select ON public.quiz_item_reports;
CREATE POLICY quiz_item_reports_own_select ON public.quiz_item_reports
  FOR SELECT USING (reported_by = public.current_team_member_id());

DROP POLICY IF EXISTS quiz_item_reports_admin_select ON public.quiz_item_reports;
CREATE POLICY quiz_item_reports_admin_select ON public.quiz_item_reports
  FOR SELECT USING (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_item_reports_admin_update ON public.quiz_item_reports;
CREATE POLICY quiz_item_reports_admin_update ON public.quiz_item_reports
  FOR UPDATE USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

DROP POLICY IF EXISTS quiz_item_reports_admin_delete ON public.quiz_item_reports;
CREATE POLICY quiz_item_reports_admin_delete ON public.quiz_item_reports
  FOR DELETE USING (public.is_agency_admin());
