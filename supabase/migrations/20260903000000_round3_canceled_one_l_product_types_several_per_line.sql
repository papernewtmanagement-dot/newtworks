-- Production entry page, round three (Peter 2026-09-02).
--
-- 1. SPELLING. One L everywhere: canceled, canceling, cancelation. Table,
--    column, functions, trigger, view, point-value key and label, and every
--    message the team reads. All four tables are empty, so this is a clean
--    rename with nothing to migrate.
--
-- 2. PRODUCT TYPES. Auto and Fire have types under them:
--      Auto  — Private Passenger, Classic, Commercial, GAINSCO, RV
--      Fire  — Home, Renters, RDP, Boat, PAP, PLUP
--    Held in a table so adding one later never touches code. The other lines
--    (Business, Life, Health, IPS, Bank) have no types and log as the line.
--
-- 3. SEVERAL PER LINE. A household can quote, buy, or cancel more than one
--    policy on the same line — two cars on two policies, a home and a boat.
--    Quotes and cancelations become one row per policy like sales already
--    were, and the one-row-per-line unique key on sales comes off.
--
-- 4. MULTILINE STAYS PER LINE. Two auto policies in one sale is still ONE
--    auto line for the household, so it earns at most one Multiline credit.
--    Without this, "several per line" would have quietly doubled the pay.
--    Cars are counted on the auto policy that has them, not once per sale.

-- ============ 1. spelling: canceled with one L ============
ALTER TABLE public.cancellation_log RENAME TO cancelation_log;
ALTER TABLE public.cancelation_log RENAME COLUMN cancelled_on TO canceled_on;
ALTER INDEX IF EXISTS idx_cancellation_log_agency_week RENAME TO idx_cancelation_log_agency_week;
ALTER INDEX IF EXISTS idx_cancellation_log_customer RENAME TO idx_cancelation_log_customer;

DROP TRIGGER IF EXISTS trg_cancellation_log_void_unpaid_saves ON public.cancelation_log;
DROP FUNCTION IF EXISTS public.cancellation_log_void_unpaid_saves();

UPDATE public.retention_point_values
   SET activity_key = 'cancelation_saved', label = 'Cancelation Saved', updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'cancellation_saved';

UPDATE public.retention_activity_log SET activity_key = 'cancelation_saved' WHERE activity_key = 'cancellation_saved';

DROP VIEW IF EXISTS public.rp_saves_clearing_soon;
CREATE VIEW public.rp_saves_clearing_soon AS
 SELECT l.id, l.agency_id, l.team_member_id, t.first_name, l.customer_label,
    l.save_line, l.save_reason, l.occurred_on, l.credit_available_on,
    l.credited_week_end_date, l.points,
    l.credit_available_on - rp_today_central() AS days_until_clear
   FROM retention_activity_log l
     LEFT JOIN team_directory t ON t.id = l.team_member_id
  WHERE l.activity_key = 'cancelation_saved'::text AND l.status = 'credited'::text
    AND l.verified_at IS NULL AND l.credit_available_on IS NOT NULL
    AND l.credit_available_on >= rp_today_central();

CREATE OR REPLACE FUNCTION public.cancelation_log_void_unpaid_saves()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer := 0;
BEGIN
  UPDATE public.retention_activity_log l
     SET status = 'void', voided_at = now(), voided_by = NEW.created_by,
         void_reason = 'policy canceled ' || NEW.canceled_on::text || ' — the save did not hold',
         updated_at = now()
   WHERE l.agency_id = NEW.agency_id
     AND l.activity_key = 'cancelation_saved'
     AND l.status = 'credited'
     AND l.customer_label = NEW.customer_label
     AND l.save_line = NEW.policy_line
     AND l.occurred_on <= NEW.canceled_on
     AND l.credited_week_end_date >= public.rp_week_end(public.rp_today_central());
  GET DIAGNOSTICS v_n = ROW_COUNT;
  NEW.saves_voided := v_n;
  RETURN NEW;
END $function$;

CREATE TRIGGER trg_cancelation_log_void_unpaid_saves
BEFORE INSERT ON public.cancelation_log
FOR EACH ROW EXECUTE FUNCTION public.cancelation_log_void_unpaid_saves();

