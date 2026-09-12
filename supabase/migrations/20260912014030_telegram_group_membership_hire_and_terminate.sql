-- Telegram team group membership follows Newtworks.
-- Invite lands on the effective hire date, never before. Removal fires on termination.
--
-- HARD TELEGRAM LIMIT: a bot cannot add a person to a group. The only path a bot
-- has is a single-use invite link. So "invite" here means: create a one-person
-- link that expires in 7 days, email it to the new hire, and copy it to the admin
-- group so Peter can text it if the email does not land.

CREATE TABLE IF NOT EXISTS public.telegram_group_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  route_key text NOT NULL DEFAULT 'team',
  invite_link text NOT NULL,
  invite_name text NOT NULL,
  hire_date date,
  reason text,
  expires_at timestamptz,
  emailed_to text,
  email_request_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  joined_at timestamptz,
  joined_telegram_user_id bigint,
  revoked_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_tg_invite_live
  ON public.telegram_group_invites (agency_id, team_id, route_key)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_tg_invite_link
  ON public.telegram_group_invites (invite_link);

CREATE TABLE IF NOT EXISTS public.telegram_group_removals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  route_key text NOT NULL DEFAULT 'team',
  telegram_user_id bigint,
  removed_at timestamptz NOT NULL DEFAULT now(),
  reason text,
  api_result jsonb
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_tg_removal_once
  ON public.telegram_group_removals (agency_id, team_id, route_key);

ALTER TABLE public.telegram_group_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.telegram_group_removals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS telegram_group_invites_read ON public.telegram_group_invites;
CREATE POLICY telegram_group_invites_read ON public.telegram_group_invites FOR SELECT USING (true);
DROP POLICY IF EXISTS telegram_group_invites_service_all ON public.telegram_group_invites;
CREATE POLICY telegram_group_invites_service_all ON public.telegram_group_invites FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS telegram_group_removals_read ON public.telegram_group_removals;
CREATE POLICY telegram_group_removals_read ON public.telegram_group_removals FOR SELECT USING (true);
DROP POLICY IF EXISTS telegram_group_removals_service_all ON public.telegram_group_removals;
CREATE POLICY telegram_group_removals_service_all ON public.telegram_group_removals FOR ALL USING (true) WITH CHECK (true);

COMMENT ON TABLE public.telegram_group_invites IS
  'One row per team-group invite link issued to a new hire. A bot cannot add someone to a Telegram group, so the link is the mechanism. revoked_at set when the person is terminated or the link is pulled.';
COMMENT ON TABLE public.telegram_group_removals IS
  'One row per person removed from a Telegram group. Unique on (agency, team member, route) so a removal never fires twice.';

