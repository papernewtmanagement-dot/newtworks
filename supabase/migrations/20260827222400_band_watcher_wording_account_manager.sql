-- Peter 2026-08-26: stop calling Account Managers "managers" in anything he reads —
-- it collides with actual manager seats. Recipe blurb reworded; no logic change.
UPDATE public.automation_recipes
SET recipe_description = 'Every Sunday, checks the rolling thirteen-week Sales Points rating of everyone in an Account Manager seat or above. Raises an alert when someone drops into Caution (documented coaching conversation plus a weekly one-on-one) or Danger (signed improvement plan, back to Good within thirteen weeks). Resolves the alert automatically once the rating returns to Good or better.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'sales_points_band_drop_watcher';