-- ============ 2. product types ============
CREATE TABLE IF NOT EXISTS public.product_types (
  agency_id uuid NOT NULL,
  line_of_business text NOT NULL,
  type_key text NOT NULL,
  label text NOT NULL,
  sort_order integer NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, line_of_business, type_key),
  CONSTRAINT product_types_line_check CHECK (line_of_business = ANY (ARRAY['auto','fire','business','life','health','ips','bank']))
);
COMMENT ON TABLE public.product_types IS 'Types under a line of business (Auto: Private Passenger, Classic, ...). Lines with no rows here log as the line itself.';

ALTER TABLE public.product_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS product_types_auth_read ON public.product_types;
CREATE POLICY product_types_auth_read ON public.product_types FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
DROP POLICY IF EXISTS product_types_admin_write ON public.product_types;
CREATE POLICY product_types_admin_write ON public.product_types FOR ALL TO authenticated
  USING (public.is_agency_admin() AND agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

INSERT INTO public.product_types (agency_id, line_of_business, type_key, label, sort_order) VALUES
  ('126794dd-25ff-47d2-a436-724499733365','auto','private_passenger','Private Passenger',10),
  ('126794dd-25ff-47d2-a436-724499733365','auto','classic','Classic',20),
  ('126794dd-25ff-47d2-a436-724499733365','auto','commercial','Commercial',30),
  ('126794dd-25ff-47d2-a436-724499733365','auto','gainsco','GAINSCO',40),
  ('126794dd-25ff-47d2-a436-724499733365','auto','rv','RV',50),
  ('126794dd-25ff-47d2-a436-724499733365','fire','home','Home',10),
  ('126794dd-25ff-47d2-a436-724499733365','fire','renters','Renters',20),
  ('126794dd-25ff-47d2-a436-724499733365','fire','rdp','RDP',30),
  ('126794dd-25ff-47d2-a436-724499733365','fire','boat','Boat',40),
  ('126794dd-25ff-47d2-a436-724499733365','fire','pap','PAP',50),
  ('126794dd-25ff-47d2-a436-724499733365','fire','plup','PLUP',60)
ON CONFLICT (agency_id, line_of_business, type_key) DO UPDATE
  SET label = EXCLUDED.label, sort_order = EXCLUDED.sort_order, is_active = true, updated_at = now();

-- ============ 3. several policies per line ============
-- sales: one row per policy, not one per line
ALTER TABLE public.sales_log_products DROP CONSTRAINT IF EXISTS sales_log_products_sales_log_id_line_of_business_key;
ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS product_type text;
ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS vehicle_count integer;
COMMENT ON COLUMN public.sales_log_products.product_type IS 'product_types.type_key for this line, when the line has types.';
COMMENT ON COLUMN public.sales_log_products.vehicle_count IS 'Cars on THIS auto policy. sales_log.vehicle_count is the sale total.';

-- quotes: one row per quoted policy (quote_log.products_discussed keeps the distinct set of lines)
CREATE TABLE IF NOT EXISTS public.quote_log_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_log_id uuid NOT NULL REFERENCES public.quote_log(id) ON DELETE CASCADE,
  agency_id uuid NOT NULL,
  line_of_business text NOT NULL,
  product_type text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT quote_log_products_line_check CHECK (line_of_business = ANY (ARRAY['auto','fire','business','life','health','ips','bank']))
);
CREATE INDEX IF NOT EXISTS idx_quote_log_products_quote ON public.quote_log_products (quote_log_id);
ALTER TABLE public.quote_log_products ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS quote_log_products_auth_read ON public.quote_log_products;
CREATE POLICY quote_log_products_auth_read ON public.quote_log_products FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- cancelations: product type on the row; several rows per line already allowed
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS product_type text;
COMMENT ON COLUMN public.cancelation_log.product_type IS 'product_types.type_key for the canceled policy, when the line has types.';

