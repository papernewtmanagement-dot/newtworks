-- Peter 2026-09-19: a Policy Change and a cancelation both have to carry the
-- ECRM link, so either one can be checked against the opportunity. A sale
-- already required it.
--
-- The rule sits next to requires_note on each activity, so which activities
-- need a link is set in the point values table rather than in code.
--
-- rp_log_entry, rp_log_activity, rp_log_cancelation and rp_entry_rows are
-- large and unrelated to this change apart from a line each, so each is read
-- back and the one line edited, rather than retyped from memory where a
-- stale copy could quietly undo something else.

ALTER TABLE public.retention_point_values
  ADD COLUMN IF NOT EXISTS requires_ecrm boolean NOT NULL DEFAULT false;

UPDATE public.retention_point_values
   SET requires_ecrm = true
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND activity_key = 'service_task';

ALTER TABLE public.cancelation_log
  ADD COLUMN IF NOT EXISTS ecrm_url text;

DO $do$
DECLARE d text; old text; new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_log_activity';
  IF position('requires_ecrm' in d) > 0 THEN RETURN; END IF;
  old := 'RAISE EXCEPTION ''% needs a note on what you covered / the reason'', v.label;
    END IF;';
  new := old || '
    IF v.requires_ecrm AND v_url IS NULL THEN
      RAISE EXCEPTION ''% needs the ECRM link so it can be checked'', v.label;
    END IF;';
  IF position(old in d) = 0 THEN RAISE EXCEPTION 'rp_log_activity does not look the way this migration expects'; END IF;
  EXECUTE replace(d, old, new);
END $do$;

DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_log_cancelation';
  IF position('v_ecrm' in d) > 0 THEN RETURN; END IF;
  IF position('v_pref uuid;' in d) = 0
     OR position('v_pref := NULLIF(p->>''matched_sale_product_id'','''')::uuid;' in d) = 0
     OR position('created_by, matched_sale_product_id, is_replacement)' in d) = 0
     OR position('a.actor_id, v_pref, COALESCE((p->>''replacement'')::boolean, false))' in d) = 0 THEN
    RAISE EXCEPTION 'rp_log_cancelation does not look the way this migration expects';
  END IF;
  d := replace(d, 'v_pref uuid;', 'v_pref uuid; v_ecrm text;');
  d := replace(d,
    'v_pref := NULLIF(p->>''matched_sale_product_id'','''')::uuid;',
    'v_pref := NULLIF(p->>''matched_sale_product_id'','''')::uuid;
  v_ecrm := NULLIF(btrim(COALESCE(p->>''ecrm_url'','''')), '''');
  IF v_ecrm IS NULL THEN RAISE EXCEPTION ''a cancelation needs the ECRM link''; END IF;
  IF v_ecrm !~* ''^https?://'' THEN RAISE EXCEPTION ''the ECRM link must start with http''; END IF;');
  d := replace(d,
    'created_by, matched_sale_product_id, is_replacement)',
    'created_by, matched_sale_product_id, is_replacement, ecrm_url)');
  d := replace(d,
    'a.actor_id, v_pref, COALESCE((p->>''replacement'')::boolean, false))',
    'a.actor_id, v_pref, COALESCE((p->>''replacement'')::boolean, false), v_ecrm)');
  EXECUTE d;
END $do$;

DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_log_entry';
  IF position('''ecrm_url'', v_url,' in d) > 0 THEN RETURN; END IF;
  IF position('''matched_sale_product_id'', it->>''matched_sale_product_id'',' in d) = 0 THEN
    RAISE EXCEPTION 'rp_log_entry does not look the way this migration expects';
  END IF;
  EXECUTE replace(d,
    '''matched_sale_product_id'', it->>''matched_sale_product_id'',',
    '''matched_sale_product_id'', it->>''matched_sale_product_id'', ''ecrm_url'', v_url,');
END $do$;

DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_entry_rows';
  IF position('c.ecrm_url::text' in d) > 0 THEN RETURN; END IF;
  IF position('c.note::text, NULL::text,' in d) = 0 THEN
    RAISE EXCEPTION 'rp_entry_rows does not look the way this migration expects';
  END IF;
  EXECUTE replace(d, 'c.note::text, NULL::text,', 'c.note::text, c.ecrm_url::text,');
END $do$;

REVOKE EXECUTE ON FUNCTION public.rp_entry_rows(uuid, date, date, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rp_entry_rows(uuid, date, date, boolean) FROM anon, authenticated;

-- The spot-check lists show the customer the way History does, name plus the
-- last four, so the household is identified the same everywhere.
DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);
CREATE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, phone_last4 text, note text, ecrm_url text,
              points numeric, remaining integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end))
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, p.phone_last4, p.note, p.ecrm_url, p.points, (SELECT count(*) FROM pool)::integer
  FROM pool p
  ORDER BY md5(p.id::text || public.rp_week_end(p_week_end)::text)
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50));
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;

-- The conversion needs a link too. It uses the one on the entry when there is
-- one, and otherwise takes what the screen was given.
DROP FUNCTION IF EXISTS public.rp_convert_activity_to_cancelation(uuid, jsonb);
CREATE FUNCTION public.rp_convert_activity_to_cancelation(
  p_activity_id uuid,
  p_policies jsonb,
  p_ecrm_url text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; l RECORD; item jsonb; res jsonb; v_ids uuid[] := '{}'; v_url text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can turn an entry into a cancelation'; END IF;

  SELECT * INTO l FROM public.retention_activity_log
   WHERE id = p_activity_id AND agency_id = a.agency_id AND status = 'credited';
  IF NOT FOUND THEN RAISE EXCEPTION 'that entry is not on file any more'; END IF;

  IF p_policies IS NULL OR jsonb_typeof(p_policies) <> 'array' OR jsonb_array_length(p_policies) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy that canceled';
  END IF;

  v_url := COALESCE(NULLIF(btrim(COALESCE(l.ecrm_url, '')), ''), NULLIF(btrim(COALESCE(p_ecrm_url, '')), ''));

  FOR item IN SELECT * FROM jsonb_array_elements(p_policies) LOOP
    res := public.rp_log_cancelation(jsonb_build_object(
      'team_member_id', l.team_member_id,
      'canceled_on', l.occurred_on,
      'customer_first', l.customer_first_name,
      'customer_last_initial', l.customer_last_initial,
      'policy_line', item->>'policy_line',
      'product_type', item->>'product_type',
      'premium', item->>'premium',
      'vehicle_count', item->>'vehicle_count',
      'matched_sale_product_id', item->>'matched_sale_product_id',
      'reason', COALESCE(NULLIF(btrim(COALESCE(item->>'reason','')), ''), 'other'),
      'note', l.note,
      'ecrm_url', v_url
    ));
    v_ids := v_ids || (res->>'cancelation_id')::uuid;
  END LOOP;

  PERFORM public.rp_void_activity(p_activity_id, 'spot-check: this was a cancelation, not a ' ||
    COALESCE((SELECT v.label FROM public.retention_point_values v
               WHERE v.agency_id = a.agency_id AND v.activity_key = l.activity_key), l.activity_key));

  RETURN jsonb_build_object('ok', true, 'cancelation_ids', to_jsonb(v_ids),
                            'count', array_length(v_ids, 1), 'customer', l.customer_label);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_convert_activity_to_cancelation(uuid, jsonb, text) TO authenticated;
