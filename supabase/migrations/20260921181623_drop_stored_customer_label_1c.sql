-- 1C: the customer label is no longer stored. It is built from the name fields
-- by one function, rp_customer_label_format, and exposed per table as customer_label(row).
-- Function and view bodies are inlined so a fresh rebuild needs nothing else.

CREATE FUNCTION public.rp_customer_label_format(p_first text, p_initial text, p_kind text DEFAULT 'person')
RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN btrim(COALESCE(p_first,'')) = '' THEN NULL
    WHEN public.rp_customer_kind(p_kind) = 'org' THEN btrim(p_first)
    ELSE btrim(p_first) || ' ' || upper(btrim(COALESCE(p_initial,''))) || '.' END $f$;

CREATE FUNCTION public.customer_label(r public.sales_log) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) $f$;
CREATE FUNCTION public.customer_label(r public.quote_log) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) $f$;
CREATE FUNCTION public.customer_label(r public.cancelation_log) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) $f$;
CREATE FUNCTION public.customer_label(r public.retention_activity_log) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) $f$;
CREATE FUNCTION public.customer_label(r public.appointment_log) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) $f$;

CREATE OR REPLACE FUNCTION public.cancelation_log_chargeback()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  sp RECORD; cr RECORD; v_window_end date; v_left numeric; v_pts numeric; v_id uuid;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
BEGIN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.submitted_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = NEW.matched_sale_product_id AND s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = public.customer_label(NEW) AND p.line_of_business = NEW.policy_line
       AND s.submitted_date <= NEW.canceled_on
       AND s.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on;
  IF sp.id IS NULL THEN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.submitted_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = public.customer_label(NEW) AND p.line_of_business = NEW.policy_line
       AND s.submitted_date <= NEW.canceled_on
       AND s.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active' AND c.id <> NEW.id)
     ORDER BY (p.product_type IS NOT DISTINCT FROM NEW.product_type) DESC, s.submitted_date DESC
     LIMIT 1;
  END IF;
  IF sp.id IS NULL THEN
    UPDATE public.cancelation_log SET matched_sale_product_id = NULL WHERE id = NEW.id AND matched_sale_product_id IS NOT NULL;
    RETURN NEW;
  END IF;

  v_window_end := (sp.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval)::date;
  v_left := round((v_window_end - NEW.canceled_on)::numeric / NULLIF((v_window_end - sp.submitted_date)::numeric, 0), 4);
  v_left := LEAST(1, GREATEST(0, COALESCE(v_left, 0)));
  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;

  -- The household's phone and link travel both ways. A matched sale that has
  -- none takes the cancelation's (Peter 2026-09-20).
  UPDATE public.sales_log
     SET phone_last4 = COALESCE(phone_last4, NEW.phone_last4),
         ecrm_opportunity_url = CASE WHEN COALESCE(btrim(ecrm_opportunity_url), '') = ''
                                     THEN NULLIF(btrim(COALESCE(NEW.ecrm_url, '')), '')
                                     ELSE ecrm_opportunity_url END,
         updated_at = now()
   WHERE id = sp.sale_id
     AND ((phone_last4 IS NULL AND NEW.phone_last4 IS NOT NULL)
       OR (COALESCE(btrim(ecrm_opportunity_url), '') = '' AND COALESCE(btrim(NEW.ecrm_url), '') <> ''));

  IF sp.multiline_credit_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO cr FROM public.retention_activity_now WHERE id = sp.multiline_credit_id AND status = 'credited';
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_pts := round(cr.points * v_left, 2);
  IF v_pts <= 0 THEN RETURN NEW; END IF;

  IF cr.credited_week_end_date >= v_cur_week THEN
    UPDATE public.retention_activity_log
       SET status = 'void', voided_at = now(), voided_by = NEW.created_by,
           void_reason = 'policy canceled ' || NEW.canceled_on::text || ' inside the chargeback window', updated_at = now()
     WHERE id = cr.id;
    UPDATE public.cancelation_log SET chargeback_points = cr.points, chargeback_activity_id = cr.id WHERE id = NEW.id;
  ELSE
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_kind, note, points, source, source_id, created_by)
    VALUES (NEW.agency_id, cr.team_member_id, 'multiline_chargeback', NEW.canceled_on, public.rp_week_end(NEW.canceled_on), v_cur_week,
      NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_kind,
      'Chargeback: ' || NEW.policy_line || ' sold ' || to_char(sp.submitted_date, 'Mon FMDD') || ' canceled ' || to_char(NEW.canceled_on, 'Mon FMDD') ||
        ', ' || round(v_left * 100) || '% of the window left',
      -v_pts, 'cancelation_log', NEW.id, NEW.created_by)
    RETURNING id INTO v_id;
    UPDATE public.cancelation_log SET chargeback_points = v_pts, chargeback_activity_id = v_id WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.cancelation_log_logging_credit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_pts numeric;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
  v_week date;
BEGIN
  -- A cancelation that stops being active loses its credit.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status = 'active' OR OLD.status <> 'active' THEN RETURN NEW; END IF;
    UPDATE public.retention_activity_log
       SET status = 'void', voided_at = now(),
           void_reason = 'the cancelation it was credited for was removed', updated_at = now()
     WHERE source = 'cancelation_log' AND source_id = NEW.id
       AND activity_key = 'cancelation_logged' AND status = 'credited';
    RETURN NEW;
  END IF;

  IF NEW.status <> 'active' OR NEW.team_member_id IS NULL THEN RETURN NEW; END IF;
  -- History keyed in from the Backfill tab earns nobody a logging credit.
  IF COALESCE(NEW.entry_source, 'manual') = 'historical_backfill' THEN RETURN NEW; END IF;

  SELECT v.points INTO v_pts
    FROM public.retention_point_values v
   WHERE v.agency_id = NEW.agency_id AND v.activity_key = 'cancelation_logged' AND v.is_active;
  IF COALESCE(v_pts, 0) <= 0 THEN RETURN NEW; END IF;

  v_week := public.rp_week_end(NEW.canceled_on);

  INSERT INTO public.retention_activity_log (
    agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
    customer_first_name, customer_last_initial, customer_kind, phone_last4,
    policy_line, product_type, note, points, source, source_id, created_by)
  VALUES (
    NEW.agency_id, NEW.team_member_id, 'cancelation_logged', NEW.canceled_on, v_week,
    GREATEST(v_week, v_cur_week),
    NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_kind, NEW.phone_last4,
    NEW.policy_line, NEW.product_type,
    'Logged the cancelation of ' || initcap(COALESCE(NEW.policy_line, '')) || ' ' || COALESCE(NEW.product_type, '')
      || ' on ' || to_char(NEW.canceled_on, 'Mon FMDD'),
    v_pts, 'cancelation_log', NEW.id, NEW.created_by);

  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.cancelation_log_void_unpaid_saves()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
     AND l.customer_label = public.customer_label(NEW)
     AND l.save_line = NEW.policy_line
     AND l.occurred_on <= NEW.canceled_on
     AND l.credited_week_end_date >= public.rp_week_end(public.rp_today_central());
  GET DIAGNOSTICS v_n = ROW_COUNT;
  NEW.saves_voided := v_n;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.change_current_subject(p_table text, p_row_id uuid, p_row jsonb, p_snapshot text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    CASE p_table
      WHEN 'sales_log'              THEN (SELECT x.customer_label FROM public.sales_log x WHERE id = p_row_id)
      WHEN 'sales_log_products'     THEN (SELECT x.customer_label FROM public.sales_log x WHERE id = NULLIF(p_row ->> 'sales_log_id', '')::uuid)
      WHEN 'quote_log'              THEN (SELECT x.customer_label FROM public.quote_log x WHERE id = p_row_id)
      WHEN 'quote_log_products'     THEN (SELECT x.customer_label FROM public.quote_log x WHERE id = NULLIF(p_row ->> 'quote_log_id', '')::uuid)
      WHEN 'cancelation_log'        THEN (SELECT x.customer_label FROM public.cancelation_log x WHERE id = p_row_id)
      WHEN 'retention_activity_log' THEN (SELECT x.customer_label FROM public.retention_activity_log x WHERE id = p_row_id)
      WHEN 'fit_scorecards'         THEN (SELECT customer_first_name FROM public.fit_scorecards WHERE id = p_row_id)
    END,
    p_snapshot);
