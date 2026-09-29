SELECT set_config('app.onboarding_template_sync','off',true);
WITH src AS (
  SELECT split_part(array_to_string(statements, E'\n'), '$j$', 2)::jsonb AS j
  FROM supabase_migrations.schema_migrations WHERE version = '20260925160606'
), orig AS (
  SELECT e->>'template_key' AS k, e->'substeps' AS subs FROM src, jsonb_array_elements(src.j) e
  WHERE e->>'template_key' LIKE '%\_goals'
)
UPDATE public.onboarding_step_templates t SET substeps = o.subs
FROM orig o
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = o.k
  AND t.substeps IS DISTINCT FROM o.subs;
SELECT set_config('app.onboarding_template_sync','on',true);
SELECT public.onboarding_sync_open_plans();