-- ============ 4. writers ============
CREATE OR REPLACE FUNCTION public.rp_check_product_type(p_agency uuid, p_line text, p_type text)
 RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_type text := NULLIF(lower(btrim(COALESCE(p_type,''))),''); v_has boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.product_types WHERE agency_id=p_agency AND line_of_business=p_line AND is_active) INTO v_has;
  IF NOT v_has THEN RETURN NULL; END IF;
  IF v_type IS NULL THEN RAISE EXCEPTION 'pick the type of % policy', p_line; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.product_types WHERE agency_id=p_agency AND line_of_business=p_line AND type_key=v_type AND is_active) THEN
    RAISE EXCEPTION 'unknown % type: %', p_line, v_type;
  END IF;
  RETURN v_type;
END $function$;

DROP FUNCTION IF EXISTS public.rp_log_cancellation(jsonb);
CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_type text; v_reason text; v_note text;
  v_id uuid; v_voided integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'canceled_on','')::date, NULLIF(p->>'cancelled_on','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'the cancelation date cannot be in the future'; END IF;
  IF v_on < v_today - 90 THEN RAISE EXCEPTION 'log a cancelation within 90 days of the date it happened'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_line  := NULLIF(lower(btrim(COALESCE(p->>'policy_line',''))), '');
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
    RAISE EXCEPTION 'pick the policy line that canceled';
  END IF;
  v_type := public.rp_check_product_type(a.agency_id, v_line, p->>'product_type');
  v_reason := NULLIF(btrim(COALESCE(p->>'reason','')), '');
  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');
  INSERT INTO public.cancelation_log
    (agency_id, team_member_id, canceled_on, week_end_date, customer_first_name, customer_last_initial,
     customer_label, policy_line, product_type, reason, note, created_by)
  VALUES
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     upper(btrim(p->>'customer_last_initial')), v_label, v_line, v_type, v_reason, v_note, a.actor_id)
  RETURNING id, saves_voided INTO v_id, v_voided;
  RETURN jsonb_build_object('ok', true, 'cancelation_id', v_id, 'customer', v_label,
                            'policy_line', v_line, 'product_type', v_type, 'saves_voided', v_voided);
END $function$;

DROP FUNCTION IF EXISTS public.rp_void_cancellation(uuid, text);
CREATE OR REPLACE FUNCTION public.rp_void_cancelation(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT * INTO r FROM public.cancelation_log WHERE id = p_id AND agency_id = a.agency_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  IF NOT a.is_admin THEN
    IF r.team_member_id <> a.actor_id THEN
      RAISE EXCEPTION 'you can only remove your own entries' USING ERRCODE='42501';
    END IF;
    IF r.created_at < now() - interval '7 days' THEN
      RAISE EXCEPTION 'entries older than 7 days can only be removed by an admin' USING ERRCODE='42501';
    END IF;
  END IF;
  UPDATE public.cancelation_log
     SET status='void', voided_at=now(), voided_by=a.actor_id,
         void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id,
    'note', 'removing the cancelation does not put back a save it took away — log the save again if that is what you meant');
END $function$;

-- rp_log_activity: only the save key and its wording change.
CREATE OR REPLACE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; item jsonb; v RECORD;
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_key text; v_reason text; v_line text;
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

    v_credit_on := NULL; v_credit_week := public.rp_week_end(v_on); v_reason := NULL; v_line := NULL;
    IF v_key = 'cancelation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same business day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancelation_saved' AND l.status = 'credited'
                   AND l.customer_label = v_label AND l.save_line = v_line AND l.occurred_on > v_on - 90) THEN
        RAISE EXCEPTION 'one save per policy per ninety days — % already has a % save on file', v_label, v_line;
      END IF;
      v_credit_on := v_on + 30;
      v_credit_week := public.rp_week_end(v_credit_on);
    END IF;

    INSERT INTO public.retention_activity_log
      (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date, credit_available_on,
       customer_first_name, customer_last_initial, customer_label, ecrm_url, note, save_reason, save_line, points, source, created_by)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), upper(btrim(p_customer_last_initial)), v_label, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id)
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
END $function$;

