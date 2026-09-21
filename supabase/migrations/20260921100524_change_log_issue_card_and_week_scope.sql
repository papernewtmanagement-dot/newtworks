-- Peter 2026-09-21, round two on the change log.
--  * Issuing a policy is its own kind of entry, apart from edits. The Changes
--    tab toggles between the two; the CPR shows them as two cards.
--  * An issued entry says the issue date, the issued premium, and how far the
--    issued premium is from the submitted premium.
--  * A policy line under a sale reads as "a sale", not "a sold policy".
--  * A sale's total premium and car count filling in during the same click that
--    created it is the sale being saved, not a change. Left out everywhere.
--  * The CPR shows every change made that week, plus any change made later to a
--    policy that issued that week, since that is what moved that week's points.
--  * ECRM links read "ECRM link added" instead of printing the whole address.
--  * Day boundaries are Central time. They were midnight UTC, which put evening
--    changes on the next day.

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
  k     text;
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
          used := used || 'issued_premium'::text;
        END IF;
      END IF;
      ev := ev || jsonb_build_object('event', true, 'field', 'event:issued', 'tone', 'green',
                                     'label', 'Policy issued', 'after', det);
      used := used || 'issued_date'::text;
    ELSIF NULLIF(p_old ->> 'issued_date', '') IS NOT NULL AND NULLIF(p_new ->> 'issued_date', '') IS NULL THEN
      det := 'was ' || public.change_value_text(p_agency, 'issued_date', p_old -> 'issued_date');
      IF NULLIF(p_old ->> 'issued_premium', '') IS NOT NULL THEN
        det := det || ' at ' || public.change_value_text(p_agency, 'issued_premium', p_old -> 'issued_premium');
        IF 'issued_premium' = ANY(f) AND NULLIF(p_new ->> 'issued_premium', '') IS NULL THEN
          used := used || 'issued_premium'::text;
        END IF;
      END IF;
      ev := ev || jsonb_build_object('event', true, 'field', 'event:unissued', 'tone', 'red',
                                     'label', 'Marked not issued', 'after', det);
      used := used || 'issued_date'::text;
    END IF;
  END IF;

  -- Issued premium filled in on a policy already issued.
  IF p_table = 'sales_log_products' AND 'issued_premium' = ANY(f) AND NOT ('issued_premium' = ANY(used))
     AND NULLIF(p_old ->> 'issued_premium', '') IS NULL AND NULLIF(p_new ->> 'issued_premium', '') IS NOT NULL THEN
    det := public.change_value_text(p_agency, 'issued_premium', p_new -> 'issued_premium');
    IF NULLIF(p_new ->> 'premium', '') IS NOT NULL
       AND (p_new ->> 'premium')::numeric IS DISTINCT FROM (p_new ->> 'issued_premium')::numeric THEN
      det := det || ' (submitted ' || public.change_value_text(p_agency, 'premium', p_new -> 'premium') || ')';
    END IF;
    ev := ev || jsonb_build_object('event', true, 'field', 'event:issued_premium', 'tone', 'amber',
                                   'label', 'Issued premium entered', 'after', det);
    used := used || 'issued_premium'::text;
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
    used := used || 'already_charged_back'::text;
  END IF;

  -- ECRM links: say what happened to the link, not the whole address.
  FOREACH k IN ARRAY ARRAY['ecrm_opportunity_url', 'ecrm_url'] LOOP
    IF k = ANY(f) THEN
      ev := ev || jsonb_build_object('event', true, 'field', 'event:' || k, 'tone', 'slate',
                  'label', CASE
                             WHEN NULLIF(p_old ->> k, '') IS NULL THEN 'ECRM link added'
                             WHEN NULLIF(p_new ->> k, '') IS NULL THEN 'ECRM link removed'
                             ELSE 'ECRM link changed' END,
                  'after', NULL);
      used := used || k;
    END IF;
  END LOOP;

  RETURN ev || public.change_diff(p_agency,
                 ARRAY(SELECT x FROM unnest(f) AS u(x) WHERE NOT (x = ANY(used))),
                 p_old, p_new);
