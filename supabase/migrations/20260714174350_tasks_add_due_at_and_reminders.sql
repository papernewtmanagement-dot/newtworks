-- Widen tasks with a datetime-precise due_at + Telegram reminder plumbing.
-- Legacy due_date (DATE) stays as-is for backwards compat. When due_at is set,
-- the reminder cron uses that. When only due_date is set, no reminder fires.

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS due_at timestamptz,
  ADD COLUMN IF NOT EXISTS remind_via_telegram boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS reminded_at timestamptz;

COMMENT ON COLUMN public.tasks.due_at IS
  'Optional datetime-precise due deadline. When remind_via_telegram=true, dispatch_task_reminders() DMs Peter <=60 min before this timestamp.';
COMMENT ON COLUMN public.tasks.remind_via_telegram IS
  'When true and due_at set and status open, dispatch_task_reminders() sends a Telegram DM to Peter and stamps reminded_at.';
COMMENT ON COLUMN public.tasks.reminded_at IS
  'Set by dispatch_task_reminders() after successful send. Cleared automatically when due_at is bumped to a future timestamp (tg_task_due_at_reset_reminder).';

-- When due_at bumps forward, clear reminded_at so the new deadline re-arms.
CREATE OR REPLACE FUNCTION public.reset_task_reminded_at_on_due_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.due_at IS DISTINCT FROM OLD.due_at
     AND NEW.due_at IS NOT NULL
     AND NEW.due_at > NOW() THEN
    NEW.reminded_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_task_due_at_reset_reminder ON public.tasks;
CREATE TRIGGER tg_task_due_at_reset_reminder
BEFORE UPDATE ON public.tasks
FOR EACH ROW EXECUTE FUNCTION public.reset_task_reminded_at_on_due_change();

-- Partial index so the reminder cron's WHERE clause stays sub-ms.
CREATE INDEX IF NOT EXISTS idx_tasks_reminder_scan
  ON public.tasks (due_at)
  WHERE remind_via_telegram = true AND reminded_at IS NULL AND status = 'open' AND due_at IS NOT NULL;
