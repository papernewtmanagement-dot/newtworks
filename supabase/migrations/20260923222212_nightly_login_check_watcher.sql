-- Nightly Login Check (Peter 2026-09-23, option 1B). Catches anything a signed-in login can reach that it
-- should not, such as a new full-access function opened to logins without the login check.
-- login_guard_audit() stays the only definition of "open"; the shared watcher-task helpers own the task.

CREATE OR REPLACE FUNCTION public.login_guard_watcher(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count int;
  v_list text;
  v_closed int;
BEGIN
  SELECT count(*)::int, string_agg('- ' || a.object || ': ' || a.problem, E'\n' ORDER BY a.object)
    INTO v_count, v_list
  FROM public.login_guard_audit() a;

  IF v_count = 0 THEN
    v_closed := public.close_watcher_task(p_agency_id, 'login_guard', NULL);
    RETURN jsonb_build_object(
      'records_processed', 0,
      'closed', v_closed,
      'output_summary', CASE WHEN v_closed > 0
        THEN 'Every login is back to reaching only what its pages need. Task closed.'
        ELSE 'Every login reaches only what its pages need.' END);
  END IF;

  PERFORM public.ensure_watcher_task(
    p_agency_id, 'login_guard', NULL,
    format('Fix %s database item%s open to the wrong logins', v_count, CASE WHEN v_count = 1 THEN '' ELSE 's' END),
    'The nightly login check found database items a signed-in login can reach that it should not. '
      || 'Ask Claude to fix them using the rule "Database functions — signed-in only". This task closes itself '
      || 'the first night the check comes back clean. Found:' || E'\n' || v_list,
    'high', 'web_app');

  RETURN jsonb_build_object(
    'records_processed', v_count,
    'output_summary', format('%s database item%s open to the wrong logins. Task open for Peter.',
                             v_count, CASE WHEN v_count = 1 THEN '' ELSE 's' END));
END;
$$;

REVOKE ALL ON FUNCTION public.login_guard_watcher(uuid, uuid) FROM PUBLIC, anon, authenticated;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, composio_action, internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Nightly Login Check',
  'Every night, checks that no login can reach more of the database than its pages need. If anything is open, it opens one task for Peter to have Claude fix it. The task closes itself the first night the check comes back clean.',
  'cron', '0 3 * * *', 'INTERNAL', 'login_guard_watcher', true, 'America/Chicago'
WHERE NOT EXISTS (SELECT 1 FROM public.automation_recipes WHERE internal_handler = 'login_guard_watcher');