$function$;

CREATE OR REPLACE FUNCTION public.log_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_old     jsonb;
  v_new     jsonb;
  v_row     jsonb;
  v_fields  text[];
  v_uid     uuid;
  v_user_id uuid;
  v_tm      uuid;
  v_label   text;
  v_via     text;
  v_subject text;
  v_appname text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new := to_jsonb(NEW); v_row := v_new;
  ELSIF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD); v_row := v_old;
  ELSE
    v_old := to_jsonb(OLD); v_new := to_jsonb(NEW); v_row := v_new;
    SELECT array_agg(k ORDER BY k) INTO v_fields
      FROM jsonb_object_keys(v_new) AS k
     WHERE k <> 'updated_at' AND (v_new -> k) IS DISTINCT FROM (v_old -> k);
    IF v_fields IS NULL THEN
      RETURN NULL;  -- nothing moved but the clock
    END IF;
  END IF;

  -- Who did it.
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_uid := NULL;
  END;
  v_appname := COALESCE(current_setting('application_name', true), '');

  IF v_uid IS NOT NULL THEN
    SELECT u.id, u.team_member_id, COALESCE(NULLIF(btrim(u.full_name), ''), u.email)
      INTO v_user_id, v_tm, v_label
      FROM public.users u
     WHERE u.auth_user_id = v_uid
     LIMIT 1;
    IF v_tm IS NULL AND v_user_id IS NOT NULL THEN
      SELECT t.id INTO v_tm FROM public.team t
       WHERE t.user_id = v_user_id AND t.archived_at IS NULL
       LIMIT 1;
    END IF;
    v_via   := 'app';
    v_label := COALESCE(v_label, 'App user ' || left(v_uid::text, 8));
  ELSIF v_appname ILIKE 'pg_cron%' THEN
    v_via   := 'automation';
    v_label := 'Automation (scheduled)';
  ELSIF current_user IN ('postgres', 'supabase_admin') THEN
    v_via   := 'maintenance';
    v_label := 'Maintenance (SQL)';
  ELSE
    v_via   := 'automation';
    v_label := 'Automation (' || current_user || ')';
  END IF;

  -- Which customer the row is about.
  v_subject := COALESCE(
    CASE WHEN v_row ? 'customer_kind' THEN public.rp_customer_label_format(v_row ->> 'customer_first_name', v_row ->> 'customer_last_initial', v_row ->> 'customer_kind') END,
    NULLIF(btrim(COALESCE(v_row ->> 'customer_first_name', '') || ' ' || COALESCE(v_row ->> 'customer_last_initial', '')), '')
  );
  IF v_subject IS NULL AND TG_TABLE_NAME = 'sales_log_products' THEN
    SELECT s.customer_label INTO v_subject FROM public.sales_log s WHERE s.id = (v_row ->> 'sales_log_id')::uuid;
  ELSIF v_subject IS NULL AND TG_TABLE_NAME = 'quote_log_products' THEN
    SELECT q.customer_label INTO v_subject FROM public.quote_log q WHERE q.id = (v_row ->> 'quote_log_id')::uuid;
  END IF;

  INSERT INTO public.change_log
    (agency_id, table_name, row_id, action, changed_by_user_id, changed_by_team_member_id,
     changed_by_label, via, subject, changed_fields, old_row, new_row)
  VALUES
    ((v_row ->> 'agency_id')::uuid, TG_TABLE_NAME, (v_row ->> 'id')::uuid, lower(TG_OP), v_user_id, v_tm,
     v_label, v_via, v_subject, v_fields, v_old, v_new);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- Never block the team's write because the trail failed; shout in the log instead.
  RAISE WARNING 'change_log: % on %: %', TG_OP, TG_TABLE_NAME, SQLERRM;
  RETURN NULL;
END
$function$;

CREATE OR REPLACE FUNCTION public.rp_appointment_sync_calendar(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_host uuid; v_prod text; v_emails text[]; v_cal jsonb;
        v_summary text; v_desc text; v_end timestamptz;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not found'); END IF;
  IF r.starts_at IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no time on the appointment'); END IF;

  v_host := COALESCE(NULLIF(r.escalated_to_team_member_id, r.team_member_id), r.team_member_id);
  SELECT pt.label INTO v_prod FROM public.product_types pt
   WHERE pt.agency_id = r.agency_id AND pt.line_of_business = r.line_of_business
     AND pt.type_key = r.product_type AND pt.is_active;
  v_prod := COALESCE(v_prod, initcap(COALESCE(r.line_of_business, 'appointment')));

  -- Whoever is running it, plus whoever set it. The customer is never invited:
  -- we hold a first name, a last initial and four phone digits, never an email.
  SELECT array_agg(e) INTO v_emails FROM (
    SELECT DISTINCT COALESCE(t.email_sf, t.email_personal) AS e
    FROM public.team t
    WHERE t.id IN (v_host, r.team_member_id) AND COALESCE(t.email_sf, t.email_personal) IS NOT NULL
  ) s;

  v_summary := 'Appointment — ' || public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) || ' (' || v_prod || ')';
  v_desc := 'Set in Newtworks.' || E'\n' ||
    'Customer: ' || public.rp_customer_label_format(r.customer_first_name, r.customer_last_initial, r.customer_kind) || COALESCE(' ·' || r.phone_last4, '') || E'\n' ||
    'About: ' || v_prod || E'\n' ||
    'Where: ' || COALESCE(r.location, 'the office') ||
    COALESCE(E'\n\n' || r.note, '');
  v_end := r.starts_at + make_interval(mins => COALESCE(r.duration_minutes, 30));

  IF r.calendar_event_id IS NULL THEN
    v_cal := public.calendar_create_event_now(r.agency_id, 'primary', v_summary, v_desc,
      r.starts_at, v_end, v_emails, r.location, COALESCE(r.is_video, false), true);
  ELSE
    v_cal := public.calendar_patch_event_now(r.agency_id, 'primary', r.calendar_event_id,
      r.starts_at, v_end, v_summary, v_desc, r.location, v_emails, 'all');
  END IF;

  UPDATE public.appointment_log SET
    calendar_event_id = COALESCE(v_cal->>'event_id', calendar_event_id),
    meet_url          = COALESCE(v_cal->>'meet_url', meet_url),
    calendar_error    = CASE WHEN COALESCE((v_cal->>'ok')::boolean, false) THEN NULL ELSE v_cal->>'error' END
  WHERE id = p_id;

  RETURN jsonb_build_object(
    'on_calendar', COALESCE((v_cal->>'ok')::boolean, false),
    'meet_url', v_cal->>'meet_url',
    'calendar_error', CASE WHEN COALESCE((v_cal->>'ok')::boolean, false) THEN NULL ELSE v_cal->>'error' END);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_autopay_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_prior record;