END $function$;

CREATE OR REPLACE FUNCTION public.change_log_recent(p_days integer DEFAULT 30, p_team_member_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 300)
 RETURNS TABLE(id uuid, changed_at timestamp with time zone, txid bigint, who text, via text, action text, item text, table_name text, row_id uuid, subject text, changed_fields text[], changes jsonb, old_row jsonb, new_row jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.id, c.changed_at, c.txid, c.changed_by_label, c.via, c.action,
         CASE c.table_name
           WHEN 'sales_log'              THEN 'Sale'
           WHEN 'sales_log_products'     THEN 'Sale'
           WHEN 'quote_log'              THEN 'Quote'
           WHEN 'quote_log_products'     THEN 'Quote'
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
     -- The same click that created a record filling in its own totals is the
     -- record being saved, not a change to it.
     AND NOT (lower(c.action) = 'update' AND EXISTS (
           SELECT 1 FROM public.change_log i
            WHERE i.txid = c.txid AND i.row_id = c.row_id AND i.table_name = c.table_name
              AND lower(i.action) = 'insert'))
   ORDER BY c.changed_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 300), 1), 1000);
$function$;

DROP FUNCTION IF EXISTS public.production_changes_for_day(uuid, date);
DROP FUNCTION IF EXISTS public.production_changes_for_range(uuid, date, date);

