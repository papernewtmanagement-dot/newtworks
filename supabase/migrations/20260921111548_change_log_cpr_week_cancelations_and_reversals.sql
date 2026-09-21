-- Peter 2026-09-21, round four on the change log.
--  * The weekly view (CPR and Changes tab) now files each change under the
--    CPR week whose sales points it moved: the week the change was made, unless
--    last week's CPR had not been sent yet, in which case last week. A Sunday
--    fix to last week's numbers lands on last week's CPR until that CPR goes
--    out. cpr_week_for() is the one place that decides it. This replaces the
--    "policies issued in the range" scope, which missed changes to older
--    policies (Brian E.'s home) that still moved the week's points.
--  * A cancelation that takes a policy off the points (charged back, or taken
--    out of the quarter it issued in) is an Issued Policies entry, so James W.
--    shows up. Logging it is a new entry, which the log otherwise leaves out.
--  * An issue change that is undone by the very next change on the same policy
--    is left out, both halves: a flip and its flip back say nothing happened.

CREATE OR REPLACE FUNCTION public.cpr_week_for(p_agency uuid, p_at timestamptz)
RETURNS date
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH w AS (SELECT public.rp_week_end((p_at AT TIME ZONE 'America/Chicago')::date) AS this_end)
  SELECT CASE WHEN EXISTS (
                SELECT 1 FROM public.weekly_cpr_reports r
                 WHERE r.agency_id = p_agency
                   AND r.week_ending_date = w.this_end - 7
                   AND (r.sent_to_team_at IS NULL OR r.sent_to_team_at > p_at))
              THEN w.this_end - 7
              ELSE w.this_end END
    FROM w;
$function$;

COMMENT ON FUNCTION public.cpr_week_for(uuid, timestamptz) IS
'The CPR week a change made at p_at belongs to: the week it was made, unless last week''s CPR had not been sent to the team yet at that moment, in which case last week (its sales points were still open). Peter 2026-09-21.';

DROP FUNCTION IF EXISTS public.production_changes_for_day(uuid, date);
DROP FUNCTION IF EXISTS public.production_changes_for_range(uuid, date, date, boolean);

CREATE FUNCTION public.production_changes_for_range(p_agency_id uuid, p_start date, p_end date,
                                                    p_by_cpr_week boolean DEFAULT false)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, kind text, what text, item text,
               subject text, actor_id uuid, who text, owner_id uuid, owner_name text,
               changed_fields text[], changes jsonb, row_count integer, spot_note text,
               policy jsonb, line text, phone_last4 text)
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
           ((p_end + 1)::timestamp AT TIME ZONE 'America/Chicago') AS t1,
           COALESCE((SELECT setting_value::date FROM public.settings
                      WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date'),
                    DATE '2026-04-05') AS anchor
  ),
  -- Every change row in scope, adds included. Weekly view: the CPR week the
  -- change counts toward. Daily view: the day it was made.
  scoped_all AS (
    SELECT c.*
      FROM public.change_log c, gate g, bounds b
     WHERE g.ok
       AND c.agency_id = p_agency_id
       AND COALESCE(c.via, '') <> 'automation'
       AND CASE WHEN p_by_cpr_week
                THEN c.changed_at >= b.t0 AND c.changed_at < b.t1 + interval '14 days'
                     AND public.cpr_week_for(p_agency_id, c.changed_at) BETWEEN p_start AND p_end
                ELSE c.changed_at >= b.t0 AND c.changed_at < b.t1 END
  ),
  scoped AS (
    SELECT c.* FROM scoped_all c
     WHERE lower(c.action) IN ('update', 'delete')
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
           NULLIF(btrim(COALESCE(s.new_row ->> 'spot_check_note', '')), '') AS spot_note,
           public.change_current_phone(s.table_name, s.row_id, COALESCE(s.new_row, s.old_row)) AS phone,
           public.change_current_subject(s.table_name, s.row_id, COALESCE(s.new_row, s.old_row), s.subject) AS subject_now
      FROM scoped s
  ),
  raw AS (
    SELECT r.*,
           ARRAY(SELECT f FROM unnest(COALESCE(r.changed_fields, ARRAY[]::text[])) AS u(f)
                  WHERE f NOT IN ('verified_at', 'verified_by', 'spot_check_note')
                    AND NOT (r.is_issue AND f IN ('issued_date', 'issued_premium'))) AS edit_fields
      FROM raw0 r
  ),
  -- ---------- Issued policies: one entry per policy change ----------
  issue_seq AS (
    SELECT r.*,
           jsonb_build_array(NULLIF(r.old_row ->> 'issued_date', ''), (r.old_row ->> 'issued_premium')::numeric) AS st_old,
           jsonb_build_array(NULLIF(r.new_row ->> 'issued_date', ''), (r.new_row ->> 'issued_premium')::numeric) AS st_new
      FROM raw r WHERE r.is_issue
  ),
  issue_rev AS (
    SELECT q.*,
           COALESCE(lead(q.st_new) OVER w = q.st_old, false) AS rev_next,
           COALESCE(lag(q.st_old)  OVER w = q.st_new, false) AS rev_prev
      FROM issue_seq q
    WINDOW w AS (PARTITION BY q.row_id ORDER BY q.changed_at, q.txid)
  ),
  issue_pair AS (
    SELECT q.*,
           (q.rev_next AND NOT q.rev_prev) AS pair_start
      FROM issue_rev q
  ),
  issue_keep AS (
    SELECT q.* FROM (
      SELECT q.*, COALESCE(lag(q.pair_start) OVER (PARTITION BY q.row_id ORDER BY q.changed_at, q.txid), false) AS prev_start
        FROM issue_pair q) q
     -- a change undone by the very next one: both halves drop out
     WHERE NOT q.pair_start AND NOT (q.rev_prev AND q.prev_start)
  ),
  issues AS (
    SELECT r.txid, r.changed_at, 'issue'::text AS kind,
           CASE WHEN NULLIF(r.old_row ->> 'issued_date', '') IS NULL THEN 'issued'
                WHEN NULLIF(r.new_row ->> 'issued_date', '') IS NULL THEN 'unissued'
                ELSE 'corrected' END AS what,
           'Policy'::text AS item, r.subject_now AS subject,
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
           r.phone
      FROM issue_keep r
      LEFT JOIN public.product_types pt
        ON pt.agency_id = r.agency_id
       AND pt.line_of_business = COALESCE(r.new_row, r.old_row) ->> 'line_of_business'
       AND pt.type_key = COALESCE(r.new_row, r.old_row) ->> 'product_type'
  ),
  -- ---------- Cancelations that take a policy off the points ----------
  cxl AS (
    SELECT ci.txid, ci.changed_at, 'issue'::text AS kind, 'canceled'::text AS what, 'Policy'::text AS item,
           public.change_current_subject('cancelation_log', c.id, to_jsonb(c), ci.subject) AS subject,
           ci.changed_by_team_member_id AS actor_id, COALESCE(ci.changed_by_label, 'Unknown') AS who,
           s.team_member_id AS owner_id, ci.changed_fields, '[]'::jsonb AS changes, 1 AS row_count,
           NULL::text AS spot_note,
           jsonb_build_object(
             'line_of_business', p.line_of_business,
             'product', COALESCE(pt.label, initcap(replace(p.product_type, '_', ' '))),
             'vehicles', p.vehicle_count,
             'issued_date', p.issued_date,
             'issued_premium', COALESCE(p.issued_premium, p.premium),
             'submitted_premium', p.premium,
             'difference', NULL,
             'canceled_on', c.canceled_on,
             'effect', CASE WHEN floor((((c.created_at AT TIME ZONE 'America/Chicago')::date) - b.anchor) / 91.0)
                                 > floor((p.issued_date - b.anchor) / 91.0)
                            THEN 'charged_back' ELSE 'removed' END) AS policy,
           COALESCE(c.phone_last4, s.phone_last4) AS phone
      FROM scoped_all ci
      JOIN public.cancelation_log c ON c.id = ci.row_id
      JOIN public.sales_log_products p ON p.id = c.matched_sale_product_id
      JOIN public.sales_log s ON s.id = p.sales_log_id AND s.status = 'active'
      CROSS JOIN bounds b
      LEFT JOIN public.product_types pt
        ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
     WHERE ci.table_name = 'cancelation_log' AND lower(ci.action) = 'insert'
       AND c.status = 'active' AND NOT COALESCE(c.already_charged_back, false)
       AND p.issued_date IS NOT NULL
  ),
  issues_all AS (SELECT * FROM issues UNION ALL SELECT * FROM cxl),
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
           r.what, r.item, r.subject_now AS subject, r.owner_id, r.rank, r.phone
      FROM change_raw r ORDER BY r.txid, r.rank, r.changed_at
  ),
  grouped AS (
    SELECT t.*,
           COALESCE(d.changes, '[]'::jsonb) AS changes,
           (SELECT array_agg(DISTINCT f) FROM change_raw r2, unnest(r2.edit_fields) f WHERE r2.txid = t.txid) AS fields,
           (SELECT count(*) FROM change_raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t LEFT JOIN diffs d ON d.txid = t.txid
     WHERE t.what <> 'edited' OR d.changes IS NOT NULL
  ),
  changes_out AS (
    SELECT d.txid, d.changed_at, 'change'::text AS kind, d.what, d.item, d.subject,
           d.changed_by_team_member_id AS actor_id, COALESCE(d.changed_by_label, 'Unknown') AS who,
           d.owner_id, d.fields AS changed_fields, d.changes, d.row_count, NULL::text AS spot_note,
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
            CASE WHEN d.row_count > 1 THEN ' [' || d.row_count || ' records]' ELSE '' END) AS line,
           d.phone
      FROM grouped d
  ),
  issues_out AS (
    SELECT i.txid, i.changed_at, i.kind, i.what, i.item, i.subject, i.actor_id, i.who, i.owner_id,
           i.changed_fields, i.changes, i.row_count, i.spot_note, i.policy,
           (to_char(i.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' || i.who ||
            CASE i.what WHEN 'issued' THEN ' marked a policy issued'
                        WHEN 'unissued' THEN ' marked a policy not issued'
                        WHEN 'canceled' THEN ' logged a cancelation'
                        ELSE ' corrected an issued policy' END ||
            COALESCE(' — ' || i.subject, '') || ' (' ||
            concat_ws(', ',
              NULLIF(concat_ws(' ', initcap(i.policy ->> 'line_of_business'), i.policy ->> 'product'), ''),
              CASE i.what
                WHEN 'canceled' THEN 'canceled ' ||
                  public.change_value_text(p_agency_id, 'canceled_on', i.policy -> 'canceled_on') ||
                  CASE WHEN i.policy ->> 'effect' = 'charged_back'
                       THEN ', charged back ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium')
                       ELSE ', taken off its ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') || ' issue' END
                WHEN 'unissued' THEN 'was issued ' ||
                  public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'was_issued_date') ||
                  COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'was_issued_premium'), '')
                WHEN 'corrected' THEN concat_ws(', ',
                  CASE WHEN i.policy -> 'was_issued_date' IS DISTINCT FROM i.policy -> 'issued_date'
                       THEN 'issued date ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'was_issued_date')
                            || ' → ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') END,
                  CASE WHEN (i.policy ->> 'was_issued_premium')::numeric IS DISTINCT FROM (i.policy ->> 'issued_premium')::numeric
                       THEN 'issued premium ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'was_issued_premium')
                            || ' → ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium') END) ||
                  CASE WHEN (i.policy ->> 'difference') IS NULL THEN ''
                       WHEN (i.policy ->> 'difference')::numeric = 0 THEN ', same as submitted'
                       WHEN (i.policy ->> 'difference')::numeric > 0 THEN ', ' ||
                         public.change_value_text(p_agency_id, 'premium', i.policy -> 'difference') || ' more than submitted'
                       ELSE ', ' || public.change_value_text(p_agency_id, 'premium', to_jsonb(-(i.policy ->> 'difference')::numeric)) || ' less than submitted'
                  END
                ELSE 'issued ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') ||
                  COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium'), ', no issued premium yet') ||
                  CASE WHEN (i.policy ->> 'difference') IS NULL THEN ''
                       WHEN (i.policy ->> 'difference')::numeric = 0 THEN ', same as submitted'
                       WHEN (i.policy ->> 'difference')::numeric > 0 THEN ', ' ||
                         public.change_value_text(p_agency_id, 'premium', i.policy -> 'difference') || ' more than submitted'
                       ELSE ', ' || public.change_value_text(p_agency_id, 'premium', to_jsonb(-(i.policy ->> 'difference')::numeric)) || ' less than submitted'
                  END
              END) || ')') AS line,
           i.phone
      FROM issues_all i
  ),
  -- ---------- Spot-check notes: one entry per note ----------
  spot_out AS (
    SELECT DISTINCT ON (r.owner_id, r.subject_now, r.spot_note)
           r.txid, r.changed_at, 'spot_check'::text AS kind, 'noted'::text AS what, r.item,
           r.subject_now AS subject,
           r.changed_by_team_member_id AS actor_id, COALESCE(r.changed_by_label, 'Unknown') AS who,
           r.owner_id, ARRAY['spot_check_note']::text[] AS changed_fields, '[]'::jsonb AS changes,
           1 AS row_count, r.spot_note, NULL::jsonb AS policy,
           (to_char(r.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(r.changed_by_label, 'Unknown') || ' left a spot-check note on ' ||
            CASE WHEN lower(r.item) ~ '^[aeiou]' THEN 'an ' ELSE 'a ' END || lower(r.item) ||
            COALESCE(' — ' || r.subject_now, '') || ': ' || r.spot_note) AS line,
           r.phone
      FROM raw r
     WHERE 'spot_check_note' = ANY(COALESCE(r.changed_fields, ARRAY[]::text[]))
       AND r.spot_note IS NOT NULL
       AND r.spot_note IS DISTINCT FROM NULLIF(btrim(COALESCE(r.old_row ->> 'spot_check_note', '')), '')
     ORDER BY r.owner_id, r.subject_now, r.spot_note, r.changed_at
  )
  SELECT o.txid, o.changed_at, o.kind, o.what, o.item, o.subject, o.actor_id, o.who,
         o.owner_id,
         (SELECT btrim(concat_ws(' ', t.first_name, t.last_name)) FROM public.team_directory t WHERE t.id = o.owner_id),
         o.changed_fields, o.changes, o.row_count, o.spot_note, o.policy, o.line, o.phone
    FROM (SELECT * FROM changes_out UNION ALL SELECT * FROM issues_out UNION ALL SELECT * FROM spot_out) o
   ORDER BY o.changed_at DESC;
$function$;

COMMENT ON FUNCTION public.production_changes_for_range(uuid, date, date, boolean) IS
'Every edit, removal, issue, points-moving cancelation and spot-check note on the production logs. kind = change (one entry per click), issue (one per policy: issued, unissued, corrected, canceled; a change undone by the next change on the same policy is left out) or spot_check. p_by_cpr_week = true files each entry under the CPR week cpr_week_for() gives it (the CPR and the Changes tab week view); false = the day it was made (the daily digest).';

CREATE FUNCTION public.production_changes_for_day(p_agency_id uuid, p_day date DEFAULT NULL::date)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, kind text, what text, item text,
               subject text, actor_id uuid, who text, owner_id uuid, owner_name text,
               changed_fields text[], changes jsonb, row_count integer, spot_note text,
               policy jsonb, line text, phone_last4 text)
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
