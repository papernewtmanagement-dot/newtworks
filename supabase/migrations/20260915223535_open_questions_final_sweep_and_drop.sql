-- Final sweep and retirement of open_questions.
-- Peter 2026-09-15: "Move them to tasks and then drop the table."
-- Five rows landed here from concurrent sessions after the main fold. Same mapping,
-- then the table goes so nothing can write to it again.

-- Snapshot keeps growing so the undo point stays complete.
INSERT INTO public.open_questions_snapshot_20260915
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
  CASE WHEN q.priority = 'someday' THEN 'someday' ELSE 'active' END,
  false,
  'auto',
  'auto',
  q.opened_at,
  now()
FROM public.open_questions q
WHERE q.status = 'open';

-- The table goes. Its three trigger functions exist only for it and go with it.
DROP TABLE public.open_questions;
DROP FUNCTION IF EXISTS public.tg_open_questions_updated_at();
DROP FUNCTION IF EXISTS public.tg_open_questions_no_resolved_insert();
DROP FUNCTION IF EXISTS public.tg_open_questions_resolve_deletes();