-- ---------------------------------------------------------------------------
-- Invite one person
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.telegram_group_invite_member(
  p_team_id uuid,
  p_reason text DEFAULT 'hire_date'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_t        RECORD;
  v_route    RECORD;
  v_name     text;
  v_expire   bigint;
  v_resp     jsonb;
  v_link     text;
  v_req      bigint;
  v_full     text;
  v_emailed  text := NULL;
BEGIN
  SELECT * INTO v_t FROM public.team WHERE id = p_team_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team row not found');
  END IF;

  IF v_t.telegram_user_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'already linked to a telegram account');
  END IF;

  IF EXISTS (SELECT 1 FROM public.telegram_group_invites i
              WHERE i.team_id = p_team_id AND i.route_key = 'team' AND i.revoked_at IS NULL) THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'invite already issued');
  END IF;

  SELECT * INTO v_route FROM public.telegram_routes
   WHERE agency_id = v_t.agency_id AND route_key = 'team' AND is_active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team route missing');
  END IF;

  v_full := btrim(coalesce(v_t.first_name, '') || ' ' || coalesce(v_t.last_name, ''));
  -- Telegram caps the invite-link name at 32 characters.
  v_name := left('Newtworks ' || v_full, 32);
  v_expire := extract(epoch FROM now() + interval '7 days')::bigint;

  v_resp := public.telegram_api_call(
    'createChatInviteLink',
    jsonb_build_object(
      'chat_id', v_route.chat_id,
      'name', v_name,
      'member_limit', 1,
      'expire_date', v_expire
    ),
    v_route.bot
  );

  IF (v_resp->>'ok')::boolean IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'createChatInviteLink failed', 'response', v_resp);
  END IF;

  v_link := v_resp->'result'->>'invite_link';

  IF v_t.email_personal IS NOT NULL AND btrim(v_t.email_personal) <> '' THEN
    BEGIN
      v_req := public.composio_send_email(
        v_t.agency_id,
        v_t.email_personal,
        'Join the team Telegram group',
        '<p>Hi ' || coalesce(v_t.first_name, 'there') || ',</p>'
        || '<p>Welcome aboard. The team runs its daily check-ins in a Telegram group.</p>'
        || '<p>1. Install Telegram on your phone and set up your account.<br>'
        || '2. Tap this link to join the group:<br>'
        || '<a href="' || v_link || '">' || v_link || '</a></p>'
        || '<p>The link works one time, for you only, and expires in 7 days.</p>'
        || '<p>Any trouble, text Peter.</p>'
      );
      v_emailed := v_t.email_personal;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'invite email failed for %: %', p_team_id, SQLERRM;
    END;
  END IF;

  INSERT INTO public.telegram_group_invites
    (agency_id, team_id, route_key, invite_link, invite_name, hire_date, reason,
     expires_at, emailed_to, email_request_id)
  VALUES
    (v_t.agency_id, p_team_id, 'team', v_link, v_name, v_t.hire_date, p_reason,
     now() + interval '7 days', v_emailed, v_req);

  PERFORM public.telegram_send(
    'admin',
    '🆕 ' || v_full || ' starts today.' || E'\n'
    || CASE WHEN v_emailed IS NOT NULL
            THEN 'Telegram group invite emailed to ' || v_emailed || '.'
            ELSE 'No personal email on file, so nothing was emailed. Send this yourself.' END
    || E'\n' || v_link || E'\n'
    || 'One use, expires in 7 days.',
    v_t.agency_id
  );

  RETURN jsonb_build_object('ok', true, 'team_id', p_team_id, 'invite_link', v_link, 'emailed_to', v_emailed);
END;
$$;

-- ---------------------------------------------------------------------------
-- Remove one person
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.telegram_group_remove_member(
  p_team_id uuid,
  p_reason text DEFAULT 'terminated'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_t      RECORD;
  v_route  RECORD;
  v_ban    jsonb := NULL;
  v_unban  jsonb := NULL;
  v_inv    RECORD;
  v_full   text;
BEGIN
  SELECT * INTO v_t FROM public.team WHERE id = p_team_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team row not found');
  END IF;

  IF EXISTS (SELECT 1 FROM public.telegram_group_removals r
              WHERE r.team_id = p_team_id AND r.route_key = 'team') THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'already removed');
  END IF;

  SELECT * INTO v_route FROM public.telegram_routes
   WHERE agency_id = v_t.agency_id AND route_key = 'team' AND is_active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team route missing');
  END IF;

  v_full := btrim(coalesce(v_t.first_name, '') || ' ' || coalesce(v_t.last_name, ''));

  -- Pull any invite link still outstanding so it cannot be used after the fact.
  FOR v_inv IN
    SELECT * FROM public.telegram_group_invites
     WHERE team_id = p_team_id AND route_key = 'team' AND revoked_at IS NULL
  LOOP
    PERFORM public.telegram_api_call(
      'revokeChatInviteLink',
      jsonb_build_object('chat_id', v_route.chat_id, 'invite_link', v_inv.invite_link),
      v_route.bot
    );
    UPDATE public.telegram_group_invites SET revoked_at = now() WHERE id = v_inv.id;
  END LOOP;

  IF v_t.telegram_user_id IS NOT NULL THEN
    -- Ban then unban is the kick. Unban leaves them able to rejoin on a future
    -- invite instead of being blocked forever.
    v_ban := public.telegram_api_call(
      'banChatMember',
      jsonb_build_object('chat_id', v_route.chat_id, 'user_id', v_t.telegram_user_id, 'revoke_messages', false),
      v_route.bot
    );
    v_unban := public.telegram_api_call(
      'unbanChatMember',
      jsonb_build_object('chat_id', v_route.chat_id, 'user_id', v_t.telegram_user_id, 'only_if_banned', true),
      v_route.bot
    );
  END IF;

  INSERT INTO public.telegram_group_removals
    (agency_id, team_id, route_key, telegram_user_id, reason, api_result)
  VALUES
    (v_t.agency_id, p_team_id, 'team', v_t.telegram_user_id, p_reason,
     jsonb_build_object('ban', v_ban, 'unban', v_unban))
  ON CONFLICT DO NOTHING;

  PERFORM public.telegram_send(
    'admin',
    '👋 ' || v_full || ' removed from the team Telegram group.' || E'\n'
    || 'Reason: ' || coalesce(p_reason, 'terminated') || '.'
    || CASE WHEN v_t.telegram_user_id IS NULL
            THEN E'\nNo Telegram account was on file, so only the invite link was pulled.'
            ELSE '' END,
    v_t.agency_id
  );

  RETURN jsonb_build_object('ok', true, 'team_id', p_team_id, 'ban', v_ban, 'unban', v_unban);
