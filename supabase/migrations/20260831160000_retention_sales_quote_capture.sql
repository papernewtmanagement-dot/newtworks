-- 2026-08-31: Retention Points + Sales + Quote manual capture system (Newtworks Activity Log)
--
-- WHY: Retention Points (handbook page "Retention Points", one point = one dollar) needs a place
-- for the team to log the seven self-logged earners, a structured sale entry that derives the
-- Multiline Sold and Referral Sold credits automatically, and a per-quote entry (products
-- discussed) that can replace the hand-typed weekly quotes_discussed count.
--
-- DESIGN RECORD (Peter 2026-08-31):
--   * Service tasks vary by difficulty, but only three tiers: standard $2, company follow-up
--     (underwriting or billing question) $3, certificate of insurance $4. Nothing finer.
--   * Sale entry REQUIRES: vehicle count (when Auto is a line), premium per product, marketing
--     source, whether Good Neighbor Connect was used, and the ECRM opportunity link.
--   * Multiline Sold + Referral Sold are DERIVED from the sale entry, never logged by hand.
--   * Quote entry: click every product discussed.
--   * Cancellations get their own tracking later (cancellation_log — not built here); saves
--     logged here carry a 30-day hold and credit in the week the hold clears.
--   * Points snapshot at log time (retention_point_values.points) so a later value change
--     never re-prices history.
--   * Week boundary Sunday→Saturday (core principle calendar_conventions); week_end_date is the
--     Saturday. Central time for "today".
--
-- Missed-call reduction (handbook): reduction = 0.08 × (percent missed)², per person, calls that
-- rang at somebody's desk only (rows with a team_member_id). Calls answered = answered +
-- transferred (a transferred call was picked up).

-- ───────────────────────────────────────────────────────────────────────────────
-- helpers
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rp_week_end(p_date date)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
  -- Sunday→Saturday week; returns the Saturday that closes the week containing p_date.
  SELECT (p_date + (6 - EXTRACT(DOW FROM p_date)::int))::date;
$$;

CREATE OR REPLACE FUNCTION public.rp_today_central()
RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/Chicago')::date;
$$;

-- ───────────────────────────────────────────────────────────────────────────────
-- config: point values
-- ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.retention_point_values (
  agency_id     uuid NOT NULL,
  activity_key  text NOT NULL,
  label         text NOT NULL,
  points        numeric(8,2) NOT NULL CHECK (points >= 0),
  category      text NOT NULL CHECK (category IN ('logged','system','derived')),
  -- 'logged'  = team logs it in the Activity Log
  -- 'system'  = computed from phone report / hours function, nothing logged
  -- 'derived' = created automatically from the sale entry
  requires_note boolean NOT NULL DEFAULT false,
  sort_order    integer NOT NULL DEFAULT 100,
  is_active     boolean NOT NULL DEFAULT true,
  description   text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, activity_key)
);

INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, description) VALUES
 ('126794dd-25ff-47d2-a436-724499733365','hour_in_office',       'Hour worked in office',                          0.25,'system', false, 10, 'Any hour physically in the office during business hours. From the hours function, nothing to log.'),
 ('126794dd-25ff-47d2-a436-724499733365','call_answered',        'Call answered',                                  0.50,'system', false, 20, 'Inbound customer call that rang at your desk and you picked up (including ones you transferred). From the phone report.'),
 ('126794dd-25ff-47d2-a436-724499733365','walk_in',              'Walk-in helped',                                 1.50,'logged', false, 30, 'A customer or prospect came into the office and you handled them.'),
 ('126794dd-25ff-47d2-a436-724499733365','service_task',         'Service task — standard',                        2.00,'logged', false, 40, 'Any customer service request you finished, whatever channel it came in on.'),
 ('126794dd-25ff-47d2-a436-724499733365','service_task_company', 'Service task — underwriting or billing follow-up',3.00,'logged', false, 41, 'A request that needed you to get with underwriting or billing to answer or resolve.'),
 ('126794dd-25ff-47d2-a436-724499733365','service_task_coi',     'Service task — certificate of insurance',        4.00,'logged', false, 42, 'A certificate of insurance you built by hand for a business customer.'),
 ('126794dd-25ff-47d2-a436-724499733365','autopay_enrollment',   'Autopay enrollment',                             5.00,'logged', false, 50, 'A customer who was not on automatic payment is now on it because you set it up.'),
 ('126794dd-25ff-47d2-a436-724499733365','google_review',        'Google review',                                  5.00,'logged', false, 60, 'A customer left a Google review naming you, or you asked and they left one.'),
 ('126794dd-25ff-47d2-a436-724499733365','cancellation_saved',   'Cancellation saved',                             7.50,'logged', true,  70, 'Customer asked to cancel or the company issued a cancellation notice, and the policy is still active 30 days later. Log the same business day with the reason. Credit lands the week the 30 days clear.'),
 ('126794dd-25ff-47d2-a436-724499733365','policy_review',        'Policy review',                                  9.00,'logged', true,  80, 'A conversation with the customer about their policy. Note what you covered.'),
 ('126794dd-25ff-47d2-a436-724499733365','multiline_sold',       'Multiline Sold',                                10.00,'derived',false, 90, 'A line of business the household did not previously carry. Created automatically from the sale entry.'),
 ('126794dd-25ff-47d2-a436-724499733365','referral_sold',        'Referral Sold',                                 10.00,'derived',false,100, 'A referral you sourced became a new household with a bound policy. Created automatically from the sale entry.')
