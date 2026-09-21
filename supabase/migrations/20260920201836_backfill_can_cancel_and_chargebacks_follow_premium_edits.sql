-- Peter 2026-09-20, two things that belong together.
--
-- 1) The backfill can mark a policy canceled on a date he picks, and it charges
--    back. These are old records, so the usual 90-day floor on logging a
--    cancelation does not apply to them. That floor is relaxed ONLY for the
--    backfill, by an explicit flag on the payload, and nothing else is.
--
-- 2) A chargeback has to use the premium he is applying, not the stale one.
--    Two halves: inside one save the premium is written BEFORE the cancelation
--    is logged, and rp_mark_issued now carries a changed premium onto any live
--    cancelation already matched to that policy. The sales-points side needed
--    nothing: production_rows_for reads the policy's own premium, so it follows
--    on its own.

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_prem numeric; v_raw text; v_n integer := 0;
  v_today date := public.rp_today_central(); v_synced integer := 0; v_k integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy to mark issued';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := NULLIF(it->>'sale_product_id','')::uuid;
    v_on := COALESCE(NULLIF(it->>'issued_date','')::date, v_today);
    -- "$1,527.10" is a premium. Drop the formatting, keep the number.
    v_raw := NULLIF(regexp_replace(COALESCE(it->>'issued_premium',''), '[^0-9.\-]', '', 'g'), '');
    IF v_raw IS NOT NULL AND v_raw !~ '^-?[0-9]*\.?[0-9]+$' THEN
      RAISE EXCEPTION 'the issued premium has to be a number';
    END IF;
    v_prem := v_raw::numeric;
    IF v_on > v_today THEN RAISE EXCEPTION 'the issue date cannot be in the future'; END IF;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'the issued premium looks too large. Double-check it.'; END IF;
    SELECT s.submitted_date INTO v_sub
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;
    IF v_on < v_sub THEN RAISE EXCEPTION 'a policy cannot issue before it was submitted (submitted %)', v_sub; END IF;
    UPDATE public.sales_log_products SET issued_date = v_on, issued_premium = v_prem WHERE id = v_id;
    v_n := v_n + 1;

    -- A live cancelation on this policy recorded the premium as it stood then.
    -- Changing the premium changes what was lost, so the cancelation follows
    -- (Peter 2026-09-20). Only the amount moves; the chargeback points are the
    -- multiline credit times the window left, and that does not depend on it.
    UPDATE public.cancelation_log c
       SET premium = v_prem, updated_at = now()
     WHERE c.matched_sale_product_id = v_id
       AND c.status = 'active'
       AND c.premium IS DISTINCT FROM v_prem;
    GET DIAGNOSTICS v_k = ROW_COUNT; v_synced := v_synced + v_k;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n, 'cancelations_repriced', v_synced);
END $function$;

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_type text; v_reason text; v_note text;
  v_prem numeric; v_veh integer; v_id uuid; r RECORD; v_pref uuid; v_ecrm text;
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
  v_backfill boolean := COALESCE((p->>'backfill')::boolean, false);
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'canceled_on','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'the cancelation date cannot be in the future'; END IF;
  -- Backfilled history is older than the 90-day rule by definition. Everything
  -- else still has to be logged inside it.
  IF NOT v_backfill AND v_on < v_today - 90 THEN
    RAISE EXCEPTION 'log a cancelation within 90 days of the date it happened';
  END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial', v_kind);
  v_line  := NULLIF(lower(btrim(COALESCE(p->>'policy_line',''))), '');
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable','bank') THEN
    RAISE EXCEPTION 'pick the policy line that canceled';
  END IF;
  v_type := public.rp_check_product_type(a.agency_id, v_line, p->>'product_type');
  v_prem := NULLIF(p->>'premium','')::numeric;
  IF v_prem IS NOT NULL AND v_prem < 0 THEN RAISE EXCEPTION 'premium cannot be negative'; END IF;
  IF v_prem IS NOT NULL AND v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_line; END IF;
  v_veh := CASE WHEN v_line = 'auto' THEN NULLIF(p->>'vehicle_count','')::integer ELSE NULL END;
  IF v_veh IS NOT NULL AND v_veh < 1 THEN RAISE EXCEPTION 'how many cars on the canceled auto policy?'; END IF;
  v_reason := NULLIF(btrim(COALESCE(p->>'reason','')), '');
  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');
  v_pref := NULLIF(p->>'matched_sale_product_id','')::uuid;
  v_ecrm := NULLIF(btrim(COALESCE(p->>'ecrm_url','')), '');
  IF v_ecrm IS NULL THEN RAISE EXCEPTION 'a cancelation needs the ECRM link'; END IF;
  IF v_ecrm !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM link must start with http'; END IF;
  INSERT INTO public.cancelation_log
    (agency_id, team_member_id, canceled_on, week_end_date, customer_first_name, customer_last_initial, customer_kind,
     customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id, is_replacement, ecrm_url)
  VALUES
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_label, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id, v_pref, COALESCE((p->>'replacement')::boolean, false), v_ecrm)
  RETURNING id INTO v_id;
  SELECT c.saves_voided, c.matched_sale_product_id, c.chargeback_points, c.window_fraction_left, s.submitted_date
    INTO r FROM public.cancelation_log c
    LEFT JOIN public.sales_log_products sp ON sp.id = c.matched_sale_product_id
    LEFT JOIN public.sales_log s ON s.id = sp.sales_log_id
   WHERE c.id = v_id;
  RETURN jsonb_build_object('ok', true, 'cancelation_id', v_id, 'customer', v_label,
                            'policy_line', v_line, 'product_type', v_type, 'premium', v_prem, 'vehicle_count', v_veh,
                            'saves_voided', r.saves_voided, 'matched_submitted_date', r.submitted_date,
                            'chargeback_points', r.chargeback_points, 'window_fraction_left', r.window_fraction_left,
                            'matched', (r.matched_sale_product_id IS NOT NULL));