-- rp_log_quote: one row per quoted policy; several on the same line allowed.
CREATE OR REPLACE FUNCTION public.rp_log_quote(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_label text; v_url text; v_id uuid;
  v_items jsonb := '[]'::jsonb; it jsonb; v_line text; v_type text;
  v_lines text[]; v_rel text; v_existing boolean; v_src text; v_gnc boolean; v_sourced uuid;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'quote_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');

  -- items: [{line_of_business, product_type}, ...]. Older callers may send
  -- products_discussed as a plain list of lines; that still works.
  IF jsonb_typeof(p->'items') = 'array' AND jsonb_array_length(p->'items') > 0 THEN
    v_items := p->'items';
  ELSIF jsonb_typeof(p->'products_discussed') = 'array' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('line_of_business', lower(e))), '[]'::jsonb)
      INTO v_items FROM jsonb_array_elements_text(p->'products_discussed') e;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN RAISE EXCEPTION 'click every product you discussed. At least one.'; END IF;
  IF jsonb_array_length(v_items) > 40 THEN RAISE EXCEPTION 'more than 40 quoted policies in one entry. Double-check it.'; END IF;

  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;
  v_rel := NULLIF(lower(btrim(COALESCE(p->>'relationship_type',''))),'');
  IF v_rel IS NOT NULL AND v_rel NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'relationship type must be new, existing, or winback';
  END IF;
  v_existing := CASE WHEN v_rel IS NOT NULL THEN v_rel = 'existing'
                     ELSE COALESCE((p->>'is_existing_customer')::boolean, false) END;
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'unknown marketing source';
  END IF;
  v_gnc := CASE WHEN NULLIF(p->>'gnc_used','') IS NULL THEN NULL ELSE (p->>'gnc_used')::boolean END;
  v_sourced := NULLIF(p->>'sourced_by_team_member_id','')::uuid;
  IF v_sourced IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;

  -- validate every quoted policy before writing anything
  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_line := lower(btrim(COALESCE(it->>'line_of_business','')));
    IF v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN RAISE EXCEPTION 'unknown product: %', v_line; END IF;
    PERFORM public.rp_check_product_type(a.agency_id, v_line, it->>'product_type');
  END LOOP;
  SELECT array_agg(DISTINCT lower(x->>'line_of_business')) INTO v_lines FROM jsonb_array_elements(v_items) x;

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_label,
    is_existing_customer, relationship_type, marketing_source, gnc_used, sourced_by_team_member_id,
    ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label,
    v_existing, v_rel, v_src, v_gnc, v_sourced, v_url, v_lines, NULLIF(btrim(COALESCE(p->>'note','')),''), a.actor_id)
  RETURNING id INTO v_id;

  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_line := lower(btrim(it->>'line_of_business'));
    v_type := public.rp_check_product_type(a.agency_id, v_line, it->>'product_type');
    INSERT INTO public.quote_log_products (quote_log_id, agency_id, line_of_business, product_type)
    VALUES (v_id, a.agency_id, v_line, v_type);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'quote_id', v_id, 'customer', v_label,
                            'products_discussed', to_jsonb(v_lines), 'policies', jsonb_array_length(v_items),
                            'relationship_type', v_rel, 'marketing_source', v_src);
END $function$;

