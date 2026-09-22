ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS reinstated_on date;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS reinstated_at timestamptz;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS reinstated_by uuid REFERENCES public.team(id);

-- Peter 2026-09-22: a home can be reinstated within 30 days of the cancel, an auto within 15.
-- One place decides the window; the button and the save both read it.
CREATE OR REPLACE FUNCTION public.cancel_reinstate_until(p_policy_line text, p_canceled_on date)
 RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(p_policy_line) WHEN 'fire' THEN p_canceled_on + 30
                                   WHEN 'auto' THEN p_canceled_on + 15 END
$$;

-- Cancelations the History tab can offer to reinstate, plus ones already reinstated.
CREATE OR REPLACE FUNCTION public.rp_reinstatable_cancelations()
 RETURNS TABLE(id uuid, reinstate_until date, reinstated_on date)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE a RECORD; v_today date := public.rp_today_central();
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF a.agency_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  RETURN QUERY
  SELECT c.id, public.cancel_reinstate_until(c.policy_line, c.canceled_on), c.reinstated_on
    FROM public.cancelation_log c
   WHERE c.agency_id = a.agency_id AND c.status = 'active'
     AND (c.reinstated_on IS NOT NULL
          OR v_today <= public.cancel_reinstate_until(c.policy_line, c.canceled_on));
END $$;

CREATE OR REPLACE FUNCTION public.rp_reinstate_cancelation(p_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE a RECORD; c public.cancelation_log%ROWTYPE; v_today date := public.rp_today_central(); v_until date;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF a.agency_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO c FROM public.cancelation_log x WHERE x.id = p_id AND x.agency_id = a.agency_id FOR UPDATE;
  IF NOT FOUND OR c.status <> 'active' THEN RAISE EXCEPTION 'Cancelation not found'; END IF;
  IF c.reinstated_on IS NOT NULL THEN RAISE EXCEPTION 'Already reinstated on %', to_char(c.reinstated_on, 'FMMM/FMDD'); END IF;
  v_until := public.cancel_reinstate_until(c.policy_line, c.canceled_on);
  IF v_until IS NULL THEN RAISE EXCEPTION 'Only home and auto policies can be reinstated'; END IF;
  IF v_today > v_until THEN RAISE EXCEPTION 'Too late to reinstate. The window closed %', to_char(v_until, 'FMMM/FMDD'); END IF;
  UPDATE public.cancelation_log
     SET reinstated_on = v_today, reinstated_at = now(), reinstated_by = a.actor_id, updated_at = now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'reinstated_on', v_today, 'days_out', v_today - c.canceled_on);
END $$;

GRANT EXECUTE ON FUNCTION public.rp_reinstatable_cancelations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_reinstate_cancelation(uuid) TO authenticated;

-- Production: a reinstatement gives back the chargeback, less the premium for the days
-- the policy was out of force, and puts the app back. It lands in the week it was
-- reinstated; the original chargeback week is never rewritten.
DO $mig$
DECLARE d text; r text[][] := ARRAY[
  ARRAY['           public.cancel_counts_on(c.agency_id, c.created_at) AS recorded_on
      FROM public.cancelation_log c',
        '           public.cancel_counts_on(c.agency_id, c.created_at) AS recorded_on,
           c.canceled_on, c.reinstated_on,
           CASE WHEN c.reinstated_at IS NOT NULL THEN public.cancel_counts_on(c.agency_id, c.reinstated_at) END AS reinstated_counts_on
      FROM public.cancelation_log c'],
  ARRAY['   WHERE cx.recorded_on BETWEEN p_from AND p_through;',
        '   WHERE cx.recorded_on BETWEEN p_from AND p_through
  UNION ALL
  -- Peter 2026-09-22: reinstated inside the window (home 30 days, auto 15). The chargeback
  -- comes back, minus the premium for the days out of force, and the app comes back whole.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type,
         GREATEST(0, round(b.premium * cx.left_frac, 2)
                     - round(b.premium * (cx.reinstated_on - cx.canceled_on) / 365.0, 2)),
         b.policy_count, b.vehicle_count, b.units, cx.reinstated_counts_on, b.customer_label,
         ''Reinstated: '' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl cx ON cx.pid = b.id
   WHERE cx.reinstated_on IS NOT NULL
     AND cx.reinstated_counts_on BETWEEN p_from AND p_through;']
]; i int;
BEGIN
  d := pg_get_functiondef('public.production_rows_for(uuid,date,date)'::regprocedure);
  FOR i IN 1..array_length(r,1) LOOP
    IF (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 THEN
      RAISE EXCEPTION 'production_rows_for patch % did not match exactly once', i;
    END IF;
    d := replace(d, r[i][1], r[i][2]);
  END LOOP;
  EXECUTE d;

  d := pg_get_functiondef('public.rp_entry_rows(uuid,date,date,boolean)'::regprocedure);
  r := ARRAY[ARRAY['         (initcap(c.policy_line) || '' '' || COALESCE(c.product_type,''''))::text,',
                   '         (initcap(c.policy_line) || '' '' || COALESCE(c.product_type,'''')
          || CASE WHEN c.reinstated_on IS NOT NULL THEN '' · Reinstated '' || to_char(c.reinstated_on, ''FMMM/FMDD'') ELSE '''' END)::text,']];
  IF (length(d) - length(replace(d, r[1][1], ''))) / length(r[1][1]) <> 1 THEN
    RAISE EXCEPTION 'rp_entry_rows patch did not match exactly once';
  END IF;
  EXECUTE replace(d, r[1][1], r[1][2]);
END $mig$;
