-- Chargebacks (Peter 2026-09-04): a canceled policy is matched to the sale
-- that wrote it (same customer, same line, most recent active sale, same
-- type preferred). If the cancelation lands inside the window — 6 months
-- for auto, 12 months for everything else — the Multiline credit that sale
-- earned on that line comes back, prorated to the part of the window that
-- was left. Credit still unpaid (its week has not closed) is voided outright;
-- credit already paid gets a negative row in the current week, so the next
-- pay run nets it. Undo of the cancelation reverses either one.
--
-- Referral Sold is a household credit, not a line credit, so it is not
-- touched by a single line canceling.

ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS matched_sale_product_id uuid REFERENCES public.sales_log_products(id);
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS chargeback_activity_id uuid REFERENCES public.retention_activity_log(id);
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS chargeback_points numeric;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS window_fraction_left numeric;
COMMENT ON COLUMN public.cancelation_log.matched_sale_product_id IS 'The sold policy this cancelation was matched to (same customer + line, most recent, inside the chargeback window).';
COMMENT ON COLUMN public.cancelation_log.chargeback_points IS 'Points taken back from the Multiline credit on the matched sale, prorated. Positive number; the activity row carries it as negative.';

ALTER TABLE public.retention_activity_log DROP CONSTRAINT IF EXISTS retention_activity_log_source_check;
ALTER TABLE public.retention_activity_log ADD CONSTRAINT retention_activity_log_source_check
  CHECK (source = ANY (ARRAY['manual'::text, 'sales_log'::text, 'system'::text, 'cancelation_log'::text]));

INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, is_active, description)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'multiline_chargeback', 'Multiline Chargeback', 0.00, 'derived', false, 95, true,
        'A line that earned a Multiline credit canceled inside its window (6 months auto, 12 months everything else). The credit comes back, prorated to the part of the window that was left. Never logged by hand.')
ON CONFLICT (agency_id, activity_key) DO UPDATE SET label = EXCLUDED.label, category = EXCLUDED.category, description = EXCLUDED.description, is_active = true, updated_at = now();

CREATE OR REPLACE FUNCTION public.rp_chargeback_window_months(p_line text)
 RETURNS integer LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN lower(p_line) = 'auto' THEN 6 ELSE 12 END $$;

-- Runs after the cancelation row exists (AFTER INSERT), so the row can carry
-- the match and the chargeback it produced.
CREATE OR REPLACE FUNCTION public.cancelation_log_chargeback()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  sp RECORD; cr RECORD; v_window_end date; v_left numeric; v_pts numeric; v_id uuid;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
BEGIN
  -- most recent active sale of this line for this customer, same type first
  SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.sale_date, s.id AS sale_id, s.customer_label
    INTO sp
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE s.agency_id = NEW.agency_id AND s.status = 'active'
     AND s.customer_label = NEW.customer_label AND p.line_of_business = NEW.policy_line
     AND s.sale_date <= NEW.canceled_on
     AND s.sale_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on
     AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active' AND c.id <> NEW.id)
   ORDER BY (p.product_type IS NOT DISTINCT FROM NEW.product_type) DESC, s.sale_date DESC
   LIMIT 1;
  IF NOT FOUND THEN RETURN NEW; END IF;

  v_window_end := (sp.sale_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval)::date;
  v_left := round((v_window_end - NEW.canceled_on)::numeric / NULLIF((v_window_end - sp.sale_date)::numeric, 0), 4);
  v_left := LEAST(1, GREATEST(0, COALESCE(v_left, 0)));

  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;

  IF sp.multiline_credit_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO cr FROM public.retention_activity_log WHERE id = sp.multiline_credit_id AND status = 'credited';
  IF NOT FOUND THEN RETURN NEW; END IF;

  v_pts := round(cr.points * v_left, 2);
  IF v_pts <= 0 THEN RETURN NEW; END IF;

  IF cr.credited_week_end_date >= v_cur_week THEN
    -- not paid yet: take the credit itself back
    UPDATE public.retention_activity_log
       SET status = 'void', voided_at = now(), voided_by = NEW.created_by,
           void_reason = 'policy canceled ' || NEW.canceled_on::text || ' inside the chargeback window', updated_at = now()
     WHERE id = cr.id;
    UPDATE public.cancelation_log SET chargeback_points = cr.points, chargeback_activity_id = cr.id WHERE id = NEW.id;
  ELSE
    -- already paid: a negative row this week nets it on the next pay run
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, note, points, source, source_id, created_by)
    VALUES (NEW.agency_id, cr.team_member_id, 'multiline_chargeback', NEW.canceled_on, public.rp_week_end(NEW.canceled_on), v_cur_week,
      NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_label,
      'Chargeback: ' || NEW.policy_line || ' sold ' || to_char(sp.sale_date, 'Mon FMDD') || ' canceled ' || to_char(NEW.canceled_on, 'Mon FMDD') ||
        ', ' || round(v_left * 100) || '% of the window left',
      -v_pts, 'cancelation_log', NEW.id, NEW.created_by)
    RETURNING id INTO v_id;
    UPDATE public.cancelation_log SET chargeback_points = v_pts, chargeback_activity_id = v_id WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_cancelation_log_chargeback ON public.cancelation_log;
