-- 1. Peter ruling 2026-09-13: the backlog starts its clock today.
ALTER TABLE public.tasks DISABLE TRIGGER trg_tasks_updated;
UPDATE public.tasks SET updated_at = now()
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND status='open';
ALTER TABLE public.tasks ENABLE TRIGGER trg_tasks_updated;

-- 2. Close the John Kostov offboarding work. Children first, then the parent story.
UPDATE public.tasks
   SET status='closed', completed_at=now(), in_weekly_focus=false, scheduled_day=NULL
 WHERE status='open'
   AND parent_task_id='53284fab-c342-4f0f-ae20-572a8e115330';

UPDATE public.tasks
   SET status='closed', completed_at=now(), in_weekly_focus=false, scheduled_day=NULL
 WHERE status='open'
   AND id IN ('53284fab-c342-4f0f-ae20-572a8e115330',   -- Offboard John Kostov (story)
              '6cc6b24b-10a9-452d-950b-ab5e12ae30d2');  -- John 1:1 talking point, moot now

-- 3. Close the four orphaned onboarding rows. Their parent plan no longer exists:
--    zero rows in team_onboarding_plans, and all four related_id values point at deleted steps.
UPDATE public.tasks
   SET status='closed', completed_at=now(), in_weekly_focus=false, scheduled_day=NULL
 WHERE status='open' AND created_by='onboarding_plan'
   AND title ILIKE 'Onboarding — Peter Story%';

-- 4. Reopen the Books cleanup epic. Seven of its children are still live.
UPDATE public.tasks
   SET status='open', completed_at=NULL
 WHERE id='85422c91-7ebd-486c-80a9-ed5da79d3016';