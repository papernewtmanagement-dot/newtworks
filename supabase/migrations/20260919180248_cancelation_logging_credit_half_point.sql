-- Peter 2026-09-19 (option 1B): logging a cancelation earns 0.50, paid on the
-- cancelation record itself rather than as an activity someone types in. The
-- credit then cannot exist without a real cancelation on file, which is the
-- hole that let nine cancelations get filed as Policy Change at 1.00 each.
-- The chargeback still lands, so a cancelation is still a net loss.
--
-- category 'derived' keeps it off the logging screen, same as the multiline
-- credit and its chargeback.

INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, sort_order, is_active)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'cancelation_logged', 'Cancelation Logged', 0.50, 'derived', 96, true)
ON CONFLICT (agency_id, activity_key) DO UPDATE
  SET label = EXCLUDED.label, points = EXCLUDED.points, category = EXCLUDED.category,
      sort_order = EXCLUDED.sort_order, is_active = EXCLUDED.is_active;

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

  SELECT v.points INTO v_pts
    FROM public.retention_point_values v
   WHERE v.agency_id = NEW.agency_id AND v.activity_key = 'cancelation_logged' AND v.is_active;
  IF COALESCE(v_pts, 0) <= 0 THEN RETURN NEW; END IF;

  v_week := public.rp_week_end(NEW.canceled_on);

  INSERT INTO public.retention_activity_log (
    agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
    customer_first_name, customer_last_initial, customer_label, phone_last4,
    policy_line, product_type, note, points, source, source_id, created_by)
  VALUES (
    NEW.agency_id, NEW.team_member_id, 'cancelation_logged', NEW.canceled_on, v_week,
    GREATEST(v_week, v_cur_week),
    NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_label, NEW.phone_last4,
    NEW.policy_line, NEW.product_type,
    'Logged the cancelation of ' || initcap(COALESCE(NEW.policy_line, '')) || ' ' || COALESCE(NEW.product_type, '')
      || ' on ' || to_char(NEW.canceled_on, 'Mon FMDD'),
    v_pts, 'cancelation_log', NEW.id, NEW.created_by);

  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS cancelation_log_logging_credit_ins ON public.cancelation_log;
CREATE TRIGGER cancelation_log_logging_credit_ins
AFTER INSERT ON public.cancelation_log
FOR EACH ROW EXECUTE FUNCTION public.cancelation_log_logging_credit();

DROP TRIGGER IF EXISTS cancelation_log_logging_credit_upd ON public.cancelation_log;
CREATE TRIGGER cancelation_log_logging_credit_upd
AFTER UPDATE OF status ON public.cancelation_log
FOR EACH ROW EXECUTE FUNCTION public.cancelation_log_logging_credit();
