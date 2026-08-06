-- Peter directive 2026-08-06: financials are owner/manager only.
--
-- FINDING 1 — v_growth_budget_full_ytd leaked 1 row to a staff session after the
-- invoker flip. Cause: it is a nested view over v_growth_budget_ytd, which reads
-- public.team. The team read policy deliberately scopes a staff member to their
-- OWN row, so a staff caller saw a growth-budget dollar figure derived from their
-- own pay rate (Thomas Lynch, $5,464.80) — not other people's compensation.
-- Reverting to definer would have been WORSE: as a definer view it bypasses RLS
-- entirely and would return EVERY ramping hire's figure to any caller who can
-- read the view. So invoker stays on, and the admin check moves into the view.
-- This view is consumed only by Financials.jsx (an owner/manager module), so an
-- admin predicate matches its sole consumer.
--
-- FINDING 2 — v_growth_budget_licensing_ytd was reverted to definer during the
-- run because it returned 0 rows for owner under invoker, which the runbook read
-- as a failure. That was a false negative: the view returns 0 rows for the
-- SERVICE ROLE too. There are simply no licensing journal entries year-to-date.
-- Its underlying tables (chart_of_accounts, journal_entries, journal_lines) are
-- already admin-gated, so invoker is correct and is restored here.
--
-- NOT CHANGED, deliberately: v_growth_budget_current and v_growth_budget_ytd.
-- Both were already invoker-rights before any lockdown work, both feed
-- Dashboard.jsx (team-visible), and their per-person scoping (staff sees only
-- their own figure) is pre-existing behavior, not a regression. Changing them
-- would alter what the team sees on the Dashboard — a product decision for Peter.

CREATE OR REPLACE VIEW public.v_growth_budget_full_ytd AS
 WITH salary_totals AS (
         SELECT v_growth_budget_ytd.agency_id,
            round(sum(v_growth_budget_ytd.growth_budget_ytd), 2) AS salary_ramp_ytd_dollars,
            sum(v_growth_budget_ytd.weeks_ramping_ytd) AS total_weeks_ramping_ytd,
            count(*) AS active_new_hires_ramping
           FROM v_growth_budget_ytd
          GROUP BY v_growth_budget_ytd.agency_id
        ), licensing_totals AS (
         SELECT v_growth_budget_licensing_ytd.agency_id,
            v_growth_budget_licensing_ytd.licensing_ytd_dollars,
            v_growth_budget_licensing_ytd.entry_count AS licensing_entries_ytd
           FROM v_growth_budget_licensing_ytd
        )
 SELECT COALESCE(s.agency_id, l.agency_id) AS agency_id,
    COALESCE(s.salary_ramp_ytd_dollars, 0::numeric) AS salary_ramp_ytd_dollars,
    COALESCE(l.licensing_ytd_dollars, 0::numeric) AS licensing_ytd_dollars,
    COALESCE(s.salary_ramp_ytd_dollars, 0::numeric) + COALESCE(l.licensing_ytd_dollars, 0::numeric) AS total_growth_budget_ytd_dollars,
    COALESCE(s.active_new_hires_ramping, 0::bigint) AS active_new_hires_ramping,
    COALESCE(s.total_weeks_ramping_ytd, 0::numeric) AS total_weeks_ramping_ytd,
    COALESCE(l.licensing_entries_ytd, 0::bigint) AS licensing_entries_ytd
   FROM salary_totals s
     FULL JOIN licensing_totals l ON l.agency_id = s.agency_id
  WHERE public.is_agency_admin();

ALTER VIEW public.v_growth_budget_full_ytd SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_licensing_ytd SET (security_invoker = true);