-- rp_log_sale: several policies per line; ONE Multiline credit per line.
CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text; v_gnc boolean;
  v_sourced uuid; v_sale_id uuid; prod jsonb; v_lob text; v_type text; v_prem numeric;
  v_cnt integer; v_new boolean; v_veh integer; v_veh_total integer := 0;
  v_total numeric := 0; v_anchor text; v_ml_pts numeric; v_ref_pts numeric; v_credit_id uuid;
  v_credited text[] := ARRAY[]::text[];
  v_credits jsonb := '[]'::jsonb; v_rp numeric := 0; v_note text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'sale_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'sale date cannot be in the future'; END IF;
  IF v_on < v_today - 30 THEN RAISE EXCEPTION 'log a sale within 30 days of the bind'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_status := lower(COALESCE(p->>'household_status',''));
  IF v_status NOT IN ('new','existing','winback') THEN RAISE EXCEPTION 'pick the relationship type: new, existing, or winback'; END IF;
  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NULL OR v_url !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM opportunity link is required (must start with http)'; END IF;
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NULL OR NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF p->>'gnc_used' IS NULL THEN RAISE EXCEPTION 'say whether Good Neighbor Connect was used'; END IF;
  v_gnc := (p->>'gnc_used')::boolean;
  v_sourced := COALESCE(NULLIF(p->>'sourced_by_team_member_id','')::uuid, a.team_member_id);
  IF NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;
  v_note := NULLIF(btrim(COALESCE(p->>'note','')),'');

  IF jsonb_typeof(p->'products') <> 'array' OR jsonb_array_length(p->'products') = 0 THEN
    RAISE EXCEPTION 'add at least one policy with its premium';
  END IF;
  IF jsonb_array_length(p->'products') > 40 THEN RAISE EXCEPTION 'more than 40 policies in one sale. Double-check it.'; END IF;

  -- validate every policy first, so nothing is written on a bad entry
  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(COALESCE(prod->>'line_of_business',''));
    IF v_lob NOT IN ('auto','fire','business','life','health','ips','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
    PERFORM public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem := NULLIF(prod->>'premium','')::numeric;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'premium required for %', v_lob; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_lob; END IF;
    IF v_lob = 'auto' THEN
      v_veh := NULLIF(prod->>'vehicle_count','')::integer;
      IF v_veh IS NULL OR v_veh < 1 THEN RAISE EXCEPTION 'how many cars on the auto policy?'; END IF;
      v_veh_total := v_veh_total + v_veh;
    END IF;
    v_total := v_total + v_prem;
  END LOOP;

  INSERT INTO public.sales_log (agency_id, team_member_id, sourced_by_team_member_id, sale_date, week_end_date,
    customer_first_name, customer_last_initial, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, gnc_used, vehicle_count, total_premium, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_sourced, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_status, v_url,
    v_src, v_gnc, NULLIF(v_veh_total, 0), v_total, v_note, a.actor_id)
  RETURNING id INTO v_sale_id;

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='multiline_sold' AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='referral_sold' AND is_active;

  -- household with nothing in force (new or winback): the biggest new line is
  -- the anchor and earns no multiline
  IF v_status IN ('new','winback') THEN
    SELECT lower(x->>'line_of_business') INTO v_anchor
    FROM jsonb_array_elements(p->'products') x
    WHERE COALESCE((x->>'is_new_line')::boolean, true)
    ORDER BY NULLIF(x->>'premium','')::numeric DESC NULLS LAST, lower(x->>'line_of_business') LIMIT 1;
  END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(prod->>'line_of_business');
    v_type := public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem := NULLIF(prod->>'premium','')::numeric;
    v_cnt := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    v_new := COALESCE((prod->>'is_new_line')::boolean, true);
    v_veh := CASE WHEN v_lob = 'auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END;
    v_credit_id := NULL;
    -- Multiline is per LINE for the household. A second auto policy is still
    -- the same auto line, so it earns nothing more.
    IF v_new AND v_ml_pts IS NOT NULL AND NOT (v_lob = ANY (v_credited))
       AND (v_status = 'existing' OR v_lob IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
      VALUES (a.agency_id, v_sourced, 'multiline_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
        btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
        'From sale entry: ' || v_lob || ' added to household', v_ml_pts, 'sales_log', v_sale_id, a.actor_id)
      RETURNING id INTO v_credit_id;
      v_rp := v_rp + v_ml_pts;
      v_credited := v_credited || v_lob;
      v_credits := v_credits || jsonb_build_object('activity_key','multiline_sold','line',v_lob,'points',v_ml_pts);
    END IF;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, multiline_credit_id)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_credit_id);
  END LOOP;

  IF v_src = 'referral' AND v_status IN ('new','winback') AND v_ref_pts IS NOT NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
    VALUES (a.agency_id, v_sourced, 'referral_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
      btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', v_sale_id, a.actor_id);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key','referral_sold','points',v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'sale_id', v_sale_id, 'customer', v_label, 'total_premium', v_total,
                            'policies', jsonb_array_length(p->'products'),
                            'retention_points', v_rp, 'credits', v_credits, 'sourced_by', v_sourced);
END $function$;

