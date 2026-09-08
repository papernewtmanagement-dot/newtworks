-- Cadences cut against 30 days of actual output from automation_run_log.
-- Pollers that never found anything drop hard. Ones that found work keep a cadence
-- proportional to how often work actually arrives.

UPDATE public.automation_recipes SET cron_expression = v.expr, updated_at = NOW()
FROM (VALUES
  -- Zero records in 30 days.
  ('Amazon Order Email Capture',          '0 6 * * *'),        -- daily
  ('GBP Review Checker — Hourly',         '0 9 * * *'),        -- daily; reviews trickle in
  ('Reference Email Ingest',              '0 14,20 * * 1-6'),  -- twice a day on hiring days
  -- Found work occasionally; hiring is live so keep these responsive but not hourly.
  ('CareerPlug Applicant Intake',         '0 */3 * * *'),
  ('CareerPlug Webhook Applicant Writer', '0 */3 * * *'),
  ('Candidate Email Reply Ingestor',      '0 */3 * * *'),
  ('Send v1 Assessment Invitations',      '0 */3 * * *'),
  ('Detect Assessment Invite Bounces',    '0 */6 * * *'),      -- a bounce is never urgent
  ('time_clock_edit_notifier',            '0 9,13,17 * * *'),  -- 3x on the workday
  ('Cash Register Alert Ingestor',        '0 */3 * * *'),
  ('Cash Register GL Writer',             '0 */6 * * *')
) AS v(name, expr)
WHERE automation_recipes.recipe_name = v.name
  AND automation_recipes.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- Reference Figures: 47 figures, one per run because the search response overflows
-- the model request ceiling. New federal figures publish in the fall, so Nov and Dec
-- are the window; January was dead weight. Twice a day drains all 47 in ~24 days
-- inside a 61-day window, then it no-ops for the rest.
UPDATE public.automation_recipes
   SET cron_expression = '0 6,14 * 11,12 *', updated_at = NOW()
 WHERE recipe_name = 'Reference Figures Annual Refresh'
   AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
