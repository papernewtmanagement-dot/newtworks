-- Peter 2026-09-11, two changes:
--   1. Only agency members get invited to the team group. Leslie is category
--      'admin' (back office, paid by PaperNewt) and is not in the team group.
--      With that filter the old 2026-09-12 hire-date floor is no longer doing
--      any work, so it comes out - a backdated hire now gets invited properly.
--   2. Daily nag in the team group for anyone we cannot match to a Telegram
--      account, telling them to run /iam.

CREATE OR REPLACE FUNCTION public.telegram_identify_nag(
  p_agency_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_names   text[];
  v_last    timestamptz;
BEGIN
  -- Anyone active, agency, hired, with no Telegram account on file. Someone
  -- who still has an invite outstanding is skipped - they are not in the group
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
     AND t.hire_date IS NOT NULL
     AND t.hire_date <= (now() AT TIME ZONE 'America/Chicago')::date
     AND NOT EXISTS (SELECT 1 FROM public.telegram_group_invites i
                      WHERE i.team_id = t.id AND i.route_key = 'team'
                        AND i.joined_at IS NULL AND i.revoked_at IS NULL);

  IF v_names IS NULL OR array_length(v_names, 1) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'missing_count', 0, 'sent', false);
  END IF;

  -- One nag a day at most, even if the sweep is run by hand.
  SELECT setting_value::timestamptz INTO v_last
    FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'telegram_identify_nag_last_sent';

  IF v_last IS NOT NULL AND v_last > now() - interval '20 hours' THEN
    RETURN jsonb_build_object('ok', true, 'missing_count', array_length(v_names, 1),
                              'sent', false, 'reason', 'already nagged today');
  END IF;

  PERFORM public.telegram_send(
    'team',
    '👋 I cannot match these names to a Telegram account yet: '
    || array_to_string(v_names, ', ') || E'\n'
    || 'Send /iam and your first name in here so I can tie your messages to you. Example: /iam '
    || v_names[1],
    p_agency_id
  );

  INSERT INTO public.settings (agency_id, setting_key, setting_value)
  VALUES (p_agency_id, 'telegram_identify_nag_last_sent', now()::text)
  ON CONFLICT (agency_id, setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;

  RETURN jsonb_build_object('ok', true, 'missing_count', array_length(v_names, 1),
                            'sent', true, 'names', to_jsonb(v_names));
END;
$$;

COMMENT ON FUNCTION public.telegram_identify_nag(uuid) IS
  'Posts one message a day to the team group naming anyone we cannot match to a Telegram account, asking them to run /iam. Skips people with an invite still outstanding - they are not in the group yet.';

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
  v_nag      jsonb;
BEGIN
  -- Invite: agency members only. Back-office (category 'admin') is not in the
  -- team group and never gets an invite.
  FOR v_r IN
    SELECT t.id, t.first_name, t.last_name
      FROM public.team t
     WHERE t.agency_id = p_agency_id
       AND t.is_active IS TRUE
       AND t.archived_at IS NULL
       AND coalesce(t.is_test_user, false) = false
       AND t.category = 'agency'
       AND t.telegram_user_id IS NULL
       AND t.hire_date IS NOT NULL
       AND t.hire_date <= v_today
       AND NOT EXISTS (SELECT 1 FROM public.telegram_group_invites i
                        WHERE i.team_id = t.id AND i.route_key = 'team' AND i.revoked_at IS NULL)
  LOOP
    v_invited := v_invited || jsonb_build_object(
      'name', btrim(coalesce(v_r.first_name,'') || ' ' || coalesce(v_r.last_name,'')),
      'result', public.telegram_group_invite_member(v_r.id, 'hire_date')
    );
  END LOOP;

  -- Remove: anyone with a Telegram account on file who is no longer active.
  -- Not scoped to agency - if a back-office person is in the group and leaves,
  -- they still come out.
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

  v_nag := public.telegram_identify_nag(p_agency_id);

  RETURN jsonb_build_object(
    'ok', true,
    'run_date', v_today,
    'invited_count', jsonb_array_length(v_invited),
    'removed_count', jsonb_array_length(v_removed),
    'invited', v_invited,
    'removed', v_removed,
    'identify_nag', v_nag
  );
END;
$$;