-- Peter 2026-09-11 (late): (1) a replacement is a normal cancelation — the old policy is charged back and the new one
-- follows the normal multiline rules; the is_replacement marker stays as a record only. (2) The customer's phone last
-- four digits are required on every record and join the household key: first name + last initial + last four.
-- Records without a phone (the backfill) match any phone, so history keeps matching.

DROP TRIGGER IF EXISTS zz_cxl_replacement_no_chargeback ON public.cancelation_log;
DROP FUNCTION IF EXISTS public.cxl_replacement_no_chargeback();

ALTER TABLE public.sales_log              ADD COLUMN IF NOT EXISTS phone_last4 text;
ALTER TABLE public.quote_log              ADD COLUMN IF NOT EXISTS phone_last4 text;
ALTER TABLE public.retention_activity_log ADD COLUMN IF NOT EXISTS phone_last4 text;
ALTER TABLE public.cancelation_log        ADD COLUMN IF NOT EXISTS phone_last4 text;
ALTER TABLE public.fit_scorecards         ADD COLUMN IF NOT EXISTS phone_last4 text;

-- rp_log_entry sets the phone for the transaction; every row written by that click picks it up through the trigger below.
CREATE OR REPLACE FUNCTION public.rp_fill_phone_last4()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v text := NULLIF(current_setting('rp.phone_last4', true), '');
BEGIN
  IF NEW.phone_last4 IS NULL AND v IS NOT NULL THEN NEW.phone_last4 := v; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_fill_phone_last4 ON public.sales_log;
CREATE TRIGGER trg_fill_phone_last4 BEFORE INSERT ON public.sales_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_phone_last4();
DROP TRIGGER IF EXISTS trg_fill_phone_last4 ON public.quote_log;
CREATE TRIGGER trg_fill_phone_last4 BEFORE INSERT ON public.quote_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_phone_last4();
DROP TRIGGER IF EXISTS trg_fill_phone_last4 ON public.retention_activity_log;
CREATE TRIGGER trg_fill_phone_last4 BEFORE INSERT ON public.retention_activity_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_phone_last4();
DROP TRIGGER IF EXISTS trg_fill_phone_last4 ON public.cancelation_log;
CREATE TRIGGER trg_fill_phone_last4 BEFORE INSERT ON public.cancelation_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_phone_last4();
DROP TRIGGER IF EXISTS trg_fill_phone_last4 ON public.fit_scorecards;
CREATE TRIGGER trg_fill_phone_last4 BEFORE INSERT ON public.fit_scorecards FOR EACH ROW EXECUTE FUNCTION public.rp_fill_phone_last4();