BEGIN
  IF NEW.activity_key <> 'autopay_enrollment' OR COALESCE(NEW.status, 'credited') = 'voided' THEN RETURN NEW; END IF;
  IF NEW.policy_line IS NULL THEN RAISE EXCEPTION 'Autopay needs the policy line it was set up on'; END IF;
  IF NEW.premium IS NULL OR NEW.premium < 0 THEN RAISE EXCEPTION 'Autopay needs the policy premium'; END IF;
  SELECT l.occurred_on, l.source INTO v_prior FROM public.retention_activity_log l
   WHERE l.agency_id = NEW.agency_id AND l.activity_key = 'autopay_enrollment' AND l.status <> 'voided'
     AND l.customer_label = public.customer_label(NEW) AND l.policy_line = NEW.policy_line
     AND (l.phone_last4 IS NULL OR NEW.phone_last4 IS NULL OR l.phone_last4 = NEW.phone_last4)
     AND (l.product_type IS NULL OR NEW.product_type IS NULL OR l.product_type = NEW.product_type)
   ORDER BY l.occurred_on DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Autopay for % on % is already credited (% %). One autopay credit per policy.',
      public.customer_label(NEW), NEW.policy_line, CASE WHEN v_prior.source = 'manual' THEN 'logged' ELSE 'from the sale on' END, to_char(v_prior.occurred_on, 'Mon FMDD');
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; rec jsonb; pol jsonb; v_id uuid; v_kind text; v_label text;
  v_phone text; v_ecrm text; v_src text; v_refcust text; v_refby uuid; v_sub date;
  v_old_phone text; v_old_ecrm text; v_old_src text;
  v_items jsonb; v_touched boolean;
  v_saved integer := 0; v_spread integer := 0; v_issued integer := 0; n integer;
  v_canceled integer := 0; v_charged integer := 0;
  v_on date; v_res jsonb; sp RECORD; sl RECORD; v_type text; v_veh integer;
  v_today date := public.rp_today_central();
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

    -- What this record holds right now, before anything changes.
    IF v_kind = 'sale' THEN
      SELECT x.customer_label, phone_last4, ecrm_opportunity_url, marketing_source
        INTO v_label, v_old_phone, v_old_ecrm, v_old_src
        FROM public.sales_log x WHERE id = v_id AND agency_id = a.agency_id AND status = 'active';
    ELSE
      SELECT x.customer_label, phone_last4, NULL::text, marketing_source
        INTO v_label, v_old_phone, v_old_ecrm, v_old_src
        FROM public.quote_log x WHERE id = v_id AND agency_id = a.agency_id AND status = 'active';
    END IF;
    IF v_label IS NULL THEN CONTINUE; END IF;

    -- ---- 1. submitted date ---------------------------------------------------
    v_sub := NULLIF(btrim(COALESCE(rec->>'submitted_date','')), '')::date;
    IF v_sub IS NOT NULL THEN
      IF v_sub > v_today THEN RAISE EXCEPTION 'the submitted date cannot be in the future'; END IF;
      IF v_kind = 'sale' THEN
        UPDATE public.sales_log SET submitted_date = v_sub, week_end_date = public.rp_week_end(v_sub), updated_at = now()
         WHERE id = v_id AND submitted_date IS DISTINCT FROM v_sub;
        GET DIAGNOSTICS n = ROW_COUNT;
        -- A policy cannot have issued before the sale was submitted.
        UPDATE public.sales_log_products SET issued_date = v_sub
         WHERE sales_log_id = v_id AND issued_date IS NOT NULL AND issued_date < v_sub;
      ELSE
        UPDATE public.quote_log SET quote_date = v_sub, week_end_date = public.rp_week_end(v_sub), updated_at = now()
         WHERE id = v_id AND quote_date IS DISTINCT FROM v_sub;
        GET DIAGNOSTICS n = ROW_COUNT;
      END IF;
      IF n > 0 THEN v_touched := true; END IF;
    END IF;

    -- ---- 2. household fields -------------------------------------------------
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
        WHERE id = v_id;
      ELSE
        UPDATE public.quote_log SET
          phone_last4 = COALESCE(v_phone, phone_last4),
          marketing_source = COALESCE(v_src, marketing_source),
          referred_by_customer = COALESCE(v_refcust, referred_by_customer),
          sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
          updated_at = now()
        WHERE id = v_id;
      END IF;
      v_touched := true;
    END IF;

    IF v_kind = 'sale' AND jsonb_typeof(rec->'policies') = 'array' THEN
      -- ---- 3. product type and cars ------------------------------------------
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        SELECT p.* INTO sp FROM public.sales_log_products p
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;
        CONTINUE WHEN sp.id IS NULL;
        IF NULLIF(btrim(COALESCE(pol->>'product_type','')), '') IS NOT NULL THEN
          v_type := public.rp_check_product_type(a.agency_id, sp.line_of_business, pol->>'product_type');
          UPDATE public.sales_log_products SET product_type = v_type
           WHERE id = sp.id AND product_type IS DISTINCT FROM v_type;
          GET DIAGNOSTICS n = ROW_COUNT; IF n > 0 THEN v_touched := true; END IF;
        END IF;
        IF sp.line_of_business = 'auto' AND NULLIF(btrim(COALESCE(pol->>'vehicle_count','')), '') IS NOT NULL THEN
          v_veh := (pol->>'vehicle_count')::integer;
          IF v_veh < 1 OR v_veh > 20 THEN RAISE EXCEPTION 'how many cars on that auto policy?'; END IF;
          UPDATE public.sales_log_products SET vehicle_count = v_veh
           WHERE id = sp.id AND vehicle_count IS DISTINCT FROM v_veh;
          GET DIAGNOSTICS n = ROW_COUNT; IF n > 0 THEN v_touched := true; END IF;
        END IF;
      END LOOP;

      -- ---- 4. issued date and premium, through rp_mark_issued -----------------
      -- Runs BEFORE any cancelation, so a chargeback logged in the same save is
      -- priced off the premium being applied, not the old one.
      SELECT jsonb_agg(jsonb_build_object(
               'sale_product_id', x->>'id',
               'issued_date', NULLIF(x->>'issued_date',''),
               'issued_premium', NULLIF(x->>'issued_premium','')))
        INTO v_items
        FROM jsonb_array_elements(rec->'policies') x
       WHERE (NULLIF(btrim(COALESCE(x->>'issued_premium','')), '') IS NOT NULL
              OR NULLIF(btrim(COALESCE(x->>'issued_date','')), '') IS NOT NULL)
         AND EXISTS (SELECT 1 FROM public.sales_log_products p
                      WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id);
      IF v_items IS NOT NULL AND jsonb_array_length(v_items) > 0 THEN
        PERFORM public.rp_mark_issued(v_items);
        v_issued := v_issued + jsonb_array_length(v_items);
        v_touched := true;
      END IF;

      -- ---- 5. added car ---------------------------------------------------------
      -- Credits on a backfilled sale are locked, so this corrects the record and
      -- moves no points.
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        CONTINUE WHEN NOT (pol ? 'added_to_existing');
        UPDATE public.sales_log_products p
           SET is_added_to_existing = COALESCE((pol->>'added_to_existing')::boolean, false),
               is_new_line = NOT COALESCE((pol->>'added_to_existing')::boolean, false)
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id
           AND p.line_of_business = 'auto'
           AND p.is_added_to_existing IS DISTINCT FROM COALESCE((pol->>'added_to_existing')::boolean, false);
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n > 0 THEN v_touched := true; END IF;
      END LOOP;

      -- ---- 6. canceled ----------------------------------------------------------
      -- Logged through rp_log_cancelation like every other cancelation. The
      -- backfill flag lifts only the 90-day floor and marks it as history, which
      -- keeps it from paying anyone a logging credit.
      SELECT s.* INTO sl FROM public.sales_log s WHERE s.id = v_id;
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        v_on := NULLIF(btrim(COALESCE(pol->>'canceled_on','')), '')::date;
        CONTINUE WHEN v_on IS NULL;
        SELECT p.* INTO sp FROM public.sales_log_products p
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;
        CONTINUE WHEN sp.id IS NULL;
        CONTINUE WHEN EXISTS (SELECT 1 FROM public.cancelation_log c
                               WHERE c.matched_sale_product_id = sp.id AND c.status = 'active');
        IF sl.ecrm_opportunity_url IS NULL OR btrim(sl.ecrm_opportunity_url) = '' THEN
          RAISE EXCEPTION 'marking % canceled needs the ECRM link on the household first', public.rp_customer_label_format(sl.customer_first_name, sl.customer_last_initial, sl.customer_kind);
        END IF;
        v_res := public.rp_log_cancelation(jsonb_build_object(
          'backfill', true,
          'replacement', COALESCE((pol->>'replacement')::boolean, false),
          'team_member_id', sl.team_member_id,
          'customer_first', sl.customer_first_name,
          'customer_last_initial', sl.customer_last_initial,
          'customer_kind', sl.customer_kind,
          'canceled_on', v_on::text,
          'policy_line', sp.line_of_business,
          'product_type', sp.product_type,
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

    -- ---- 7. spread household values to the rest of the household -------------
    -- Same household = same name, and a value that is empty or is the one just
    -- replaced. A different household that shares the name keeps its own.
    IF v_phone IS NOT NULL THEN
      UPDATE public.sales_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND sales_log.customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.quote_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND quote_log.customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.cancelation_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND cancelation_log.customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.retention_activity_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status <> 'void' AND retention_activity_log.customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;

    IF v_src IS NOT NULL THEN
      UPDATE public.sales_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND sales_log.customer_label = v_label
         AND (COALESCE(btrim(marketing_source), '') = '' OR marketing_source = v_old_src)
         AND marketing_source IS DISTINCT FROM v_src;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.quote_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND quote_log.customer_label = v_label
         AND (COALESCE(btrim(marketing_source), '') = '' OR marketing_source = v_old_src)
         AND marketing_source IS DISTINCT FROM v_src;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;

    IF v_ecrm IS NOT NULL THEN
      UPDATE public.sales_log SET ecrm_opportunity_url = v_ecrm, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND sales_log.customer_label = v_label
         AND (COALESCE(btrim(ecrm_opportunity_url), '') = '' OR ecrm_opportunity_url = v_old_ecrm)
         AND ecrm_opportunity_url IS DISTINCT FROM v_ecrm;
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

CREATE OR REPLACE FUNCTION public.rp_convert_activity_to_cancelation(p_activity_id uuid, p_policies jsonb, p_ecrm_url text DEFAULT NULL::text, p_also_void uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; l RECORD; item jsonb; res jsonb; v_ids uuid[] := '{}'; v_url text;
  v_other uuid; v_also integer := 0; v_reason text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can turn an entry into a cancelation'; END IF;

  SELECT * INTO l FROM public.retention_activity_log
   WHERE id = p_activity_id AND agency_id = a.agency_id AND status = 'credited';
  IF NOT FOUND THEN RAISE EXCEPTION 'that entry is not on file any more'; END IF;

  IF p_policies IS NULL OR jsonb_typeof(p_policies) <> 'array' OR jsonb_array_length(p_policies) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy that canceled';
  END IF;

  v_url := COALESCE(NULLIF(btrim(COALESCE(l.ecrm_url, '')), ''), NULLIF(btrim(COALESCE(p_ecrm_url, '')), ''));

  FOR item IN SELECT * FROM jsonb_array_elements(p_policies) LOOP
    res := public.rp_log_cancelation(jsonb_build_object(
      'team_member_id', l.team_member_id,
      'canceled_on', l.occurred_on,
      'customer_first', l.customer_first_name,
      'customer_last_initial', l.customer_last_initial,
      'phone_last4', l.phone_last4,
      'policy_line', item->>'policy_line',
      'product_type', item->>'product_type',
      'premium', item->>'premium',
      'vehicle_count', item->>'vehicle_count',
      'matched_sale_product_id', item->>'matched_sale_product_id',
      'note', COALESCE(NULLIF(btrim(COALESCE(l.note, '')), ''), 'Turned into a cancelation at spot-check'),
      'ecrm_url', v_url
    ));
    v_ids := v_ids || (res->>'cancelation_id')::uuid;
  END LOOP;

  -- The household key is the name plus the last four. rp_log_cancelation does
  -- not take the phone, so it is put on here, on the cancelation and on the
  -- logging credit the trigger wrote from it.
  IF l.phone_last4 IS NOT NULL THEN
    UPDATE public.cancelation_log SET phone_last4 = l.phone_last4
     WHERE id = ANY(v_ids) AND phone_last4 IS NULL;
    UPDATE public.retention_activity_log SET phone_last4 = l.phone_last4
     WHERE source = 'cancelation_log' AND source_id = ANY(v_ids) AND phone_last4 IS NULL;
  END IF;

  v_reason := 'spot-check: this was a cancelation, not a ' ||
    COALESCE((SELECT v.label FROM public.retention_point_values v
               WHERE v.agency_id = a.agency_id AND v.activity_key = l.activity_key), l.activity_key);

  PERFORM public.rp_void_activity(p_activity_id, v_reason);

  -- The same cancelation typed more than once for one household.
  FOREACH v_other IN ARRAY COALESCE(p_also_void, '{}'::uuid[]) LOOP
    IF v_other = p_activity_id THEN CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM public.retention_activity_log x
                WHERE x.id = v_other AND x.agency_id = a.agency_id AND x.status = 'credited') THEN
      PERFORM public.rp_void_activity(v_other, v_reason || ', and the same one as another entry');
      v_also := v_also + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'cancelation_ids', to_jsonb(v_ids),
                            'count', array_length(v_ids, 1), 'also_removed', v_also,
                            'customer', public.rp_customer_label_format(l.customer_first_name, l.customer_last_initial, l.customer_kind));
END $function$;

CREATE OR REPLACE FUNCTION public.rp_customer_label(p_first text, p_initial text, p_kind text DEFAULT 'person'::text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  f text := btrim(COALESCE(p_first, ''));
  i text := btrim(COALESCE(p_initial, ''));
  k text := public.rp_customer_kind(p_kind);
BEGIN
  IF k = 'org' THEN
    IF f = '' THEN RAISE EXCEPTION 'the organization name is required'; END IF;
    IF length(f) > 80 THEN RAISE EXCEPTION 'organization name too long (max 80)'; END IF;
    -- An organization name is stored as typed. Periods are part of plenty of
    -- them, and there is no initial to bolt on the end.
    RETURN public.rp_customer_label_format(f, i, k);
  END IF;
  IF f = '' THEN RAISE EXCEPTION 'customer first name required'; END IF;
  IF f ~ '\.' THEN RAISE EXCEPTION 'first name should not contain a period'; END IF;
  IF length(f) > 40 THEN RAISE EXCEPTION 'first name too long (max 40)'; END IF;
  IF i !~ '^[A-Za-z]$' THEN RAISE EXCEPTION 'last initial must be a single letter'; END IF;
  RETURN public.rp_customer_label_format(f, i, k);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_derive_sale_credits(p_sale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s RECORD; pr RECORD; v_ml_pts numeric; v_ref_pts numeric; v_anchor text;
  v_credited text[] := ARRAY[]::text[]; v_credits jsonb := '[]'::jsonb;
  v_rp numeric := 0; v_credit_id uuid; v_total numeric; v_veh integer; v_locked boolean;
BEGIN
  SELECT * INTO s FROM public.sales_log WHERE id = p_sale_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sale not found'; END IF;

  SELECT COALESCE(SUM(premium), 0), NULLIF(SUM(COALESCE(vehicle_count, 0)), 0)
    INTO v_total, v_veh
    FROM public.sales_log_products WHERE sales_log_id = p_sale_id;
  UPDATE public.sales_log SET total_premium = v_total, vehicle_count = v_veh, updated_at = now()
   WHERE id = p_sale_id
     AND (total_premium IS DISTINCT FROM v_total OR vehicle_count IS DISTINCT FROM v_veh);

  SELECT EXISTS (
    SELECT 1 FROM public.retention_activity_log l
     WHERE l.source = 'sales_log' AND l.source_id = p_sale_id
       AND l.activity_key IN ('multiline_sold', 'referral_sold')
       AND EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.chargeback_activity_id = l.id)
  ) INTO v_locked;

  IF v_locked OR COALESCE(s.entry_source, 'manual') <> 'manual' OR s.status <> 'active' THEN
    RETURN jsonb_build_object('ok', true, 'total_premium', v_total,
      'credits_locked', (v_locked OR COALESCE(s.entry_source,'manual') <> 'manual'),
      'retention_points', (SELECT COALESCE(SUM(points), 0) FROM public.retention_activity_log
        WHERE source = 'sales_log' AND source_id = p_sale_id AND activity_key IN ('multiline_sold','referral_sold')),
      'credits', '[]'::jsonb);
  END IF;

  UPDATE public.sales_log_products SET multiline_credit_id = NULL
   WHERE sales_log_id = p_sale_id AND multiline_credit_id IS NOT NULL;
  DELETE FROM public.retention_activity_log
   WHERE source = 'sales_log' AND source_id = p_sale_id
     AND activity_key IN ('multiline_sold', 'referral_sold');

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id = s.agency_id AND activity_key = 'multiline_sold'  AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id = s.agency_id AND activity_key = 'referral_sold' AND is_active;

  IF s.household_status IN ('new', 'winback') THEN
    SELECT p.line_of_business INTO v_anchor FROM public.sales_log_products p
     WHERE p.sales_log_id = p_sale_id AND COALESCE(p.is_new_line, true) AND NOT COALESCE(p.is_added_to_existing, false)
     ORDER BY p.premium DESC NULLS LAST, p.line_of_business LIMIT 1;
  END IF;

  FOR pr IN SELECT * FROM public.sales_log_products WHERE sales_log_id = p_sale_id ORDER BY created_at, id LOOP
    IF COALESCE(pr.is_new_line, true) AND NOT COALESCE(pr.is_added_to_existing, false) AND v_ml_pts IS NOT NULL
       AND NOT (pr.line_of_business = ANY (v_credited))
       AND (s.household_status = 'existing' OR pr.line_of_business IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_kind, phone_last4, ecrm_url, note, points, source, source_id, created_by)
      VALUES (s.agency_id, s.team_member_id, 'multiline_sold', s.submitted_date,
        public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
        s.customer_first_name, s.customer_last_initial, s.customer_kind, s.phone_last4, s.ecrm_opportunity_url,
        'From sale entry: ' || pr.line_of_business || ' added to household', v_ml_pts, 'sales_log', p_sale_id, s.created_by)
      RETURNING id INTO v_credit_id;
      UPDATE public.sales_log_products SET multiline_credit_id = v_credit_id WHERE id = pr.id;
      v_rp := v_rp + v_ml_pts;
      v_credited := v_credited || pr.line_of_business;
      v_credits := v_credits || jsonb_build_object('activity_key', 'multiline_sold', 'line', pr.line_of_business, 'points', v_ml_pts);
    END IF;
  END LOOP;

  IF s.marketing_source = 'referral' AND s.household_status IN ('new', 'winback') AND v_ref_pts IS NOT NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_kind, phone_last4, ecrm_url, note, points, source, source_id, created_by)
    VALUES (s.agency_id, s.team_member_id, 'referral_sold', s.submitted_date,
      public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
      s.customer_first_name, s.customer_last_initial, s.customer_kind, s.phone_last4, s.ecrm_opportunity_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', p_sale_id, s.created_by);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key', 'referral_sold', 'points', v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'total_premium', v_total, 'retention_points', v_rp, 'credits', v_credits);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_activity(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date; v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RAISE EXCEPTION 'that entry was removed. Log it again instead.'; END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — change the sale instead'; END IF;
  IF c ? 'activity_key' AND c->>'activity_key' IS DISTINCT FROM r.activity_key THEN
    RAISE EXCEPTION 'to change which activity it was, remove this one and log the right one';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'occurred_on','')::date, r.occurred_on);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name), COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind);
  END IF;
  UPDATE public.retention_activity_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    occurred_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    credited_week_end_date = CASE WHEN credited_week_end_date IS NULL THEN NULL ELSE public.rp_week_end(v_on) END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    policy_line  = CASE WHEN c ? 'policy_line'  THEN NULLIF(lower(btrim(COALESCE(c->>'policy_line',''))),'') ELSE policy_line END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    save_line    = CASE WHEN c ? 'save_line'   THEN NULLIF(lower(btrim(COALESCE(c->>'save_line',''))),'') ELSE save_line END,
    save_reason  = CASE WHEN c ? 'save_reason' THEN NULLIF(btrim(COALESCE(c->>'save_reason','')),'') ELSE save_reason END,
    review_platform = CASE WHEN c ? 'review_platform' THEN NULLIF(lower(btrim(COALESCE(c->>'review_platform',''))),'') ELSE review_platform END,
    updated_at = now()
  WHERE id = p_id;
  -- The link cannot be cleared off something that requires it.
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_ecrm AND l.ecrm_url IS NULL) THEN
    RAISE EXCEPTION 'this one needs the ECRM link, so it cannot be cleared';
  END IF;
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_platform AND l.review_platform IS NULL) THEN
    RAISE EXCEPTION 'this one needs the site the review was left on, so it cannot be cleared';
  END IF;
  -- Same for the note. It is required when the entry is logged, so an edit
  -- must not be able to empty it out afterwards (Peter 2026-09-20).
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_note
                AND l.note IS NULL AND l.save_reason IS NULL) THEN
    RAISE EXCEPTION 'this one needs a note on what you covered, so it cannot be cleared';
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_appointment(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_on date;
        v_lob text; v_type text; v_starts timestamptz; v_mins int; v_video boolean;
        v_where text; v_cal jsonb; v_kind text; v_who boolean;
        OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'set_on','')::date, r.set_on);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  v_lob  := CASE WHEN c ? 'line_of_business' THEN lower(btrim(COALESCE(c->>'line_of_business',''))) ELSE r.line_of_business END;
  v_type := CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'')
                 WHEN c ? 'line_of_business' THEN NULL ELSE r.product_type END;
  IF c ? 'line_of_business' OR c ? 'product_type' THEN
    IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
      RAISE EXCEPTION 'what product is the appointment about?';
    END IF;
    PERFORM public.rp_check_product_type(r.agency_id, v_lob, v_type);
  END IF;
  v_starts := CASE WHEN c ? 'starts_at' THEN NULLIF(c->>'starts_at','')::timestamptz ELSE r.starts_at END;
  IF c ? 'starts_at' AND v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;
  v_mins  := CASE WHEN c ? 'duration_minutes'
                  THEN GREATEST(15, LEAST(240, COALESCE(NULLIF(c->>'duration_minutes','')::int, 30)))
                  ELSE COALESCE(r.duration_minutes, 30) END;
  v_video := CASE WHEN c ? 'is_video' THEN COALESCE((c->>'is_video')::boolean, false) ELSE COALESCE(r.is_video, false) END;
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name), COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind);
  END IF;
  UPDATE public.appointment_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    escalated_to_team_member_id = CASE WHEN c ? 'escalated_to_team_member_id'
                                       THEN NULLIF(c->>'escalated_to_team_member_id','')::uuid
                                       ELSE escalated_to_team_member_id END,
    line_of_business = v_lob,
    product_type     = v_type,
    starts_at        = v_starts,
    duration_minutes = v_mins,
    is_video         = v_video,
    location         = v_where,
    set_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    updated_at = now()
  WHERE id = p_id;

  v_cal := public.rp_appointment_sync_calendar(p_id);
  RETURN jsonb_build_object('ok', true, 'id', p_id) || v_cal;
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_cancelation(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.cancelation_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that cancelation was removed. Log it again instead.'; END IF;
  IF (c ? 'canceled_on' AND NULLIF(c->>'canceled_on','')::date IS DISTINCT FROM r.canceled_on)
     OR (c ? 'policy_line' AND lower(c->>'policy_line') IS DISTINCT FROM r.policy_line) THEN
    RAISE EXCEPTION 'to change the cancelation date or the policy line, remove this one and log it again — the chargeback is worked out from both';
  END IF;
  IF c ? 'note' AND NULLIF(btrim(COALESCE(c->>'note','')), '') IS NULL AND r.entry_source = 'manual' THEN
    RAISE EXCEPTION 'a cancelation needs a note on why it canceled, so it cannot be cleared';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name), COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind);
  END IF;
  UPDATE public.cancelation_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    phone_last4  = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    vehicle_count= CASE WHEN c ? 'vehicle_count' THEN NULLIF(c->>'vehicle_count','')::integer ELSE vehicle_count END,
    reason       = CASE WHEN c ? 'reason' THEN NULLIF(btrim(COALESCE(c->>'reason','')),'') ELSE reason END,
    note         = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    updated_at   = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_quote(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date; prod jsonb; v_lob text;
        v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.quote_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that quote was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'quote_date','')::date, r.quote_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF c ? 'relationship_type' AND lower(COALESCE(c->>'relationship_type','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name), COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind);
  END IF;
  UPDATE public.quote_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    phone_last4           = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    quote_date            = v_on,
    week_end_date         = public.rp_week_end(v_on),
    relationship_type     = CASE WHEN c ? 'relationship_type' THEN lower(c->>'relationship_type') ELSE relationship_type END,
    marketing_source      = CASE WHEN c ? 'marketing_source' THEN c->>'marketing_source' ELSE marketing_source END,
    sourced_by_team_member_id = CASE WHEN c ? 'sourced_by_team_member_id' THEN NULLIF(c->>'sourced_by_team_member_id','')::uuid ELSE sourced_by_team_member_id END,
    ecrm_opportunity_url  = CASE WHEN c ? 'ecrm_opportunity_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_opportunity_url','')),'') ELSE ecrm_opportunity_url END,
    note                  = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    updated_at            = now()
  WHERE id = p_id;

  IF c ? 'products' THEN
    IF jsonb_typeof(c->'products') <> 'array' OR jsonb_array_length(c->'products') = 0 THEN
      RAISE EXCEPTION 'a quote needs at least one product';
    END IF;
    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      v_lob := lower(COALESCE(prod->>'line_of_business',''));
      IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
      PERFORM public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
    END LOOP;
    DELETE FROM public.quote_log_products WHERE quote_log_id = p_id;
    INSERT INTO public.quote_log_products (quote_log_id, agency_id, line_of_business, product_type)
    SELECT p_id, r.agency_id, lower(x->>'line_of_business'),
           public.rp_check_product_type(r.agency_id, lower(x->>'line_of_business'), x->>'product_type')
      FROM jsonb_array_elements(c->'products') x;
    UPDATE public.quote_log SET products_discussed = (
      SELECT array_agg(DISTINCT lower(x->>'line_of_business')) FROM jsonb_array_elements(c->'products') x
    ) WHERE id = p_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_sale(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
  v_today date := public.rp_today_central(); v_on date; prod jsonb; v_keep uuid[] := ARRAY[]::uuid[];
  v_pid uuid; v_lob text; v_type text; v_blocked text; v_was text; v_added boolean; v_new boolean;
  v_ecrm text; v_source text; v_label text; v_phone text; v_note text; v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.sales_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that sale was removed. Put it back first.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  v_was := COALESCE(r.entry_source, 'manual');

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'submitted_date','')::date, r.submitted_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;

  IF c ? 'household_status' AND lower(COALESCE(c->>'household_status','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'ecrm_opportunity_url' AND btrim(COALESCE(c->>'ecrm_opportunity_url','')) <> ''
     AND btrim(c->>'ecrm_opportunity_url') !~* '^https?://' THEN
    RAISE EXCEPTION 'the ECRM opportunity link must start with http';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  -- What the row will hold once these changes are applied.
  v_ecrm   := NULLIF(btrim(COALESCE(NULLIF(c->>'ecrm_opportunity_url',''), r.ecrm_opportunity_url, '')), '');
  v_source := NULLIF(COALESCE(NULLIF(c->>'marketing_source',''), r.marketing_source, ''), '');
  v_note   := NULLIF(btrim(COALESCE(NULLIF(btrim(COALESCE(c->>'note','')),''), r.note, '')), '');

  IF v_ecrm IS NULL THEN
    RAISE EXCEPTION '%', CASE WHEN v_was <> 'manual'
      THEN 'Moving this into the production log needs the ECRM opportunity link.'
      ELSE 'A sale needs the ECRM opportunity link.' END;
  END IF;
  IF v_source IS NULL THEN
    RAISE EXCEPTION 'Pick the marketing source.';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'A sale needs a note on what happened.';
  END IF;

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name), COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind);
  END IF;
  UPDATE public.sales_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    phone_last4           = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    submitted_date        = v_on,
    week_end_date         = public.rp_week_end(v_on),
    household_status      = CASE WHEN c ? 'household_status' THEN lower(c->>'household_status') ELSE household_status END,
    ecrm_opportunity_url  = v_ecrm,
    marketing_source      = v_source,
    note                  = v_note,
    entry_source          = 'manual',
    updated_at            = now()
  WHERE id = p_id;

  SELECT s.customer_label, s.phone_last4 INTO v_label, v_phone FROM public.sales_log s WHERE s.id = p_id;

  IF c ? 'products' THEN
    IF jsonb_typeof(c->'products') <> 'array' OR jsonb_array_length(c->'products') = 0 THEN
      RAISE EXCEPTION 'a sale needs at least one policy';
    END IF;
    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      PERFORM public.rp_check_sale_product(r.agency_id, prod);
      IF NULLIF(prod->>'id','') IS NOT NULL THEN v_keep := v_keep || (prod->>'id')::uuid; END IF;
    END LOOP;

    SELECT string_agg(DISTINCT p.line_of_business, ', ') INTO v_blocked
      FROM public.sales_log_products p
     WHERE p.sales_log_id = p_id AND NOT (p.id = ANY (v_keep))
       AND EXISTS (SELECT 1 FROM public.cancelation_log x WHERE x.matched_sale_product_id = p.id AND x.status = 'active');
    IF v_blocked IS NOT NULL THEN
      RAISE EXCEPTION 'the % policy has a cancelation logged against it. Remove the cancelation first.', v_blocked;
    END IF;

    UPDATE public.sales_log_products SET multiline_credit_id = NULL
     WHERE sales_log_id = p_id AND NOT (id = ANY (v_keep));
    DELETE FROM public.sales_log_products WHERE sales_log_id = p_id AND NOT (id = ANY (v_keep));

    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      v_lob   := lower(prod->>'line_of_business');
      v_type  := public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
      v_pid   := NULLIF(prod->>'id','')::uuid;
      -- ticked by the team, OR the household already has this same auto product on file
      v_added := (v_lob = 'auto' AND (
                    COALESCE((prod->>'added_to_existing')::boolean, false)
                    OR public.rp_auto_on_file(r.agency_id, v_label, v_phone, v_type, v_on, p_id)));
      v_new   := CASE WHEN v_added THEN false ELSE COALESCE((prod->>'is_new_line')::boolean, true) END;
      IF v_pid IS NULL THEN
        INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled)
        VALUES (p_id, r.agency_id, v_lob, v_type, NULLIF(prod->>'premium','')::numeric,
                GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
                CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
                v_new, v_added,
                NULLIF(prod->>'issued_date','')::date, NULLIF(prod->>'issued_premium','')::numeric,
                COALESCE((prod->>'autopay')::boolean, false));
      ELSE
        UPDATE public.sales_log_products SET
          line_of_business = v_lob, product_type = v_type,
          premium = NULLIF(prod->>'premium','')::numeric,
          policy_count = GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
          vehicle_count = CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
          is_added_to_existing = v_added,
          is_new_line = v_new,
          issued_date = CASE WHEN prod ? 'issued_date' THEN NULLIF(prod->>'issued_date','')::date ELSE issued_date END,
          issued_premium = CASE WHEN prod ? 'issued_premium' THEN NULLIF(prod->>'issued_premium','')::numeric ELSE issued_premium END,
          autopay_enrolled = CASE WHEN prod ? 'autopay' THEN COALESCE((prod->>'autopay')::boolean, false) ELSE autopay_enrolled END
        WHERE id = v_pid AND sales_log_id = p_id;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id,
                            'moved_from_historical', (v_was <> 'manual'),
                            'derived', public.rp_derive_sale_credits(p_id));
