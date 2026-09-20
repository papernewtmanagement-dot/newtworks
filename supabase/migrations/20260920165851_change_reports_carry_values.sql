-- The CPR change report line and the Change history tab both carry the before
-- and after values now, built by change_diff / change_diff_text so there is
-- one place that decides how a field is named and how a value is written.

DROP FUNCTION IF EXISTS public.production_changes_for_day(uuid, date);
DROP FUNCTION IF EXISTS public.production_changes_for_range(uuid, date, date);

CREATE FUNCTION public.production_changes_for_range(p_agency_id uuid, p_start date, p_end date)
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
           NULLIF(btrim(COALESCE(r.new_row->>'spot_check_note', '')), '') AS spot_note
      FROM raw r ORDER BY r.txid, r.rank, r.changed_at
  ), grouped AS (
    SELECT t.*, (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid)::integer AS row_count,
           public.change_diff(p_agency_id, t.changed_fields, t.old_row, t.new_row) AS changes,
           public.change_diff_text(p_agency_id, t.changed_fields, t.old_row, t.new_row) AS diff_text
      FROM top t
  )
  SELECT g.txid, g.changed_at, g.changed_by_team_member_id,
         COALESCE(g.changed_by_label, 'Unknown') AS who, g.what, g.item,
         g.subject, g.changed_fields, g.changes, g.row_count,
         (to_char(g.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
          COALESCE(g.changed_by_label, 'Unknown') || ' ' || g.what || ' a ' || lower(g.item) ||
          COALESCE(' — ' || g.subject, '') ||
          CASE WHEN g.what = 'edited' THEN COALESCE(' (' || g.diff_text || ')', '') ELSE '' END ||
          CASE WHEN g.row_count > 1 THEN ' [' || g.row_count || ' records]' ELSE '' END ||
          COALESCE(' — spot-check: ' || g.spot_note, '')) AS line
    FROM grouped g
   ORDER BY g.changed_at DESC;
$function$;

CREATE FUNCTION public.production_changes_for_day(p_agency_id uuid, p_day date DEFAULT NULL::date)
RETURNS TABLE(txid bigint, changed_at timestamp with time zone, who text, what text, item text,
              subject text, changed_fields text[], changes jsonb, row_count integer, line text)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT r.txid, r.changed_at, r.who, r.what, r.item, r.subject,
         r.changed_fields, r.changes, r.row_count, r.line
    FROM public.production_changes_for_range(
           p_agency_id,
           COALESCE(p_day, public.rp_today_central()),
           COALESCE(p_day, public.rp_today_central())) r
   ORDER BY r.changed_at DESC;
$function$;

DROP FUNCTION IF EXISTS public.change_log_recent(integer, uuid, integer);

CREATE FUNCTION public.change_log_recent(p_days integer DEFAULT 30, p_team_member_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 300)
RETURNS TABLE(id uuid, changed_at timestamp with time zone, txid bigint, who text, via text,
              action text, item text, table_name text, row_id uuid, subject text,
              changed_fields text[], changes jsonb, old_row jsonb, new_row jsonb)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.id, c.changed_at, c.txid, c.changed_by_label, c.via, c.action,
         CASE c.table_name
           WHEN 'sales_log'              THEN 'Sale'
           WHEN 'sales_log_products'     THEN 'Sold policy'
           WHEN 'quote_log'              THEN 'Quote'
           WHEN 'quote_log_products'     THEN 'Quoted product'
           WHEN 'cancelation_log'        THEN 'Cancelation'
           WHEN 'retention_activity_log' THEN 'Activity'
           WHEN 'fit_scorecards'         THEN 'FIT scorecard'
           ELSE c.table_name
         END,
         c.table_name, c.row_id, c.subject, c.changed_fields,
         public.change_diff('126794dd-25ff-47d2-a436-724499733365'::uuid, c.changed_fields, c.old_row, c.new_row),
         c.old_row, c.new_row
    FROM public.change_log c
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
     AND c.changed_at >= now() - make_interval(days => GREATEST(COALESCE(p_days, 30), 1))
     AND (p_team_member_id IS NULL
          OR c.changed_by_team_member_id = p_team_member_id
          OR (COALESCE(c.new_row, c.old_row) ->> 'team_member_id') = p_team_member_id::text)
   ORDER BY c.changed_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 300), 1), 1000);
$function$;
