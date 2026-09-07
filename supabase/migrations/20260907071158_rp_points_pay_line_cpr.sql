-- Step 7 of the Production module tracker (2026-09-07): Retention Points pay line on the CPR.
-- One stored dollar figure per teammate per week: the points guarantee (net points x $1)
-- after the Win-the-Week requirements adjustment scale, the same scale every other bonus
-- component already carries. It is the guarantee part of retention_pool_share; the rest of
-- retention_pool_share is the points share of what was left of the retention third.
-- Reads 0 until settings.retention_points_go_live_week_end is set, because
-- compute_weekly_comp_residual_pool returns weekly_retention_guarantee = 0 in hours mode.
-- Nothing about how pay is computed changes. This names a number that was already inside
-- bonus and retention_pool_share so the page can show it on its own line without double counting.
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS retention_points_pay numeric DEFAULT 0;

COMMENT ON COLUMN public.weekly_cpr_team_detail.retention_points_pay IS
  'Retention Points dollars this week: net points x $1 guarantee x the requirements-adjustment scale. Already inside bonus and retention_pool_share; never add it to them. 0 until settings.retention_points_go_live_week_end is set. Written by write_weekly_comp_v2.';

-- write_weekly_comp_v2: add one assignment to the weekly_cpr_team_detail UPDATE, right after
-- retention_guarantee_topup. Patched by exact anchor so the rest of the function is untouched;
-- loud failure if the anchor line ever changes.
DO $$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef('public.write_weekly_comp_v2(uuid,date)'::regprocedure) INTO v_def;
  IF position('retention_points_pay' IN v_def) > 0 THEN
    RAISE NOTICE 'write_weekly_comp_v2 already writes retention_points_pay; nothing to do';
    RETURN;
  END IF;
  v_new := replace(v_def,
    E'        retention_guarantee_topup = COALESCE(s.weekly_retention_topup, 0) * v_scale.scale,\n',
    E'        retention_guarantee_topup = COALESCE(s.weekly_retention_topup, 0) * v_scale.scale,\n        retention_points_pay = COALESCE(s.weekly_retention_guarantee, 0) * v_scale.scale,\n');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'write_weekly_comp_v2: anchor line for retention_points_pay not found; function text changed, patch by hand';
  END IF;
  EXECUTE v_new;
END $$;
