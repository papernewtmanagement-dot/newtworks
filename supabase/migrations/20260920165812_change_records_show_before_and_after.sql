-- Change records named the fields that changed but never the values, so there
-- was no way to confirm a correction stuck. change_log already stores the whole
-- row before and after; nothing surfaced it.
--
-- The naming and the value formatting now live in one place in the database.
-- The CPR change report line and the Change history tab both read it, so the
-- two can never drift apart the way a second copy in the page would.

-- Bookkeeping columns nobody needs to read.
CREATE OR REPLACE FUNCTION public.change_field_hidden(p_field text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT p_field ~ '^(id|agency_id|created_by|created_by_user_id|created_at|updated_at|voided_by|voided_at|verified_by|source|source_id|sales_log_id|quote_log_id|multiline_credit_id|matched_sale_product_id|chargeback_activity_id|entry_source|tenure_tier_at_entry|entry_type)$';
$function$;

-- Column name to plain English. Anything not named here falls back to the
-- column with its underscores taken out.
CREATE OR REPLACE FUNCTION public.change_field_label(p_field text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT COALESCE(
    '{
      "premium":"premium","total_premium":"total premium","issued_premium":"issued premium",
      "issued_date":"issued","status":"status","void_reason":"void reason","note":"note",
      "customer_label":"customer","customer_first_name":"first name","customer_last_initial":"last initial",
      "marketing_source":"source","marketing_source_import":"source as imported",
      "household_status":"relationship","relationship_type":"relationship",
      "submitted_date":"submitted","quote_date":"quote date","occurred_on":"date",
      "canceled_on":"canceled on","vehicle_count":"cars","policy_count":"policies",
      "line_of_business":"line","policy_line":"line","save_line":"line","product_type":"product",
      "is_new_line":"new line","points":"points","activity_key":"activity",
      "save_reason":"save reason","reason":"reason","week_end_date":"week",
      "credited_week_end_date":"credited week","credit_available_on":"clears on",
      "products_discussed":"products discussed","is_existing_customer":"existing customer",
      "ecrm_opportunity_url":"ECRM link","ecrm_url":"ECRM link","team_member_id":"person",
      "sourced_by_team_member_id":"sourced by","saves_voided":"saves voided",
      "chargeback_points":"chargeback","is_added_to_existing":"added to a policy they had",
      "window_fraction_left":"window left","verified_at":"verified","spot_check_note":"spot-check note",
      "scorecard_date":"date","average_score":"average","recording_turned_in":"recording turned in",
      "recording_url":"recording","opportunity_ref":"opportunity","phone_last4":"phone",
      "review_platform":"review site","autopay_enrolled":"autopay","on_file_answer":"already on file",
      "referred_by_customer":"referred by","appointment_id":"appointment"
    }'::jsonb ->> p_field,
    btrim(replace(regexp_replace(p_field, '_score$', ''), '_', ' '))
  );
$function$;

-- One stored value, written the way a person reads it. Ids become names,
-- money gets a dollar sign, dates get spelled out, a missing value says blank.
CREATE OR REPLACE FUNCTION public.change_value_text(p_agency uuid, p_field text, p_value jsonb)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v text; n numeric;
BEGIN
  IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN RETURN 'blank'; END IF;

  IF jsonb_typeof(p_value) = 'boolean' THEN
    RETURN CASE WHEN (p_value)::text = 'true' THEN 'yes' ELSE 'no' END;
  END IF;

  IF jsonb_typeof(p_value) = 'array' THEN
    SELECT string_agg(initcap(replace(x, '_', ' ')), ', ')
      INTO v FROM jsonb_array_elements_text(p_value) AS t(x);
    RETURN COALESCE(NULLIF(v, ''), 'blank');
  END IF;

  v := CASE WHEN jsonb_typeof(p_value) = 'string' THEN p_value #>> '{}' ELSE p_value::text END;
  IF btrim(COALESCE(v, '')) = '' THEN RETURN 'blank'; END IF;

  IF p_field LIKE '%team_member_id' THEN
    RETURN COALESCE((SELECT btrim(concat_ws(' ', t.first_name, t.last_name))
                       FROM public.team_directory t WHERE t.id = v::uuid), v);
  END IF;

  IF p_field = 'activity_key' THEN
    RETURN COALESCE((SELECT pv.label FROM public.retention_point_values pv
                      WHERE pv.agency_id = p_agency AND pv.activity_key = v), v);
  END IF;

  IF p_field ~ '(premium|points)$' THEN
    BEGIN n := v::numeric; RETURN '$' || trim(to_char(n, 'FM999G999G990D00')); EXCEPTION WHEN others THEN RETURN v; END;
  END IF;

  IF p_field = 'window_fraction_left' THEN
    BEGIN n := v::numeric; RETURN round(n * 100)::text || '%'; EXCEPTION WHEN others THEN RETURN v; END;
  END IF;

  IF p_field ~ '^(line_of_business|policy_line|save_line|product_type|household_status|relationship_type|status|review_platform|marketing_source|on_file_answer)$' THEN
    RETURN initcap(replace(v, '_', ' '));
  END IF;

  IF v ~ '^\d{4}-\d{2}-\d{2}' THEN
    RETURN to_char((left(v, 10))::date, 'FMMon FMDD, YYYY');
  END IF;

  RETURN v;
END $function$;

-- Every field that changed, named and valued, as a list the page can lay out
-- and the report can read straight through.
CREATE OR REPLACE FUNCTION public.change_diff(p_agency uuid, p_fields text[], p_old jsonb, p_new jsonb)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'field', f,
           'label', public.change_field_label(f),
           'before', public.change_value_text(p_agency, f, p_old -> f),
           'after',  public.change_value_text(p_agency, f, p_new -> f)
         ) ORDER BY ord), '[]'::jsonb)
    FROM unnest(COALESCE(p_fields, ARRAY[]::text[])) WITH ORDINALITY AS t(f, ord)
   WHERE NOT public.change_field_hidden(f);
$function$;

-- The same list as one readable run of text, for the CPR change report.
CREATE OR REPLACE FUNCTION public.change_diff_text(p_agency uuid, p_fields text[], p_old jsonb, p_new jsonb)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT NULLIF(string_agg(
           (d ->> 'label') || ': ' || (d ->> 'before') || ' to ' || (d ->> 'after'), '; '), '')
    FROM jsonb_array_elements(public.change_diff(p_agency, p_fields, p_old, p_new)) AS t(d);
$function$;