ON CONFLICT (agency_id, activity_key) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────────
-- config: marketing sources for the sale entry
-- ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sales_marketing_sources (
  agency_id   uuid NOT NULL,
  source_key  text NOT NULL,
  label       text NOT NULL,
  sort_order  integer NOT NULL DEFAULT 100,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, source_key)
);

INSERT INTO public.sales_marketing_sources (agency_id, source_key, label, sort_order) VALUES
 ('126794dd-25ff-47d2-a436-724499733365','referral',          'Referral',                     10),
 ('126794dd-25ff-47d2-a436-724499733365','existing_customer', 'Existing customer (added a line)', 20),
 ('126794dd-25ff-47d2-a436-724499733365','internet_lead',     'Internet lead',                30),
 ('126794dd-25ff-47d2-a436-724499733365','sf_lead',           'State Farm lead',              40),
 ('126794dd-25ff-47d2-a436-724499733365','walk_in',           'Walk-in',                      50),
 ('126794dd-25ff-47d2-a436-724499733365','call_in',           'Called the office',            60),
 ('126794dd-25ff-47d2-a436-724499733365','website',           'Agency website',               70),
 ('126794dd-25ff-47d2-a436-724499733365','social_media',      'Social media',                 80),
 ('126794dd-25ff-47d2-a436-724499733365','community_event',   'Community event',              90),
 ('126794dd-25ff-47d2-a436-724499733365','mailer',            'Mailer',                      100),
 ('126794dd-25ff-47d2-a436-724499733365','other',             'Other',                       999)
ON CONFLICT (agency_id, source_key) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────────
-- retention_activity_log — one row per credit
-- ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.retention_activity_log (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id               uuid NOT NULL,
  team_member_id          uuid NOT NULL REFERENCES public.team(id),
  activity_key            text NOT NULL,
  occurred_on             date NOT NULL,
  week_end_date           date NOT NULL,            -- Saturday of the week it happened
  credited_week_end_date  date NOT NULL,            -- Saturday of the week it pays (saves: +30 days)
  credit_available_on     date,                     -- saves only: occurred_on + 30
  customer_first_name     text,
  customer_last_initial   text,
  customer_label          text,                     -- "First L."
  ecrm_url                text,
  note                    text,
  save_reason             text,                     -- saves only
  save_line               text,                     -- saves only: which policy line was at risk
  points                  numeric(8,2) NOT NULL,    -- snapshot of value at log time
  status                  text NOT NULL DEFAULT 'credited' CHECK (status IN ('credited','void')),
  source                  text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','sales_log','system')),
  source_id               uuid,
  created_by              uuid,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  voided_at               timestamptz,
  voided_by               uuid,
  void_reason             text,
  verified_at             timestamptz,              -- Peter's spot-check
  verified_by             uuid,
  FOREIGN KEY (agency_id, activity_key) REFERENCES public.retention_point_values(agency_id, activity_key)
);
CREATE INDEX IF NOT EXISTS retention_activity_log_week_idx ON public.retention_activity_log (agency_id, credited_week_end_date, team_member_id);
CREATE INDEX IF NOT EXISTS retention_activity_log_customer_idx ON public.retention_activity_log (agency_id, customer_label, activity_key, occurred_on);

