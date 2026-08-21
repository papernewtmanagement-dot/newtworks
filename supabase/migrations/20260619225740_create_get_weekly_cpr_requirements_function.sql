-- Runtime per-person Requirements computation per the locked algorithm:
--   carryover[p] = prior week's owed[p]
--   personal_misses[p] = NOT(cpr_reply) + NOT(wrapup) + NOT(inbox)
--   team_misses (constant for week) = NOT-count across 11 team booleans on weekly_cpr_reports
--   missed[p] = team_misses + personal_misses[p]
--   cost = 1 (uniform; tenure-based mapping deferred to later)
--   total[p] = carryover[p] + missed[p] * cost
--   net_quotes[p] = quotes_discussed[p] - total[p]
--   paid[p] = pro-rata allocation, carryover-first:
--     if team_quotes >= team_total_debt: paid = total
--     elif team_quotes >= team_carryover: carryover fully cleared, surplus pays missed-cost pro-rata
--     else: carryover only partially paid pro-rata, no missed-cost paid
--   owed[p] = total[p] - paid[p]
CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(
  p_agency_id        uuid,
  p_week_ending_date date
)
RETURNS TABLE (
  team_member_id   uuid,
  carryover        integer,
  personal_misses  integer,
  team_misses      integer,
  missed           integer,
  cost             integer,
  total            integer,
  quotes_discussed integer,
  paid             integer,
  owed             integer,
  net_quotes       integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH
  this_report AS (
    SELECT
      id AS report_id,
      (CASE WHEN COALESCE(shareds_done,       true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(texts_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(deposits_done,      true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(appts_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(tasks_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(cases_done,         true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(no_fu_task_done,    true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(new_opps_done,      true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(no_onboarding_done, true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(no_phone_done,      true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(bad_data_done,      true) THEN 0 ELSE 1 END
      )::integer AS team_misses
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = p_week_ending_date
  ),
  prior_report AS (
    SELECT id AS report_id
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = p_week_ending_date - 7
  ),
  per_person AS (
    SELECT
      t.id AS team_member_id,
      COALESCE(prior_d.owed, 0)::integer AS carryover,
      (CASE WHEN COALESCE(d.cpr_reply_done, true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(d.wrapup_done,    true) THEN 0 ELSE 1 END +
       CASE WHEN COALESCE(d.inbox_done,     true) THEN 0 ELSE 1 END
      )::integer AS personal_misses,
      COALESCE((SELECT team_misses FROM this_report), 0)::integer AS team_misses,
      COALESCE(d.quotes_discussed, 0)::integer AS quotes_discussed
    FROM public.team t
    LEFT JOIN public.weekly_cpr_team_detail d
      ON d.weekly_cpr_report_id = (SELECT report_id FROM this_report)
     AND d.team_member_id       = t.id
    LEFT JOIN public.weekly_cpr_team_detail prior_d
      ON prior_d.weekly_cpr_report_id = (SELECT report_id FROM prior_report)
     AND prior_d.team_member_id       = t.id
    WHERE t.agency_id = p_agency_id
      AND t.is_active = true
      AND t.archived_at IS NULL
      AND t.category = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
  ),
  per_person_derived AS (
    SELECT
      team_member_id,
      carryover,
      personal_misses,
      team_misses,
      (team_misses + personal_misses)::integer AS missed,
      1::integer AS cost,
      (carryover + (team_misses + personal_misses) * 1)::integer AS total,
      quotes_discussed
    FROM per_person
  ),
  team_totals AS (
    SELECT
      SUM(quotes_discussed)::integer       AS team_quotes,
      SUM(carryover)::integer              AS team_carryover,
      SUM(missed * cost)::integer          AS team_missed_cost,
      (SUM(carryover) + SUM(missed * cost))::integer AS team_total_debt
    FROM per_person_derived
  ),
  allocated AS (
    SELECT
      ppd.team_member_id,
      ppd.carryover,
      ppd.personal_misses,
      ppd.team_misses,
      ppd.missed,
      ppd.cost,
      ppd.total,
      ppd.quotes_discussed,
      CASE
        WHEN tt.team_quotes >= tt.team_total_debt
          THEN ppd.total
        WHEN tt.team_quotes >= tt.team_carryover
          THEN ppd.carryover +
               CASE WHEN tt.team_missed_cost > 0
                    THEN ROUND((tt.team_quotes - tt.team_carryover)::numeric * (ppd.missed * ppd.cost)::numeric / tt.team_missed_cost)::integer
                    ELSE 0 END
        ELSE
          CASE WHEN tt.team_carryover > 0
               THEN ROUND(tt.team_quotes::numeric * ppd.carryover::numeric / tt.team_carryover)::integer
               ELSE 0 END
      END::integer AS paid
    FROM per_person_derived ppd
    CROSS JOIN team_totals tt
  )
SELECT
  team_member_id,
  carryover,
  personal_misses,
  team_misses,
  missed,
  cost,
  total,
  quotes_discussed,
  paid,
  (total - paid)::integer AS owed,
  (quotes_discussed - total)::integer AS net_quotes
FROM allocated;
$$;

GRANT EXECUTE ON FUNCTION public.get_weekly_cpr_requirements(uuid, date) TO authenticated, anon;

COMMENT ON FUNCTION public.get_weekly_cpr_requirements(uuid, date) IS
'Runtime per-person Requirements computation for the CPR Requirements section. Derives carryover (from prior week owed), missed (team + personal checklist misses), cost (uniform 1), total, paid (carryover-first then pro-rata allocation), owed (total - paid), net_quotes (quotes_discussed - total). Stored inputs: weekly_cpr_reports.{11 team booleans}, weekly_cpr_team_detail.{cpr_reply_done, wrapup_done, inbox_done, quotes_discussed}, prior weeks weekly_cpr_team_detail.owed. Cost=1 is locked per Peter 2026-06-19; tenure-based mapping deferred to handbook integration.';