-- rp_log_entry: cancelation is a list of policies now.
CREATE OR REPLACE FUNCTION public.rp_log_entry(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p        jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_first  text  := p->>'customer_first';
  v_init   text  := p->>'customer_last_initial';
  v_on     date  := NULLIF(p->>'occurred_on', '')::date;
  v_url    text  := NULLIF(btrim(COALESCE(p->>'ecrm_url', '')), '');
  v_note   text  := NULLIF(btrim(COALESCE(p->>'note', '')), '');
  v_tm     uuid  := NULLIF(p->>'team_member_id', '')::uuid;
  v_rel    text  := NULLIF(lower(btrim(COALESCE(p->>'relationship_type', ''))), '');
  v_src    text  := NULLIF(btrim(COALESCE(p->>'marketing_source', '')), '');
  v_gnc    text  := NULLIF(p->>'gnc_used', '');
  v_srcby  text  := NULLIF(p->>'sourced_by_team_member_id', '');
  v_act    jsonb := p->'activity';
  v_quote  jsonb := p->'quote';
  v_sale   jsonb := p->'sale';
  v_cxl    jsonb := COALESCE(p->'cancelation', p->'cancellation');
  v_cxl_items jsonb := '[]'::jsonb;
  v_items  jsonb := '[]'::jsonb;
  v_shared jsonb;
  it       jsonb;
  v_cnt    integer;
  i        integer;
  r_act    jsonb; r_quote jsonb; r_sale jsonb; r_cxl jsonb := '[]'::jsonb; r_one jsonb;
BEGIN
  IF v_act IS NULL OR jsonb_typeof(v_act) <> 'object'
     OR jsonb_typeof(v_act->'items') <> 'array' OR jsonb_array_length(v_act->'items') = 0 THEN
    v_act := NULL;
  END IF;
  IF v_quote IS NULL OR jsonb_typeof(v_quote) <> 'object'
     OR NOT ((jsonb_typeof(v_quote->'items') = 'array' AND jsonb_array_length(v_quote->'items') > 0)
             OR (jsonb_typeof(v_quote->'products_discussed') = 'array' AND jsonb_array_length(v_quote->'products_discussed') > 0)) THEN
    v_quote := NULL;
  END IF;
  IF v_sale IS NULL OR jsonb_typeof(v_sale) <> 'object'
     OR jsonb_typeof(v_sale->'products') <> 'array' OR jsonb_array_length(v_sale->'products') = 0 THEN
    v_sale := NULL;
  END IF;

  -- cancelation: [{line_of_business, product_type}, ...]; older shapes still work
  IF v_cxl IS NOT NULL AND jsonb_typeof(v_cxl) = 'object' THEN
    IF jsonb_typeof(v_cxl->'items') = 'array' THEN
      v_cxl_items := v_cxl->'items';
    ELSIF jsonb_typeof(v_cxl->'policy_lines') = 'array' THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object('line_of_business', lower(btrim(e)))), '[]'::jsonb)
        INTO v_cxl_items FROM jsonb_array_elements_text(v_cxl->'policy_lines') e WHERE btrim(e) <> '';
    ELSIF NULLIF(btrim(COALESCE(v_cxl->>'policy_line','')),'') IS NOT NULL THEN
      v_cxl_items := jsonb_build_array(jsonb_build_object('line_of_business', lower(btrim(v_cxl->>'policy_line'))));
    END IF;
  END IF;
  IF jsonb_array_length(v_cxl_items) = 0 THEN v_cxl := NULL; END IF;
  IF jsonb_array_length(v_cxl_items) > 40 THEN RAISE EXCEPTION 'more than 40 canceled policies in one entry. Double-check it.'; END IF;

  IF v_act IS NULL AND v_quote IS NULL AND v_sale IS NULL AND v_cxl IS NULL THEN
    RAISE EXCEPTION 'add at least one thing to log: an activity, a quote, a sale, or a cancelation';
  END IF;

  -- sold and canceled on the same line in one entry is a contradiction
  IF v_sale IS NOT NULL AND v_cxl IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sale->'products') s
               JOIN jsonb_array_elements(v_cxl_items) c
                 ON lower(btrim(COALESCE(s->>'line_of_business',''))) = lower(btrim(COALESCE(c->>'line_of_business','')))) THEN
      RAISE EXCEPTION 'a sale and a cancelation on the same policy line cannot go in one entry. Log them separately.';
    END IF;
  END IF;

  v_shared := jsonb_build_object(
    'customer_first', v_first, 'customer_last_initial', v_init,
    'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm,
    'relationship_type', v_rel, 'household_status', v_rel,
    'marketing_source', v_src, 'gnc_used', v_gnc, 'sourced_by_team_member_id', v_srcby);

  IF v_act IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_act->'items') LOOP
      v_cnt := GREATEST(1, COALESCE(NULLIF(it->>'count', '')::integer, 1));
      IF v_cnt > 50 THEN RAISE EXCEPTION 'more than 50 of one item in a single entry. Double-check the count.'; END IF;
      FOR i IN 1..v_cnt LOOP v_items := v_items || (it - 'count'); END LOOP;
    END LOOP;
    r_act := public.rp_log_activity(v_items, v_first, v_init, v_on, v_url, v_note, v_tm);
  END IF;

  IF v_quote IS NOT NULL THEN
    r_quote := public.rp_log_quote(v_shared || v_quote || jsonb_build_object('quote_date', v_on));
  END IF;

  IF v_sale IS NOT NULL THEN
    r_sale := public.rp_log_sale(v_shared || v_sale || jsonb_build_object('sale_date', v_on));
  END IF;

  -- last, so the trigger sees any save logged above
  IF v_cxl IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_cxl_items) LOOP
      r_one := public.rp_log_cancelation(jsonb_build_object(
        'customer_first', v_first, 'customer_last_initial', v_init, 'canceled_on', v_on,
        'policy_line', it->>'line_of_business', 'product_type', it->>'product_type',
        'reason', v_cxl->>'reason', 'note', v_note, 'team_member_id', v_tm));
      r_cxl := r_cxl || r_one;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'customer', public.rp_customer_label(v_first, v_init),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale,
    'cancelation', CASE WHEN v_cxl IS NULL THEN NULL ELSE r_cxl END);
