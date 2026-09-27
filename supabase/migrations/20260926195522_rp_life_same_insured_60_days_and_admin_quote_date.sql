-- Life on the same insured (Peter 2026-09-26): a new life policy on the same insured within
-- rp_life_repeat_days() after the last life policy on that insured does not count. The insured is recorded
-- on each life policy; left blank it is the customer. Applies to the production log, not the historical load.
-- Also: an admin adding a quote while correcting a record may date it more than 7 days back.

ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS insured_name text;
COMMENT ON COLUMN public.sales_log_products.insured_name IS
  'Life only: the insured, first name and last initial. Blank means the customer on the sale.';

CREATE OR REPLACE FUNCTION public.rp_life_repeat_days()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT 60 $function$;

-- One way to compare insured names: letters only, lower case. "Bella S." and "bella s" are the same person.
CREATE OR REPLACE FUNCTION public.rp_insured_key(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT lower(regexp_replace(COALESCE(p_name, ''), '[^A-Za-z]', '', 'g')) $function$;

-- True when this life policy is on an insured whose last life policy (same household) was submitted within
-- rp_life_repeat_days() before it. Same day, the one logged first counts. The rule starts with sales entered
-- from 2026-09-26, the day Peter set it, so weeks already paid do not move.
CREATE OR REPLACE FUNCTION public.rp_life_repeat_insured(p_product_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM public.sales_log_products p
      JOIN public.sales_log s ON s.id = p.sales_log_id
      JOIN public.sales_log s2
        ON s2.agency_id = s.agency_id AND s2.status = 'active'
       AND s2.customer_label = s.customer_label
       AND (s.phone_last4 IS NULL OR s2.phone_last4 IS NULL OR s2.phone_last4 = s.phone_last4)
      JOIN public.sales_log_products p2 ON p2.sales_log_id = s2.id AND p2.line_of_business = 'life' AND p2.id <> p.id
     WHERE p.id = p_product_id
       AND p.line_of_business = 'life'
       AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
       AND s.created_at >= TIMESTAMPTZ '2026-09-26 00:00:00-05'
       AND public.rp_insured_key(COALESCE(p2.insured_name, s2.customer_label))
         = public.rp_insured_key(COALESCE(p.insured_name, s.customer_label))
       AND s2.submitted_date >= s.submitted_date - public.rp_life_repeat_days()
       AND (s2.submitted_date < s.submitted_date
            OR (s2.submitted_date = s.submitted_date AND (p2.created_at, p2.id) < (p.created_at, p.id)))
  );
$function$;

-- Sales points leave those policies out: no app, no premium, and so no chargeback if one cancels later.
CREATE OR REPLACE FUNCTION public.production_rows_for(p_agency_id uuid, p_from date, p_through date)
 RETURNS TABLE(tm uuid, id uuid, sale_id uuid, lob text, product_type text, premium numeric, policy_count integer, vehicle_count integer, units integer, issued_date date, customer_label text, type_label text, on_file_answer text, phone_last4 text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cxl AS (
    -- Live cancelations matched to a policy (matched = inside the chargeback
    -- window), the date each counts on, and how much of the window was left.
    SELECT c.matched_sale_product_id AS pid,
           LEAST(1, GREATEST(0, COALESCE(c.window_fraction_left, 1))) AS left_frac,
           public.cancel_counts_on(c.agency_id, c.created_at) AS recorded_on,
           c.canceled_on, c.reinstated_on,
           CASE WHEN c.reinstated_at IS NOT NULL THEN public.cancel_counts_on(c.agency_id, c.reinstated_at) END AS reinstated_counts_on
      FROM public.cancelation_log c
     WHERE c.agency_id = p_agency_id AND c.status = 'active' AND c.matched_sale_product_id IS NOT NULL
       AND NOT COALESCE(c.already_charged_back, false)
  ),
  base AS (
    SELECT s.team_member_id AS tm, p.id, s.id AS sale_id, p.line_of_business AS lob, p.product_type,
           COALESCE(p.issued_premium, p.premium) AS premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count,
           p.vehicle_count,
           -- Auto counts one app per VEHICLE. Everything else counts policies.
           CASE WHEN p.line_of_business = 'auto'
                THEN GREATEST(1, COALESCE(p.vehicle_count, s.vehicle_count, p.policy_count, 1))
                ELSE GREATEST(1, COALESCE(p.policy_count, 1)) END AS units,
           p.issued_date, s.customer_label, pt.label AS type_label, s.on_file_answer, s.phone_last4
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    LEFT JOIN public.product_types pt
      ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
      -- Peter 2026-09-26: life on the same insured within 60 days of the last one does not count.
      AND (p.line_of_business <> 'life' OR NOT public.rp_life_repeat_insured(p.id))
  )
  -- Policies, in the week they issued. A later cancelation never rewrites this.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, b.premium, b.policy_count, b.vehicle_count,
         b.units, b.issued_date, b.customer_label, b.type_label, b.on_file_answer, b.phone_last4
    FROM base b
   WHERE b.issued_date BETWEEN p_from AND p_through
  UNION ALL
  -- Peter 2026-09-21: every cancelation inside the window is a chargeback, whenever
  -- the policy issued. Lands on the date the cancel counts on. Premium prorated by
  -- the window left; the app comes off whole. Replacements included. Rows marked
  -- already charged back are record only.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, -round(b.premium * cx.left_frac, 2), -b.policy_count, b.vehicle_count,
         -b.units, cx.recorded_on, b.customer_label,
         'Chargeback: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl cx ON cx.pid = b.id
   WHERE cx.recorded_on BETWEEN p_from AND p_through
  UNION ALL
  -- Peter 2026-09-22: reinstated inside the window (home 30 days, auto 15). The chargeback
  -- comes back, minus the premium for the days out of force, and the app comes back whole.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type,
         GREATEST(0, round(b.premium * cx.left_frac, 2)
                     - round(b.premium * (cx.reinstated_on - cx.canceled_on) / 365.0, 2)),
         b.policy_count, b.vehicle_count, b.units, cx.reinstated_counts_on, b.customer_label,
         'Reinstated: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl cx ON cx.pid = b.id
   WHERE cx.reinstated_on IS NOT NULL
     AND cx.reinstated_counts_on BETWEEN p_from AND p_through;
$function$;

-- The insured rides along when a sale is logged, edited, or opened for editing. Each change is one exact
-- replacement inside the function as it stands; any text that is not there exactly once stops the migration.
DO $migrate$
DECLARE
  d text; old text; new text; n integer;
BEGIN
  -- rp_log_sale: store the insured on a life policy (blank = the customer)
  d := pg_get_functiondef('public.rp_log_sale(jsonb)'::regprocedure);
  old := $o$    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, autopay_enrolled)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_added, NULLIF(prod->>'issued_date','')::date, COALESCE((prod->>'autopay')::boolean, false));$o$;
  new := $n$    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, autopay_enrolled, insured_name)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_added, NULLIF(prod->>'issued_date','')::date, COALESCE((prod->>'autopay')::boolean, false),
            CASE WHEN v_lob = 'life' THEN COALESCE(NULLIF(btrim(COALESCE(prod->>'insured_name', '')), ''), v_label) END);$n$;
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_log_sale: insert text found % times', n; END IF;
  EXECUTE replace(d, old, new);

  -- rp_edit_sale: a new policy row and an edited one both carry the insured
  d := pg_get_functiondef('public.rp_edit_sale(uuid,jsonb)'::regprocedure);
  old := $o$        INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled)
        VALUES (p_id, r.agency_id, v_lob, v_type, NULLIF(prod->>'premium','')::numeric,$o$;
  new := $n$        INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled, insured_name)
        VALUES (p_id, r.agency_id, v_lob, v_type, NULLIF(prod->>'premium','')::numeric,$n$;
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_edit_sale: insert head found % times', n; END IF;
  d := replace(d, old, new);
  old := $o$                NULLIF(prod->>'issued_date','')::date, NULLIF(prod->>'issued_premium','')::numeric,
                COALESCE((prod->>'autopay')::boolean, false));$o$;
  new := $n$                NULLIF(prod->>'issued_date','')::date, NULLIF(prod->>'issued_premium','')::numeric,
                COALESCE((prod->>'autopay')::boolean, false),
                CASE WHEN v_lob = 'life' THEN COALESCE(NULLIF(btrim(COALESCE(prod->>'insured_name', '')), ''), v_label) END);$n$;
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_edit_sale: insert values found % times', n; END IF;
  d := replace(d, old, new);
  old := $o$          autopay_enrolled = CASE WHEN prod ? 'autopay' THEN COALESCE((prod->>'autopay')::boolean, false) ELSE autopay_enrolled END
        WHERE id = v_pid$o$;
  new := $n$          autopay_enrolled = CASE WHEN prod ? 'autopay' THEN COALESCE((prod->>'autopay')::boolean, false) ELSE autopay_enrolled END,
          insured_name = CASE WHEN v_lob <> 'life' THEN NULL
                              WHEN prod ? 'insured_name' THEN COALESCE(NULLIF(btrim(COALESCE(prod->>'insured_name', '')), ''), v_label)
                              ELSE COALESCE(insured_name, v_label) END
        WHERE id = v_pid$n$;
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_edit_sale: update found % times', n; END IF;
  EXECUTE replace(d, old, new);

  -- rp_entry_for_edit: hand the insured to the edit form
  d := pg_get_functiondef('public.rp_entry_for_edit(text,uuid)'::regprocedure);
  old := $o$'issued_date', p.issued_date, 'issued_premium', p.issued_premium,$o$;
  new := $n$'issued_date', p.issued_date, 'issued_premium', p.issued_premium, 'insured_name', p.insured_name,$n$;
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_entry_for_edit: products text found % times', n; END IF;
  EXECUTE replace(d, old, new);

  -- rp_log_quote: an admin correcting a record may add a quote dated more than 7 days back
  d := pg_get_functiondef('public.rp_log_quote(jsonb)'::regprocedure);
  old := $o$  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;$o$;
  new := $n$  IF v_on < v_today - 7 AND NOT COALESCE(a.is_admin, false) THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;$n$;
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_log_quote: date check found % times', n; END IF;
  EXECUTE replace(d, old, new);
END $migrate$;
