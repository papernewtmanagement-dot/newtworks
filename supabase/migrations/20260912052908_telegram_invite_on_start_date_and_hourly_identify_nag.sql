-- Peter 2026-09-11, two changes:
--   1. The invite fires on the START DATE, not the hire date. hire_date is kept
--      as a fallback only for a row where start_date was never filled in, so a
--      half-filled record still gets the person into the group.
--   2. The identify nag runs hourly through business hours instead of once a
--      day, and deletes its own previous message before posting the new one -
--      same delete-then-repost pattern as the check-in compile, so the channel
--      keeps one bubble and the repost still pings.

-- ---------------------------------------------------------------------------
-- Identify nag: hourly, delete-then-repost
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.telegram_identify_nag(
  p_agency_id uuid,
  p_recipe_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_names    text[];
  v_chat_id  bigint;
  v_last_id  bigint;
  v_resp     jsonb;
  v_new_id   bigint;
BEGIN
  SELECT chat_id INTO v_chat_id FROM public.telegram_routes
   WHERE agency_id = p_agency_id AND route_key = 'team' AND is_active;
  IF v_chat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team route missing');
  END IF;

  -- Anyone active, agency, started, with no Telegram account on file. Someone
  -- whose invite is still outstanding is skipped - they are not in the group
  -- yet, so they would never see the message.
  SELECT array_agg(coalesce(nullif(t.nickname, ''), t.first_name) ORDER BY t.first_name)
    INTO v_names
    FROM public.team t
   WHERE t.agency_id = p_agency_id
     AND t.is_active IS TRUE
     AND t.archived_at IS NULL
     AND coalesce(t.is_test_user, false) = false
     AND t.category = 'agency'
     AND t.telegram_user_id IS NULL
     AND coalesce(t.start_date, t.hire_date) IS NOT NULL
     AND coalesce(t.start_date, t.hire_date) <= (now() AT TIME ZONE 'America/Chicago')::date
     AND NOT EXISTS (SELECT 1 FROM public.telegram_group_invites i
                      WHERE i.team_id = t.id AND i.route_key = 'team'
                        AND i.joined_at IS NULL AND i.revoked_at IS NULL);

  -- Take the old one down first, whether or not a new one is going up.
  SELECT setting_value::bigint INTO v_last_id
    FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'telegram_identify_nag_last_message_id';

  IF v_last_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_last_id);
    DELETE FROM public.settings
     WHERE agency_id = p_agency_id AND setting_key = 'telegram_identify_nag_last_message_id';
  END IF;

  IF v_names IS NULL OR array_length(v_names, 1) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'missing_count', 0, 'sent', false,
                              'deleted_previous', v_last_id IS NOT NULL);
  END IF;

  v_resp := public.telegram_send(
    'team',
    '👋 I cannot match these names to a Telegram account yet: '
    || array_to_string(v_names, ', ') || E'\n'
    || 'Send /iam and your first name in here so I can tie your messages to you. Example: /iam '
    || v_names[1],
    p_agency_id
  );

  v_new_id := (v_resp->'result'->>'message_id')::bigint;

  IF v_new_id IS NOT NULL THEN
    INSERT INTO public.settings (agency_id, setting_key, setting_value)
    VALUES (p_agency_id, 'telegram_identify_nag_last_message_id', v_new_id::text)
    ON CONFLICT (agency_id, setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;
  END IF;

  RETURN jsonb_build_object('ok', true, 'missing_count', array_length(v_names, 1),
                            'sent', true, 'message_id', v_new_id,
                            'deleted_previous', v_last_id IS NOT NULL,
                            'names', to_jsonb(v_names));
END;
$$;

COMMENT ON FUNCTION public.telegram_identify_nag(uuid, uuid) IS
  'Hourly through business hours. Names anyone on the agency team we cannot match to a Telegram account and asks them to run /iam. Deletes its own previous message first so the channel keeps one bubble and the repost still notifies. Skips people whose invite is still outstanding.';

DROP FUNCTION IF EXISTS public.telegram_identify_nag(uuid);

DELETE FROM public.settings
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND setting_key = 'telegram_identify_nag_last_sent';

-- ---------------------------------------------------------------------------
-- Sweep: invite on start date, and no longer carries the nag
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.telegram_group_sync(
  p_agency_id uuid,
  p_recipe_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_today    date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_r        RECORD;
  v_invited  jsonb := '[]'::jsonb;
  v_removed  jsonb := '[]'::jsonb;
BEGIN
  -- Invite on the START DATE. Agency members only - back office (category
  -- 'admin') is not in the team group. hire_date is a fallback for a record
  -- where start_date was never filled in.
  FOR v_r IN
    SELECT t.id, t.first_name, t.last_name
      FROM public.team t
     WHERE t.agency_id = p_agency_id
       AND t.is_active IS TRUE
       AND t.archived_at IS NULL
       AND coalesce(t.is_test_user, false) = false
       AND t.category = 'agency'
       AND t.telegram_user_id IS NULL
       AND coalesce(t.start_date, t.hire_date) IS NOT NULL
       AND coalesce(t.start_date, t.hire_date) <= v_today
       AND NOT EXISTS (SELECT 1 FROM public.telegram_group_invites i
                        WHERE i.team_id = t.id AND i.route_key = 'team' AND i.revoked_at IS NULL)
  LOOP
    v_invited := v_invited || jsonb_build_object(
      'name', btrim(coalesce(v_r.first_name,'') || ' ' || coalesce(v_r.last_name,'')),
      'result', public.telegram_group_invite_member(v_r.id, 'start_date')
    );
  END LOOP;

  -- Remove: anyone with a Telegram account on file who is no longer active.
  -- Deliberately not scoped to agency - whoever is in the group comes out.
  FOR v_r IN
    SELECT t.id, t.first_name, t.last_name
      FROM public.team t
     WHERE t.agency_id = p_agency_id
       AND t.telegram_user_id IS NOT NULL
       AND (t.is_active IS FALSE
            OR t.archived_at IS NOT NULL
            OR (t.end_date IS NOT NULL AND t.end_date < v_today))
       AND NOT EXISTS (SELECT 1 FROM public.telegram_group_removals r
                        WHERE r.team_id = t.id AND r.route_key = 'team')
  LOOP
    v_removed := v_removed || jsonb_build_object(
      'name', btrim(coalesce(v_r.first_name,'') || ' ' || coalesce(v_r.last_name,'')),
      'result', public.telegram_group_remove_member(v_r.id, 'terminated')
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'run_date', v_today,
    'invited_count', jsonb_array_length(v_invited),
    'removed_count', jsonb_array_length(v_removed),
    'invited', v_invited,
    'removed', v_removed
  );
END;
$$;

-- The invite row records the start date it fired on.
COMMENT ON COLUMN public.telegram_group_invites.hire_date IS
  'The start date the invite fired on (falls back to hire_date when start_date is null).';

-- ---------------------------------------------------------------------------
-- Recipe: hourly nag, weekdays, business hours. Rides the existing runner.
-- ---------------------------------------------------------------------------
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
   composio_action, internal_handler, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Telegram Identify Nag — Hourly',
       'Asks anyone on the agency team with no Telegram account on file to run /iam. Deletes its previous message each time.',
       'cron', '0 8-16 * * 1-5', 'America/Chicago',
       'INTERNAL', 'telegram_identify_nag', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND recipe_name = 'Telegram Identify Nag — Hourly'
);