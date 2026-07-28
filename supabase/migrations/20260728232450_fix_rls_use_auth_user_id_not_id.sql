-- Fix 12 RLS policies that joined users on u.id = auth.uid() instead of
-- u.auth_user_id = auth.uid(). The wrong column silently returned false for
-- every real user, blocking all admin writes (P&L edit/delete, prior-year P&L,
-- account map, bot prompts, standing time-off prefs) and one read
-- (time_off_email_vote_replies owner read). SELECT paths on the affected
-- financial tables continued to work only because each has an `anon_read_*`
-- permissive policy alongside.

-- journal_entries
DROP POLICY IF EXISTS journal_entries_admin_update ON public.journal_entries;
CREATE POLICY journal_entries_admin_update ON public.journal_entries
  FOR UPDATE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  )
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS journal_entries_admin_delete ON public.journal_entries;
CREATE POLICY journal_entries_admin_delete ON public.journal_entries
  FOR DELETE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

-- journal_lines
DROP POLICY IF EXISTS journal_lines_admin_update ON public.journal_lines;
CREATE POLICY journal_lines_admin_update ON public.journal_lines
  FOR UPDATE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  )
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS journal_lines_admin_delete ON public.journal_lines;
CREATE POLICY journal_lines_admin_delete ON public.journal_lines
  FOR DELETE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

-- prior_year_pl (SELECT, UPDATE, DELETE)
DROP POLICY IF EXISTS prior_year_pl_admin_select ON public.prior_year_pl;
CREATE POLICY prior_year_pl_admin_select ON public.prior_year_pl
  FOR SELECT TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

DROP POLICY IF EXISTS prior_year_pl_admin_update ON public.prior_year_pl;
CREATE POLICY prior_year_pl_admin_update ON public.prior_year_pl
  FOR UPDATE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  )
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS prior_year_pl_admin_delete ON public.prior_year_pl;
CREATE POLICY prior_year_pl_admin_delete ON public.prior_year_pl
  FOR DELETE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

-- prior_year_pl_account_map (SELECT + ALL)
DROP POLICY IF EXISTS pypam_admin_select ON public.prior_year_pl_account_map;
CREATE POLICY pypam_admin_select ON public.prior_year_pl_account_map
  FOR SELECT TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

DROP POLICY IF EXISTS pypam_admin_write ON public.prior_year_pl_account_map;
CREATE POLICY pypam_admin_write ON public.prior_year_pl_account_map
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

-- bot_prompts (ALL)
DROP POLICY IF EXISTS bot_prompts_admin_all ON public.bot_prompts;
CREATE POLICY bot_prompts_admin_all ON public.bot_prompts
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

-- standing_time_off_preferences (ALL)
DROP POLICY IF EXISTS stop_write_admin ON public.standing_time_off_preferences;
CREATE POLICY stop_write_admin ON public.standing_time_off_preferences
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner','manager'])
    )
  );

-- time_off_email_vote_replies (SELECT owner-only)
DROP POLICY IF EXISTS tovr_owner_read ON public.time_off_email_vote_replies;
CREATE POLICY tovr_owner_read ON public.time_off_email_vote_replies
  FOR SELECT TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = 'owner'
    )
  );
