-- Vehicle swap, reading the note better (Peter 2026-09-26): "2019 Honda removed" is a vehicle coming off.
-- A note gets one of three answers. yes: a removal word next to a vehicle (a vehicle word, a make, or a
-- model year) either side, and the swap happens on its own. no: no removal word, or every one of them is
-- about something else (a driver, a lienholder, coverage). maybe: a removal word the check cannot place,
-- like "Removed the Tahoe" or just "Removed". A maybe with an added auto near it waits on Spot-check for
-- Peter to say swap or not.

ALTER TABLE public.vehicle_swaps ADD COLUMN IF NOT EXISTS decision text NOT NULL DEFAULT 'swap';
ALTER TABLE public.vehicle_swaps DROP CONSTRAINT IF EXISTS vehicle_swaps_decision_chk;
ALTER TABLE public.vehicle_swaps ADD CONSTRAINT vehicle_swaps_decision_chk CHECK (decision IN ('swap', 'not_swap'));
COMMENT ON COLUMN public.vehicle_swaps.decision IS
  'swap: the added auto became a replacement Policy Change. not_swap: Peter said this Policy Change did not take a vehicle off.';

CREATE OR REPLACE FUNCTION public.rp_note_vehicle_removal(p_note text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH t AS (SELECT lower(COALESCE(p_note, '')) AS s),
  words AS (
    SELECT ARRAY['car','cars','vehicle','vehicles','truck','trucks','van','vans','suv','auto','autos','motorcycle',
                 'motorcycles','bike','trailer','rv','camper','jeep','dodge','ram','ford','chevy','chevrolet','gmc',
                 'toyota','honda','nissan','hyundai','kia','tesla','bmw','mercedes','benz','audi','lexus','acura',
                 'infiniti','mazda','subaru','volkswagen','vw','volvo','buick','cadillac','chrysler','lincoln',
                 'mitsubishi','porsche','mini','fiat','genesis','harley','yamaha','suzuki','polaris','kawasaki',
                 'tahoe','silverado','f150','f250','camry','corolla','civic','accord','altima','sentra','tacoma',
                 'tundra','wrangler','explorer','escape','malibu','equinox','rav4','crv','highlander','sienna',
                 'odyssey','pilot','rogue','elantra','sonata','tucson','optima','soul','sorento','charger',
                 'challenger','durango','mustang','impala','yukon','sierra','suburban','expedition'] AS veh,
           ARRAY['driver','drivers','lienholder','lienholders','lien','liens','loss','payee','payees','mortgagee',
                 'mortgagees','coverage','coverages','comp','comprehensive','collision','rental','towing','roadside',
                 'ers','endorsement','endorsements','emergency','discount','discounts','autopay','card','cards','bank',
                 'account','payment','payments','name','address','email','phone','number','spouse','wife','husband',
                 'son','daughter','kid','kids','child','children','person','insured','additional','interest',
                 'violation','violations','ticket','tickets','accident','accidents','claim','claims','glass',
                 'windshield','deductible','deductibles','um','uim','pip','medical','gap','id','ids','sr22',
                 'excluded','exclusion','policy','policies','them','him','it','off','cost','value','roof'] AS skip,
           ARRAY['from','of','on','in','at','as','per','effective','today','yesterday','and','then','to'] AS prep
  ),
  hits AS (
    SELECT m[1] AS before_word, m[2] AS verb, m[4] AS after_word
      FROM t, regexp_matches(t.s,
        '(?:(\w+)\s+(?:(?:was|is|got|been|being|were|are|get|gets)\s+)?)?\m(remov\w*|delet\w*|replac\w*|took\s+off|take\s+off|takes\s+off|taking\s+off|taken\s+off|drop\w*)(?:\s+((?:(?:a|an|the|her|his|their|my|our|old|older|one|both|other|that|this)\s+)*)(\w+))?',
        'g') m
  ),
  judged AS (
    SELECT CASE
             WHEN h.after_word IS NOT NULL AND NOT (h.after_word = ANY (w.prep)) THEN
               CASE WHEN h.after_word = ANY (w.veh) OR h.after_word ~ '^(19|20)\d\d$' THEN 'yes'
                    WHEN h.after_word = ANY (w.skip) THEN 'no'
                    ELSE 'maybe' END
             WHEN h.before_word IS NOT NULL THEN
               CASE WHEN h.before_word = ANY (w.veh) OR h.before_word ~ '^(19|20)\d\d$' THEN 'yes'
                    WHEN h.before_word = ANY (w.skip) THEN 'no'
                    ELSE 'maybe' END
             ELSE 'maybe'
           END AS v
      FROM hits h, words w
  )
  SELECT CASE
           WHEN EXISTS (SELECT 1 FROM judged WHERE v = 'yes') THEN 'yes'
           -- "the car she sold was removed": a plain vehicle word shortly before the removal word
           WHEN (SELECT s FROM t) ~ '\m(car|cars|vehicle|vehicles|truck|trucks|van|suv|auto|motorcycle|trailer)\M[^.]{0,20}\m(remov\w*|delet\w*|replac\w*|taken\s+off|dropped)' THEN 'yes'
           WHEN EXISTS (SELECT 1 FROM judged WHERE v = 'maybe') THEN 'maybe'
           ELSE 'no'
         END
$function$;

-- The automatic swap acts on a sure yes only.
CREATE OR REPLACE FUNCTION public.rp_note_removes_vehicle(p_note text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT public.rp_note_vehicle_removal(p_note) = 'yes' $function$;

-- Maybes for Peter: a Policy Change whose note the check could not place, with an added auto for the same
-- household within the swap window, neither decided yet. One row per pair.
CREATE OR REPLACE FUNCTION public.rp_vehicle_swap_review()
 RETURNS TABLE(removal_id uuid, removal_on date, removal_note text, removal_by text, product_id uuid, sale_id uuid,
               sold_on date, sale_label text, sale_note text, sold_by text, premium numeric, vehicle_count integer,
               customer_label text, phone_last4 text, ecrm_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1)
  SELECT rm.id, rm.occurred_on, rm.note, t1.first_name, sp.id, s.id, s.submitted_date,
         COALESCE(pt.label, sp.product_type), s.note, t2.first_name, sp.premium, sp.vehicle_count,
         s.customer_label, COALESCE(s.phone_last4, rm.phone_last4), COALESCE(s.ecrm_opportunity_url, rm.ecrm_url)
    FROM public.retention_activity_log rm
    JOIN me ON me.agency_id = rm.agency_id
    JOIN public.sales_log s
      ON s.agency_id = rm.agency_id AND s.customer_label = rm.customer_label
     AND (rm.phone_last4 IS NULL OR s.phone_last4 IS NULL OR s.phone_last4 = rm.phone_last4)
    JOIN public.sales_log_products sp ON sp.sales_log_id = s.id
    LEFT JOIN public.product_types pt
      ON pt.agency_id = s.agency_id AND pt.line_of_business = sp.line_of_business AND pt.type_key = sp.product_type
    LEFT JOIN public.team_directory t1 ON t1.id = rm.team_member_id
    LEFT JOIN public.team_directory t2 ON t2.id = s.team_member_id
   WHERE public.is_agency_admin()
     AND rm.activity_key = 'service_task' AND rm.status = 'credited'
     AND public.rp_note_vehicle_removal(rm.note) = 'maybe'
     AND NOT EXISTS (SELECT 1 FROM public.vehicle_swaps w
                      WHERE w.removal_activity_id = rm.id OR w.replacement_activity_id = rm.id)
     AND s.status = 'active' AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
     AND sp.line_of_business = 'auto' AND COALESCE(sp.is_added_to_existing, false)
     AND abs(s.submitted_date - rm.occurred_on) <= public.rp_vehicle_swap_days()
     AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c
                      WHERE c.matched_sale_product_id = sp.id AND c.status = 'active')
   ORDER BY rm.occurred_on DESC, s.submitted_date;
$function$;

-- Peter's answer on a maybe. Swap: the added auto becomes a replacement Policy Change, the same way the
-- automatic swap does it. Not a swap: that Policy Change is set aside and never asked about again.
CREATE OR REPLACE FUNCTION public.rp_vehicle_swap_decide(p_removal_id uuid, p_product_id uuid, p_swap boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; rm public.retention_activity_log; v_sale uuid; v_res jsonb;
BEGIN
  PERFORM public.require_login('staff');
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can decide a vehicle swap'; END IF;
  SELECT * INTO rm FROM public.retention_activity_log WHERE id = p_removal_id AND agency_id = a.agency_id;
  IF NOT FOUND OR rm.status <> 'credited' THEN RAISE EXCEPTION 'that Policy Change is not on file any more'; END IF;
  IF EXISTS (SELECT 1 FROM public.vehicle_swaps WHERE removal_activity_id = p_removal_id) THEN
    RETURN jsonb_build_object('ok', true, 'already_decided', true);
  END IF;
  SELECT sp.sales_log_id INTO v_sale FROM public.sales_log_products sp WHERE sp.id = p_product_id AND sp.agency_id = a.agency_id;
  IF v_sale IS NULL THEN RAISE EXCEPTION 'that added auto is not on file any more'; END IF;
  IF p_swap THEN
    PERFORM set_config('rp.vehicle_swap', '1', true);
    v_res := public.rp_vehicle_swap_convert(p_product_id, p_removal_id);
    PERFORM set_config('rp.vehicle_swap', '', true);
    IF v_res IS NULL THEN RAISE EXCEPTION 'that added auto can no longer be turned into a Policy Change'; END IF;
    RETURN jsonb_build_object('ok', true) || v_res;
  END IF;
  INSERT INTO public.vehicle_swaps (agency_id, removal_activity_id, sale_id, sale_product_id, what_changed, decision, created_by)
  VALUES (a.agency_id, p_removal_id, v_sale, p_product_id, 'nothing: not a swap', 'not_swap', a.actor_id);
  RETURN jsonb_build_object('ok', true, 'decision', 'not_swap');
END $function$;

REVOKE ALL ON FUNCTION public.rp_vehicle_swap_review() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rp_vehicle_swap_decide(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_vehicle_swap_review() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_vehicle_swap_decide(uuid, uuid, boolean) TO authenticated;
