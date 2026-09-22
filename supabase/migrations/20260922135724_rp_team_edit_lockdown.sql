-- Peter 2026-09-22: team edit lockdown on Production records.
-- Once saved, a team member can change or delete an entry only until midnight
-- Central on the day they entered it. Exceptions: the submitted side of a sale
-- while a policy on it is not yet issued; marking a policy issued (changeable
-- the same day it was marked); the appointment host marking kept, no show or
-- sold; adding a note to their own records. Owner and managers keep full rights.

ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS issued_marked_at timestamptz;
ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS issued_marked_by uuid;

-- Who is signed in, as a team member. NULL for the system or an owner with no team row.
CREATE OR REPLACE FUNCTION public.rp_my_team_id()
 RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT t.id FROM public.team t JOIN public.users u ON u.id = t.user_id
   WHERE u.auth_user_id = auth.uid() AND t.archived_at IS NULL LIMIT 1;
$function$;

-- True when a moment falls on today's date in Central time. NULL is never today.
CREATE OR REPLACE FUNCTION public.rp_entered_today(p_at timestamptz)
 RETURNS boolean LANGUAGE sql STABLE
AS $function$
  SELECT p_at IS NOT NULL AND (p_at AT TIME ZONE 'America/Chicago')::date = public.rp_today_central();
$function$;

-- Full change or delete: owner/manager, or the person who entered it, on the day they entered it.
CREATE OR REPLACE FUNCTION public.rp_entry_can_change(p_owner uuid, p_created_at timestamptz)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_agency_admin()
      OR (p_owner IS NOT NULL AND p_owner = public.rp_my_team_id() AND public.rp_entered_today(p_created_at));
$function$;