CREATE TRIGGER trg_cancelation_log_chargeback AFTER INSERT ON public.cancelation_log
FOR EACH ROW EXECUTE FUNCTION public.cancelation_log_chargeback();

-- rp_log_cancelation: report the match and the chargeback back to the page.
CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_type text; v_reason text; v_note text;
  v_prem numeric; v_veh integer; v_id uuid; r RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'canceled_on','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'the cancelation date cannot be in the future'; END IF;
  IF v_on < v_today - 90 THEN RAISE EXCEPTION 'log a cancelation within 90 days of the date it happened'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_line  := NULLIF(lower(btrim(COALESCE(p->>'policy_line',''))), '');
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
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
  INSERT INTO public.cancelation_log
    (agency_id, team_member_id, canceled_on, week_end_date, customer_first_name, customer_last_initial,
     customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by)
  VALUES
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     upper(btrim(p->>'customer_last_initial')), v_label, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id)
  RETURNING id INTO v_id;
  SELECT c.saves_voided, c.matched_sale_product_id, c.chargeback_points, c.window_fraction_left, s.sale_date
    INTO r FROM public.cancelation_log c
    LEFT JOIN public.sales_log_products sp ON sp.id = c.matched_sale_product_id
    LEFT JOIN public.sales_log s ON s.id = sp.sales_log_id
   WHERE c.id = v_id;
  RETURN jsonb_build_object('ok', true, 'cancelation_id', v_id, 'customer', v_label,
                            'policy_line', v_line, 'product_type', v_type, 'premium', v_prem, 'vehicle_count', v_veh,
                            'saves_voided', r.saves_voided, 'matched_sale_date', r.sale_date,
                            'chargeback_points', r.chargeback_points, 'window_fraction_left', r.window_fraction_left);
END $function$;

-- rp_void_cancelation and rp_undo_entry: reverse the chargeback too.
CREATE OR REPLACE FUNCTION public.rp_void_cancelation(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; cb RECORD;
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
  -- reverse the chargeback: a negative row is voided; a voided credit is restored
  IF r.chargeback_activity_id IS NOT NULL THEN
    SELECT * INTO cb FROM public.retention_activity_log WHERE id = r.chargeback_activity_id;
    IF FOUND AND cb.source = 'cancelation_log' AND cb.status = 'credited' THEN
      UPDATE public.retention_activity_log SET status='void', voided_at=now(), voided_by=a.actor_id,
             void_reason='cancelation removed', updated_at=now() WHERE id = cb.id;
    ELSIF FOUND AND cb.source = 'sales_log' AND cb.status = 'void' AND cb.void_reason LIKE '%chargeback window%' THEN
      UPDATE public.retention_activity_log SET status='credited', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now() WHERE id = cb.id;
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id,
    'note', 'removing the cancelation does not put back a save it took away — log the save again if that is what you meant');
END $function$;
