INSERT INTO public.automation_recipes (
  agency_id,
  recipe_name,
  recipe_description,
  trigger_type,
  cron_expression,
  composio_action,
  internal_handler,
  is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'Standing Time Off Materialize (Sunday)',
  'Sunday PM. Reads standing_time_off_preferences, evaluates wtw_won_prior_week trigger against prior CPR outcome, INSERTs concrete auto-approved time_off_requests for the upcoming Mon-Fri work week. Idempotent via ux_tor_derived_pref_date.',
  'cron',
  '0 20 * * 0',
  'INTERNAL',
  'materialize_standing_time_off',
  true
);;