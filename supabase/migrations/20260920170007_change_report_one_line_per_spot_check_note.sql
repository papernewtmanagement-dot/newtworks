-- Saving a spot-check note and then ticking Verified are two writes, and both
-- carry the note, so the report printed the same coaching line twice. When a
-- row changed nothing about the record and only carries a note, keep one line
-- per record per note. Rows that changed something real are never collapsed.

CREATE OR REPLACE FUNCTION public.production_changes_for_range(p_agency_id uuid, p_start date, p_end date)
RETURNS TABLE(txid bigint, changed_at timestamp with time zone, team_member_id uuid, who text,
              what text, item text, subject text, changed_fields text[], changes jsonb,
              row_count integer, line text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH gate AS (
    SELECT (public.current_team_member_id() IS NOT NULL
            OR current_user IN ('postgres', 'supabase_admin', 'service_role')) AS ok
  ),
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
      FROM public.change_log c, gate g
     WHERE g.ok
       AND c.agency_id = p_agency_id
       AND c.changed_at >= p_start::timestamptz
       AND c.changed_at <  (p_end + 1)::timestamptz
       AND lower(c.action) IN ('update', 'delete')
       AND COALESCE(c.via, '') <> 'automation'
  ), top AS (
    SELECT DISTINCT ON (r.txid)
           r.txid, r.changed_at, r.row_id, r.changed_by_team_member_id, r.changed_by_label,
           r.what, r.item, r.subject, r.changed_fields, r.old_row, r.new_row,
           NULLIF(btrim(COALESCE(r.new_row->>'spot_check_note', '')), '') AS spot_note,
           -- what actually changed about the record, leaving out the three
           -- columns the spot-check itself writes
           ARRAY(SELECT f FROM unnest(COALESCE(r.changed_fields, ARRAY[]::text[])) AS u(f)
                  WHERE f NOT IN ('verified_at', 'verified_by', 'spot_check_note')) AS edit_fields
      FROM raw r ORDER BY r.txid, r.rank, r.changed_at
  ), grouped AS (
    SELECT t.*, (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid)::integer AS row_count,
           public.change_diff(p_agency_id, t.edit_fields, t.old_row, t.new_row) AS changes,
           public.change_diff_text(p_agency_id, t.edit_fields, t.old_row, t.new_row) AS diff_text
      FROM top t
     WHERE t.what <> 'edited'
        OR public.change_diff_text(p_agency_id, t.edit_fields, t.old_row, t.new_row) IS NOT NULL
        OR t.spot_note IS NOT NULL
  ), deduped AS (
    SELECT DISTINCT ON (
             CASE WHEN g.diff_text IS NULL AND g.spot_note IS NOT NULL
                  THEN g.row_id::text || '|' || g.spot_note
                  ELSE g.txid::text END) g.*
      FROM grouped g
     ORDER BY
       CASE WHEN g.diff_text IS NULL AND g.spot_note IS NOT NULL
            THEN g.row_id::text || '|' || g.spot_note
            ELSE g.txid::text END,
       g.changed_at
  )
  SELECT d.txid, d.changed_at, d.changed_by_team_member_id,
         COALESCE(d.changed_by_label, 'Unknown') AS who, d.what, d.item,
         d.subject, d.edit_fields, d.changes, d.row_count,
         (to_char(d.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
          COALESCE(d.changed_by_label, 'Unknown') || ' ' || d.what ||
          CASE WHEN left(lower(d.item), 1) IN ('a','e','i','o','u') THEN ' an ' ELSE ' a ' END ||
          lower(d.item) ||
          COALESCE(' — ' || d.subject, '') ||
          CASE WHEN d.what = 'edited' THEN COALESCE(' (' || d.diff_text || ')', '') ELSE '' END ||
          CASE WHEN d.row_count > 1 THEN ' [' || d.row_count || ' records]' ELSE '' END ||
          COALESCE(' — spot-check: ' || d.spot_note, '')) AS line
    FROM deduped d
   ORDER BY d.changed_at DESC;
$function$;
