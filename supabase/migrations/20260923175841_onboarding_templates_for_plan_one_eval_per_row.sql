-- Fix: saving an onboarding template subcard failed with "canceling statement due to statement timeout".
-- Every template save syncs all open plans, and the sync reads onboarding_templates_for_plan() four times per plan.
-- That function built each row as (jsonb_populate_record(...)).* in the select list. Postgres expands that into one
-- call per column, so the whole row build (and the phase date lookups inside it) ran about 40 times per row.
-- One plan took about 7 seconds; two plans passed the 8-second limit on a browser request.
-- Moving the row build into a LATERAL join runs it once per row. Output checked identical for both live plans
-- (412 rows, zero differences) before this shipped. Same logic, same rules, nothing else changed.
CREATE OR REPLACE FUNCTION public.onboarding_templates_for_plan(p_plan_id uuid)
 RETURNS SETOF onboarding_step_templates
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- The row build sits in a LATERAL join on purpose. Written as (jsonb_populate_record(...)).*
  -- in the select list, Postgres runs it once per column instead of once per row.
  SELECT r.*
  FROM public.team_onboarding_plans p
  JOIN public.onboarding_step_templates t
    ON t.agency_id = p.agency_id
   AND t.is_active = true
   AND (t.applies_to_roles           IS NULL OR p.role_snapshot          = ANY (t.applies_to_roles))
   AND (t.applies_to_role_categories IS NULL OR p.role_category_snapshot = ANY (t.applies_to_role_categories))
   AND (t.applies_to_role_levels     IS NULL OR p.role_level_snapshot    = ANY (t.applies_to_role_levels))
  LEFT JOIN public.onboarding_phases ph
    ON ph.agency_id = p.agency_id AND ph.phase = t.phase AND ph.stage = 'ramp' AND COALESCE(ph.weeks_long, 0) >= 1
  LEFT JOIN LATERAL (
    SELECT gs AS n
    FROM generate_series(public.onboarding_phase_first_week(p.agency_id, t.phase),
                         public.onboarding_phase_first_week(p.agency_id, t.phase) + ph.weeks_long - 1) gs
    WHERE ph.phase IS NOT NULL AND (t.weeks IS NULL OR gs = ANY (t.weeks))
  ) w ON true
  CROSS JOIN LATERAL jsonb_populate_record(NULL::public.onboarding_step_templates,
            to_jsonb(t) || jsonb_build_object(
              'template_key', CASE WHEN ph.weeks_long > 1 THEN t.template_key || '@w' || w.n ELSE t.template_key END,
              'plan_week_no', w.n,
              'plan_unlocks_on', COALESCE(
                 public.onboarding_unlock_date(t.unlock_rule, p.start_date),
                 CASE WHEN w.n IS NOT NULL AND p.start_date IS NOT NULL
                      THEN public.onboarding_phase_opens_on(p.agency_id, t.phase, p.start_date)
                           + 7 * (w.n - public.onboarding_phase_first_week(p.agency_id, t.phase)) END))) r
  WHERE p.id = p_plan_id
    AND (ph.phase IS NULL OR w.n IS NOT NULL);
$function$;
