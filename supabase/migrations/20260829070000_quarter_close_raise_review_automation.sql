-- Peter 2026-08-28: raises are reviewed at quarter close, automatically.
--
-- Runs the same way the prize-cart close does — cron every Saturday 23:59
-- CT, and the dispatcher skips unless that Saturday IS the cycle end, so it
-- fires once a quarter. Uses current_cycle_info for the boundary; calendar
-- quarter maths is a week off and must not be used.
--
-- It does not change anyone's pay. It records the review and raises a task
-- for each person who qualified, because the rate change is Peter's to make.
-- One tier per close, in order, is already how team_raise_progress reports
-- the next rung, so acting on its output honours that by construction.
--
-- Everyone is written to the log, qualified or not, so there is a record of
-- what each person's average was at the close rather than only the winners.

CREATE TABLE IF NOT EXISTS public.raise_review_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  reviewed_on       date NOT NULL,
  team_member_id    uuid NOT NULL,
  first_name        text,
  role_category     text,
  role_level        text,
  current_hourly    numeric,
  title_increment   numeric,
  tier_hourly       numeric,
  current_tier      int,
  next_tier         int,
  next_hourly       numeric,
  next_requirement  text,
  avg_weekly_sp     numeric,
  qualified         boolean NOT NULL,
  task_id           uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, reviewed_on, team_member_id)
);

COMMENT ON TABLE public.raise_review_log IS
  'One row per person per quarter-close raise review. Records what they were paid, what the next rung needed, where their average stood, and whether they qualified. Nothing here changes pay — a qualifying row also raises a task.';

ALTER TABLE public.raise_review_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS raise_review_log_admin ON public.raise_review_log;
CREATE POLICY raise_review_log_admin ON public.raise_review_log
  FOR SELECT USING (public.is_agency_admin());

CREATE OR REPLACE FUNCTION public.quarter_close_raise_review(p_agency_id uuid, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r            record;
  v_task_id    uuid;
  v_qualified  int := 0;
  v_reviewed   int := 0;
  v_names      text[] := ARRAY[]::text[];
BEGIN
  FOR r IN SELECT * FROM public.team_raise_progress(p_agency_id, p_as_of) LOOP
    v_reviewed := v_reviewed + 1;
    v_task_id := NULL;

    IF r.on_track AND r.next_tier IS NOT NULL THEN
      -- Skip if this exact raise was already raised at this close.
      SELECT l.task_id INTO v_task_id
        FROM public.raise_review_log l
       WHERE l.agency_id = p_agency_id AND l.reviewed_on = p_as_of
         AND l.team_member_id = r.team_member_id AND l.qualified;

      IF v_task_id IS NULL THEN
        INSERT INTO public.tasks (agency_id, title, description, task_category, task_type,
                                  priority, status, due_date, related_id, created_at, updated_at)
        VALUES (
          p_agency_id,
          'Raise earned — ' || r.first_name || ' to $' || to_char(r.next_hourly, 'FM990.00') || '/hr',
          r.first_name || ' met raise tier ' || r.next_tier || ' at the ' || p_as_of || ' quarter close.'
            || E'\n\nNeeded: ' || COALESCE(r.next_requirement, 'the next step')
            || CASE WHEN r.avg_weekly_sp IS NOT NULL
                    THEN E'\nTheir average: ' || r.avg_weekly_sp || ' a week' ELSE '' END
            || E'\n\nPaid now: $' || to_char(r.current_hourly, 'FM990.00') || '/hr'
            || CASE WHEN COALESCE(r.title_increment,0) > 0
                    THEN ' (tier $' || to_char(r.tier_hourly, 'FM990.00')
                         || ' plus $' || to_char(r.title_increment, 'FM990.00')
                         || ' ' || COALESCE(r.role_level,'title') || ')' ELSE '' END
            || E'\nNew rate: $' || to_char(r.next_hourly, 'FM990.00') || '/hr'
            || E'\n\nUpdate their pay rate on the Team record to apply it.',
          'admin', 'epic', 'high', 'open', p_as_of + 7, r.team_member_id, now(), now()
        )
        RETURNING id INTO v_task_id;
      END IF;

      v_qualified := v_qualified + 1;
      v_names := array_append(v_names, r.first_name);
    END IF;

    INSERT INTO public.raise_review_log (
      agency_id, reviewed_on, team_member_id, first_name, role_category, role_level,
      current_hourly, title_increment, tier_hourly, current_tier, next_tier, next_hourly,
      next_requirement, avg_weekly_sp, qualified, task_id)
    VALUES (
      p_agency_id, p_as_of, r.team_member_id, r.first_name, r.role_category, r.role_level,
      r.current_hourly, r.title_increment, r.tier_hourly, r.current_tier, r.next_tier,
      r.next_hourly, r.next_requirement, r.avg_weekly_sp,
      COALESCE(r.on_track, false) AND r.next_tier IS NOT NULL, v_task_id)
    ON CONFLICT (agency_id, reviewed_on, team_member_id) DO UPDATE
      SET current_hourly = EXCLUDED.current_hourly,
          avg_weekly_sp  = EXCLUDED.avg_weekly_sp,
          qualified      = EXCLUDED.qualified,
          task_id        = COALESCE(public.raise_review_log.task_id, EXCLUDED.task_id);
  END LOOP;

  RETURN jsonb_build_object(
    'reviewed_on', p_as_of,
    'seats_reviewed', v_reviewed,
    'raises_earned', v_qualified,
    'who', v_names);
END;
$function$;

CREATE OR REPLACE FUNCTION public.quarter_close_raise_review_dispatcher(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today_ct  date;
  v_cycle_end date;
  v_result    jsonb;
BEGIN
  v_today_ct  := (now() AT TIME ZONE 'America/Chicago')::date;
  v_cycle_end := (public.current_cycle_info(p_agency_id, v_today_ct)).cycle_end;

  -- Cron fires every Saturday 23:59 CT. Only the Saturday that IS the cycle
  -- end is a quarter close; every other week is a skip.
  IF v_today_ct <> v_cycle_end THEN
    RETURN jsonb_build_object(
      'skipped', true,
      'reason', 'not quarter-close week',
      'today_ct', v_today_ct,
      'cycle_end', v_cycle_end,
      'recipe_id', p_recipe_id,
      'records_processed', 0,
      'output_summary', 'Skipped: not quarter-close week (today=' || v_today_ct
                        || ', cycle_end=' || v_cycle_end || ')');
  END IF;

  v_result := public.quarter_close_raise_review(p_agency_id, v_today_ct);

  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'raises_earned')::int, 0),
    'output_summary', 'Raise review at ' || v_today_ct || ': '
      || COALESCE(v_result->>'seats_reviewed','0') || ' seat(s) reviewed, '
      || COALESCE(v_result->>'raises_earned','0') || ' raise(s) earned'
      || CASE WHEN COALESCE((v_result->>'raises_earned')::int,0) > 0
              THEN ' — ' || array_to_string(
                     ARRAY(SELECT jsonb_array_elements_text(v_result->'who')), ', ')
              ELSE '' END);
END;
$function$;

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, timezone, is_active)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Quarter Close — raise review',
  'Runs at Q-close Saturday 23:59 CT. Measures every seat against the published raise ladder in pay_scale, logs the review, and raises a task for each person who earned their next tier. Does not change pay.',
  'cron', '59 23 * * 6', 'INTERNAL',
  'quarter_close_raise_review_dispatcher', 'America/Chicago', true)
ON CONFLICT DO NOTHING;
