-- Review Ask and Referral Ask: tracked at $0 like Pivot. The ask has no
-- retention value of its own; the outcome pays (Google Review $5, Referral
-- Sold $10). Asks per rep against outcomes per rep is the coaching number.
INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, is_active, description) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'review_ask', 'Review Ask', 0.00, 'logged', false, 6, true,
  'You asked the customer for a Google review. Tracking only. The review itself pays when it posts.'),
 ('126794dd-25ff-47d2-a436-724499733365', 'referral_ask', 'Referral Ask', 0.00, 'logged', false, 7, true,
  'You asked the customer who else they know that should hear from us. Tracking only. Referral Sold pays when the referral becomes a household.')
ON CONFLICT (agency_id, activity_key) DO UPDATE
  SET label = EXCLUDED.label, points = EXCLUDED.points, sort_order = EXCLUDED.sort_order,
      description = EXCLUDED.description, is_active = true, updated_at = now();

-- Undo right after logging. Takes the exact result rp_log_entry returned and
-- voids every row it created, in one transaction, through the same void
-- functions the Remove buttons use (so the 7-day / own-entries rules hold).
-- A cancelation that took back unpaid saves gives them back.
CREATE OR REPLACE FUNCTION public.rp_undo_entry(p_result jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb := COALESCE(p_result, '{}'::jsonb); it jsonb; v_n integer := 0; v_cxl uuid; v_why text := 'undone right after logging';
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(r->'activity'->'items', '[]'::jsonb)) LOOP
    PERFORM public.rp_void_activity((it->>'id')::uuid, v_why); v_n := v_n + 1;
  END LOOP;
  IF NULLIF(r->'quote'->>'quote_id', '') IS NOT NULL THEN
    PERFORM public.rp_void_quote((r->'quote'->>'quote_id')::uuid, v_why); v_n := v_n + 1;
  END IF;
  IF NULLIF(r->'sale'->>'sale_id', '') IS NOT NULL THEN
    PERFORM public.rp_void_sale((r->'sale'->>'sale_id')::uuid, v_why); v_n := v_n + 1;
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r->'cancelation') = 'array' THEN r->'cancelation' ELSE '[]'::jsonb END) LOOP
    v_cxl := (it->>'cancelation_id')::uuid;
    PERFORM public.rp_void_cancelation(v_cxl, v_why);
    UPDATE public.retention_activity_log l
       SET status = 'credited', voided_at = NULL, voided_by = NULL, void_reason = NULL, updated_at = now()
      FROM public.cancelation_log c
     WHERE c.id = v_cxl AND l.agency_id = c.agency_id
       AND l.activity_key = 'cancelation_saved' AND l.status = 'void'
       AND l.customer_label = c.customer_label AND l.save_line = c.policy_line
       AND l.voided_at >= c.created_at - interval '1 second'
       AND l.void_reason LIKE 'policy canceled %';
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'undone', v_n);
END $function$;
REVOKE ALL ON FUNCTION public.rp_undo_entry(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_undo_entry(jsonb) TO authenticated;
