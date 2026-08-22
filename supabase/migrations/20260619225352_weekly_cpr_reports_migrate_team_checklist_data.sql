-- Migrate existing team checklist data from per-person rows to report row.
-- Rule (per Peter 2026-06-19): "if ALL 5 marked done, team marks done".
-- Applies to existing rows in weekly_cpr_reports: only the 6/13 and 6/20 rows have detail data.
UPDATE public.weekly_cpr_reports r
SET
  shareds_done       = sub.shareds_done,
  texts_done         = sub.texts_done,
  deposits_done      = sub.deposits_done,
  appts_done         = sub.appts_done,
  tasks_done         = sub.tasks_done,
  cases_done         = sub.cases_done,
  no_fu_task_done    = sub.no_fu_task_done,
  new_opps_done      = sub.new_opps_done,
  no_onboarding_done = sub.no_onboarding_done,
  no_phone_done      = sub.no_phone_done,
  bad_data_done      = sub.bad_data_done
FROM (
  SELECT
    weekly_cpr_report_id,
    BOOL_AND(COALESCE(shareds_done,       false)) AS shareds_done,
    BOOL_AND(COALESCE(texts_done,         false)) AS texts_done,
    BOOL_AND(COALESCE(deposits_done,      false)) AS deposits_done,
    BOOL_AND(COALESCE(appts_done,         false)) AS appts_done,
    BOOL_AND(COALESCE(tasks_done,         false)) AS tasks_done,
    BOOL_AND(COALESCE(cases_done,         false)) AS cases_done,
    BOOL_AND(COALESCE(no_fu_task_done,    false)) AS no_fu_task_done,
    BOOL_AND(COALESCE(new_opps_done,      false)) AS new_opps_done,
    BOOL_AND(COALESCE(no_onboarding_done, false)) AS no_onboarding_done,
    BOOL_AND(COALESCE(no_phone_done,      false)) AS no_phone_done,
    BOOL_AND(COALESCE(bad_data_done,      false)) AS bad_data_done
  FROM public.weekly_cpr_team_detail
  GROUP BY weekly_cpr_report_id
) AS sub
WHERE r.id = sub.weekly_cpr_report_id;