END $function$;

CREATE OR REPLACE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid, p_customer_kind text DEFAULT 'person'::text)
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
  v_kind text := public.rp_customer_kind(p_customer_kind);
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(p_team_member_id);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'check at least one thing you did';
  END IF;
  v_on := COALESCE(p_occurred_on, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log within 7 days of when it happened'; END IF;
  v_label := public.rp_customer_label(p_customer_first, p_customer_last_initial, v_kind);
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
    IF v.requires_ecrm AND v_url IS NULL THEN
      RAISE EXCEPTION '% needs the ECRM link so it can be checked', v.label;
    END IF;
    IF v.requires_platform AND NULLIF(btrim(COALESCE(item->>'review_platform','')), '') IS NULL THEN
      RAISE EXCEPTION '% needs the site it was left on: Google, Facebook or Yelp', v.label;
    END IF;
    IF NULLIF(btrim(COALESCE(item->>'review_platform','')), '') IS NOT NULL
       AND lower(btrim(item->>'review_platform')) NOT IN ('google', 'facebook', 'yelp') THEN
      RAISE EXCEPTION 'the review site has to be Google, Facebook or Yelp';
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
       customer_first_name, customer_last_initial, customer_kind, ecrm_url, note, save_reason, save_line, points, source, created_by, policy_line, product_type, premium, review_platform)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), public.rp_customer_initial(p_customer_last_initial, v_kind), v_kind, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id,
       NULLIF(lower(btrim(COALESCE(item->>'policy_line',''))), ''), NULLIF(btrim(COALESCE(item->>'product_type','')), ''), NULLIF(item->>'premium','')::numeric, NULLIF(lower(btrim(COALESCE(item->>'review_platform',''))), ''))
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_log_appointment(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_on date := COALESCE(NULLIF(p->>'set_on','')::date, public.rp_today_central());
  v_to uuid := NULLIF(p->>'escalated_to_team_member_id','')::uuid;
  v_first text := btrim(COALESCE(p->>'customer_first',''));
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
  v_init  text := public.rp_customer_initial(p->>'customer_last_initial', v_kind);
  v_lob  text := lower(btrim(COALESCE(p->>'line_of_business','')));
  v_type text := NULLIF(btrim(COALESCE(p->>'product_type','')),'');
  v_starts timestamptz := NULLIF(p->>'starts_at','')::timestamptz;
  v_mins int := GREATEST(15, LEAST(240, COALESCE(NULLIF(p->>'duration_minutes','')::int, 30)));
  v_video boolean := COALESCE((p->>'is_video')::boolean, false);
  v_label text; v_where text; v_cal jsonb; v_id uuid;
  OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_first = '' THEN RAISE EXCEPTION 'who is the appointment with'; END IF;
  IF regexp_replace(COALESCE(p->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
    RAISE EXCEPTION 'what product is the appointment about?';
  END IF;
  PERFORM public.rp_check_product_type(a.agency_id, v_lob, v_type);
  IF v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;

  v_label := public.rp_customer_label(v_first, v_init, v_kind);
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;

  INSERT INTO public.appointment_log (agency_id, team_member_id, escalated_to_team_member_id,
    customer_first_name, customer_last_initial, customer_kind, phone_last4,
    line_of_business, product_type, starts_at, duration_minutes, is_video, location,
    set_on, week_end_date, note, ecrm_url, created_by)
  VALUES (a.agency_id, a.team_member_id, v_to, v_first, v_init, v_kind,
    regexp_replace(p->>'phone_last4','\D','','g'), v_lob, v_type,
    v_starts, v_mins, v_video, v_where,
    v_on, public.rp_week_end(v_on),
    NULLIF(btrim(COALESCE(p->>'note','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_url','')),''),
    auth.uid())
  RETURNING id INTO v_id;

  v_cal := public.rp_appointment_sync_calendar(v_id);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'customer', v_label) || v_cal;
END $function$;

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
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id, v_pref, COALESCE((p->>'replacement')::boolean, false), v_ecrm, CASE WHEN v_backfill THEN 'historical_backfill' ELSE 'manual' END)
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

CREATE OR REPLACE FUNCTION public.rp_log_quote(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_label text; v_url text; v_id uuid;
  v_items jsonb := '[]'::jsonb; it jsonb; v_line text; v_type text;
  v_lines text[]; v_rel text; v_existing boolean; v_src text; v_sourced uuid;
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'quote_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial', v_kind);

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
  v_sourced := NULLIF(p->>'sourced_by_team_member_id','')::uuid;
  IF v_sourced IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_line := lower(btrim(COALESCE(it->>'line_of_business','')));
    IF v_line NOT IN ('auto','fire','life','health','variable','bank') THEN RAISE EXCEPTION 'unknown product: %', v_line; END IF;
    PERFORM public.rp_check_product_type(a.agency_id, v_line, it->>'product_type');
  END LOOP;
  SELECT array_agg(DISTINCT lower(x->>'line_of_business')) INTO v_lines FROM jsonb_array_elements(v_items) x;

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_kind,
    is_existing_customer, relationship_type, marketing_source, sourced_by_team_member_id,
    ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind,
    v_existing, v_rel, v_src, v_sourced, v_url, v_lines, NULLIF(btrim(COALESCE(p->>'note','')),''), a.actor_id)
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

CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text;
  v_sale_id uuid; prod jsonb; v_lob text; v_type text; v_prem numeric;
  v_cnt integer; v_new boolean; v_added boolean; v_veh integer; v_note text; v_derived jsonb;
  v_phone text;
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'submitted_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;
  IF v_on < v_today - 30 THEN RAISE EXCEPTION 'log a sale within 30 days of the bind'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial', v_kind);
  v_status := lower(COALESCE(p->>'household_status',''));
  IF v_status NOT IN ('new','existing','winback') THEN RAISE EXCEPTION 'pick the relationship type: new, existing, or winback'; END IF;
  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NULL OR v_url !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM opportunity link is required (must start with http)'; END IF;
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NULL OR NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  v_note := NULLIF(btrim(COALESCE(p->>'note','')),'');
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'a sale needs a note on what happened, so it can be checked later';
  END IF;

  IF jsonb_typeof(p->'products') <> 'array' OR jsonb_array_length(p->'products') = 0 THEN
    RAISE EXCEPTION 'add at least one policy with its premium';
  END IF;
  IF jsonb_array_length(p->'products') > 40 THEN RAISE EXCEPTION 'more than 40 policies in one sale. Double-check it.'; END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    PERFORM public.rp_check_sale_product(a.agency_id, prod);
  END LOOP;

  INSERT INTO public.sales_log (agency_id, team_member_id, submitted_date, week_end_date,
    customer_first_name, customer_last_initial, customer_kind, household_status, ecrm_opportunity_url,
    marketing_source, vehicle_count, total_premium, note, created_by, on_file_answer, replaced_sale_product_id)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_status, v_url,
    v_src, NULL, 0, v_note, a.actor_id, NULLIF(btrim(COALESCE(p->>'on_file_answer','')), ''), NULLIF(p->>'replaced_sale_product_id','')::uuid)
  RETURNING id INTO v_sale_id;

  SELECT phone_last4 INTO v_phone FROM public.sales_log WHERE id = v_sale_id;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob   := lower(prod->>'line_of_business');
    v_type  := public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem  := NULLIF(prod->>'premium','')::numeric;
    v_cnt   := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    -- ticked by the team, OR the household already has this same auto product on file
    v_added := (v_lob = 'auto' AND (
                  COALESCE((prod->>'added_to_existing')::boolean, false)
                  OR public.rp_auto_on_file(a.agency_id, v_label, v_phone, v_type, v_on, v_sale_id)));
    -- a vehicle added to a policy they already have is not a new line
    v_new   := CASE WHEN v_added THEN false ELSE COALESCE((prod->>'is_new_line')::boolean, true) END;
    v_veh   := CASE WHEN v_lob = 'auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, autopay_enrolled)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_added, NULLIF(prod->>'issued_date','')::date, COALESCE((prod->>'autopay')::boolean, false));
  END LOOP;

  v_derived := public.rp_derive_sale_credits(v_sale_id);

  RETURN jsonb_build_object('ok', true, 'sale_id', v_sale_id, 'customer', v_label,
                            'total_premium', v_derived->'total_premium',
                            'policies', jsonb_array_length(p->'products'),
                            'retention_points', v_derived->'retention_points',
                            'credits', v_derived->'credits');
