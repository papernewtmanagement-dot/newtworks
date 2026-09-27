-- Vehicle swaps (Peter 2026-09-26). A household that takes a vehicle off and puts one on within
-- rp_vehicle_swap_days() of each other, in either order, swapped cars. The added auto is not a sale:
-- it turns into a replacement-vehicle Policy Change. Angelica S. 1373 was the first case.

-- One row per swap: the Policy Change that took a vehicle off, the added-auto sale it paired with,
-- and the replacement Policy Change the sale turned into. A removal pairs once.
CREATE TABLE IF NOT EXISTS public.vehicle_swaps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  removal_activity_id uuid NOT NULL UNIQUE REFERENCES public.retention_activity_log(id),
  sale_id uuid NOT NULL REFERENCES public.sales_log(id),
  sale_product_id uuid,
  replacement_activity_id uuid REFERENCES public.retention_activity_log(id),
  what_changed text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);
ALTER TABLE public.vehicle_swaps ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vehicle_swaps_admin_read ON public.vehicle_swaps;
CREATE POLICY vehicle_swaps_admin_read ON public.vehicle_swaps FOR SELECT TO authenticated
  USING (public.is_agency_admin() AND agency_id = (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1));

-- How far apart the two can be. State Farm's Texas car policy (form 9843C) covers a newly delivered car
-- on its own for 20 days, so the new car goes on inside that; taking the old one off can trail a
-- private sale by a week or more. 30 days covers both without reaching unrelated changes.
CREATE OR REPLACE FUNCTION public.rp_vehicle_swap_days()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT 30 $function$;

