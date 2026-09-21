-- Peter 2026-09-21: the handbook shows the current pay formulas on its own,
-- straight from what the system pays with, so it can never drift again.
-- Sources, each the one the pay math itself reads:
--   sales      -> compute_sp_from_production (its constants, returned at zero)
--   windows    -> rp_chargeback_window_months
--   retention  -> retention_point_values
--   marketing  -> marketing_point_values
-- The Manual page fills {{live:...}} tokens from this.
CREATE OR REPLACE FUNCTION public.handbook_live_formulas(p_agency_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'sales', public.compute_sp_from_production(0, 0, 0, 0, 0, 0),
    'sales_caps', jsonb_build_object('pc_cap', 0.06, 'lh_cap', 0.18),
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
GRANT EXECUTE ON FUNCTION public.handbook_live_formulas(uuid) TO authenticated;