END $function$;

CREATE OR REPLACE FUNCTION public.rp_sale_autopay_credit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor uuid := NULLIF(current_setting('rp.autopay_actor', true), '')::uuid;
  v_later boolean := (TG_OP = 'UPDATE');
  v_on    date;
BEGIN
  IF v_later AND COALESCE(OLD.autopay_enrolled, false) = COALESCE(NEW.autopay_enrolled, false) THEN
    RETURN NEW;
  END IF;

  IF NOT COALESCE(NEW.autopay_enrolled, false) THEN
    IF v_later THEN
      UPDATE public.retention_activity_log l
         SET status = 'voided', voided_at = now(), updated_at = now(),
             void_reason = 'Autopay unticked on the sold policy'
       WHERE l.activity_key = 'autopay_enrollment'
         AND l.status <> 'voided'
         AND l.source = 'sales_log'
         AND l.source_id = NEW.sales_log_id
         AND l.policy_line = NEW.line_of_business
         AND l.product_type IS NOT DISTINCT FROM NEW.product_type;
    END IF;
    RETURN NEW;
  END IF;

  SELECT CASE WHEN v_later THEN public.rp_today_central() ELSE s.submitted_date END
    INTO v_on
    FROM public.sales_log s WHERE s.id = NEW.sales_log_id;

  INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on,
      week_end_date, credited_week_end_date, customer_first_name, customer_last_initial, customer_kind,
      phone_last4, ecrm_url, note, points, source, source_id, created_by,
      policy_line, product_type, premium)
  SELECT s.agency_id,
         CASE WHEN v_later THEN COALESCE(v_actor, s.team_member_id) ELSE s.team_member_id END,
         'autopay_enrollment', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
         s.customer_first_name, s.customer_last_initial, s.customer_kind, s.phone_last4,
         s.ecrm_opportunity_url,
         CASE WHEN v_later THEN 'Autopay confirmed after the sale' ELSE 'From sale entry: policy set up on autopay' END,
         v.points, 'sales_log', s.id, s.created_by, NEW.line_of_business, NEW.product_type, NEW.premium
  FROM public.sales_log s
  JOIN public.retention_point_values v ON v.agency_id = s.agency_id AND v.activity_key = 'autopay_enrollment' AND v.is_active
  WHERE s.id = NEW.sales_log_id;

  RETURN NEW;