-- ───────────────────────────────────────────────────────────────────────────────
-- sales_log + sales_log_products
-- ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sales_log (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                 uuid NOT NULL,
  team_member_id            uuid NOT NULL REFERENCES public.team(id),  -- who wrote it
  sourced_by_team_member_id uuid NOT NULL REFERENCES public.team(id),  -- who sourced it (gets Multiline / Referral RP)
  sale_date                 date NOT NULL,
  week_end_date             date NOT NULL,
  customer_first_name       text NOT NULL,
  customer_last_initial     text NOT NULL,
  customer_label            text NOT NULL,
  household_status          text NOT NULL CHECK (household_status IN ('new','existing')),
  ecrm_opportunity_url      text NOT NULL,
  marketing_source          text NOT NULL,
  gnc_used                  boolean NOT NULL,       -- Good Neighbor Connect used on this sale
  vehicle_count             integer CHECK (vehicle_count IS NULL OR vehicle_count >= 0),
  total_premium             numeric(12,2) NOT NULL CHECK (total_premium >= 0),
  note                      text,
  status                    text NOT NULL DEFAULT 'active' CHECK (status IN ('active','void')),
  created_by                uuid,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  voided_at                 timestamptz,
  voided_by                 uuid,
  void_reason               text,
  FOREIGN KEY (agency_id, marketing_source) REFERENCES public.sales_marketing_sources(agency_id, source_key)
);
CREATE INDEX IF NOT EXISTS sales_log_week_idx ON public.sales_log (agency_id, week_end_date, team_member_id);

CREATE TABLE IF NOT EXISTS public.sales_log_products (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_log_id     uuid NOT NULL REFERENCES public.sales_log(id) ON DELETE CASCADE,
  agency_id        uuid NOT NULL,
  line_of_business text NOT NULL CHECK (line_of_business IN ('auto','fire','business','life','health','ips','bank')),
  premium          numeric(12,2) NOT NULL CHECK (premium >= 0),
  policy_count     integer NOT NULL DEFAULT 1 CHECK (policy_count >= 1),
  is_new_line      boolean NOT NULL DEFAULT true,   -- household did not previously carry this line
  multiline_credit_id uuid REFERENCES public.retention_activity_log(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sales_log_id, line_of_business)
);

-- ───────────────────────────────────────────────────────────────────────────────
-- quote_log — one row per quote conversation, every product discussed clicked
-- ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.quote_log (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id              uuid NOT NULL,
  team_member_id         uuid NOT NULL REFERENCES public.team(id),
  quote_date             date NOT NULL,
  week_end_date          date NOT NULL,
  customer_first_name    text NOT NULL,
  customer_last_initial  text NOT NULL,
  customer_label         text NOT NULL,
  is_existing_customer   boolean NOT NULL DEFAULT false,
  ecrm_opportunity_url   text,
  products_discussed     text[] NOT NULL CHECK (cardinality(products_discussed) >= 1),
  note                   text,
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','void')),
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  voided_at              timestamptz,
  voided_by              uuid,
  void_reason            text
);
CREATE INDEX IF NOT EXISTS quote_log_week_idx ON public.quote_log (agency_id, week_end_date, team_member_id);

-- ───────────────────────────────────────────────────────────────────────────────
-- RLS: everyone signed in to the agency can READ; all WRITES go through the RPCs below.
-- (Admins may edit the two config tables directly.)
-- ───────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.retention_point_values   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_marketing_sources  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retention_activity_log   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_log                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_log_products       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_log                ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['retention_point_values','sales_marketing_sources','retention_activity_log','sales_log','sales_log_products','quote_log'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_auth_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (agency_id = %L::uuid)',
                   t || '_auth_read', t, '126794dd-25ff-47d2-a436-724499733365');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['retention_point_values','sales_marketing_sources'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin_write', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_agency_admin() AND agency_id = %L::uuid) WITH CHECK (public.is_agency_admin() AND agency_id = %L::uuid)',
                   t || '_admin_write', t, '126794dd-25ff-47d2-a436-724499733365', '126794dd-25ff-47d2-a436-724499733365');
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
  END LOOP;
