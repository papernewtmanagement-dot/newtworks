-- The spot-check screen now shows two kinds of record, so Verified, the note
-- box and Remove all take the kind alongside the id and send the work to the
-- one function that already owns that table. No second copy of any rule.

CREATE OR REPLACE FUNCTION public.rp_verify_sale(p_id uuid, p_note text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; n integer; v_note text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can verify entries' USING ERRCODE='42501'; END IF;
  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  UPDATE public.sales_log
     SET verified_at = now(), verified_by = a.actor_id, updated_at = now(),
         spot_check_note = COALESCE(v_note, spot_check_note)
   WHERE id = p_id AND agency_id = a.agency_id AND status = 'active' AND verified_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'nothing to verify: sale not found, already verified, or removed'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'note', v_note);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_spot_check_note_sale(p_id uuid, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can leave a spot-check note' USING ERRCODE='42501'; END IF;
  UPDATE public.sales_log
     SET spot_check_note = NULLIF(btrim(COALESCE(p_note, '')), ''), updated_at = now()
   WHERE id = p_id AND agency_id = a.agency_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'that sale is not on file any more'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_spot_check_verify(p_kind text, p_id uuid, p_note text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_kind = 'sale' THEN RETURN public.rp_verify_sale(p_id, p_note); END IF;
  IF p_kind = 'activity' THEN RETURN public.rp_verify_activity(p_id, p_note); END IF;
  RAISE EXCEPTION 'cannot verify a record of kind %', p_kind;
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
  RAISE EXCEPTION 'cannot leave a note on a record of kind %', p_kind;
END $function$;

CREATE OR REPLACE FUNCTION public.rp_spot_check_remove(p_kind text, p_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_kind = 'sale' THEN RETURN public.rp_void_sale(p_id, p_reason); END IF;
  IF p_kind = 'activity' THEN RETURN public.rp_void_activity(p_id, p_reason); END IF;
  RAISE EXCEPTION 'cannot remove a record of kind %', p_kind;
END $function$;
