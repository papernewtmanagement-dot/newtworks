-- Two fixes.
--
-- 1. "record sp is not assigned yet". The chargeback trigger only ran its
--    first lookup when the cancelation already pointed at a sold policy, then
--    tested sp.id either way. With nothing to point at, sp had never been
--    given a shape and the whole cancelation failed. Any cancelation for a
--    household with no policy in the log hit this, not just the conversions
--    from the spot-check. Running the lookup unconditionally fixes it: with
--    no match the record comes back with empty fields, which is what the
--    test below it expects.
--
-- 2. An activity that requires the ECRM link could have it cleared on edit.
--    The requirement now holds on the way out as well as the way in.

DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace AND proname = 'cancelation_log_chargeback';
  IF position('IF NEW.matched_sale_product_id IS NOT NULL THEN' in d) = 0 THEN RETURN; END IF;
  IF position('months'')::interval > NEW.canceled_on;
  END IF;
  IF sp.id IS NULL THEN' in d) = 0 THEN
    RAISE EXCEPTION 'cancelation_log_chargeback does not look the way this migration expects';
  END IF;
  d := replace(d, '  IF NEW.matched_sale_product_id IS NOT NULL THEN
    SELECT p.id,', '    SELECT p.id,');
  d := replace(d, 'months'')::interval > NEW.canceled_on;
  END IF;
  IF sp.id IS NULL THEN', 'months'')::interval > NEW.canceled_on;
  IF sp.id IS NULL THEN');
  EXECUTE d;
END $do$;

DO $do$
DECLARE d text; old text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace AND proname = 'rp_edit_activity';
  IF position('requires_ecrm' in d) > 0 THEN RETURN; END IF;
  old := '  WHERE id = p_id;
  RETURN jsonb_build_object(''ok'', true, ''id'', p_id);';
  IF position(old in d) = 0 THEN
    RAISE EXCEPTION 'rp_edit_activity does not look the way this migration expects';
  END IF;
  EXECUTE replace(d, old, '  WHERE id = p_id;
  -- The link cannot be cleared off something that requires it.
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_ecrm AND l.ecrm_url IS NULL) THEN
    RAISE EXCEPTION ''this one needs the ECRM link, so it cannot be cleared'';
  END IF;
  RETURN jsonb_build_object(''ok'', true, ''id'', p_id);');
END $do$;
