-- Correction: team and weekly_cpr_team_detail were locked fully admin-only in
-- the last batch, which blocks a staff member from reading their OWN row too.
-- That breaks real functionality: Licensing/Onboarding/PFA/FitScorecards/
-- CPRDetail all need a person to see (and in some cases write) their own team
-- row and their own weekly CPR detail row. Same fix pattern already used for
-- time_clock_entries: admin sees everything, everyone else sees only their
-- own row. Full team-wide directory visibility (everyone sees everyone's
-- name/role but not each other's pay) is the still-deferred view-split work.

DROP POLICY IF EXISTS team_admin_read ON public.team;
CREATE POLICY team_admin_or_own_read ON public.team FOR SELECT TO authenticated
  USING (is_agency_admin() OR id = current_team_member_id());

DROP POLICY IF EXISTS weekly_cpr_team_detail_admin_read ON public.weekly_cpr_team_detail;
CREATE POLICY weekly_cpr_team_detail_admin_or_own_read ON public.weekly_cpr_team_detail FOR SELECT TO authenticated
  USING (is_agency_admin() OR team_member_id = current_team_member_id());
