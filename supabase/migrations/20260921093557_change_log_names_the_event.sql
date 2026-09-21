-- Peter 2026-09-21: the change log should say what happened, not list raw
-- fields. A policy going from no issue date and no issued premium to both is
-- "Policy issued", not two separate blank -> value lines.
--
-- change_items is the one place that turns a change record into what the
-- screens show. It names the recognised events first, then hands every field
-- the events did not already explain to change_diff, which is unchanged.
-- change_log_recent and production_changes_for_range both read it.

CREATE OR REPLACE FUNCTION public.change_items(p_agency uuid, p_table text, p_action text,
                                               p_fields text[], p_old jsonb, p_new jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  f     text[] := COALESCE(p_fields, ARRAY[]::text[]);
  used  text[] := ARRAY[]::text[];
  ev    jsonb  := '[]'::jsonb;
  item  text   := CASE p_table
                    WHEN 'sales_log'              THEN 'Sale'
                    WHEN 'sales_log_products'     THEN 'Policy'
                    WHEN 'quote_log'              THEN 'Quote'
                    WHEN 'quote_log_products'     THEN 'Quoted product'
                    WHEN 'cancelation_log'        THEN 'Cancelation'
                    WHEN 'retention_activity_log' THEN 'Activity'
                    WHEN 'fit_scorecards'         THEN 'Conversation score'
                    WHEN 'appointment_log'        THEN 'Appointment'
                    ELSE 'Record' END;
  o_st  text := lower(COALESCE(p_old ->> 'status', ''));
  n_st  text := lower(COALESCE(p_new ->> 'status', ''));
  det   text;
BEGIN
  IF lower(COALESCE(p_action, '')) <> 'update' THEN RETURN '[]'::jsonb; END IF;

  -- Taken out, or put back.
  IF 'status' = ANY(f) AND n_st IN ('void', 'voided') AND o_st NOT IN ('void', 'voided') THEN
    det := NULLIF(btrim(COALESCE(p_new ->> 'void_reason', '')), '');
    ev := ev || jsonb_build_object('event', true, 'field', 'event:removed', 'tone', 'red',
                                   'label', item || ' removed', 'after', det);
    used := used || ARRAY['status', 'void_reason', 'voided_at', 'voided_by'];
  ELSIF 'status' = ANY(f) AND o_st IN ('void', 'voided') AND n_st NOT IN ('void', 'voided') THEN
    ev := ev || jsonb_build_object('event', true, 'field', 'event:restored', 'tone', 'green',
                                   'label', item || ' put back', 'after', NULL);
    used := used || ARRAY['status', 'void_reason', 'voided_at', 'voided_by'];
  END IF;

  -- Issued, or the issue taken off.
  IF p_table = 'sales_log_products' AND 'issued_date' = ANY(f) THEN
    IF NULLIF(p_old ->> 'issued_date', '') IS NULL AND NULLIF(p_new ->> 'issued_date', '') IS NOT NULL THEN
      det := public.change_value_text(p_agency, 'issued_date', p_new -> 'issued_date');
      IF NULLIF(p_new ->> 'issued_premium', '') IS NOT NULL THEN
        det := det || ' at ' || public.change_value_text(p_agency, 'issued_premium', p_new -> 'issued_premium');
        IF 'issued_premium' = ANY(f) AND NULLIF(p_old ->> 'issued_premium', '') IS NULL THEN
          used := used || 'issued_premium';
        END IF;
      END IF;
      ev := ev || jsonb_build_object('event', true, 'field', 'event:issued', 'tone', 'green',
                                     'label', 'Policy issued', 'after', det);
      used := used || 'issued_date';
    ELSIF NULLIF(p_old ->> 'issued_date', '') IS NOT NULL AND NULLIF(p_new ->> 'issued_date', '') IS NULL THEN
      det := 'was ' || public.change_value_text(p_agency, 'issued_date', p_old -> 'issued_date');
      IF NULLIF(p_old ->> 'issued_premium', '') IS NOT NULL THEN
        det := det || ' at ' || public.change_value_text(p_agency, 'issued_premium', p_old -> 'issued_premium');
        IF 'issued_premium' = ANY(f) AND NULLIF(p_new ->> 'issued_premium', '') IS NULL THEN
          used := used || 'issued_premium';
        END IF;
      END IF;
      ev := ev || jsonb_build_object('event', true, 'field', 'event:unissued', 'tone', 'red',
                                     'label', 'Marked not issued', 'after', det);
      used := used || 'issued_date';
    END IF;
  END IF;

  -- Issued premium filled in on a policy already issued. Shows the written
  -- premium beside it when the two differ, since that is what moved the points.
  IF p_table = 'sales_log_products' AND 'issued_premium' = ANY(f) AND NOT ('issued_premium' = ANY(used))
     AND NULLIF(p_old ->> 'issued_premium', '') IS NULL AND NULLIF(p_new ->> 'issued_premium', '') IS NOT NULL THEN
    det := public.change_value_text(p_agency, 'issued_premium', p_new -> 'issued_premium');
    IF NULLIF(p_new ->> 'premium', '') IS NOT NULL
       AND (p_new ->> 'premium')::numeric IS DISTINCT FROM (p_new ->> 'issued_premium')::numeric THEN
      det := det || ' (written ' || public.change_value_text(p_agency, 'premium', p_new -> 'premium') || ')';
    END IF;
    ev := ev || jsonb_build_object('event', true, 'field', 'event:issued_premium', 'tone', 'amber',
                                   'label', 'Issued premium entered', 'after', det);
    used := used || 'issued_premium';
  END IF;

  -- Spot-check verified, or the check cleared.
  IF 'verified_at' = ANY(f) THEN
    IF NULLIF(p_old ->> 'verified_at', '') IS NULL AND NULLIF(p_new ->> 'verified_at', '') IS NOT NULL THEN
      ev := ev || jsonb_build_object('event', true, 'field', 'event:verified', 'tone', 'green',
                                     'label', 'Spot-check verified', 'after', NULL);
    ELSIF NULLIF(p_old ->> 'verified_at', '') IS NOT NULL AND NULLIF(p_new ->> 'verified_at', '') IS NULL THEN
      ev := ev || jsonb_build_object('event', true, 'field', 'event:unverified', 'tone', 'amber',
                                     'label', 'Spot-check cleared', 'after', NULL);
    END IF;
    used := used || ARRAY['verified_at', 'verified_by'];
  END IF;

  -- A cancelation marked as already charged back when it happened.
  IF p_table = 'cancelation_log' AND 'already_charged_back' = ANY(f) THEN
    ev := ev || jsonb_build_object('event', true, 'field', 'event:charged_back', 'tone', 'amber',
                                   'label', CASE WHEN (p_new ->> 'already_charged_back')::boolean
                                                 THEN 'Marked already charged back'
                                                 ELSE 'Marked not yet charged back' END,
                                   'after', NULL);
    used := used || 'already_charged_back';
  END IF;

  RETURN ev || public.change_diff(p_agency,
                 ARRAY(SELECT x FROM unnest(f) AS u(x) WHERE NOT (x = ANY(used))),
                 p_old, p_new);
END $function$;

COMMENT ON FUNCTION public.change_items(uuid, text, text, text[], jsonb, jsonb) IS
'What a change record shows on screen. Named events first (Policy issued, Marked not issued, Issued premium entered, <item> removed / put back, Spot-check verified, Marked already charged back), each {event:true, field, label, after, tone}; then change_diff over every field the events did not explain. The one reader for change_log_recent and production_changes_for_range.';

CREATE OR REPLACE FUNCTION public.change_log_recent(p_days integer DEFAULT 30, p_team_member_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 300)
 RETURNS TABLE(id uuid, changed_at timestamp with time zone, txid bigint, who text, via text, action text, item text, table_name text, row_id uuid, subject text, changed_fields text[], changes jsonb, old_row jsonb, new_row jsonb)
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
         public.change_items(c.agency_id, c.table_name, c.action, c.changed_fields, c.old_row, c.new_row),
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

CREATE OR REPLACE FUNCTION public.production_changes_for_range(p_agency_id uuid, p_start date, p_end date)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, team_member_id uuid, who text, what text, item text, subject text, changed_fields text[], changes jsonb, row_count integer, line text)
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
             ELSE 'edited' END AS what,
           -- what actually changed about the record, leaving out the three
           -- columns the spot-check itself writes
           ARRAY(SELECT f FROM unnest(COALESCE(c.changed_fields, ARRAY[]::text[])) AS u(f)
                  WHERE f NOT IN ('verified_at', 'verified_by', 'spot_check_note')) AS edit_fields
      FROM public.change_log c, gate g
     WHERE g.ok
       AND c.agency_id = p_agency_id
       AND c.changed_at >= p_start::timestamptz
       AND c.changed_at <  (p_end + 1)::timestamptz
       AND lower(c.action) IN ('update', 'delete')
       AND COALESCE(c.via, '') <> 'automation'
  ),
  -- Every field that moved anywhere inside one click. A sale and the policy
  -- line under it are one click, so both sets of values belong on one line.
  -- The same move repeated across records is shown once with a count.
  diff_rows AS (
    SELECT r.txid, e.val, count(*)::integer AS n, min(r.rank * 1000 + e.ord) AS ord
      FROM raw r
      CROSS JOIN LATERAL jsonb_array_elements(
             public.change_items(p_agency_id, r.table_name, r.action, r.edit_fields, r.old_row, r.new_row)
           ) WITH ORDINALITY AS e(val, ord)
     WHERE lower(r.action) = 'update'
     GROUP BY r.txid, e.val
  ),
  diffs AS (
    SELECT d.txid,
           jsonb_agg(d.val || jsonb_build_object('count', d.n) ORDER BY d.ord) AS changes
      FROM diff_rows d GROUP BY d.txid
  ), top AS (
    SELECT DISTINCT ON (r.txid)
           r.txid, r.changed_at, r.row_id, r.changed_by_team_member_id, r.changed_by_label,
           r.what, r.item, r.subject, r.edit_fields,
           NULLIF(btrim(COALESCE(r.new_row->>'spot_check_note', '')), '') AS spot_note
      FROM raw r ORDER BY r.txid, r.rank, r.changed_at
  ), grouped AS (
    SELECT t.*,
           COALESCE(d.changes, '[]'::jsonb) AS changes,
           (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t LEFT JOIN diffs d ON d.txid = t.txid
     WHERE t.what <> 'edited'
        OR d.changes IS NOT NULL
        OR t.spot_note IS NOT NULL
  ), deduped AS (
    SELECT DISTINCT ON (
             CASE WHEN g.changes = '[]'::jsonb AND g.spot_note IS NOT NULL
                  THEN g.row_id::text || '|' || g.spot_note
                  ELSE g.txid::text END) g.*
      FROM grouped g
     ORDER BY
       CASE WHEN g.changes = '[]'::jsonb AND g.spot_note IS NOT NULL
            THEN g.row_id::text || '|' || g.spot_note
            ELSE g.txid::text END,
       g.changed_at
  )
  SELECT d.txid, d.changed_at, d.changed_by_team_member_id,
         COALESCE(d.changed_by_label, 'Unknown') AS who, d.what, d.item,
         d.subject, d.edit_fields, d.changes, d.row_count,
         (to_char(d.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
          COALESCE(d.changed_by_label, 'Unknown') || ' ' || d.what ||
          CASE WHEN lower(d.item) ~ '^[aeiou]' THEN ' an ' ELSE ' a ' END || lower(d.item) ||
          COALESCE(' — ' || d.subject, '') ||
          COALESCE(' (' || (
            SELECT string_agg(
                     CASE
                       -- "removed a sale" already says it; keep only the reason
                       WHEN c.val->>'field' = 'event:removed' THEN 'reason: ' || (c.val->>'after')
                       WHEN (c.val->>'event')::boolean THEN (c.val->>'label') || COALESCE(': ' || (c.val->>'after'), '')
                       ELSE (c.val->>'label') || ': ' || (c.val->>'before') || ' → ' || (c.val->>'after')
                     END
                     || CASE WHEN (c.val->>'count')::int > 1 THEN ' ×' || (c.val->>'count') ELSE '' END,
                     '; ' ORDER BY c.ord)
              FROM jsonb_array_elements(d.changes) WITH ORDINALITY AS c(val, ord)
             WHERE c.ord <= 6
               AND NOT (c.val->>'field' = 'event:removed' AND c.val->>'after' IS NULL)
          ) || CASE WHEN jsonb_array_length(d.changes) > 6
                    THEN '; and ' || (jsonb_array_length(d.changes) - 6) || ' more' ELSE '' END
          || ')', '') ||
          CASE WHEN d.row_count > 1 THEN ' [' || d.row_count || ' records]' ELSE '' END ||
          COALESCE(' — spot-check: ' || d.spot_note, '')) AS line
    FROM deduped d
   ORDER BY d.changed_at DESC;
$function$;