END $function$;

-- the reminder text the team reads
CREATE OR REPLACE FUNCTION public.run_rp_save_clear_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE rec RECORD; v_count integer := 0; v_ref text;
BEGIN
  FOR rec IN
    SELECT s.id, s.first_name, s.customer_label, s.save_line, s.credit_available_on, s.days_until_clear
    FROM public.rp_saves_clearing_soon s
    WHERE s.agency_id = p_agency_id AND s.days_until_clear BETWEEN 0 AND 3
  LOOP
    v_ref := 'retention_points:save_clear:' || rec.id::text;
    IF NOT EXISTS (SELECT 1 FROM public.alerts a
      WHERE a.agency_id = p_agency_id AND a.module_reference = v_ref AND a.is_resolved IS NOT TRUE) THEN
      INSERT INTO public.alerts
        (id, agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (gen_random_uuid(), p_agency_id, 'rp_save_clearing', 'low',
        COALESCE(rec.first_name, 'A teammate') || ' — ' || rec.customer_label ||
          ' save clears ' || to_char(rec.credit_available_on, 'Mon FMDD'),
        'The ' || rec.save_line || ' policy for ' || rec.customer_label ||
          ' was saved 30 days ago and the credit lands on ' || to_char(rec.credit_available_on, 'Mon FMDD') ||
          '. Check the policy is still active. If it canceled anyway, log the cancelation on the Production page and the credit comes back off before it is paid.',
        v_ref, rec.id, false, false, now());
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'records_processed', v_count,
    'output_summary', v_count || ' save-clearing reminder(s) raised');
END $function$;

REVOKE ALL ON FUNCTION public.rp_log_cancelation(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rp_void_cancelation(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rp_check_product_type(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_log_cancelation(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_void_cancelation(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_check_product_type(uuid, text, text) TO authenticated;
GRANT SELECT ON public.product_types TO authenticated;
GRANT SELECT ON public.quote_log_products TO authenticated;
