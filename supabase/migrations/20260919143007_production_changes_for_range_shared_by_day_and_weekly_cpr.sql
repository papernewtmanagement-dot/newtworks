-- One implementation of "what changed in the production logs", over any window.
-- production_changes_for_day now delegates to it, so the daily alert, the Telegram
-- note, the Activity Log Changes tab and the weekly CPR all read the same rows
-- from the same code. No second copy of the grouping/labelling logic anywhere.
--
-- SECURITY DEFINER on purpose: change_log RLS is owner/manager only, but the
-- weekly CPR is a team-facing page and the whole point of the new section is that
-- every teammate can see the week's edits. The gate below replaces the RLS check:
-- any signed-in team member, or a trusted server role (automation runner, service
-- role). PUBLIC and anon are revoked from both functions at the bottom.
CREATE OR REPLACE FUNCTION public.production_changes_for_range(
  p_agency_id uuid,
  p_start     date,
  p_end       date
)
RETURNS TABLE(
  txid           bigint,
  changed_at     timestamp with time zone,
  team_member_id uuid,
  who            text,
  what           text,
  item           text,
  subject        text,
  changed_fields text[],
  row_count      integer,
  line           text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
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
           r.what, r.item, r.subject, r.changed_fields
      FROM raw r ORDER BY r.txid, r.rank, r.changed_at
  ), grouped AS (
    SELECT t.*, (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t
  )
  SELECT g.txid, g.changed_at, g.changed_by_team_member_id,
         COALESCE(g.changed_by_label, 'Unknown') AS who, g.what, g.item,
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

COMMENT ON FUNCTION public.production_changes_for_range(uuid, date, date) IS
  'Edits and removals made to the production logs between p_start and p_end inclusive, one row per save (grouped by txid). Single source for the daily change alert, the Activity Log Changes tab and the weekly CPR Log Changes section.';

-- Day view is now a thin window over the range function. Same columns as before,
-- so every existing caller keeps working untouched.
CREATE OR REPLACE FUNCTION public.production_changes_for_day(
  p_agency_id uuid,
  p_day       date DEFAULT NULL::date
)
RETURNS TABLE(
  txid bigint, changed_at timestamp with time zone, who text, what text, item text,
  subject text, changed_fields text[], row_count integer, line text
)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT r.txid, r.changed_at, r.who, r.what, r.item, r.subject,
         r.changed_fields, r.row_count, r.line
    FROM public.production_changes_for_range(
           p_agency_id,
           COALESCE(p_day, public.rp_today_central()),
           COALESCE(p_day, public.rp_today_central())) r
   ORDER BY r.changed_at DESC;
$function$;

REVOKE EXECUTE ON FUNCTION public.production_changes_for_range(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.production_changes_for_day(uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.production_changes_for_day(uuid, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.production_changes_for_range(uuid, date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.production_changes_for_day(uuid, date) TO authenticated, service_role;
