-- Peter 2026-09-21, round six.
--  * An edit or removal names the thing: the products on the sale, the
--    activity's own name, the canceled line. change_record_label() gives it,
--    and falls back to the kind of record when nothing more is known.
--  * A cancelation shows twice when it moves points: once as logged, under the
--    teammate who logged it (their activity), and once as the chargeback or
--    take-off, under the teammate whose policy it was. One that moves no points
--    shows only as logged.
--  * A cancelation carries its spot-check note on its own line.

CREATE OR REPLACE FUNCTION public.change_record_label(p_agency uuid, p_table text, p_row_id uuid, p_row jsonb)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    CASE p_table
      WHEN 'sales_log' THEN (
        SELECT string_agg(initcap(sp.line_of_business) || ' ' ||
                          COALESCE(pt.label, initcap(replace(sp.product_type, '_', ' '))), ', '
                          ORDER BY sp.line_of_business, sp.product_type)
          FROM public.sales_log_products sp
          LEFT JOIN public.product_types pt
            ON pt.agency_id = p_agency AND pt.line_of_business = sp.line_of_business AND pt.type_key = sp.product_type
         WHERE sp.sales_log_id = p_row_id)
      WHEN 'sales_log_products' THEN
        initcap(p_row ->> 'line_of_business') || ' ' ||
        COALESCE((SELECT pt.label FROM public.product_types pt
                   WHERE pt.agency_id = p_agency AND pt.line_of_business = p_row ->> 'line_of_business'
                     AND pt.type_key = p_row ->> 'product_type'),
                 initcap(replace(p_row ->> 'product_type', '_', ' ')))
      WHEN 'retention_activity_log' THEN
        (SELECT pv.label FROM public.retention_point_values pv
          WHERE pv.agency_id = p_agency AND pv.activity_key = p_row ->> 'activity_key')
      WHEN 'cancelation_log' THEN
        'Canceled ' || initcap(COALESCE(p_row ->> 'policy_line', '')) || ' ' ||
        COALESCE((SELECT pt.label FROM public.product_types pt
                   WHERE pt.agency_id = p_agency AND pt.line_of_business = p_row ->> 'policy_line'
                     AND pt.type_key = p_row ->> 'product_type'),
                 initcap(replace(COALESCE(p_row ->> 'product_type', ''), '_', ' ')))
      WHEN 'quote_log' THEN (
        SELECT 'Quote: ' || string_agg(initcap(qp.line_of_business) || ' ' ||
                          COALESCE(pt.label, initcap(replace(qp.product_type, '_', ' '))), ', '
                          ORDER BY qp.line_of_business, qp.product_type)
          FROM public.quote_log_products qp
          LEFT JOIN public.product_types pt
            ON pt.agency_id = p_agency AND pt.line_of_business = qp.line_of_business AND pt.type_key = qp.product_type
         WHERE qp.quote_log_id = p_row_id)
      WHEN 'quote_log_products' THEN 'Quote: ' || initcap(COALESCE(p_row ->> 'line_of_business', ''))
      WHEN 'fit_scorecards' THEN 'Conversation score'
    END,
    CASE p_table
      WHEN 'sales_log' THEN 'Sale' WHEN 'sales_log_products' THEN 'Sale'
      WHEN 'quote_log' THEN 'Quote' WHEN 'quote_log_products' THEN 'Quote'
      WHEN 'retention_activity_log' THEN 'Activity' WHEN 'cancelation_log' THEN 'Cancelation'
      ELSE 'Record' END);
$function$;

