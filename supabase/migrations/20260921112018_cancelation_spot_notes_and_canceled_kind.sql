-- Peter 2026-09-21, round five on the change log.
--  * Cancelations can carry a spot-check note, like sales and activities.
--  * Cancelations are their own kind ('canceled'): every one logged, with what
--    it did to the points (charged back, taken off its issue week, already
--    charged back, or outside the window). Own card on the CPR, own toggle on
--    the Changes tab.
--  * A spot-check entry names the thing, not "a sale": the products sold, the
--    activity's own name, the canceled line. change_record_label() is that name.

ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS spot_check_note text;

CREATE OR REPLACE FUNCTION public.rp_spot_check_note_cancelation(p_id uuid, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can leave a spot-check note' USING ERRCODE='42501'; END IF;
  UPDATE public.cancelation_log
     SET spot_check_note = NULLIF(btrim(COALESCE(p_note, '')), ''), updated_at = now()
   WHERE id = p_id AND agency_id = a.agency_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'that cancelation is not on file any more'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_spot_check_note(p_kind text, p_id uuid, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_kind = 'sale' THEN RETURN public.rp_spot_check_note_sale(p_id, p_note); END IF;
  IF p_kind = 'activity' THEN RETURN public.rp_spot_check_note(p_id, p_note); END IF;
  IF p_kind = 'cancelation' THEN RETURN public.rp_spot_check_note_cancelation(p_id, p_note); END IF;
  RAISE EXCEPTION 'cannot leave a note on a record of kind %', p_kind;
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_note_cancelation(uuid, text) TO authenticated;

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
      WHEN 'quote_log' THEN 'Quote'
      WHEN 'quote_log_products' THEN 'Quoted ' || initcap(COALESCE(p_row ->> 'line_of_business', ''))
      WHEN 'fit_scorecards' THEN 'Conversation score'
    END,
    'Record');
$function$;

DO $mig$
DECLARE d text; a int; b int; old_block text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;

  -- 1. Cancelations: every one logged, as their own kind.
  a := position('  -- ---------- Cancelations that take a policy off the points ----------' IN d);
  b := position('  issues_all AS (SELECT * FROM issues UNION ALL SELECT * FROM cxl),' IN d);
  IF a = 0 OR b = 0 OR b < a THEN RAISE EXCEPTION 'cxl block not found'; END IF;
  d := substr(d, 1, a - 1) || $blk$  -- ---------- Cancelations: every one logged, and what it did to the points ----------
  cxl AS (
    SELECT ci.txid, ci.changed_at, 'canceled'::text AS kind, 'canceled'::text AS what, 'Policy'::text AS item,
           public.change_current_subject('cancelation_log', c.id, to_jsonb(c), ci.subject) AS subject,
           ci.changed_by_team_member_id AS actor_id, COALESCE(ci.changed_by_label, 'Unknown') AS who,
           COALESCE(s.team_member_id, c.team_member_id) AS owner_id, ci.changed_fields, '[]'::jsonb AS changes,
           1 AS row_count, NULL::text AS spot_note,
           jsonb_build_object(
             'line_of_business', COALESCE(p.line_of_business, c.policy_line),
             'product', COALESCE(pt.label, initcap(replace(COALESCE(p.product_type, c.product_type), '_', ' '))),
             'vehicles', p.vehicle_count,
             'issued_date', p.issued_date,
             'issued_premium', COALESCE(p.issued_premium, p.premium, c.premium),
             'submitted_premium', p.premium,
             'difference', NULL,
             'canceled_on', c.canceled_on,
             'charge', CASE WHEN p.id IS NULL OR COALESCE(c.already_charged_back, false)
                                 OR s.id IS NULL OR p.issued_date IS NULL THEN 0
                            ELSE COALESCE(p.issued_premium, p.premium) END,
             'effect', CASE WHEN p.id IS NULL THEN 'outside_window'
                            WHEN COALESCE(c.already_charged_back, false) THEN 'already_charged_back'
                            WHEN s.id IS NULL OR p.issued_date IS NULL THEN 'not_counted'
                            WHEN floor((((c.created_at AT TIME ZONE 'America/Chicago')::date) - b.anchor) / 91.0)
                                 > floor((p.issued_date - b.anchor) / 91.0) THEN 'charged_back'
                            ELSE 'removed' END) AS policy,
           COALESCE(c.phone_last4, s.phone_last4) AS phone
      FROM scoped_all ci
      JOIN public.cancelation_log c ON c.id = ci.row_id
      LEFT JOIN public.sales_log_products p ON p.id = c.matched_sale_product_id
      LEFT JOIN public.sales_log s ON s.id = p.sales_log_id AND s.status = 'active'
      CROSS JOIN bounds b
      LEFT JOIN public.product_types pt
        ON pt.agency_id = c.agency_id
       AND pt.line_of_business = COALESCE(p.line_of_business, c.policy_line)
       AND pt.type_key = COALESCE(p.product_type, c.product_type)
     WHERE ci.table_name = 'cancelation_log' AND lower(ci.action) = 'insert'
       AND c.status = 'active'
  ),
$blk$ || substr(d, b);

  -- 2. The cancelation line says what it did.
  old_block := $o$                WHEN 'canceled' THEN 'canceled ' ||
                  public.change_value_text(p_agency_id, 'canceled_on', i.policy -> 'canceled_on') ||
                  CASE WHEN i.policy ->> 'effect' = 'charged_back'
                       THEN ', charged back ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium')
                       ELSE ', taken off its ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') || ' issue' END$o$;
  IF position(old_block IN d) = 0 THEN RAISE EXCEPTION 'cancel line not found'; END IF;
  d := replace(d, old_block, $n$                WHEN 'canceled' THEN 'canceled ' ||
                  public.change_value_text(p_agency_id, 'canceled_on', i.policy -> 'canceled_on') ||
                  CASE i.policy ->> 'effect'
                    WHEN 'charged_back' THEN ', charged back ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium')
                    WHEN 'removed' THEN ', taken off its ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date')
                                        || ' issue (' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium') || ')'
                    WHEN 'already_charged_back' THEN ', already charged back when it happened'
                    WHEN 'not_counted' THEN ', never counted, no charge'
                    ELSE ', outside the chargeback window, no charge' END$n$);

  -- 3. Spot-check entries name the thing and drop who wrote the note.
  old_block := $o$'spot_check'::text AS kind, 'noted'::text AS what, r.item,$o$;
  IF position(old_block IN d) = 0 THEN RAISE EXCEPTION 'spot item not found'; END IF;
  d := replace(d, old_block, $n$'spot_check'::text AS kind, 'noted'::text AS what,
           public.change_record_label(p_agency_id, r.table_name, r.row_id, COALESCE(r.new_row, r.old_row)) AS item,$n$);
  a := position($o$           (to_char(r.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(r.changed_by_label, 'Unknown') || ' left a spot-check note on ' ||$o$ IN d);
  b := position($o$': ' || r.spot_note) AS line,$o$ IN d);
  IF a = 0 OR b = 0 OR b < a THEN RAISE EXCEPTION 'spot line not found'; END IF;
  d := substr(d, 1, a - 1) || $n$           (to_char(r.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(r.subject_now || ' — ', '') ||
            public.change_record_label(p_agency_id, r.table_name, r.row_id, COALESCE(r.new_row, r.old_row)) ||
            $n$ || substr(d, b);

  EXECUTE d;
END $mig$;
