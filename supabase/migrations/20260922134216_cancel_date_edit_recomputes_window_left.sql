-- One rule for how much of the chargeback window was left when a policy canceled.
CREATE OR REPLACE FUNCTION public.cancel_window_fraction_left(p_policy_line text, p_submitted date, p_canceled_on date)
 RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $$
  WITH w AS (SELECT (p_submitted + (public.rp_chargeback_window_months(p_policy_line) || ' months')::interval)::date AS window_end)
  SELECT LEAST(1, GREATEST(0, COALESCE(round((w.window_end - p_canceled_on)::numeric / NULLIF((w.window_end - p_submitted)::numeric, 0), 4), 0)))
  FROM w
$$;

-- The insert trigger now calls it instead of working it out inline.
DO $mig$
DECLARE d text; old text := '  v_left := round((v_window_end - NEW.canceled_on)::numeric / NULLIF((v_window_end - sp.submitted_date)::numeric, 0), 4);
  v_left := LEAST(1, GREATEST(0, COALESCE(v_left, 0)));';
BEGIN
  d := pg_get_functiondef('public.cancelation_log_chargeback()'::regprocedure);
  IF (length(d) - length(replace(d, old, ''))) / length(old) <> 1 THEN RAISE EXCEPTION 'patch did not match'; END IF;
  EXECUTE replace(d, old, '  v_left := public.cancel_window_fraction_left(NEW.policy_line, sp.submitted_date, NEW.canceled_on);');
END $mig$;

-- Editing the cancel date moves its week and its share of the window with it.
-- Before this, a corrected date kept the old week and the old fraction.
CREATE OR REPLACE FUNCTION public.cancelation_log_date_changed()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_sub date;
BEGIN
  NEW.week_end_date := public.rp_week_end(NEW.canceled_on);
  IF NEW.matched_sale_product_id IS NOT NULL THEN
    SELECT s.submitted_date INTO v_sub
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = NEW.matched_sale_product_id;
    IF v_sub IS NOT NULL THEN
      NEW.window_fraction_left := public.cancel_window_fraction_left(NEW.policy_line, v_sub, NEW.canceled_on);
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_cancelation_log_date_changed ON public.cancelation_log;
CREATE TRIGGER trg_cancelation_log_date_changed BEFORE UPDATE OF canceled_on ON public.cancelation_log
  FOR EACH ROW WHEN (NEW.canceled_on IS DISTINCT FROM OLD.canceled_on)
  EXECUTE FUNCTION public.cancelation_log_date_changed();

-- Elizabeth S. home (issued 7/3): Peter 2026-09-22, canceled from day one.
UPDATE public.cancelation_log
   SET week_end_date = public.rp_week_end(canceled_on),
       window_fraction_left = public.cancel_window_fraction_left(policy_line, DATE '2026-07-03', canceled_on)
 WHERE id = '4c629982-022e-4282-98e9-2182a86ad532';
