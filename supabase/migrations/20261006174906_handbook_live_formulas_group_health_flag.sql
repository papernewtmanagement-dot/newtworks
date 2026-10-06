-- Peter 2026-10-06: the handbook's group health section shows only while an active
-- teammate is on the plan (an agency-paid weekly health premium on their team record).
-- The page wraps that section in {{live-if:group-health}} ... {{/live-if}}.
CREATE OR REPLACE FUNCTION public.handbook_live_formulas(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
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
       WHERE m.agency_id = p_agency_id AND m.is_active), '[]'::jsonb),
    'show', jsonb_build_object(
      'group-health', EXISTS (
        SELECT 1 FROM public.team t
         WHERE t.agency_id = p_agency_id AND t.is_active IS TRUE
           AND COALESCE(t.is_test_user, false) = false
           AND t.archived_at IS NULL
           AND COALESCE(t.weekly_health_benefit_agency_paid, 0) > 0)));
$function$;