DO $do$
DECLARE d text; anchor text := E'\nBEGIN\n'; snippet text;
BEGIN
  d := pg_get_functiondef('public.rp_log_entry'::regproc);
  IF position(anchor in d) = 0 THEN RAISE EXCEPTION 'rp_log_entry BEGIN anchor not found'; END IF;
  snippet := $q$  -- customer phone, last four digits: required on every record, part of the household key (Peter 2026-09-11)
  IF regexp_replace(COALESCE(p_payload->>'phone_last4', ''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  PERFORM set_config('rp.phone_last4', regexp_replace(p_payload->>'phone_last4', '\D', '', 'g'), true);
$q$;
  d := overlay(d placing (anchor || snippet) from position(anchor in d) for length(anchor));
  EXECUTE d;
END $do$;

-- customer picker: distinct households (name + last four) with what is on file, newest first
CREATE OR REPLACE FUNCTION public.rp_customer_suggest2(p_prefix text)
RETURNS TABLE(customer_first_name text, customer_last_initial text, customer_label text, phone_last4 text, policies_on_file integer, last_seen date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  seen AS (
    SELECT s.customer_first_name, s.customer_last_initial, s.customer_label, s.phone_last4, s.submitted_date AS d, 1 AS pol
      FROM public.sales_log s JOIN me ON me.agency_id = s.agency_id WHERE s.status = 'active'
    UNION ALL
    SELECT q.customer_first_name, q.customer_last_initial, q.customer_label, q.phone_last4, q.quote_date, 0
      FROM public.quote_log q JOIN me ON me.agency_id = q.agency_id WHERE q.status = 'active'
    UNION ALL
    SELECT l.customer_first_name, l.customer_last_initial, l.customer_label, l.phone_last4, l.occurred_on, 0
      FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id WHERE l.status <> 'voided'
    UNION ALL
    SELECT c.customer_first_name, c.customer_last_initial, c.customer_label, c.phone_last4, c.canceled_on, 0
      FROM public.cancelation_log c JOIN me ON me.agency_id = c.agency_id WHERE c.status = 'active'
  )
  SELECT customer_first_name, customer_last_initial, customer_label, phone_last4,
         SUM(pol)::int AS policies_on_file, MAX(d) AS last_seen
  FROM seen
  WHERE auth.uid() IS NOT NULL AND customer_label IS NOT NULL AND lower(customer_label) LIKE lower(btrim(p_prefix)) || '%'
  GROUP BY 1, 2, 3, 4
  ORDER BY MAX(d) DESC, customer_label
  LIMIT 8;
$$;
REVOKE ALL ON FUNCTION public.rp_customer_suggest2(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_customer_suggest2(text) TO authenticated;

-- sold policies on file for the household: a sale without a phone (backfill) matches any phone
CREATE OR REPLACE FUNCTION public.rp_sold_on_file2(p_customer_first text, p_customer_last_initial text, p_phone_last4 text DEFAULT NULL)
RETURNS TABLE(sale_product_id uuid, line_of_business text, product_type text, premium numeric, vehicle_count integer, submitted_date date, already_canceled boolean, window_end date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT f.sale_product_id::uuid, f.line_of_business::text, f.product_type::text, f.premium::numeric, f.vehicle_count::integer,
         f.submitted_date::date, f.already_canceled::boolean, f.window_end::date
  FROM public.rp_sold_on_file(p_customer_first, p_customer_last_initial) f
  JOIN public.sales_log_products sp ON sp.id = f.sale_product_id
  JOIN public.sales_log s ON s.id = sp.sales_log_id
  WHERE auth.uid() IS NOT NULL
    AND (NULLIF(p_phone_last4, '') IS NULL OR s.phone_last4 IS NULL OR s.phone_last4 = p_phone_last4);
$$;
REVOKE ALL ON FUNCTION public.rp_sold_on_file2(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_sold_on_file2(text, text, text) TO authenticated;

-- autopay guard: one credit per household (name + phone) + line (+ type)
CREATE OR REPLACE FUNCTION public.rp_autopay_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_prior record;
BEGIN
  IF NEW.activity_key <> 'autopay_enrollment' OR COALESCE(NEW.status, 'credited') = 'voided' THEN RETURN NEW; END IF;
  IF NEW.policy_line IS NULL THEN RAISE EXCEPTION 'Autopay needs the policy line it was set up on'; END IF;
  IF NEW.premium IS NULL OR NEW.premium < 0 THEN RAISE EXCEPTION 'Autopay needs the policy premium'; END IF;
  SELECT l.occurred_on, l.source INTO v_prior FROM public.retention_activity_log l
   WHERE l.agency_id = NEW.agency_id AND l.activity_key = 'autopay_enrollment' AND l.status <> 'voided'
     AND l.customer_label = NEW.customer_label AND l.policy_line = NEW.policy_line
     AND (l.phone_last4 IS NULL OR NEW.phone_last4 IS NULL OR l.phone_last4 = NEW.phone_last4)
     AND (l.product_type IS NULL OR NEW.product_type IS NULL OR l.product_type = NEW.product_type)
   ORDER BY l.occurred_on DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Autopay for % on % is already credited (% %). One autopay credit per policy.',
      NEW.customer_label, NEW.policy_line, CASE WHEN v_prior.source = 'manual' THEN 'logged' ELSE 'from the sale on' END, to_char(v_prior.occurred_on, 'Mon FMDD');
  END IF;
  RETURN NEW;
END $$;

-- scoreboard: repeat quote = same name + compatible phone; HH quotes distinct by name + phone; phone rides on the items
DO $$
DECLARE d text; o1 text; n1 text; o2 text; n2 text; o3 text; n3 text; o4 text; n4 text; o5 text; n5 text; o6 text; n6 text;
BEGIN
  d := pg_get_functiondef('public.rp_week_scoreboard_for'::regproc);
  o1 := 'AND x.customer_label = q.customer_label AND x.week_end_date = q.week_end_date';
  n1 := 'AND x.customer_label = q.customer_label AND x.week_end_date = q.week_end_date AND (x.phone_last4 IS NULL OR q.phone_last4 IS NULL OR x.phone_last4 = q.phone_last4)';
  o2 := 'count(DISTINCT customer_label)::int AS n,';
  n2 := 'count(DISTINCT customer_label || COALESCE(phone_last4, ''''))::int AS n,';
  o3 := 'SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.products_discussed, q.marketing_source, q.relationship_type,';
  n3 := 'SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.phone_last4, q.products_discussed, q.marketing_source, q.relationship_type,';
  o4 := '''source'', marketing_source, ''relationship'', relationship_type, ''dup'', dup)';
  n4 := '''source'', marketing_source, ''relationship'', relationship_type, ''dup'', dup, ''phone'', phone_last4)';
  o5 := 'pt.label AS type_label, s.on_file_answer';
  n5 := 'pt.label AS type_label, s.on_file_answer, s.phone_last4';
  o6 := '''on_file_answer'', x.on_file_answer)';
  n6 := '''on_file_answer'', x.on_file_answer, ''phone'', x.phone_last4)';
  IF position(o1 in d) = 0 OR position(o2 in d) = 0 OR position(o3 in d) = 0 OR position(o4 in d) = 0 OR position(o5 in d) = 0 OR position(o6 in d) = 0 THEN
    RAISE EXCEPTION 'rp_week_scoreboard_for anchors not found';
  END IF;
  EXECUTE replace(replace(replace(replace(replace(replace(d, o1, n1), o2, n2), o3, n3), o4, n4), o5, n5), o6, n6);
END $$;