END $function$;

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; rec jsonb; x jsonb; v_id uuid; v_kind text; v_label text;
  v_phone text; v_ecrm text; v_src text; v_refcust text; v_refby uuid;
  v_items jsonb; v_touched boolean;
  v_saved integer := 0; v_spread integer := 0; v_issued integer := 0; n integer;
  v_canceled integer := 0; v_charged integer := 0;
  v_on date; v_res jsonb; sp RECORD; sl RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'nothing to save'; END IF;
  IF jsonb_array_length(p_rows) > 200 THEN RAISE EXCEPTION 'more than 200 rows in one save. Do it in two passes.'; END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_kind := lower(COALESCE(rec->>'kind',''));
    v_id   := NULLIF(rec->>'id','')::uuid;
    IF v_id IS NULL OR v_kind NOT IN ('sale','quote') THEN CONTINUE; END IF;
    v_touched := false;
    v_label := NULL;

    v_phone := NULLIF(regexp_replace(COALESCE(rec->>'phone_last4',''), '\D', '', 'g'), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^\d{4}$' THEN
      RAISE EXCEPTION 'the last four digits of the phone, four numbers';
    END IF;

    v_ecrm := NULLIF(btrim(COALESCE(rec->>'ecrm','')), '');
    IF v_ecrm IS NOT NULL AND v_ecrm !~* '^https?://' THEN
      RAISE EXCEPTION 'an ECRM link has to start with http';
    END IF;

    v_src := NULLIF(btrim(COALESCE(rec->>'marketing_source','')), '');
    IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
        WHERE agency_id = a.agency_id AND source_key = v_src AND is_active) THEN
      RAISE EXCEPTION 'pick the marketing source';
    END IF;

    v_refcust := NULLIF(btrim(COALESCE(rec->>'referred_by_customer','')), '');
    v_refby   := NULLIF(rec->>'sourced_by_team_member_id','')::uuid;

    IF v_phone IS NOT NULL OR v_ecrm IS NOT NULL OR v_src IS NOT NULL OR v_refcust IS NOT NULL OR v_refby IS NOT NULL THEN
      IF v_kind = 'sale' THEN
        UPDATE public.sales_log SET
          phone_last4 = COALESCE(v_phone, phone_last4),
          ecrm_opportunity_url = COALESCE(v_ecrm, ecrm_opportunity_url),
          marketing_source = COALESCE(v_src, marketing_source),
          referred_by_customer = COALESCE(v_refcust, referred_by_customer),
          sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
          updated_at = now()
        WHERE id = v_id AND agency_id = a.agency_id AND status = 'active'
        RETURNING customer_label INTO v_label;
      ELSE
        UPDATE public.quote_log SET
          phone_last4 = COALESCE(v_phone, phone_last4),
          marketing_source = COALESCE(v_src, marketing_source),
          referred_by_customer = COALESCE(v_refcust, referred_by_customer),
          sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
          updated_at = now()
        WHERE id = v_id AND agency_id = a.agency_id AND status = 'active'
        RETURNING customer_label INTO v_label;
      END IF;
      IF v_label IS NOT NULL THEN v_touched := true; END IF;
    END IF;

    -- Issuing a policy is rp_mark_issued's job, here as everywhere else. This
    -- runs BEFORE any cancelation below, so a chargeback logged in the same
    -- save is priced off the premium being applied, not the old one.
    IF v_kind = 'sale' AND jsonb_typeof(rec->'policies') = 'array' THEN
      SELECT jsonb_agg(jsonb_build_object(
               'sale_product_id', x->>'id',
               'issued_date', COALESCE(NULLIF(x->>'issued_date',''), (SELECT p.issued_date::text FROM public.sales_log_products p
                                                                       WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id)),
               'issued_premium', x->>'issued_premium'))
        INTO v_items
        FROM jsonb_array_elements(rec->'policies') x
       WHERE NULLIF(btrim(COALESCE(x->>'issued_premium','')), '') IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.sales_log_products p
                      WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id);
      IF v_items IS NOT NULL AND jsonb_array_length(v_items) > 0 THEN
        PERFORM public.rp_mark_issued(v_items);
        v_issued := v_issued + jsonb_array_length(v_items);
        v_touched := true;
      END IF;
    END IF;

    -- A policy marked canceled on a date he picked. Logged through
    -- rp_log_cancelation like every other cancelation, so the chargeback, the
    -- voided saves and the matching all behave the same; the only thing the
    -- backfill flag changes is the 90-day floor on how old the date may be.
    IF v_kind = 'sale' AND jsonb_typeof(rec->'policies') = 'array' THEN
      SELECT s.* INTO sl FROM public.sales_log s WHERE s.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
      FOR x IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        v_on := NULLIF(btrim(COALESCE(x->>'canceled_on','')), '')::date;
        CONTINUE WHEN v_on IS NULL OR sl.id IS NULL;
        SELECT p.* INTO sp FROM public.sales_log_products p
         WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;
        CONTINUE WHEN sp.id IS NULL;
        -- Already canceled? Leave it alone rather than stacking a second one.
        CONTINUE WHEN EXISTS (SELECT 1 FROM public.cancelation_log c
                               WHERE c.matched_sale_product_id = sp.id AND c.status = 'active');
        IF sl.ecrm_opportunity_url IS NULL OR btrim(sl.ecrm_opportunity_url) = '' THEN
          RAISE EXCEPTION 'marking % canceled needs the ECRM link on the household first', sl.customer_label;
        END IF;
        v_res := public.rp_log_cancelation(jsonb_build_object(
          'backfill', true,
          'team_member_id', sl.team_member_id,
          'customer_first', sl.customer_first_name,
          'customer_last_initial', sl.customer_last_initial,
          'customer_kind', sl.customer_kind,
          'canceled_on', v_on::text,
          'policy_line', sp.line_of_business,
          'product_type', sp.product_type,
          -- the premium as it stands right now, after the issue above
          'premium', COALESCE(sp.issued_premium, sp.premium)::text,
          'vehicle_count', sp.vehicle_count::text,
          'matched_sale_product_id', sp.id::text,
          'ecrm_url', sl.ecrm_opportunity_url,
          'reason', 'Backfilled from the history load',
          'note', 'Marked canceled from the Backfill tab'));
        v_canceled := v_canceled + 1;
        IF COALESCE((v_res->>'matched')::boolean, false) THEN v_charged := v_charged + 1; END IF;
        v_touched := true;
      END LOOP;
    END IF;

    IF v_touched THEN v_saved := v_saved + 1; END IF;

    IF v_phone IS NOT NULL AND v_label IS NOT NULL THEN
      UPDATE public.sales_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.quote_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.cancelation_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.retention_activity_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;

    -- Same for the marketing source (Peter 2026-09-20). Only rows that have
    -- none are filled; nothing already answered is overwritten.
    IF v_src IS NOT NULL AND v_label IS NOT NULL THEN
      UPDATE public.sales_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND COALESCE(btrim(marketing_source), '') = '';
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.quote_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND COALESCE(btrim(marketing_source), '') = '';
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;

    -- And the ECRM link (Peter 2026-09-20): one link for the household. Sales
    -- only; a quote carries no link.
    IF v_ecrm IS NOT NULL AND v_label IS NOT NULL THEN
      UPDATE public.sales_log SET ecrm_opportunity_url = v_ecrm, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND COALESCE(btrim(ecrm_opportunity_url), '') = '';
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;
  END LOOP;

  UPDATE public.cancelation_log c SET phone_last4 = s.phone_last4, updated_at = now()
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE c.matched_sale_product_id = p.id
     AND c.agency_id = a.agency_id AND c.status = 'active'
     AND c.phone_last4 IS NULL AND s.phone_last4 IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

  RETURN jsonb_build_object('ok', true, 'rows_saved', v_saved, 'policies_issued', v_issued,
                            'also_filled', v_spread,
                            'policies_canceled', v_canceled, 'charged_back', v_charged);
END $function$;
