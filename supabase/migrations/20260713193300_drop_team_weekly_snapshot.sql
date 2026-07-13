-- Consolidation complete: all readers pull snapshot data from
-- weekly_cpr_team_detail cols. team_weekly_snapshot is unused.
DROP TRIGGER IF EXISTS trg_snapshot_team_on_weekly_cpr_reports_insert ON public.weekly_cpr_reports;
DROP FUNCTION IF EXISTS public.snapshot_team_on_weekly_cpr_reports_insert();
DROP TABLE IF EXISTS public.team_weekly_snapshot;
