-- The handbook reads the rate caps from the sales points function itself
-- instead of a second copy.
DO $mig$
DECLARE d text; o text;
BEGIN
  SELECT pg_get_functiondef('public.compute_sp_from_production(numeric,numeric,numeric,numeric,numeric,numeric)'::regprocedure) INTO d;
  o := $o$      'pc_base_pct',      c_pc_base_pct,$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'rates block not found'; END IF;
  d := replace(d, o, $n$      'pc_base_pct',      c_pc_base_pct,
      'pc_cap',           c_pc_cap,
      'lh_cap',           c_lh_cap,$n$);
  EXECUTE d;
END $mig$;

CREATE OR REPLACE FUNCTION public.handbook_live_formulas(p_agency_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'sales', public.compute_sp_from_production(0, 0, 0, 0, 0, 0),
    'chargeback_months', jsonb_build_object(
      'auto', public.rp_chargeback_window_months('auto'),
      'fire', public.rp_chargeback_window_months('fire'),
      'life', public.rp_chargeback_window_months('life'),
      'health', public.rp_chargeback_window_months('health')),
    'retention', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('key', v.activity_key, 'label', v.label, 'points', v.points,
                                          'step_pct', v.prior_step_pct, 'cap', v.prior_cap)
                       ORDER BY v.points, v.label)
        FROM public.retention_point_values v
       WHERE v.agency_id = p_agency_id AND v.points > 0), '[]'::jsonb),
    'marketing', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('key', m.event_key, 'label', m.label, 'points', m.base_points,
                                          'step', m.step_per_prior, 'cap', m.prior_cap)
                       ORDER BY m.base_points DESC, m.label)
        FROM public.marketing_point_values m
       WHERE m.agency_id = p_agency_id AND m.is_active), '[]'::jsonb));
$function$;