END;
$$;

-- ---------------------------------------------------------------------------
-- Daily sweep: invite anyone whose hire date has landed, remove anyone terminated
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
  -- Nothing hired before this date gets a retroactive invite. The feature went
  -- live 2026-09-12; without this floor the sweep would invite long-tenured
  -- people who simply have no Telegram account on file.
  v_floor    date := DATE '2026-09-12';
  v_r        RECORD;
  v_invited  jsonb := '[]'::jsonb;
  v_removed  jsonb := '[]'::jsonb;
BEGIN
  FOR v_r IN
    SELECT t.id, t.first_name, t.last_name
      FROM public.team t
     WHERE t.agency_id = p_agency_id
       AND t.is_active IS TRUE
       AND t.archived_at IS NULL
       AND coalesce(t.is_test_user, false) = false
       AND t.telegram_user_id IS NULL
       AND t.hire_date IS NOT NULL
       AND t.hire_date <= v_today
       AND t.hire_date >= greatest(v_today - 7, v_floor)
       AND NOT EXISTS (SELECT 1 FROM public.telegram_group_invites i
                        WHERE i.team_id = t.id AND i.route_key = 'team' AND i.revoked_at IS NULL)
  LOOP
    v_invited := v_invited || jsonb_build_object(
      'name', btrim(coalesce(v_r.first_name,'') || ' ' || coalesce(v_r.last_name,'')),
      'result', public.telegram_group_invite_member(v_r.id, 'hire_date')
    );
  END LOOP;

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

-- ---------------------------------------------------------------------------
-- Immediate offboard the moment someone is marked inactive or archived
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_team_telegram_offboard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF (NEW.is_active IS FALSE AND coalesce(OLD.is_active, true) IS TRUE)
     OR (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL) THEN
    BEGIN
      PERFORM public.telegram_group_remove_member(NEW.id, 'terminated');
    EXCEPTION WHEN OTHERS THEN
      -- A Telegram hiccup must never roll back the termination itself.
      RAISE WARNING 'telegram offboard failed for %: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS team_telegram_offboard ON public.team;
CREATE TRIGGER team_telegram_offboard
AFTER UPDATE ON public.team
FOR EACH ROW
EXECUTE FUNCTION public.trg_team_telegram_offboard();

-- Backfill: people already terminated are already out of the group (verified
-- 2026-09-11 via getChatMember). Log them so the first sweep stays silent.
INSERT INTO public.telegram_group_removals
  (agency_id, team_id, route_key, telegram_user_id, removed_at, reason)
SELECT t.agency_id, t.id, 'team', t.telegram_user_id,
       coalesce(t.archived_at, t.end_date::timestamptz, now()),
       'backfill - confirmed already out of the group on 2026-09-11'
  FROM public.team t
 WHERE t.telegram_user_id IS NOT NULL
   AND (t.is_active IS FALSE OR t.archived_at IS NOT NULL)
ON CONFLICT DO NOTHING;

-- Daily recipe. Rides the hourly automation runner, fires in the 7am Central tick.
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
   composio_action, internal_handler, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Telegram Group Membership Sync',
       'Invites a new hire to the team Telegram group on their hire date and removes anyone terminated.',
       'cron', '0 7 * * *', 'America/Chicago',
       'INTERNAL', 'telegram_group_sync', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND recipe_name = 'Telegram Group Membership Sync'
);