CREATE FUNCTION public.production_changes_for_range(p_agency_id uuid, p_start date, p_end date,
                                                    p_issued_in_range boolean DEFAULT false)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, kind text, what text, item text,
               subject text, actor_id uuid, who text, owner_id uuid, owner_name text,
               changed_fields text[], changes jsonb, row_count integer, spot_note text,
               policy jsonb, line text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH gate AS (
    SELECT (public.current_team_member_id() IS NOT NULL
            OR current_user IN ('postgres', 'supabase_admin', 'service_role')) AS ok
  ),
  bounds AS (
    SELECT (p_start::timestamp AT TIME ZONE 'America/Chicago') AS t0,
           ((p_end + 1)::timestamp AT TIME ZONE 'America/Chicago') AS t1
  ),
  scoped AS (
    SELECT c.*
      FROM public.change_log c, gate g, bounds b
     WHERE g.ok
       AND c.agency_id = p_agency_id
       AND lower(c.action) IN ('update', 'delete')
       AND COALESCE(c.via, '') <> 'automation'
       AND (
             (c.changed_at >= b.t0 AND c.changed_at < b.t1)
          OR (p_issued_in_range AND (
                (c.table_name = 'sales_log_products'
                 AND ((NULLIF(c.old_row ->> 'issued_date', ''))::date BETWEEN p_start AND p_end
                   OR (NULLIF(c.new_row ->> 'issued_date', ''))::date BETWEEN p_start AND p_end))
             OR (c.table_name = 'sales_log'
                 AND EXISTS (SELECT 1 FROM public.sales_log_products sp
                              WHERE sp.sales_log_id = c.row_id
                                AND sp.issued_date BETWEEN p_start AND p_end))))
           )
       AND NOT (lower(c.action) = 'update' AND EXISTS (
             SELECT 1 FROM public.change_log i
              WHERE i.txid = c.txid AND i.row_id = c.row_id AND i.table_name = c.table_name
                AND lower(i.action) = 'insert'))
  ),
  raw0 AS (
    SELECT s.*,
           CASE WHEN s.table_name IN ('sales_log', 'sales_log_products') THEN 'Sale'
                WHEN s.table_name IN ('quote_log', 'quote_log_products') THEN 'Quote'
                WHEN s.table_name = 'cancelation_log' THEN 'Cancelation'
                WHEN s.table_name = 'retention_activity_log' THEN 'Activity'
                WHEN s.table_name = 'fit_scorecards' THEN 'Conversation score'
                ELSE s.table_name END AS item,
           CASE s.table_name
             WHEN 'sales_log' THEN 1 WHEN 'quote_log' THEN 1 WHEN 'cancelation_log' THEN 1
             WHEN 'fit_scorecards' THEN 1 WHEN 'retention_activity_log' THEN 2 ELSE 3 END AS rank,
           CASE
             WHEN lower(s.action) = 'delete' THEN 'removed'
             WHEN lower(s.action) = 'update' AND COALESCE(s.new_row ->> 'status', '') IN ('void', 'voided')
                  AND COALESCE(s.old_row ->> 'status', '') NOT IN ('void', 'voided') THEN 'removed'
             ELSE 'edited' END AS what,
           -- An issue record: a policy that is or was issued, whose issue date
           -- or issued premium moved.
           (s.table_name = 'sales_log_products' AND lower(s.action) = 'update'
            AND (NULLIF(s.old_row ->> 'issued_date', '') IS NOT NULL OR NULLIF(s.new_row ->> 'issued_date', '') IS NOT NULL)
            AND ((s.old_row -> 'issued_date') IS DISTINCT FROM (s.new_row -> 'issued_date')
              OR (s.old_row ->> 'issued_premium')::numeric IS DISTINCT FROM (s.new_row ->> 'issued_premium')::numeric)) AS is_issue,
           CASE s.table_name
             WHEN 'sales_log_products' THEN (SELECT sl.team_member_id FROM public.sales_log sl
                                              WHERE sl.id = (COALESCE(s.new_row, s.old_row) ->> 'sales_log_id')::uuid)
             WHEN 'quote_log_products' THEN (SELECT ql.team_member_id FROM public.quote_log ql
                                              WHERE ql.id = (COALESCE(s.new_row, s.old_row) ->> 'quote_log_id')::uuid)
             ELSE NULLIF(COALESCE(s.new_row, s.old_row) ->> 'team_member_id', '')::uuid END AS owner_id,
           NULLIF(btrim(COALESCE(s.new_row ->> 'spot_check_note', '')), '') AS spot_note
      FROM scoped s
  ),
  raw AS (
    SELECT r.*,
           -- what changed about the record, leaving out the three columns the
           -- spot-check writes, and the issue fields when they have their own entry
           ARRAY(SELECT f FROM unnest(COALESCE(r.changed_fields, ARRAY[]::text[])) AS u(f)
                  WHERE f NOT IN ('verified_at', 'verified_by', 'spot_check_note')
                    AND NOT (r.is_issue AND f IN ('issued_date', 'issued_premium'))) AS edit_fields
      FROM raw0 r
  ),
  -- ---------- Issued policies: one entry per policy ----------
  issues AS (
    SELECT r.txid, r.changed_at, 'issue'::text AS kind,
           CASE WHEN NULLIF(r.old_row ->> 'issued_date', '') IS NULL THEN 'issued'
                WHEN NULLIF(r.new_row ->> 'issued_date', '') IS NULL THEN 'unissued'
                ELSE 'corrected' END AS what,
           'Policy'::text AS item, r.subject,
           r.changed_by_team_member_id AS actor_id, COALESCE(r.changed_by_label, 'Unknown') AS who,
           r.owner_id, r.changed_fields, '[]'::jsonb AS changes, 1 AS row_count, NULL::text AS spot_note,
           jsonb_build_object(
             'line_of_business', COALESCE(r.new_row, r.old_row) ->> 'line_of_business',
             'product', COALESCE(pt.label, initcap(replace(COALESCE(r.new_row, r.old_row) ->> 'product_type', '_', ' '))),
             'vehicles', (COALESCE(r.new_row, r.old_row) ->> 'vehicle_count')::int,
             'issued_date', NULLIF(r.new_row ->> 'issued_date', ''),
             'issued_premium', (r.new_row ->> 'issued_premium')::numeric,
             'submitted_premium', (COALESCE(r.new_row, r.old_row) ->> 'premium')::numeric,
             'difference', (r.new_row ->> 'issued_premium')::numeric - (COALESCE(r.new_row, r.old_row) ->> 'premium')::numeric,
             'was_issued_date', NULLIF(r.old_row ->> 'issued_date', ''),
             'was_issued_premium', (r.old_row ->> 'issued_premium')::numeric) AS policy,
           r.rank
      FROM raw r
      LEFT JOIN public.product_types pt
        ON pt.agency_id = r.agency_id
       AND pt.line_of_business = COALESCE(r.new_row, r.old_row) ->> 'line_of_business'
       AND pt.type_key = COALESCE(r.new_row, r.old_row) ->> 'product_type'
     WHERE r.is_issue
  ),
  -- ---------- Everything else: one entry per click ----------
  change_raw AS (
    SELECT * FROM raw r
     WHERE NOT r.is_issue OR cardinality(r.edit_fields) > 0 OR r.what = 'removed'
  ),
  diff_rows AS (
    SELECT r.txid, e.val, count(*)::integer AS n, min(r.rank * 1000 + e.ord) AS ord
      FROM change_raw r
      CROSS JOIN LATERAL jsonb_array_elements(
             public.change_items(p_agency_id, r.table_name, r.action, r.edit_fields, r.old_row, r.new_row)
           ) WITH ORDINALITY AS e(val, ord)
     WHERE lower(r.action) = 'update'
     GROUP BY r.txid, e.val
  ),
  diffs AS (
    SELECT d.txid, jsonb_agg(d.val || jsonb_build_object('count', d.n) ORDER BY d.ord) AS changes
      FROM diff_rows d GROUP BY d.txid
  ),
  top AS (
    SELECT DISTINCT ON (r.txid)
           r.txid, r.changed_at, r.row_id, r.changed_by_team_member_id, r.changed_by_label,
           r.what, r.item, r.subject, r.owner_id, r.spot_note, r.rank
      FROM change_raw r ORDER BY r.txid, r.rank, r.changed_at
  ),
  grouped AS (
    SELECT t.*,
           COALESCE(d.changes, '[]'::jsonb) AS changes,
           (SELECT array_agg(DISTINCT f) FROM change_raw r2, unnest(r2.edit_fields) f WHERE r2.txid = t.txid) AS fields,
           (SELECT count(*) FROM change_raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t LEFT JOIN diffs d ON d.txid = t.txid
     WHERE t.what <> 'edited' OR d.changes IS NOT NULL OR t.spot_note IS NOT NULL
  ),
  deduped AS (
    SELECT DISTINCT ON (
             CASE WHEN g.changes = '[]'::jsonb AND g.spot_note IS NOT NULL
                  THEN g.row_id::text || '|' || g.spot_note ELSE g.txid::text END) g.*
      FROM grouped g
     ORDER BY CASE WHEN g.changes = '[]'::jsonb AND g.spot_note IS NOT NULL
                   THEN g.row_id::text || '|' || g.spot_note ELSE g.txid::text END,
              g.changed_at
  ),
  changes_out AS (
    SELECT d.txid, d.changed_at, 'change'::text AS kind, d.what, d.item, d.subject,
           d.changed_by_team_member_id AS actor_id, COALESCE(d.changed_by_label, 'Unknown') AS who,
           d.owner_id, d.fields AS changed_fields, d.changes, d.row_count, d.spot_note,
           NULL::jsonb AS policy,
           (to_char(d.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(d.changed_by_label, 'Unknown') || ' ' || d.what ||
            CASE WHEN lower(d.item) ~ '^[aeiou]' THEN ' an ' ELSE ' a ' END || lower(d.item) ||
            COALESCE(' — ' || d.subject, '') ||
            COALESCE(' (' || (
              SELECT string_agg(
                       CASE
                         WHEN c.val ->> 'field' = 'event:removed' THEN 'reason: ' || (c.val ->> 'after')
                         WHEN (c.val ->> 'event')::boolean THEN (c.val ->> 'label') || COALESCE(': ' || (c.val ->> 'after'), '')
                         ELSE (c.val ->> 'label') || ': ' || (c.val ->> 'before') || ' → ' || (c.val ->> 'after')
                       END
                       || CASE WHEN (c.val ->> 'count')::int > 1 THEN ' ×' || (c.val ->> 'count') ELSE '' END,
                       '; ' ORDER BY c.ord)
                FROM jsonb_array_elements(d.changes) WITH ORDINALITY AS c(val, ord)
               WHERE c.ord <= 6
                 AND NOT (c.val ->> 'field' = 'event:removed' AND c.val ->> 'after' IS NULL)
            ) || CASE WHEN jsonb_array_length(d.changes) > 6
                      THEN '; and ' || (jsonb_array_length(d.changes) - 6) || ' more' ELSE '' END
            || ')', '') ||
            CASE WHEN d.row_count > 1 THEN ' [' || d.row_count || ' records]' ELSE '' END ||
            COALESCE(' — spot-check: ' || d.spot_note, '')) AS line
      FROM deduped d
  ),
  issues_out AS (
    SELECT i.txid, i.changed_at, i.kind, i.what, i.item, i.subject, i.actor_id, i.who, i.owner_id,
           i.changed_fields, i.changes, i.row_count, i.spot_note, i.policy,
           (to_char(i.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' || i.who ||
            CASE i.what WHEN 'issued' THEN ' marked a policy issued'
                        WHEN 'unissued' THEN ' marked a policy not issued'
                        ELSE ' corrected an issued policy' END ||
            COALESCE(' — ' || i.subject, '') || ' (' ||
            concat_ws(', ',
              NULLIF(concat_ws(' ', initcap(i.policy ->> 'line_of_business'), i.policy ->> 'product'), ''),
              CASE i.what
                WHEN 'unissued' THEN 'was issued ' ||
                  public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'was_issued_date') ||
                  COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'was_issued_premium'), '')
                ELSE 'issued ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') ||
                  COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium'), '') ||
                  CASE WHEN (i.policy ->> 'difference') IS NULL THEN ''
                       WHEN (i.policy ->> 'difference')::numeric = 0 THEN ', same as submitted'
                       WHEN (i.policy ->> 'difference')::numeric > 0 THEN ', ' ||
                         public.change_value_text(p_agency_id, 'premium', i.policy -> 'difference') || ' more than submitted'
                       ELSE ', ' || public.change_value_text(p_agency_id, 'premium', to_jsonb(-(i.policy ->> 'difference')::numeric)) || ' less than submitted'
                  END ||
                  CASE WHEN i.what = 'corrected' THEN ' (was ' ||
                    public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'was_issued_date') ||
                    COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'was_issued_premium'), '') || ')'
                  ELSE '' END
              END) || ')') AS line
      FROM issues i
  )
  SELECT o.txid, o.changed_at, o.kind, o.what, o.item, o.subject, o.actor_id, o.who,
         o.owner_id,
         (SELECT btrim(concat_ws(' ', t.first_name, t.last_name)) FROM public.team_directory t WHERE t.id = o.owner_id),
         o.changed_fields, o.changes, o.row_count, o.spot_note, o.policy, o.line
    FROM (SELECT * FROM changes_out UNION ALL SELECT * FROM issues_out) o
   ORDER BY o.changed_at DESC;
$function$;

COMMENT ON FUNCTION public.production_changes_for_range(uuid, date, date, boolean) IS
'Every edit, removal and issue on the production logs for a Central-time date range. kind = change (one entry per click, item Sale/Quote/Cancelation/Activity/Conversation score) or issue (one entry per policy: issued, unissued, corrected, with the policy jsonb carrying issue date, issued premium and the difference from submitted). p_issued_in_range adds changes made at any time to policies that issued in the range, and to their sales; the CPR passes true, the daily view false. Read by the Changes tab, the CPR and the daily digest.';

CREATE FUNCTION public.production_changes_for_day(p_agency_id uuid, p_day date DEFAULT NULL::date)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, kind text, what text, item text,
               subject text, actor_id uuid, who text, owner_id uuid, owner_name text,
               changed_fields text[], changes jsonb, row_count integer, spot_note text,
               policy jsonb, line text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT r.*
    FROM public.production_changes_for_range(
           p_agency_id,
           COALESCE(p_day, public.rp_today_central()),
           COALESCE(p_day, public.rp_today_central()),
           false) r
   ORDER BY r.changed_at DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.production_changes_for_range(uuid, date, date, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.production_changes_for_day(uuid, date) TO authenticated;
