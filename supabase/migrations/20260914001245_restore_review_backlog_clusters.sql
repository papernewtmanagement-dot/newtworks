-- The cluster sheet. One decision per cluster instead of one per task.
-- Created 2026-09-13 in migration 20260913211437 alongside build_weekly_focus,
-- but absent from pg_proc on 2026-09-14. Restored byte-for-byte from the ledger.
CREATE OR REPLACE FUNCTION public.review_backlog_clusters(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'
)
RETURNS TABLE (
  cluster text, items int, hours numeric, top_importance int,
  oldest date, last_human_touch date, owner text
)
LANGUAGE sql STABLE
AS $fn$
  SELECT COALESCE(left(p.title,60), '(no parent) — '||COALESCE(t.task_category,'uncategorized')) AS cluster,
         count(*)::int,
         ROUND(SUM(t.estimated_hours),1),
         MAX(t.importance)::int,
         MIN(t.created_at)::date,
         MAX(t.updated_at)::date,
         COALESCE(string_agg(DISTINCT split_part(u.full_name,' ',1), '/'), 'unassigned')
  FROM tasks t
  LEFT JOIN tasks p ON p.id = t.parent_task_id
  LEFT JOIN users u ON u.id = t.assigned_to
  WHERE t.agency_id = p_agency_id AND t.status='open'
    AND t.backlog_state='active' AND t.task_type <> 'epic'
  GROUP BY 1
  ORDER BY count(*) DESC;
$fn$;