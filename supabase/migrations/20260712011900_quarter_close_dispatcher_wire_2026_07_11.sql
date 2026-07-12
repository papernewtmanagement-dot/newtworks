-- Wrapper for the automation recipe path (agency_id, recipe_id) — calls
-- quarter_close_prize_cart_and_leaderboards with proper quarter-end date.
-- Skips when it's not actually a quarter-close Saturday.

CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards_dispatcher(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_today_ct date;
  v_cycle_end date;
BEGIN
  v_today_ct := (now() AT TIME ZONE 'America/Chicago')::date;
  v_cycle_end := (public.current_cycle_info(p_agency_id, v_today_ct)).cycle_end;

  -- Only run on quarter-close Saturday. Cron fires every Sunday 04:59 UTC (~Sat 23:59 CT),
  -- so v_today_ct at fire time is Saturday. If Saturday != cycle_end, skip.
  IF v_today_ct != v_cycle_end THEN
    RETURN jsonb_build_object(
      'skipped', true,
      'reason', 'not quarter-close week',
      'today_ct', v_today_ct,
      'cycle_end', v_cycle_end,
      'recipe_id', p_recipe_id
    );
  END IF;

  RETURN public.quarter_close_prize_cart_and_leaderboards(p_agency_id, v_today_ct);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.quarter_close_prize_cart_and_leaderboards_dispatcher(uuid, uuid)
  TO service_role, authenticated;

-- Wire the recipe: composio_action='INTERNAL', flip to active
UPDATE public.automation_recipes
SET composio_action = 'INTERNAL',
    is_active = true,
    updated_at = now()
WHERE id = '9af4cf5c-e801-47f8-8c95-c74ac8f65282'
  AND recipe_name = 'Quarter Close — prize cart carry + budget + MVP snapshot';