DO $mig$
DECLARE d text; a int; b int; o text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;

  -- 1. Edits and removals name the thing.
  o := 'r.what, r.item, r.subject_now AS subject, r.owner_id, r.rank, r.phone';
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'top block not found'; END IF;
  d := replace(d, o, 'r.what, public.change_record_label(p_agency_id, r.table_name, r.row_id, COALESCE(r.new_row, r.old_row)) AS item, r.subject_now AS subject, r.owner_id, r.rank, r.phone');

  a := position($o$           (to_char(d.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(d.changed_by_label, 'Unknown') || ' ' || d.what ||$o$ IN d);
  b := position($o$            COALESCE(' (' || ($o$ IN d);
  IF a = 0 OR b = 0 OR b < a THEN RAISE EXCEPTION 'change line head not found'; END IF;
  d := substr(d, 1, a - 1) || $n$           (to_char(d.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(d.subject || ' — ', '') || d.item || ' · ' || initcap(d.what) || ' by ' ||
            COALESCE(d.changed_by_label, 'Unknown') ||
$n$ || substr(d, b);

  -- 2. A cancelation: logged (for the logger), and the chargeback (for the owner).
  a := position($o$  cxl AS (
    SELECT x.txid, x.changed_at, 'canceled'::text AS kind, 'canceled'::text AS what,$o$ IN d);
  b := position('  issues_all AS (SELECT * FROM issues UNION ALL SELECT * FROM cxl),' IN d);
  IF a = 0 OR b = 0 OR b < a THEN RAISE EXCEPTION 'cxl block not found'; END IF;
  d := substr(d, 1, a - 1) || $blk$  cxl AS (
    SELECT x.txid, x.changed_at, 'canceled'::text AS kind, v.what,
           public.change_record_label(p_agency_id, 'cancelation_log', x.cxl_id, x.cxl_row) AS item,
           public.change_current_subject('cancelation_log', x.cxl_id, x.cxl_row, x.snap_subject) AS subject,
           x.changed_by_team_member_id AS actor_id, COALESCE(x.changed_by_label, 'Unknown') AS who,
           v.owner_id, x.changed_fields, '[]'::jsonb AS changes,
           1 AS row_count, NULL::text AS spot_note,
           jsonb_build_object(
             'line_of_business', COALESCE(x.line_of_business, x.policy_line),
             'product', COALESCE(x.type_label, initcap(replace(COALESCE(x.product_type, x.cxl_type), '_', ' '))),
             'vehicles', x.vehicle_count,
             'issued_date', x.issued_date,
             'issued_premium', COALESCE(x.issued_premium, x.premium, x.cxl_premium),
             'submitted_premium', x.premium,
             'difference', NULL,
             'canceled_on', x.canceled_on,
             'recorded_on', x.recorded_on,
             'charge', CASE WHEN x.effect IN ('charged_back', 'removed') THEN COALESCE(x.issued_premium, x.premium) ELSE 0 END,
             'effect', x.effect,
             'logged_for', (SELECT btrim(concat_ws(' ', t.first_name, t.last_name)) FROM public.team_directory t WHERE t.id = x.logged_for),
             'note', NULLIF(btrim(COALESCE(x.cxl_row ->> 'spot_check_note', '')), '')) AS policy,
           COALESCE(x.cxl_phone, x.sale_phone) AS phone
      FROM cxl_src x
      CROSS JOIN bounds b
      CROSS JOIN LATERAL (VALUES
        ('logged'::text, x.logged_for, true),
        (x.effect, x.sale_owner, x.effect IN ('charged_back', 'removed'))
      ) AS v(what, owner_id, keep)
     WHERE v.keep
       AND CASE WHEN NOT p_by_cpr_week
                  THEN x.changed_at >= b.t0 AND x.changed_at < b.t1
                WHEN v.what = 'charged_back'
                  -- the charge counts in the week it was recorded
                  THEN public.rp_week_end(x.recorded_on) BETWEEN p_start AND p_end
                ELSE public.cpr_week_for(p_agency_id, x.changed_at) BETWEEN p_start AND p_end END
  ),
$blk$ || substr(d, b);

  o := $o$            CASE i.what WHEN 'issued' THEN ' marked a policy issued'
                        WHEN 'unissued' THEN ' marked a policy not issued'
                        WHEN 'canceled' THEN ' logged a cancelation'
                        ELSE ' corrected an issued policy' END ||$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'issue verb not found'; END IF;
  d := replace(d, o, $n$            CASE WHEN i.kind = 'canceled' AND i.what = 'logged' THEN ' logged a cancelation'
                 WHEN i.kind = 'canceled' THEN ' logged a cancelation on this policy'
                 WHEN i.what = 'issued' THEN ' marked a policy issued'
                 WHEN i.what = 'unissued' THEN ' marked a policy not issued'
                 ELSE ' corrected an issued policy' END ||$n$);
  o := $o$              CASE i.what
                WHEN 'canceled' THEN 'canceled ' ||$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'issue detail not found'; END IF;
  d := replace(d, o, $n$              CASE CASE WHEN i.kind = 'canceled' THEN 'canceled' ELSE i.what END
                WHEN 'canceled' THEN 'canceled ' ||$n$);

  EXECUTE d;
END $mig$;
