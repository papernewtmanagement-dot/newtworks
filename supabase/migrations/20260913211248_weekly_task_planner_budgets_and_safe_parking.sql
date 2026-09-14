-- Real budgets.
UPDATE public.task_scoring_rules SET hours_value = 10.00, updated_at = now()
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND rule_kind='setting' AND match_pattern='weekly_hours_peter';
UPDATE public.task_scoring_rules SET hours_value = 6.00, updated_at = now()
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND rule_kind='setting' AND match_pattern='weekly_hours_marie';

-- Nothing is ever parked without a recorded reason and date.
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS parked_reason text;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS parked_at timestamptz;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS stuck_since date;

COMMENT ON COLUMN public.tasks.parked_reason IS
  'Why this left the active pool. Always populated when backlog_state becomes someday. Parking is a holding shelf, never a delete.';
COMMENT ON COLUMN public.tasks.stuck_since IS
  'Set when an important task keeps rolling over. Important work does not get parked. It gets surfaced, because repeated rollover on something that matters means it is too big or it is blocked, not that it is unimportant.';

-- Importance floor. Above this, a task can never be auto-parked.
INSERT INTO public.task_scoring_rules
  (agency_id, rule_kind, match_pattern, importance_value, notes, priority)
VALUES ('126794dd-25ff-47d2-a436-724499733365','setting','park_protect_importance',70,
 'A task scoring at or above this importance is never auto-parked, no matter how long it sits or how often it rolls over. Back burner is a legitimate place for important work.',50)
ON CONFLICT DO NOTHING;