-- Can open the sale to edit at all: full rights, or it is theirs and a policy on it is not yet issued.
CREATE OR REPLACE FUNCTION public.rp_sale_can_edit(p_owner uuid, p_created_at timestamptz, p_sale_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.rp_entry_can_change(p_owner, p_created_at)
      OR (p_owner IS NOT NULL AND p_owner = public.rp_my_team_id()
          AND EXISTS (SELECT 1 FROM public.sales_log_products p WHERE p.sales_log_id = p_sale_id AND p.issued_date IS NULL));
$function$;

-- An issued policy can be changed or put back only the day it was marked, unless owner/manager.
CREATE OR REPLACE FUNCTION public.rp_issue_can_change(p_marked_at timestamptz)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_agency_admin() OR public.rp_entered_today(p_marked_at);
$function$;

-- The host (whoever it was handed to, else the setter) marks an appointment kept, no show or sold.
CREATE OR REPLACE FUNCTION public.rp_appt_can_mark(p_host uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_agency_admin() OR (p_host IS NOT NULL AND p_host = public.rp_my_team_id());
$function$;

-- Autopay: the seller can turn it on any time (customers sign up after the sale).
-- Taking it off follows the same-day rule.
CREATE OR REPLACE FUNCTION public.rp_autopay_can_change(p_owner uuid, p_created_at timestamptz, p_on_now boolean)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.rp_entry_can_change(p_owner, p_created_at)
      OR (NOT COALESCE(p_on_now, false) AND p_owner IS NOT NULL AND p_owner = public.rp_my_team_id());
$function$;

-- Read-only fields the screens select next to the row, so the buttons shown match the server.
CREATE OR REPLACE FUNCTION public.rp_sale_can_change(r public.sales_log)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_entry_can_change(r.team_member_id, r.created_at); $function$;
CREATE OR REPLACE FUNCTION public.rp_sale_edit_ok(r public.sales_log)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_sale_can_edit(r.team_member_id, r.created_at, r.id); $function$;
CREATE OR REPLACE FUNCTION public.rp_appt_can_change(r public.appointment_log)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_entry_can_change(r.team_member_id, r.created_at); $function$;
CREATE OR REPLACE FUNCTION public.rp_appt_mark_ok(r public.appointment_log)
 RETURNS boolean LANGUAGE sql STABLE AS $function$
  SELECT public.rp_appt_can_mark(COALESCE(NULLIF(r.escalated_to_team_member_id, r.team_member_id), r.team_member_id)); $function$;
CREATE OR REPLACE FUNCTION public.rp_act_can_change(r public.retention_activity_now)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_entry_can_change(r.team_member_id, r.created_at); $function$;
CREATE OR REPLACE FUNCTION public.rp_issue_change_ok(p public.sales_log_products)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_issue_can_change(p.issued_marked_at); $function$;
CREATE OR REPLACE FUNCTION public.rp_autopay_ok(p public.sales_log_products)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $function$
  SELECT public.rp_autopay_can_change(s.team_member_id, s.created_at, p.autopay_enrolled)
    FROM public.sales_log s WHERE s.id = p.sales_log_id; $function$;

-- Stamp when a policy was marked issued, and by whom. Runs after rp_auto_issue.
CREATE OR REPLACE FUNCTION public.rp_stamp_issued()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.issued_date IS NOT NULL THEN
      NEW.issued_marked_at := now(); NEW.issued_marked_by := public.rp_my_team_id();
    END IF;
  ELSIF NEW.issued_date IS DISTINCT FROM OLD.issued_date OR NEW.issued_premium IS DISTINCT FROM OLD.issued_premium THEN
    IF NEW.issued_date IS NULL THEN
      NEW.issued_marked_at := NULL; NEW.issued_marked_by := NULL;
    ELSIF auth.uid() IS NOT NULL THEN
      -- A person marked or changed it. System upkeep keeps the old stamp.
      NEW.issued_marked_at := now(); NEW.issued_marked_by := public.rp_my_team_id();
    END IF;
  END IF;
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS trg_rp_zz_issued_stamp ON public.sales_log_products;
CREATE TRIGGER trg_rp_zz_issued_stamp BEFORE INSERT OR UPDATE ON public.sales_log_products
  FOR EACH ROW EXECUTE FUNCTION public.rp_stamp_issued();

-- The one guard every edit, delete and restore path calls. Signature unchanged;
-- p_week_end is no longer used.
CREATE OR REPLACE FUNCTION public.rp_guard_change(p_row_team_member_id uuid, p_week_end date, p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(actor_id uuid, team_member_id uuid, agency_id uuid, is_admin boolean)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT public.rp_entry_can_change(p_row_team_member_id, p_created_at) THEN
    IF p_row_team_member_id IS DISTINCT FROM a.actor_id THEN
      RAISE EXCEPTION 'you can only change your own entries' USING ERRCODE='42501';
    END IF;
    RAISE EXCEPTION 'An entry can be changed only on the day it was entered. Add a note instead, or ask a manager.' USING ERRCODE='42501';
  END IF;
  RETURN QUERY SELECT a.actor_id, a.team_member_id, a.agency_id, a.is_admin;
END $function$;

-- Notes: add one to your own record. Earlier notes stay as written.
CREATE OR REPLACE FUNCTION public.rp_add_note(p_kind text, p_id uuid, p_note text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_kind text := lower(btrim(COALESCE(p_kind, ''))); v_text text := btrim(COALESCE(p_note, ''));
        v_owner uuid; v_host uuid; v_agency uuid; v_old text; v_name text; v_new text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF v_text = '' THEN RAISE EXCEPTION 'Write the note first.'; END IF;
  IF length(v_text) > 2000 THEN RAISE EXCEPTION 'That note is too long. Keep it under 2,000 characters.'; END IF;
  IF v_kind = 'sale' THEN
    SELECT x.team_member_id, x.agency_id, x.note INTO v_owner, v_agency, v_old FROM public.sales_log x WHERE x.id = p_id AND x.status = 'active';
  ELSIF v_kind = 'quote' THEN
    SELECT x.team_member_id, x.agency_id, x.note INTO v_owner, v_agency, v_old FROM public.quote_log x WHERE x.id = p_id AND x.status = 'active';
  ELSIF v_kind = 'cancelation' THEN
    SELECT x.team_member_id, x.agency_id, x.note INTO v_owner, v_agency, v_old FROM public.cancelation_log x WHERE x.id = p_id AND x.status = 'active';
  ELSIF v_kind = 'activity' THEN
    SELECT x.team_member_id, x.agency_id, x.note INTO v_owner, v_agency, v_old FROM public.retention_activity_log x WHERE x.id = p_id AND x.status <> 'void';
  ELSIF v_kind = 'appointment' THEN
    SELECT x.team_member_id, x.agency_id, x.note, x.escalated_to_team_member_id INTO v_owner, v_agency, v_old, v_host
      FROM public.appointment_log x WHERE x.id = p_id AND x.status = 'active';
  ELSIF v_kind = 'scorecard' THEN
    SELECT x.team_member_id, x.agency_id, x.notes INTO v_owner, v_agency, v_old FROM public.fit_scorecards x WHERE x.id = p_id;
  ELSE
    RAISE EXCEPTION 'cannot add a note to a record of kind %', p_kind;
  END IF;
  IF v_agency IS NULL OR v_agency <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  IF NOT a.is_admin AND a.actor_id IS DISTINCT FROM v_owner AND a.actor_id IS DISTINCT FROM v_host THEN
    RAISE EXCEPTION 'You can add notes only to your own entries.' USING ERRCODE='42501';
  END IF;
  SELECT COALESCE(t.nickname, t.first_name) INTO v_name FROM public.team t WHERE t.id = a.actor_id;
  v_text := to_char(public.rp_today_central(), 'FMMM/FMDD') || ' ' || COALESCE(v_name, 'Manager') || ': ' || v_text;
  v_new := CASE WHEN NULLIF(btrim(COALESCE(v_old, '')), '') IS NULL THEN v_text ELSE rtrim(v_old) || E'\n' || v_text END;

  PERFORM set_config('rp.note_append', '1', true);
  IF v_kind = 'sale' THEN UPDATE public.sales_log SET note = v_new, updated_at = now() WHERE id = p_id;
  ELSIF v_kind = 'quote' THEN UPDATE public.quote_log SET note = v_new, updated_at = now() WHERE id = p_id;
  ELSIF v_kind = 'cancelation' THEN UPDATE public.cancelation_log SET note = v_new, updated_at = now() WHERE id = p_id;
  ELSIF v_kind = 'activity' THEN UPDATE public.retention_activity_log SET note = v_new, updated_at = now() WHERE id = p_id;
  ELSIF v_kind = 'appointment' THEN UPDATE public.appointment_log SET note = v_new, updated_at = now() WHERE id = p_id;
  ELSE UPDATE public.fit_scorecards SET notes = v_new, updated_at = now() WHERE id = p_id;
  END IF;
  PERFORM set_config('rp.note_append', '', true);
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'note', v_new);
END $function$;

-- Adding a note does not undo a manager's verification.
CREATE OR REPLACE FUNCTION public.rp_unverify_on_change()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE skip text[] := ARRAY['verified_at', 'verified_by', 'updated_at', 'spot_check_note'];
BEGIN
  IF NEW.verified_at IS NULL THEN RETURN NEW; END IF;
  IF public.is_agency_admin() THEN RETURN NEW; END IF;
  IF COALESCE(current_setting('rp.note_append', true), '') = '1' THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - skip) IS DISTINCT FROM (to_jsonb(OLD) - skip) THEN
    NEW.verified_at := NULL;
    NEW.verified_by := NULL;
  END IF;
  RETURN NEW;
END $function$;

-- Marking issued: anyone can. Once marked, only the same day it was marked.
CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_prem numeric; v_raw text; v_n integer := 0;
  v_today date := public.rp_today_central(); v_synced integer := 0; v_k integer;
  v_given date; v_existing date; v_existing_prem numeric; v_marked_at timestamptz;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy to mark issued';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := NULLIF(it->>'sale_product_id','')::uuid;
    v_given := NULLIF(btrim(COALESCE(it->>'issued_date','')), '')::date;
    -- "$1,527.10" is a premium. Drop the formatting, keep the number.
    v_raw := NULLIF(regexp_replace(COALESCE(it->>'issued_premium',''), '[^0-9.\-]', '', 'g'), '');
    IF v_raw IS NOT NULL AND v_raw !~ '^-?[0-9]*\.?[0-9]+$' THEN
      RAISE EXCEPTION 'the issued premium has to be a number';
    END IF;

    SELECT s.submitted_date, p.issued_date, p.issued_premium, p.issued_marked_at
      INTO v_sub, v_existing, v_existing_prem, v_marked_at
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;
    IF v_existing IS NOT NULL AND NOT public.rp_issue_can_change(v_marked_at) THEN
      RAISE EXCEPTION 'That policy was already marked issued (%). It can be changed only on the day it was marked. Ask a manager.', to_char(v_existing, 'FMMM/FMDD/YYYY') USING ERRCODE='42501';
    END IF;

    v_prem := COALESCE(v_raw::numeric, CASE WHEN v_existing IS NOT NULL THEN v_existing_prem END);
    IF v_prem IS NULL AND v_existing IS NULL THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem IS NOT NULL AND v_prem < 0 THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'the issued premium looks too large. Double-check it.'; END IF;

    IF v_given IS NOT NULL THEN
      -- A date was typed, so it gets checked.
      IF v_given > v_today THEN RAISE EXCEPTION 'the issue date cannot be in the future'; END IF;
      IF v_given < v_sub THEN RAISE EXCEPTION 'a policy cannot issue before it was submitted (submitted %)', v_sub; END IF;
      v_on := v_given;
    ELSE
      -- No date given: keep the one on the record, except that a date earlier
      -- than the submit date is impossible, so it moves up to it. No date at
      -- all means the policy issued when it was submitted.
      v_on := GREATEST(COALESCE(v_existing, v_sub), v_sub);
    END IF;

    UPDATE public.sales_log_products SET issued_date = v_on, issued_premium = v_prem WHERE id = v_id;
    v_n := v_n + 1;

    -- A live cancelation on this policy recorded the premium as it stood then.
    -- Changing the premium changes what was lost, so the cancelation follows.
    IF v_prem IS NOT NULL THEN
      UPDATE public.cancelation_log c
         SET premium = v_prem, updated_at = now()
       WHERE c.matched_sale_product_id = v_id
         AND c.status = 'active'
         AND c.premium IS DISTINCT FROM v_prem;
      GET DIAGNOSTICS v_k = ROW_COUNT; v_synced := v_synced + v_k;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n, 'cancelations_repriced', v_synced);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_unmark_issued(p_sale_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_n integer; v_on date; v_marked_at timestamptz;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT p.issued_date, p.issued_marked_at INTO v_on, v_marked_at
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE p.id = p_sale_product_id AND s.agency_id = a.agency_id AND s.status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'that policy was not found'; END IF;
  IF v_on IS NOT NULL AND NOT public.rp_issue_can_change(v_marked_at) THEN
    RAISE EXCEPTION 'That policy was marked issued on an earlier day. It can be changed only on the day it was marked. Ask a manager.' USING ERRCODE='42501';
  END IF;
  UPDATE public.sales_log_products SET issued_date = NULL, issued_premium = NULL WHERE id = p_sale_product_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_n > 0);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_set_sale_autopay(p_sale_product_id uuid, p_on boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_phone text; v_n integer; v_owner uuid; v_created timestamptz; v_cur boolean;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT s.phone_last4, s.team_member_id, s.created_at, COALESCE(p.autopay_enrolled, false)
    INTO v_phone, v_owner, v_created, v_cur
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE p.id = p_sale_product_id AND s.agency_id = a.agency_id AND s.status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'that policy was not found'; END IF;
  IF v_cur IS DISTINCT FROM COALESCE(p_on, false) AND NOT public.rp_autopay_can_change(v_owner, v_created, v_cur) THEN
    IF v_owner IS DISTINCT FROM a.actor_id THEN
      RAISE EXCEPTION 'you can only change autopay on your own sales' USING ERRCODE='42501';
    END IF;
    RAISE EXCEPTION 'Autopay can be taken off only on the day the sale was entered. Ask a manager.' USING ERRCODE='42501';
  END IF;

  PERFORM set_config('rp.autopay_actor', COALESCE(a.team_member_id::text, ''), true);
  PERFORM set_config('rp.phone_last4', COALESCE(v_phone, ''), true);

  UPDATE public.sales_log_products p SET autopay_enrolled = COALESCE(p_on, false)
    FROM public.sales_log s
   WHERE p.id = p_sale_product_id AND s.id = p.sales_log_id AND s.agency_id = a.agency_id
     AND s.status = 'active' AND COALESCE(p.autopay_enrolled, false) <> COALESCE(p_on, false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'changed', v_n > 0, 'autopay', COALESCE(p_on, false));
END $function$;
-- Patch the functions that carry the rule, in place, so nothing else in them moves.
DO $patch$
DECLARE d text; n text;
BEGIN
  -- rp_edit_sale: after the entry day, the person who entered it may still fix the
  -- submitted side of policies not yet issued. Issued policies, notes, and (once any
  -- policy has issued) the shared sale details stay as they are.
  d := pg_get_functiondef('public.rp_edit_sale(uuid,jsonb)'::regprocedure);
  n := replace(d, $q$v_kind text; v_who boolean;$q$, $q$v_kind text; v_who boolean; v_limited boolean := false; v_any_issued boolean;$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_edit_sale patch 1 missed'; END IF; d := n;
  n := replace(d, $q$  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id$q$, $q$  BEGIN
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  EXCEPTION WHEN insufficient_privilege THEN
    -- Peter 2026-09-22: the submitted side stays open until the policy is marked issued.
    IF NOT public.rp_sale_can_edit(r.team_member_id, r.created_at, r.id) THEN RAISE; END IF;
    SELECT * INTO a FROM public.rp_resolve_actor(NULL);
    v_limited := true;
  END;
  IF r.agency_id$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_edit_sale patch 2 missed'; END IF; d := n;
  n := replace(d, $q$  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name)$q$, $q$  IF v_limited THEN
    IF COALESCE(r.entry_source, 'manual') <> 'manual' THEN
      RAISE EXCEPTION 'This sale came from the historical load. Ask a manager to change it.' USING ERRCODE='42501';
    END IF;
    IF v_note IS DISTINCT FROM NULLIF(btrim(COALESCE(r.note, '')), '') THEN
      RAISE EXCEPTION 'A note cannot be changed after the day it was written. Use Add note instead.' USING ERRCODE='42501';
    END IF;
    v_any_issued := EXISTS (SELECT 1 FROM public.sales_log_products p WHERE p.sales_log_id = p_id AND p.issued_date IS NOT NULL);
    IF v_any_issued AND (
         v_kind IS DISTINCT FROM r.customer_kind
      OR (c ? 'customer_first' AND btrim(c->>'customer_first') IS DISTINCT FROM r.customer_first_name)
      OR (v_who AND public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind) IS DISTINCT FROM r.customer_last_initial)
      OR (c ? 'phone_last4' AND regexp_replace(c->>'phone_last4', '\D', '', 'g') IS DISTINCT FROM r.phone_last4)
      OR v_on IS DISTINCT FROM r.submitted_date
      OR (c ? 'household_status' AND lower(c->>'household_status') IS DISTINCT FROM r.household_status)
      OR v_ecrm IS DISTINCT FROM r.ecrm_opportunity_url
      OR v_source IS DISTINCT FROM r.marketing_source) THEN
      RAISE EXCEPTION 'A policy on this sale is marked issued, so the customer and sale details are locked. You can still fix the policies that have not issued. Ask a manager for the rest.' USING ERRCODE='42501';
    END IF;
    IF c ? 'products' AND jsonb_typeof(c->'products') = 'array' THEN
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(c->'products') e WHERE NULLIF(e->>'id', '') IS NULL) THEN
        RAISE EXCEPTION 'A policy can be added only on the day the sale was entered. Log it as a new sale, or ask a manager.' USING ERRCODE='42501';
      END IF;
      SELECT string_agg(DISTINCT p.line_of_business, ', ') INTO v_blocked
        FROM public.sales_log_products p
       WHERE p.sales_log_id = p_id AND p.issued_date IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(c->'products') e
            WHERE (e->>'id')::uuid = p.id
              AND lower(COALESCE(e->>'line_of_business', p.line_of_business)) IS NOT DISTINCT FROM p.line_of_business
              AND (NOT e ? 'product_type' OR NULLIF(e->>'product_type', '') IS NOT DISTINCT FROM p.product_type)
              AND (NOT e ? 'premium' OR NULLIF(e->>'premium', '')::numeric IS NOT DISTINCT FROM p.premium)
              AND (NOT e ? 'policy_count' OR GREATEST(1, COALESCE(NULLIF(e->>'policy_count', '')::integer, 1)) IS NOT DISTINCT FROM p.policy_count)
              AND (NOT e ? 'vehicle_count' OR p.line_of_business <> 'auto' OR NULLIF(e->>'vehicle_count', '')::integer IS NOT DISTINCT FROM p.vehicle_count)
              AND (NOT e ? 'issued_date' OR NULLIF(e->>'issued_date', '')::date IS NOT DISTINCT FROM p.issued_date)
              AND (NOT e ? 'issued_premium' OR NULLIF(e->>'issued_premium', '')::numeric IS NOT DISTINCT FROM p.issued_premium)
              AND (NOT e ? 'autopay' OR COALESCE((e->>'autopay')::boolean, false) IS NOT DISTINCT FROM COALESCE(p.autopay_enrolled, false)));
      IF v_blocked IS NOT NULL THEN
        RAISE EXCEPTION 'The % policy is marked issued, so it cannot be changed or removed here. Ask a manager.', v_blocked USING ERRCODE='42501';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(c->'products') e
                   JOIN public.sales_log_products p ON p.id = (e->>'id')::uuid AND p.sales_log_id = p_id
                  WHERE p.issued_date IS NULL
                    AND (NULLIF(e->>'issued_date', '') IS NOT NULL OR NULLIF(e->>'issued_premium', '') IS NOT NULL)) THEN
        RAISE EXCEPTION 'Use the Issue button to mark a policy issued.' USING ERRCODE='42501';
      END IF;
    END IF;
  END IF;

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name)$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_edit_sale patch 3 missed'; END IF; d := n;
  n := replace(d, $q$        WHERE id = v_pid AND sales_log_id = p_id;$q$, $q$        WHERE id = v_pid AND sales_log_id = p_id AND (NOT v_limited OR issued_date IS NULL);$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_edit_sale patch 4 missed'; END IF; d := n;
  EXECUTE d;

  -- rp_set_appointment_state: the host marks it, any day. Owner and managers too.
  d := pg_get_functiondef('public.rp_set_appointment_state(uuid,text,date)'::regprocedure);
  n := regexp_replace(d, '  BEGIN\n    SELECT \* INTO a FROM public\.rp_guard_change\(v_host.*?\n  END;\n',
    E'  SELECT * INTO a FROM public.rp_resolve_actor(NULL);\n  IF NOT public.rp_appt_can_mark(v_host) THEN\n    RAISE EXCEPTION ''only the person the appointment was handed to can mark it'' USING ERRCODE=''42501'';\n  END IF;\n');
  IF n = d THEN RAISE EXCEPTION 'rp_set_appointment_state patch missed'; END IF;
  EXECUTE n;

  -- rp_attach_entry_to_appointment: tying a sale or quote to an appointment changes
  -- that record, so it follows the same rule as any other change.
  d := pg_get_functiondef('public.rp_attach_entry_to_appointment(uuid,uuid,uuid)'::regprocedure);
  n := replace(d, $q$  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
$q$, $q$  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  IF p_sale_id IS NOT NULL THEN
    PERFORM public.rp_guard_change(x.team_member_id, NULL::date, x.created_at) FROM public.sales_log x WHERE x.id = p_sale_id;
  END IF;
  IF p_quote_id IS NOT NULL THEN
    PERFORM public.rp_guard_change(x.team_member_id, NULL::date, x.created_at) FROM public.quote_log x WHERE x.id = p_quote_id;
  END IF;
$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_attach_entry_to_appointment patch missed'; END IF;
  EXECUTE n;

  -- The lists: can_change comes from the one rule.
  d := pg_get_functiondef('public.rp_recent_entries(integer,uuid,integer,text,date,date,text)'::regprocedure);
  n := replace(d, $q$(a.is_admin OR (r.team_member_id = a.actor_id AND (r.week_end_date >= v_week OR r.created_at >= v_today))) AS can_change$q$,
                  $q$public.rp_entry_can_change(r.team_member_id, r.created_at) AS can_change$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_recent_entries patch missed'; END IF;
  EXECUTE n;

  d := pg_get_functiondef('public.rp_customer_account(text,text)'::regprocedure);
  n := regexp_replace(d, '\(a\.is_admin OR \(e\.team_member_id = a\.actor_id\s+AND \(e\.week_end_date >= v_week OR e\.created_at >= v_today\)\)\) AS can_change',
                         'public.rp_entry_can_change(e.team_member_id, e.created_at) AS can_change');
  IF n = d THEN RAISE EXCEPTION 'rp_customer_account patch missed'; END IF;
  EXECUTE n;

  d := pg_get_functiondef('public.rp_entry_for_edit(text,uuid)'::regprocedure);
  n := regexp_replace(d, '\(a\.is_admin OR \(\(v_out->>''team_member_id''\)::uuid = a\.actor_id\s+AND \(\(v_out->>''week_end_date''\)::date >= v_week\s+OR \(v_out->>''created_at''\)::timestamptz >= v_today\)\)\)',
                         'public.rp_entry_can_change((v_out->>''team_member_id'')::uuid, (v_out->>''created_at'')::timestamptz)');
  IF n = d THEN RAISE EXCEPTION 'rp_entry_for_edit patch missed'; END IF;
  EXECUTE n;
END $patch$;
