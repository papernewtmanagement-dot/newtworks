SELECT set_config('app.onboarding_template_sync','off',true);
UPDATE public.onboarding_step_templates t
SET substeps = (
  SELECT jsonb_agg(e ORDER BY ord)
  FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS x(e, ord)
  WHERE NOT (e#>>'{}' ILIKE '%dials a day%' OR e#>>'{}' ILIKE 'answer %' OR e#>>'{}' = '5 service calls a day from Tuesday')
)
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND t.template_key LIKE 'cur\_%goals'
  AND jsonb_typeof(t.substeps) = 'array'
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.substeps) e
              WHERE e#>>'{}' ILIKE '%dials a day%' OR e#>>'{}' ILIKE 'answer %' OR e#>>'{}' = '5 service calls a day from Tuesday');
UPDATE public.onboarding_step_templates
SET track = 'Role Play & Practice', track_order = 3
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'cur_b_w01_live';
SELECT set_config('app.onboarding_template_sync','on',true);
SELECT public.onboarding_sync_open_plans();
