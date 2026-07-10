-- Weekly refresh of team trajectory summaries.
-- Sunday 13:00 UTC = 7:00 AM CST (winter) / 8:00 AM CDT (summer). Once a week is plenty —
-- behavioral notes accumulate slowly and Peter can trigger on-demand via the UI button.
SELECT cron.schedule(
  'weekly_team_trajectory_refresh',
  '0 13 * * 0',
  $$SELECT public.team_trajectory_recompute(NULL::uuid, true);$$
);
