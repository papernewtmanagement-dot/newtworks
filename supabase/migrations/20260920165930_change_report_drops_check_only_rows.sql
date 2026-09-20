-- Two faults the values made visible on the CPR change report.
--   1. Ticking Verified is not a correction to the record, it is the check
--      itself, so every spot-check click was filling the report with
--      "edited an activity (verified: blank to Sep 19, 2026)" and a second
--      line for the note beside it. The report now ignores the three
--      check-keeping columns when it works out what changed, and drops a row
--      that has nothing left to say. A spot-check note still comes through,
--      because that is the point of leaving one.
--   2. It read "edited a activity". Now "an" in front of a vowel.
-- The Change history tab keeps showing all three columns. That tab is the
-- full record of who touched what, and hiding the check there would lose it.

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
           r.txid, r.changed_at, r.changed_by_team_member_id, r.changed_by_label,
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
  )
  SELECT g.txid, g.changed_at, g.changed_by_team_member_id,
         COALESCE(g.changed_by_label, 'Unknown') AS who, g.what, g.item,
         g.subject, g.edit_fields, g.changes, g.row_count,
         (to_char(g.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
          COALESCE(g.changed_by_label, 'Unknown') || ' ' || g.what ||
          CASE WHEN left(lower(g.item), 1) IN ('a','e','i','o','u') THEN ' an ' ELSE ' a ' END ||
          lower(g.item) ||
          COALESCE(' — ' || g.subject, '') ||
          CASE WHEN g.what = 'edited' THEN COALESCE(' (' || g.diff_text || ')', '') ELSE '' END ||
          CASE WHEN g.row_count > 1 THEN ' [' || g.row_count || ' records]' ELSE '' END ||
          COALESCE(' — spot-check: ' || g.spot_note, '')) AS line
    FROM grouped g
   WHERE g.what <> 'edited'
      OR g.diff_text IS NOT NULL
      OR g.spot_note IS NOT NULL
   ORDER BY g.changed_at DESC;
$function$;