-- Does a Policy Change note say a vehicle came off (or was replaced)? "Removed Dodge", "remove vehicle
-- and add driver", "Replace Vehicle" do; "Remove Driver", "removed lienholder", "dropped off papers" do not.
CREATE OR REPLACE FUNCTION public.rp_note_removes_vehicle(p_note text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT EXISTS (
           SELECT 1
             FROM regexp_matches(lower(COALESCE(p_note, '')),
                  '(?:remov\w*|delet\w*|replac\w*|took\s+off|take\s+off|takes\s+off|taking\s+off|drop\w*)\s+((?:(?:a|an|the|her|his|their|my|our|old|older|1|one|both|other|that|this)\s+)*)(\w+)',
                  'g') m
            WHERE m[2] NOT IN (
              'driver','drivers','lienholder','lienholders','lien','liens','loss','payee','payees','mortgagee','mortgagees',
              'coverage','coverages','comp','comprehensive','collision','rental','towing','roadside','ers','endorsement',
              'endorsements','emergency','discount','discounts','autopay','card','cards','bank','account','payment','payments',
              'name','address','email','phone','number','spouse','wife','husband','son','daughter','kid','kids','child',
              'children','person','insured','additional','interest','violation','violations','ticket','tickets','accident',
              'accidents','claim','claims','glass','deductible','deductibles','um','uim','pip','medical','gap','id','ids',
              'sr22','excluded','exclusion','policy','policies','them','him','it','from','off','by','in','into','to','at',
              'for','with','and','on','out','down','up','of','over','back'))
      OR lower(COALESCE(p_note, '')) ~ '\m(car|cars|vehicle|vehicles|truck|trucks|van|suv|jeep|motorcycle)\M[^.]{0,20}\m(remov\w*|delet\w*|replac\w*|taken\s+off|dropped)'
$function$;

-- Voiding a sale's rows, written once. rp_void_sale (a person removing a sale) and the vehicle swap both use it.
CREATE OR REPLACE FUNCTION public.rp_void_sale_rows(p_id uuid, p_actor uuid, p_reason text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  UPDATE public.sales_log
     SET status = 'void', voided_at = now(), voided_by = p_actor,
         void_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''), updated_at = now()
   WHERE id = p_id AND status <> 'void';
  UPDATE public.retention_activity_log
     SET status = 'void', voided_at = now(), voided_by = p_actor, void_reason = 'sale entry removed', updated_at = now()
   WHERE source = 'sales_log' AND source_id = p_id AND status = 'credited';
$function$;

CREATE OR REPLACE FUNCTION public.rp_void_sale(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO r FROM public.sales_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  PERFORM public.rp_void_sale_rows(p_id, a.actor_id, p_reason);
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

-- Turn one added auto into a replacement-vehicle Policy Change, paired with the Policy Change that took a
-- vehicle off. One car of a several-car policy comes off that policy with its share of the premium; an auto
-- on a sale with other policies comes off the sale; an auto that is the whole sale removes the sale.
CREATE OR REPLACE FUNCTION public.rp_vehicle_swap_convert(p_product_id uuid, p_removal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  sp public.sales_log_products; s public.sales_log; rm public.retention_activity_log;
  v_points numeric; v_actor uuid; v_nprod integer; v_pc uuid; v_reason text; v_did text;
BEGIN
  SELECT * INTO sp FROM public.sales_log_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO s FROM public.sales_log WHERE id = sp.sales_log_id;
  SELECT * INTO rm FROM public.retention_activity_log WHERE id = p_removal_id;
  IF s.id IS NULL OR rm.id IS NULL OR s.status <> 'active' OR rm.status <> 'credited' THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.vehicle_swaps w WHERE w.removal_activity_id = rm.id) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = sp.id AND c.status = 'active') THEN RETURN NULL; END IF;

  SELECT t.id INTO v_actor
    FROM public.team t JOIN public.users u ON u.id = t.user_id
   WHERE u.auth_user_id = auth.uid() AND t.archived_at IS NULL LIMIT 1;
  v_reason := format('vehicle swap: a vehicle came off on %s, so this added auto is a replacement Policy Change',
                     to_char(rm.occurred_on, 'Mon FMDD'));
  SELECT count(*) INTO v_nprod FROM public.sales_log_products WHERE sales_log_id = s.id;

  IF COALESCE(sp.vehicle_count, 1) > 1 THEN
    UPDATE public.sales_log_products
       SET vehicle_count = sp.vehicle_count - 1,
           premium = round(sp.premium * (sp.vehicle_count - 1) / sp.vehicle_count, 2),
           issued_premium = CASE WHEN sp.issued_premium IS NULL THEN NULL
                                 ELSE round(sp.issued_premium * (sp.vehicle_count - 1) / sp.vehicle_count, 2) END
     WHERE id = sp.id;
    v_did := 'one car taken off the sale';
  ELSIF v_nprod > 1 THEN
    UPDATE public.sales_log_products SET multiline_credit_id = NULL WHERE id = sp.id;
    DELETE FROM public.sales_log_products WHERE id = sp.id;
    v_did := 'auto taken off the sale';
  ELSE
    PERFORM public.rp_void_sale_rows(s.id, v_actor, v_reason);
    v_did := 'sale removed';
  END IF;
  IF v_did <> 'sale removed' THEN PERFORM public.rp_derive_sale_credits(s.id); END IF;

  -- One Policy Change per person, customer and day. When that day already has one, the swap adds none.
  IF NOT EXISTS (SELECT 1 FROM public.retention_activity_log l
                  WHERE l.agency_id = s.agency_id AND l.team_member_id = s.team_member_id
                    AND l.activity_key = 'service_task' AND l.status = 'credited'
                    AND l.customer_first_name = s.customer_first_name
                    AND l.customer_last_initial IS NOT DISTINCT FROM s.customer_last_initial
                    AND l.occurred_on = s.submitted_date) THEN
    SELECT points INTO v_points FROM public.retention_point_values
     WHERE agency_id = s.agency_id AND activity_key = 'service_task' AND is_active;
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date,
      credited_week_end_date, customer_first_name, customer_last_initial, customer_kind, phone_last4, ecrm_url,
      note, points, source, created_by)
    VALUES (s.agency_id, s.team_member_id, 'service_task', s.submitted_date, public.rp_week_end(s.submitted_date),
      public.rp_week_end(s.submitted_date), s.customer_first_name, s.customer_last_initial, s.customer_kind,
      s.phone_last4, s.ecrm_opportunity_url,
      'Replacement vehicle' || COALESCE(': ' || NULLIF(btrim(s.note), ''), ''), v_points, 'manual', s.created_by)
    RETURNING id INTO v_pc;
  END IF;

  INSERT INTO public.vehicle_swaps (agency_id, removal_activity_id, sale_id, sale_product_id, replacement_activity_id, what_changed, created_by)
  VALUES (s.agency_id, rm.id, s.id, sp.id, v_pc, v_did, v_actor);
  RETURN jsonb_build_object('sale_id', s.id, 'removal_id', rm.id, 'policy_change_id', v_pc, 'what_changed', v_did);
END $function$;

