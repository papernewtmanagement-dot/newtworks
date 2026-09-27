-- One per household (Peter 2026-09-26): a household holds one PLUP and one PAP. A new one replaces the
-- older one on the books: the older one is canceled as a replacement in the same save and charged back as
-- normal (inside the chargeback window). Every other product keeps the Replaces it / Added / Different
-- household question, since most fire policies can be held more than once.

ALTER TABLE public.product_types ADD COLUMN IF NOT EXISTS one_per_household boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.product_types.one_per_household IS
  'A household holds one of these. A new one cancels and charges back the older one on the books (Peter 2026-09-26: PLUP and PAP).';
UPDATE public.product_types SET one_per_household = true
 WHERE line_of_business = 'fire' AND type_key IN ('plup', 'pap') AND NOT one_per_household;

-- Writing a cancelation, in one place. rp_log_cancelation (a person logging one) and the one-per-household
-- replacement both use it; only who is allowed to log it differs.
CREATE OR REPLACE FUNCTION public.rp_cancelation_write(p_agency uuid, p_team_member uuid, p_actor uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_type text; v_reason text; v_note text;
  v_prem numeric; v_veh integer; v_id uuid; r RECORD; v_pref uuid; v_ecrm text;
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
  v_backfill boolean := COALESCE((p->>'backfill')::boolean, false);
BEGIN
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
  v_type := public.rp_check_product_type(p_agency, v_line, p->>'product_type');
  v_prem := NULLIF(p->>'premium','')::numeric;
  IF v_prem IS NOT NULL AND v_prem < 0 THEN RAISE EXCEPTION 'premium cannot be negative'; END IF;
  IF v_prem IS NOT NULL AND v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_line; END IF;
  v_veh := CASE WHEN v_line = 'auto' THEN NULLIF(p->>'vehicle_count','')::integer ELSE NULL END;
  IF v_veh IS NOT NULL AND v_veh < 1 THEN RAISE EXCEPTION 'how many cars on the canceled auto policy?'; END IF;
  v_reason := NULLIF(btrim(COALESCE(p->>'reason','')), '');
  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');
  IF v_note IS NULL AND NOT v_backfill THEN
    RAISE EXCEPTION 'a cancelation needs a note on why it canceled';
  END IF;
  v_pref := NULLIF(p->>'matched_sale_product_id','')::uuid;
  v_ecrm := NULLIF(btrim(COALESCE(p->>'ecrm_url','')), '');
  IF v_ecrm IS NULL THEN RAISE EXCEPTION 'a cancelation needs the ECRM link'; END IF;
  IF v_ecrm !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM link must start with http'; END IF;
  INSERT INTO public.cancelation_log
    (agency_id, team_member_id, canceled_on, week_end_date, customer_first_name, customer_last_initial, customer_kind,
     policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id, is_replacement, ecrm_url, entry_source)
  VALUES
    (p_agency, p_team_member, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_line, v_type, v_prem, v_veh, v_reason, v_note, p_actor, v_pref, COALESCE((p->>'replacement')::boolean, false), v_ecrm, CASE WHEN v_backfill THEN 'historical_backfill' ELSE 'manual' END)
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

CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(COALESCE(p_payload, '{}'::jsonb)->>'team_member_id','')::uuid);
  RETURN public.rp_cancelation_write(a.agency_id, a.team_member_id, a.actor_id, p_payload);
END $function$;

-- The replacement itself. Runs for a new or retyped policy on a live sale: every older policy of the same
-- one-per-household type the household still has on the books is canceled as a replacement, dated the day
-- the new one was sold, under the seller of the new one. The chargeback follows the normal rules.
CREATE OR REPLACE FUNCTION public.rp_replace_one_per_household(p_product_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  sp public.sales_log_products; s public.sales_log; o RECORD;
  v_actor uuid; v_type_label text; v_first uuid; n integer := 0; res jsonb; v_cid uuid;
BEGIN
  SELECT * INTO sp FROM public.sales_log_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT * INTO s FROM public.sales_log WHERE id = sp.sales_log_id;
  IF NOT FOUND OR s.status <> 'active' OR COALESCE(s.entry_source, 'manual') = 'historical_backfill' THEN RETURN 0; END IF;
  SELECT pt.label INTO v_type_label FROM public.product_types pt
   WHERE pt.agency_id = s.agency_id AND pt.line_of_business = sp.line_of_business
     AND pt.type_key = sp.product_type AND pt.one_per_household;
  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT t.id INTO v_actor
    FROM public.team t JOIN public.users u ON u.id = t.user_id
   WHERE u.auth_user_id = auth.uid() AND t.archived_at IS NULL LIMIT 1;

  FOR o IN
    SELECT op.id, op.line_of_business, op.product_type, COALESCE(op.issued_premium, op.premium) AS premium
      FROM public.sales_log os
      JOIN public.sales_log_products op ON op.sales_log_id = os.id
     WHERE os.agency_id = s.agency_id AND os.status = 'active' AND os.id <> s.id
       AND os.customer_label = s.customer_label
       AND (os.phone_last4 IS NULL OR s.phone_last4 IS NULL OR os.phone_last4 = s.phone_last4)
       AND op.line_of_business = sp.line_of_business AND op.product_type = sp.product_type
       AND (os.submitted_date, os.created_at) < (s.submitted_date, s.created_at)
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c
                        WHERE c.matched_sale_product_id = op.id AND c.status = 'active')
     ORDER BY os.submitted_date DESC
  LOOP
    res := public.rp_cancelation_write(s.agency_id, s.team_member_id, v_actor, jsonb_build_object(
      'customer_first', s.customer_first_name, 'customer_last_initial', s.customer_last_initial,
      'customer_kind', s.customer_kind, 'canceled_on', s.submitted_date,
      'policy_line', o.line_of_business, 'product_type', o.product_type, 'premium', o.premium,
      'matched_sale_product_id', o.id, 'replacement', true, 'ecrm_url', s.ecrm_opportunity_url,
      'note', format('Replaced by the new %s sold %s', v_type_label, to_char(s.submitted_date, 'Mon FMDD'))));
    v_cid := (res->>'cancelation_id')::uuid;
    IF s.phone_last4 IS NOT NULL THEN
      UPDATE public.cancelation_log SET phone_last4 = s.phone_last4 WHERE id = v_cid AND phone_last4 IS NULL;
    END IF;
    v_first := COALESCE(v_first, o.id);
    n := n + 1;
  END LOOP;

  IF n > 0 AND s.on_file_answer IS NULL THEN
    UPDATE public.sales_log SET on_file_answer = 'replaces', replaced_sale_product_id = v_first WHERE id = s.id;
  END IF;
  RETURN n;
END $function$;

-- Runs when the save commits, so the whole sale is on file first.
CREATE OR REPLACE FUNCTION public.tg_rp_one_per_household()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  PERFORM public.rp_replace_one_per_household(NEW.id);
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS zz_rp_one_per_household ON public.sales_log_products;
CREATE CONSTRAINT TRIGGER zz_rp_one_per_household
  AFTER INSERT OR UPDATE OF product_type, line_of_business
  ON public.sales_log_products
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.tg_rp_one_per_household();

REVOKE ALL ON FUNCTION public.rp_cancelation_write(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rp_replace_one_per_household(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_rp_one_per_household() FROM PUBLIC, anon, authenticated;