END $function$;

CREATE OR REPLACE VIEW public.retention_activity_now WITH (security_invoker=true) AS
 WITH x AS (
         SELECT l.id,
            l.agency_id,
            l.team_member_id,
            l.activity_key,
            l.occurred_on,
            l.week_end_date,
            l.credited_week_end_date,
            l.credit_available_on,
            l.customer_first_name,
            l.customer_last_initial,
            public.customer_label(l) AS customer_label,
            l.ecrm_url,
            l.note,
            l.save_reason,
            l.save_line,
            l.points,
            l.status,
            l.source,
            l.source_id,
            l.created_by,
            l.created_at,
            l.updated_at,
            l.voided_at,
            l.voided_by,
            l.void_reason,
            l.verified_at,
            l.verified_by,
            l.policy_line,
            l.product_type,
            l.premium,
            l.phone_last4,
            l.review_platform,
            l.spot_check_note,
            l.customer_kind,
            v.prior_step_pct,
            v.prior_cap,
            count(*) FILTER (WHERE (l.status <> ALL (ARRAY['void'::text, 'voided'::text])) AND l.points > 0::numeric) OVER (PARTITION BY l.agency_id, l.team_member_id, l.activity_key, (floor((l.occurred_on - COALESCE(a.d, '2026-04-05'::date))::numeric / 91.0)) ORDER BY l.occurred_on, l.created_at, l.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior
           FROM retention_activity_log l
             LEFT JOIN retention_point_values v ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
             LEFT JOIN LATERAL ( SELECT s.setting_value::date AS d
                   FROM settings s
                  WHERE s.agency_id = l.agency_id AND s.setting_key = 'cycle_anchor_date'::text) a ON true
        )
 SELECT id,
    agency_id,
    team_member_id,
    activity_key,
    occurred_on,
    week_end_date,
    credited_week_end_date,
    credit_available_on,
    customer_first_name,
    customer_last_initial,
    customer_label,
    ecrm_url,
    note,
    save_reason,
    save_line,
        CASE
            WHEN points > 0::numeric AND COALESCE(prior_step_pct, 0::numeric) > 0::numeric AND COALESCE(prior_cap, 0) > 0 THEN round(points * (1::numeric + prior_step_pct / 100.0 * LEAST(prior_cap::bigint, COALESCE(prior, 0::bigint))::numeric), 2)
            ELSE points
        END AS points,
    status,
    source,
    source_id,
    created_by,
    created_at,
    updated_at,
    voided_at,
    voided_by,
    void_reason,
    verified_at,
    verified_by,
    policy_line,
    product_type,
    premium,
    phone_last4,
    review_platform,
    spot_check_note,
    customer_kind,
    points AS base_points
   FROM x;

CREATE OR REPLACE VIEW public.rp_saves_clearing_soon AS
 SELECT l.id,
    l.agency_id,
    l.team_member_id,
    t.first_name,
    public.customer_label(l) AS customer_label,
    l.save_line,
    l.save_reason,
    l.occurred_on,
    l.credit_available_on,
    l.credited_week_end_date,
    l.points,
    l.credit_available_on - rp_today_central() AS days_until_clear
   FROM retention_activity_log l
     LEFT JOIN team_directory t ON t.id = l.team_member_id
  WHERE l.activity_key = 'cancelation_saved'::text AND l.status = 'credited'::text AND l.verified_at IS NULL AND l.credit_available_on IS NOT NULL AND l.credit_available_on >= rp_today_central();

ALTER TABLE public.sales_log DROP COLUMN customer_label;
ALTER TABLE public.quote_log DROP COLUMN customer_label;
ALTER TABLE public.cancelation_log DROP COLUMN customer_label;
ALTER TABLE public.retention_activity_log DROP COLUMN customer_label;
ALTER TABLE public.appointment_log DROP COLUMN customer_label;

NOTIFY pgrst, 'reload schema';
