-- The Changes tab reads newest first everywhere else. The one-day view was the
-- odd one out, oldest first (Peter 2026-09-15). Only the final ORDER BY changes.
CREATE OR REPLACE FUNCTION public.production_changes_for_day(p_agency_id uuid, p_day date DEFAULT NULL::date)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, who text, what text, item text, subject text, changed_fields text[], row_count integer, line text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH d AS (SELECT COALESCE(p_day, public.rp_today_central()) AS day),
  raw AS (
    SELECT c.*,
           CASE c.table_name
             WHEN 'sales_log' THEN 'Sale' WHEN 'sales_log_products' THEN 'Sold policy'
             WHEN 'quote_log' THEN 'Quote' WHEN 'quote_log_products' THEN 'Quoted product'
             WHEN 'cancelation_log' THEN 'Cancelation'
             WHEN 'retention_activity_log' THEN 'Activity'
             WHEN 'fit_scorecards' THEN 'Conversation score' ELSE c.table_name END AS item,
           CASE c.table_name
             WHEN 'sales_log' THEN 1 WHEN 'quote_log' THEN 1 WHEN 'cancelation_log' THEN 1
             WHEN 'fit_scorecards' THEN 1 WHEN 'retention_activity_log' THEN 2 ELSE 3 END AS rank,
           CASE
             WHEN lower(c.action) = 'delete' THEN 'removed'
             WHEN lower(c.action) = 'update' AND COALESCE(c.new_row->>'status','') IN ('void','voided')
                  AND COALESCE(c.old_row->>'status','') NOT IN ('void','voided') THEN 'removed'
             ELSE 'edited' END AS what
      FROM public.change_log c, d
     WHERE c.agency_id = p_agency_id
       AND c.changed_at >= d.day::timestamptz
       AND c.changed_at <  (d.day + 1)::timestamptz
       AND lower(c.action) IN ('update', 'delete')
       AND COALESCE(c.via, '') <> 'automation'
  ), top AS (
    SELECT DISTINCT ON (r.txid) r.txid, r.changed_at, r.changed_by_label, r.what, r.item, r.subject, r.changed_fields
      FROM raw r ORDER BY r.txid, r.rank, r.changed_at
  ), grouped AS (
    SELECT t.*, (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t
  )
  SELECT g.txid, g.changed_at, COALESCE(g.changed_by_label, 'Unknown') AS who, g.what, g.item,
         g.subject, g.changed_fields, g.row_count,
         (to_char(g.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
          COALESCE(g.changed_by_label, 'Unknown') || ' ' || g.what || ' a ' || lower(g.item) ||
          COALESCE(' — ' || g.subject, '') ||
          CASE WHEN g.what = 'edited' AND g.changed_fields IS NOT NULL AND array_length(g.changed_fields, 1) > 0
               THEN ' (' || array_to_string(g.changed_fields, ', ') || ')' ELSE '' END ||
          CASE WHEN g.row_count > 1 THEN ' [' || g.row_count || ' records]' ELSE '' END) AS line
    FROM grouped g
   ORDER BY g.changed_at DESC;
$function$;