END $$;

-- ───────────────────────────────────────────────────────────────────────────────
-- caller resolution shared by the RPCs
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rp_resolve_actor(p_team_member_id uuid DEFAULT NULL)
RETURNS TABLE (actor_id uuid, team_member_id uuid, agency_id uuid, is_admin boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_actor uuid; v_agency uuid; v_admin boolean; v_target uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE='42501'; END IF;
  SELECT t.id, t.agency_id INTO v_actor, v_agency
  FROM public.team t JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = v_uid AND t.archived_at IS NULL
  LIMIT 1;
  v_admin := public.is_agency_admin();
  IF v_actor IS NULL AND NOT v_admin THEN
    RAISE EXCEPTION 'no active team member for authenticated user' USING ERRCODE='42501';
  END IF;
  IF v_agency IS NULL THEN
    SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = v_uid LIMIT 1;
  END IF;
  -- Admins may log on behalf of anyone; everyone else logs only for themselves.
  IF p_team_member_id IS NOT NULL AND p_team_member_id <> COALESCE(v_actor, '00000000-0000-0000-0000-000000000000'::uuid) THEN
    IF NOT v_admin THEN RAISE EXCEPTION 'only an admin can log for someone else' USING ERRCODE='42501'; END IF;
    v_target := p_team_member_id;
  ELSE
    v_target := v_actor;
  END IF;
  IF v_target IS NULL THEN RAISE EXCEPTION 'pick a team member' USING ERRCODE='22023'; END IF;
  RETURN QUERY SELECT v_actor, v_target, v_agency, v_admin;
END $$;

CREATE OR REPLACE FUNCTION public.rp_customer_label(p_first text, p_initial text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE f text := btrim(COALESCE(p_first,'')); i text := btrim(COALESCE(p_initial,''));
BEGIN
  IF f = '' THEN RAISE EXCEPTION 'customer first name required'; END IF;
  IF f ~ '\.' THEN RAISE EXCEPTION 'first name should not contain a period'; END IF;
  IF length(f) > 40 THEN RAISE EXCEPTION 'first name too long (max 40)'; END IF;
  IF i !~ '^[A-Za-z]$' THEN RAISE EXCEPTION 'last initial must be a single letter'; END IF;
  RETURN f || ' ' || upper(i) || '.';
END $$;

-- ───────────────────────────────────────────────────────────────────────────────
-- rp_log_activity — one customer contact, several credits
-- p_items: [{"activity_key":"policy_review"}, {"activity_key":"cancellation_saved","save_reason":"...","save_line":"auto"}]
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rp_log_activity(
  p_items jsonb,
  p_customer_first text,
  p_customer_last_initial text,
  p_occurred_on date DEFAULT NULL,
  p_ecrm_url text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_team_member_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
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
    IF v_key = 'cancellation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same business day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancellation_saved' AND l.status = 'credited'
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
END $$;

-- ───────────────────────────────────────────────────────────────────────────────
-- rp_void_activity — own row within 7 days, or admin any time
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rp_void_activity(p_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id AND agency_id = a.agency_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — void the sale instead'; END IF;
  IF NOT a.is_admin THEN
    IF r.team_member_id <> a.actor_id THEN RAISE EXCEPTION 'you can only remove your own entries' USING ERRCODE='42501'; END IF;
    IF r.created_at < now() - interval '7 days' THEN RAISE EXCEPTION 'entries older than 7 days can only be removed by an admin' USING ERRCODE='42501'; END IF;
  END IF;
  UPDATE public.retention_activity_log
     SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $$;

-- ───────────────────────────────────────────────────────────────────────────────
-- rp_log_sale — structured sale entry; derives Multiline Sold + Referral Sold credits
-- p_payload: {sale_date, customer_first, customer_last_initial, household_status:'new'|'existing',
--             ecrm_opportunity_url, marketing_source, gnc_used, vehicle_count, note,
--             team_member_id (admin only), sourced_by_team_member_id,
--             products:[{line_of_business, premium, policy_count, is_new_line}]}
-- Multiline rule: existing household → every new line credits. New household → every new line
-- except the anchor (highest premium) credits; the first line a brand-new household buys is not
-- a multiline. Referral Sold: marketing_source = referral AND household is new → one credit.
-- Both credits go to sourced_by_team_member_id (defaults to the writer).
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text; v_gnc boolean; v_veh integer;
  v_sourced uuid; v_sale_id uuid; prod jsonb; v_lob text; v_prem numeric; v_cnt integer; v_new boolean;
  v_total numeric := 0; v_lines int := 0; v_has_auto boolean := false;
  v_anchor text; v_ml_pts numeric; v_ref_pts numeric; v_credit_id uuid;
  v_credits jsonb := '[]'::jsonb; v_rp numeric := 0; v_note text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'sale_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'sale date cannot be in the future'; END IF;
  IF v_on < v_today - 30 THEN RAISE EXCEPTION 'log a sale within 30 days of the bind'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_status := lower(COALESCE(p->>'household_status',''));
  IF v_status NOT IN ('new','existing') THEN RAISE EXCEPTION 'is this a new household or an existing customer?'; END IF;
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
    RAISE EXCEPTION 'add at least one product with its premium';
  END IF;
  -- validate products first
  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(COALESCE(prod->>'line_of_business',''));
    IF v_lob NOT IN ('auto','fire','business','life','health','ips','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
    v_prem := NULLIF(prod->>'premium','')::numeric;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'premium required for %', v_lob; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large — double-check', v_lob; END IF;
    IF v_lob = 'auto' THEN v_has_auto := true; END IF;
    v_total := v_total + v_prem;
  END LOOP;
  v_veh := NULLIF(p->>'vehicle_count','')::integer;
  IF v_has_auto AND (v_veh IS NULL OR v_veh < 1) THEN RAISE EXCEPTION 'how many cars?'; END IF;
  IF NOT v_has_auto THEN v_veh := NULL; END IF;

  INSERT INTO public.sales_log (agency_id, team_member_id, sourced_by_team_member_id, sale_date, week_end_date,
    customer_first_name, customer_last_initial, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, gnc_used, vehicle_count, total_premium, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_sourced, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_status, v_url,
    v_src, v_gnc, v_veh, v_total, v_note, a.actor_id)
  RETURNING id INTO v_sale_id;

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='multiline_sold' AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='referral_sold' AND is_active;

  -- anchor line for a brand-new household = highest premium among new lines (no multiline credit on it)
  IF v_status = 'new' THEN
    SELECT lower(x->>'line_of_business') INTO v_anchor
    FROM jsonb_array_elements(p->'products') x
    WHERE COALESCE((x->>'is_new_line')::boolean, true)
    ORDER BY NULLIF(x->>'premium','')::numeric DESC NULLS LAST, lower(x->>'line_of_business') LIMIT 1;
  END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(prod->>'line_of_business');
    v_prem := NULLIF(prod->>'premium','')::numeric;
    v_cnt := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    v_new := COALESCE((prod->>'is_new_line')::boolean, true);
    v_credit_id := NULL;
    IF v_new AND v_ml_pts IS NOT NULL AND (v_status = 'existing' OR v_lob IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
      VALUES (a.agency_id, v_sourced, 'multiline_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
        btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
        'From sale entry: ' || v_lob || ' added to household', v_ml_pts, 'sales_log', v_sale_id, a.actor_id)
      RETURNING id INTO v_credit_id;
      v_rp := v_rp + v_ml_pts; v_lines := v_lines + 1;
      v_credits := v_credits || jsonb_build_object('activity_key','multiline_sold','line',v_lob,'points',v_ml_pts);
    END IF;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, premium, policy_count, is_new_line, multiline_credit_id)
    VALUES (v_sale_id, a.agency_id, v_lob, v_prem, v_cnt, v_new, v_credit_id);
  END LOOP;

  IF v_src = 'referral' AND v_status = 'new' AND v_ref_pts IS NOT NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
    VALUES (a.agency_id, v_sourced, 'referral_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
      btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', v_sale_id, a.actor_id);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key','referral_sold','points',v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'sale_id', v_sale_id, 'customer', v_label, 'total_premium', v_total,
                            'retention_points', v_rp, 'credits', v_credits, 'sourced_by', v_sourced);
END $$;

CREATE OR REPLACE FUNCTION public.rp_void_sale(p_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT * INTO r FROM public.sales_log WHERE id = p_id AND agency_id = a.agency_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  IF NOT a.is_admin THEN
    IF r.team_member_id <> a.actor_id THEN RAISE EXCEPTION 'you can only remove your own entries' USING ERRCODE='42501'; END IF;
    IF r.created_at < now() - interval '7 days' THEN RAISE EXCEPTION 'entries older than 7 days can only be removed by an admin' USING ERRCODE='42501'; END IF;
  END IF;
  UPDATE public.sales_log SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now() WHERE id=p_id;
  UPDATE public.retention_activity_log SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason='sale entry removed', updated_at=now()
   WHERE source='sales_log' AND source_id=p_id AND status='credited';
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $$;

-- ───────────────────────────────────────────────────────────────────────────────
-- rp_log_quote — one row per quote conversation, all products discussed clicked
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rp_log_quote(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_label text; v_prods text[]; v_url text; v_id uuid; x text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'quote_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  SELECT COALESCE(array_agg(DISTINCT lower(e)), ARRAY[]::text[]) INTO v_prods FROM jsonb_array_elements_text(COALESCE(p->'products_discussed','[]'::jsonb)) e;
  IF cardinality(v_prods) = 0 THEN RAISE EXCEPTION 'click every product you discussed — at least one'; END IF;
  FOREACH x IN ARRAY v_prods LOOP
    IF x NOT IN ('auto','fire','business','life','health','ips','bank') THEN RAISE EXCEPTION 'unknown product: %', x; END IF;
  END LOOP;
  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_label,
    is_existing_customer, ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label,
    COALESCE((p->>'is_existing_customer')::boolean, false), v_url, v_prods, NULLIF(btrim(COALESCE(p->>'note','')),''), a.actor_id)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'quote_id', v_id, 'customer', v_label, 'products_discussed', to_jsonb(v_prods));
END $$;

CREATE OR REPLACE FUNCTION public.rp_void_quote(p_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT * INTO r FROM public.quote_log WHERE id = p_id AND agency_id = a.agency_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  IF NOT a.is_admin THEN
    IF r.team_member_id <> a.actor_id THEN RAISE EXCEPTION 'you can only remove your own entries' USING ERRCODE='42501'; END IF;
    IF r.created_at < now() - interval '7 days' THEN RAISE EXCEPTION 'entries older than 7 days can only be removed by an admin' USING ERRCODE='42501'; END IF;
  END IF;
  UPDATE public.quote_log SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now() WHERE id=p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $$;

-- ───────────────────────────────────────────────────────────────────────────────
-- compute_weekly_retention_points — the number the pay function will consume.
-- One row per agency seat (owner + back-office excluded, same roster rule as the pool).
-- hours: get_weekly_cpr_hours in_office × value(hour_in_office)
-- calls: daily_call_activity rows WITH a team member, (answered + transferred) × value(call_answered)
-- missed %: (abandoned + voicemail) / (answered + transferred + abandoned + voicemail), same rows
-- reduction = 0.08 × missed%²  (capped at 100%), applied to gross points
-- logged/derived: retention_activity_log credited in this week (saves land the week the 30 days clear)
-- ───────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_weekly_retention_points(p_agency_id uuid, p_week_end_date date)
RETURNS TABLE (
  team_member_id uuid, first_name text, role_category text,
  hours_in_office numeric, hour_points numeric,
  calls_answered integer, call_points numeric,
  missed_calls integer, missed_pct numeric, reduction_pct numeric,
  logged_points numeric, derived_points numeric, gross_points numeric, net_points numeric,
  detail jsonb
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_week_end date := public.rp_week_end(p_week_end_date);
  v_week_start date := public.rp_week_end(p_week_end_date) - 6;
  v_hour_val numeric; v_call_val numeric;
BEGIN
  SELECT points INTO v_hour_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='hour_in_office' AND is_active;
  SELECT points INTO v_call_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='call_answered' AND is_active;
  v_hour_val := COALESCE(v_hour_val, 0); v_call_val := COALESCE(v_call_val, 0);

  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user,false) = false AND COALESCE(t.is_admin_backoffice,false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (t.end_date IS NULL OR t.end_date >= v_week_start)
  ),
  hrs AS (
    SELECT h.team_member_id AS tm, COALESCE(SUM(CASE WHEN h.location = 'in_office' THEN h.hours ELSE 0 END),0)::numeric AS in_office
    FROM public.get_weekly_cpr_hours(p_agency_id, v_week_end) h
    GROUP BY h.team_member_id
  ),
  calls AS (
    SELECT d.team_member_id AS tm,
           COALESCE(SUM(d.answered_calls_external),0) + COALESCE(SUM(d.transferred_calls_external),0) AS answered,
           COALESCE(SUM(d.abandoned_calls_external),0) + COALESCE(SUM(d.voicemail_calls_external),0) AS missed
    FROM public.daily_call_activity d
    WHERE d.agency_id = p_agency_id AND d.team_member_id IS NOT NULL
      AND d.activity_date BETWEEN v_week_start AND v_week_end
    GROUP BY d.team_member_id
  ),
  logged AS (
    SELECT l.team_member_id AS tm,
           COALESCE(SUM(CASE WHEN l.source = 'manual' THEN l.points ELSE 0 END),0) AS logged_pts,
           COALESCE(SUM(CASE WHEN l.source <> 'manual' THEN l.points ELSE 0 END),0) AS derived_pts,
           jsonb_object_agg(l.activity_key, l.cnt) FILTER (WHERE l.activity_key IS NOT NULL) AS by_key
    FROM (
      SELECT x.team_member_id, x.activity_key, x.source, SUM(x.points) AS points, COUNT(*) AS cnt
      FROM public.retention_activity_log x
      WHERE x.agency_id = p_agency_id AND x.status = 'credited' AND x.credited_week_end_date = v_week_end
      GROUP BY x.team_member_id, x.activity_key, x.source
    ) l
    GROUP BY l.team_member_id
  ),
  calc AS (
    SELECT r.id, r.first_name, r.role_category,
           ROUND(COALESCE(h.in_office,0), 2) AS hours_in_office,
           ROUND(COALESCE(h.in_office,0) * v_hour_val, 2) AS hour_points,
           COALESCE(c.answered,0)::int AS calls_answered,
           ROUND(COALESCE(c.answered,0) * v_call_val, 2) AS call_points,
           COALESCE(c.missed,0)::int AS missed_calls,
           CASE WHEN COALESCE(c.answered,0) + COALESCE(c.missed,0) > 0
                THEN ROUND(100.0 * COALESCE(c.missed,0) / (COALESCE(c.answered,0) + COALESCE(c.missed,0)), 2) ELSE 0 END AS missed_pct,
           COALESCE(lg.logged_pts,0) AS logged_points,
           COALESCE(lg.derived_pts,0) AS derived_points,
           COALESCE(lg.by_key,'{}'::jsonb) AS by_key
    FROM roster r
    LEFT JOIN hrs h ON h.tm = r.id
    LEFT JOIN calls c ON c.tm = r.id
    LEFT JOIN logged lg ON lg.tm = r.id
  ),
  red AS (
    SELECT k.*, LEAST(100, ROUND(0.08 * k.missed_pct * k.missed_pct, 2)) AS reduction_pct,
           (k.hour_points + k.call_points + k.logged_points + k.derived_points) AS gross
    FROM calc k
  )
  SELECT k.id, k.first_name, k.role_category,
         k.hours_in_office, k.hour_points, k.calls_answered, k.call_points,
         k.missed_calls, k.missed_pct, k.reduction_pct,
         k.logged_points, k.derived_points,
         ROUND(k.gross, 2) AS gross_points,
         ROUND(k.gross * (1 - k.reduction_pct/100.0), 2) AS net_points,
         jsonb_build_object(
           'week_end_date', v_week_end,
           'values', jsonb_build_object('hour_in_office', v_hour_val, 'call_answered', v_call_val),
           'counts_by_key', k.by_key,
           'formula', 'net = (hour_pts + call_pts + logged + derived) × (1 − 0.08 × missed%² / 100); missed% per person, desk-attributed calls only'
         ) AS detail
  FROM red k
  ORDER BY k.first_name;
END $$;

GRANT EXECUTE ON FUNCTION public.rp_week_end(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_today_central() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_customer_label(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_resolve_actor(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_log_activity(jsonb, text, text, date, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_void_activity(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_log_sale(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_void_sale(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_log_quote(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_void_quote(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.compute_weekly_retention_points(uuid, date) TO authenticated;