-- Every open swap in one household: a Policy Change that took a vehicle off, not paired yet, and an added
-- auto on an active sale within rp_vehicle_swap_days() of it, either side. Closest dates pair first.
CREATE OR REPLACE FUNCTION public.rp_vehicle_swap_check(p_agency uuid, p_label text, p_phone text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; n integer := 0;
BEGIN
  IF p_agency IS NULL OR NULLIF(btrim(COALESCE(p_label, '')), '') IS NULL THEN RETURN 0; END IF;
  LOOP
    SELECT rm.id AS removal_id, sp.id AS product_id INTO r
      FROM public.retention_activity_log rm
      JOIN public.sales_log s
        ON s.agency_id = rm.agency_id AND s.customer_label = rm.customer_label
       AND (rm.phone_last4 IS NULL OR s.phone_last4 IS NULL OR s.phone_last4 = rm.phone_last4)
      JOIN public.sales_log_products sp ON sp.sales_log_id = s.id
     WHERE rm.agency_id = p_agency AND rm.customer_label = p_label
       AND (NULLIF(p_phone, '') IS NULL OR rm.phone_last4 IS NULL OR rm.phone_last4 = p_phone)
       AND rm.activity_key = 'service_task' AND rm.status = 'credited'
       AND public.rp_note_removes_vehicle(rm.note)
       AND NOT EXISTS (SELECT 1 FROM public.vehicle_swaps w
                        WHERE w.removal_activity_id = rm.id OR w.replacement_activity_id = rm.id)
       AND s.status = 'active' AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
       AND sp.line_of_business = 'auto' AND COALESCE(sp.is_added_to_existing, false)
       AND abs(s.submitted_date - rm.occurred_on) <= public.rp_vehicle_swap_days()
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c
                        WHERE c.matched_sale_product_id = sp.id AND c.status = 'active')
     ORDER BY abs(s.submitted_date - rm.occurred_on), rm.occurred_on, s.submitted_date, sp.id
     LIMIT 1;
    EXIT WHEN NOT FOUND;
    EXIT WHEN public.rp_vehicle_swap_convert(r.product_id, r.removal_id) IS NULL;
    n := n + 1;
    EXIT WHEN n >= 20;
  END LOOP;
  RETURN n;
END $function$;

-- The check runs when the click that wrote the row commits, so a sale and a Policy Change logged together
-- are both on file first.
CREATE OR REPLACE FUNCTION public.tg_rp_vehicle_swap_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.activity_key = 'service_task' AND NEW.status = 'credited' AND public.rp_note_removes_vehicle(NEW.note) THEN
    PERFORM public.rp_vehicle_swap_check(NEW.agency_id,
      public.rp_customer_label_format(NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_kind),
      NEW.phone_last4);
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.tg_rp_vehicle_swap_product()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE s RECORD;
BEGIN
  IF NEW.line_of_business = 'auto' AND COALESCE(NEW.is_added_to_existing, false) THEN
    SELECT x.agency_id, x.customer_first_name, x.customer_last_initial, x.customer_kind, x.phone_last4, x.status
      INTO s FROM public.sales_log x WHERE x.id = NEW.sales_log_id;
    IF FOUND AND s.status = 'active' THEN
      PERFORM public.rp_vehicle_swap_check(s.agency_id,
        public.rp_customer_label_format(s.customer_first_name, s.customer_last_initial, s.customer_kind),
        s.phone_last4);
    END IF;
  END IF;
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS zz_rp_vehicle_swap ON public.retention_activity_log;
CREATE CONSTRAINT TRIGGER zz_rp_vehicle_swap
  AFTER INSERT OR UPDATE OF note, status, activity_key, customer_first_name, customer_last_initial, phone_last4, occurred_on
  ON public.retention_activity_log
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.tg_rp_vehicle_swap_activity();

DROP TRIGGER IF EXISTS zz_rp_vehicle_swap ON public.sales_log_products;
CREATE CONSTRAINT TRIGGER zz_rp_vehicle_swap
  AFTER INSERT OR UPDATE OF is_added_to_existing, line_of_business
  ON public.sales_log_products
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.tg_rp_vehicle_swap_product();

-- Internal only: nobody calls these from the app.
REVOKE ALL ON FUNCTION public.rp_void_sale_rows(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rp_vehicle_swap_convert(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rp_vehicle_swap_check(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_rp_vehicle_swap_activity() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_rp_vehicle_swap_product() FROM PUBLIC, anon, authenticated;
