CREATE OR REPLACE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; item jsonb; v RECORD;
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_key text; v_reason text; v_line text; v_type text;
  v_credit_on date; v_credit_week date; v_id uuid;
  v_created jsonb := '[]'::jsonb; v_total numeric := 0; v_note text; v_url text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(p_team_member_id);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'check at least one thing you did';
  END IF;
  v_on := COALESCE(p_occurred_on, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log within 7 days of when it happened'; END IF;
  v_label := public.rp_customer_label(p_customer_first, p_customer_last_initial);
  v_note := NULLIF(btrim(COALESCE(p_note,'')), '');
  v_url  := NULLIF(btrim(COALESCE(p_ecrm_url,'')), '');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_key := item->>'activity_key';
    SELECT * INTO v FROM public.retention_point_values
    WHERE agency_id = a.agency_id AND activity_key = v_key AND is_active AND category = 'logged';
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown or not-loggable item: %', v_key; END IF;
    IF v.requires_note AND v_note IS NULL AND NULLIF(btrim(COALESCE(item->>'save_reason','')),'') IS NULL THEN
      RAISE EXCEPTION '% needs a note on what you covered / the reason', v.label;
    END IF;
    -- Peter 2026-09-15: a save is credited per POLICY, so several saves for the
    -- same household on the same day are normal. Same reason autopay is exempt.
    IF v_key NOT IN ('autopay_enrollment', 'cancelation_saved') AND EXISTS (SELECT 1 FROM public.retention_activity_log l
               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id
                 AND l.activity_key = v_key AND l.customer_label = v_label AND l.occurred_on = v_on
                 AND l.status = 'credited' AND l.created_at < now()) THEN
      RAISE EXCEPTION '% for % is already logged for %. Use Undo or remove the first one if that was a mistake.',
        v.label, v_label, CASE WHEN v_on = v_today THEN 'today' ELSE to_char(v_on, 'Mon FMDD') END;
    END IF;

    v_credit_on := NULL; v_credit_week := public.rp_week_end(v_on); v_reason := NULL; v_line := NULL; v_type := NULL;
    IF v_key = 'cancelation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      v_type   := NULLIF(btrim(COALESCE(item->>'product_type','')), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable','bank') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      -- The unit is one policy. Line alone cannot tell two auto policies in the
      -- same household apart, so the type is required wherever the line has types.
      IF v_type IS NULL AND EXISTS (SELECT 1 FROM public.product_types pt
                                     WHERE pt.agency_id = a.agency_id AND pt.line_of_business = v_line) THEN
        RAISE EXCEPTION 'a save needs the policy type that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancelation_saved' AND l.status = 'credited'
                   AND l.customer_label = v_label AND l.save_line = v_line
                   AND COALESCE(l.product_type, '') = COALESCE(v_type, '')
                   AND l.occurred_on > v_on - 90) THEN
        RAISE EXCEPTION 'one save per policy per ninety days — % already has a % save on file', v_label, COALESCE(v_type, v_line);
      END IF;
      v_credit_on := v_on + 30;
      v_credit_week := public.rp_week_end(v_credit_on);
    END IF;

    INSERT INTO public.retention_activity_log
      (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date, credit_available_on,
       customer_first_name, customer_last_initial, customer_label, ecrm_url, note, save_reason, save_line, points, source, created_by, policy_line, product_type, premium)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), upper(btrim(p_customer_last_initial)), v_label, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id,
       NULLIF(lower(btrim(COALESCE(item->>'policy_line',''))), ''), NULLIF(btrim(COALESCE(item->>'product_type','')), ''), NULLIF(item->>'premium','')::numeric)
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
END $function$;
