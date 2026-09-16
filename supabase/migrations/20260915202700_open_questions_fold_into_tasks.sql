-- Fold open_questions into tasks so the weekly planner can see them.
-- Peter 2026-09-15: "We just need to fold those open questions into tasks."
-- A display-only overlay would not work: score_tasks and build_weekly_focus both
-- read public.tasks, so a question that is not a task row never gets scored,
-- never gets hours, and never lands in a week.

-- Undo point. Full copy of every row as it stood before the move.
CREATE TABLE IF NOT EXISTS public.open_questions_snapshot_20260915 AS
SELECT * FROM public.open_questions;

INSERT INTO public.tasks (
  agency_id, title, description, assigned_to, created_by,
  priority, status, task_type, task_category,
  backlog_state, in_weekly_focus,
  priority_source, estimated_hours_source,
  created_at, updated_at
)
SELECT
  q.agency_id,
  q.title,
  -- The question text stays verbatim. Domain and the surfacing note are kept
  -- as their own lines so nothing that was written is lost in the move.
  concat_ws(E'\n\n',
    q.question,
    CASE WHEN q.domain IS NOT NULL THEN 'Domain: ' || q.domain END,
    CASE WHEN q.trigger_condition IS NOT NULL THEN 'Surface when: ' || q.trigger_condition END,
    CASE WHEN q.related_session_note IS NOT NULL THEN 'Session note: ' || q.related_session_note END
  ),
  '6f0fa5c3-1bb9-4e96-8e6f-33705c89aa95'::uuid,   -- Peter
  'open question',
  CASE q.priority WHEN 'urgent' THEN 'high' WHEN 'someday' THEN 'low' ELSE 'medium' END,
  'open',
  'task',
  CASE
    WHEN q.domain IN ('web_app','dev','developer','engineering','platform','infrastructure',
                      'tooling','technology','rls','schema','trivia','time_off_ui','hiregauge',
                      'leaderboard','automation','automations','cpr','production','retention_points')
      THEN 'web_app'
    WHEN q.domain IN ('accounting','financials','pfa','compensation','team_compensation')
      THEN 'finances'
    WHEN q.domain IN ('hiring','recruiting','onboarding','team','team_operations','teaching')
      THEN 'team_development'
    WHEN q.domain IN ('marketing') THEN 'marketing'
    WHEN q.domain IN ('handbook') THEN 'handbook'
    WHEN q.domain IN ('manuals','newtworks_manuals','processes','processes_manual','operations')
      THEN 'processes'
    WHEN q.domain IN ('admin','compliance','retention') THEN 'admin'
    ELSE NULL
  END,
  -- someday questions keep sitting out of the weekly competition, as they already did.
  CASE WHEN q.priority = 'someday' THEN 'someday' ELSE 'active' END,
  false,
  'auto',   -- the Sunday run owns priority and hours from here
  'auto',
  q.opened_at,   -- history kept
  now()          -- staleness clock starts today, same as the 2026-09-13 ruling
FROM public.open_questions q
WHERE q.status = 'open';

-- Content is copied out, so the source rows go. Two homes for the same item is
-- the drift this move exists to end.
DELETE FROM public.open_questions;
