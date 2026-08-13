-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-19 03:39:34 UTC (ledger name: v_hiring_candidates_composite_from_weights_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260719033934.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

CREATE OR REPLACE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT
    MAX(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    MAX(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    MAX(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer = 'resume'
)
SELECT
  hc.*,
  ROUND((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score)::numeric / 3.0, 2) AS res_nature,
  ROUND((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score)::numeric / 4.0, 2) AS res_nurture,
  ROUND((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score)::numeric / 4.0, 2) AS res_drivers,
  ROUND(
      rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score)::numeric / 3.0)
    + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score)::numeric / 4.0)
    + rw.w_dr  * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score)::numeric / 4.0)
  , 2) AS res_composite
FROM public.hiring_candidates hc
CROSS JOIN resume_w rw;

COMMENT ON VIEW public.v_hiring_candidates IS
  'hiring_candidates + resume aggregates. res_nature/nurture/drivers = unweighted means of sub-signals (3, 4, 4). res_composite = resume layer total, weighted by hiregauge_layer_composite_weights WHERE layer=resume. All read-time.';

GRANT SELECT ON public.v_hiring_candidates TO anon, authenticated, service_role;
