-- Telegram group removal fires on a real termination only (Peter 2026-09-25):
-- "I want actual terminations to do plenty of things, including removing
-- someone from Telegram. But I don't want that done on team members who
-- haven't been terminated."
--   * Trigger: archived_at being set is the termination signal. The Terminate
--     button (terminate-team-member) always sets it. is_active going false on
--     its own no longer removes anyone (pre-start hires sit at is_active false).
--   * Daily sweep: archived, or end_date passed. Not is_active alone.
--   * "Already removed" now means removed since this departure, so someone
--     reactivated on the Team page and terminated again is removed again. The
--     one-row-per-person unique index goes; the check lives in one place,
--     telegram_group_remove_member, which the sweep now just calls.
--   * newtworks.dry_run = 'on' makes telegram_group_remove_member skip every
--     Telegram call and record a dry-run row (the switch comp_net_deposit_notice
--     already honors), so the path can be tested without touching anyone.

CREATE OR REPLACE FUNCTION public.telegram_group_remove_member(p_team_id uuid, p_reason text DEFAULT 'terminated'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Removes one person from the team Telegram group: pulls any outstanding
-- invite link, kicks (ban then unban, so a future invite still works), logs a
-- row in telegram_group_removals and posts one line to the admin group.
-- Skips when this departure is already handled: a removal row at or after the
-- moment they left (the earlier of archived_at and end_date). A removal from
-- an earlier stint does not count, so someone reactivated on the Team page and
-- terminated again is removed again.
-- newtworks.dry_run = 'on' (the switch comp_net_deposit_notice honors): no
-- Telegram call at all, invites left alone, the row is recorded with
-- api_result.dry_run = true, and the skip check ignores dry-run rows.
DECLARE
  v_t      RECORD;
  v_route  RECORD;
  v_ban    jsonb := NULL;
  v_unban  jsonb := NULL;
  v_inv    RECORD;
  v_full   text;
  v_left   timestamptz;
  v_dry    boolean := coalesce(current_setting('newtworks.dry_run', true), '') = 'on';
  v_links  int := 0;
BEGIN
  SELECT * INTO v_t FROM public.team WHERE id = p_team_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team row not found');
  END IF;

  v_left := least(v_t.archived_at, v_t.end_date::timestamptz);

  IF EXISTS (SELECT 1 FROM public.telegram_group_removals r
              WHERE r.team_id = p_team_id AND r.route_key = 'team'
                AND r.removed_at >= coalesce(v_left, '-infinity'::timestamptz)
                AND NOT coalesce((r.api_result->>'dry_run')::boolean, false)) THEN
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
    v_links := v_links + 1;
    IF NOT v_dry THEN
      PERFORM public.telegram_api_call(
        'revokeChatInviteLink',
        jsonb_build_object('chat_id', v_route.chat_id, 'invite_link', v_inv.invite_link),
        v_route.bot
      );
      UPDATE public.telegram_group_invites SET revoked_at = now() WHERE id = v_inv.id;
    END IF;
  END LOOP;

  IF v_t.telegram_user_id IS NOT NULL AND NOT v_dry THEN
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
     CASE WHEN v_dry
          THEN jsonb_build_object('dry_run', true, 'would_kick', v_t.telegram_user_id IS NOT NULL, 'would_revoke_links', v_links)
          ELSE jsonb_build_object('ban', v_ban, 'unban', v_unban) END);

  IF NOT v_dry THEN
    PERFORM public.telegram_send(
      'admin',
      '👋 ' || v_full || ' removed from the team Telegram group.' || E'\n'
      || 'Reason: ' || coalesce(p_reason, 'terminated') || '.'
      || CASE WHEN v_t.telegram_user_id IS NULL
              THEN E'\nNo Telegram account was on file, so only the invite link was pulled.'
              ELSE '' END,
      v_t.agency_id
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'team_id', p_team_id, 'dry_run', v_dry, 'ban', v_ban, 'unban', v_unban);
END;
$function$;

DROP INDEX IF EXISTS public.ux_tg_removal_once;
CREATE INDEX IF NOT EXISTS ix_tg_removal_team ON public.telegram_group_removals (team_id, route_key, removed_at DESC);
COMMENT ON TABLE public.telegram_group_removals IS
  'One row per removal from a Telegram group. Someone reactivated and terminated again gets a second row; telegram_group_remove_member skips only when this departure already has a (non-dry-run) row.';

CREATE OR REPLACE FUNCTION public.trg_team_telegram_offboard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Deferred constraint trigger: runs at COMMIT, never on ROLLBACK, because
-- telegram_group_remove_member calls Telegram live and a live call cannot be
-- taken back. Fires on a termination only: archived_at being set, which the
-- Terminate button always does (Peter 2026-09-25: terminated people come out,
-- nobody else). Reads the row as it stands at commit, so someone archived and
-- restored in the same transaction is left alone.
DECLARE
  v_archived boolean;
BEGIN
  SELECT (t.archived_at IS NOT NULL)
    INTO v_archived
    FROM public.team t
   WHERE t.id = NEW.id;
  IF v_archived IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  BEGIN
    PERFORM public.telegram_group_remove_member(NEW.id, 'terminated');
  EXCEPTION WHEN OTHERS THEN
    -- A Telegram hiccup must never block the termination itself.
    RAISE WARNING 'telegram offboard failed for %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS team_telegram_offboard ON public.team;
CREATE CONSTRAINT TRIGGER team_telegram_offboard
  AFTER UPDATE ON public.team
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL)
  EXECUTE FUNCTION public.trg_team_telegram_offboard();

CREATE OR REPLACE FUNCTION public.telegram_group_sync(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today    date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_r        RECORD;
  v_res      jsonb;
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

  -- Remove: anyone with a Telegram account on file who has been terminated -
  -- archived, or their end date has passed. is_active going false on its own
  -- is not a termination (Peter 2026-09-25). Not scoped to agency - whoever is
  -- in the group comes out. Whether this departure is already handled is
  -- decided in one place, telegram_group_remove_member; only real removals
  -- are listed.
  FOR v_r IN
    SELECT t.id, t.first_name, t.last_name
      FROM public.team t
     WHERE t.agency_id = p_agency_id
       AND t.telegram_user_id IS NOT NULL
       AND (t.archived_at IS NOT NULL
            OR (t.end_date IS NOT NULL AND t.end_date < v_today))
  LOOP
    v_res := public.telegram_group_remove_member(v_r.id, 'terminated');
    IF v_res->>'skipped' IS NULL THEN
      v_removed := v_removed || jsonb_build_object(
        'name', btrim(coalesce(v_r.first_name,'') || ' ' || coalesce(v_r.last_name,'')),
        'result', v_res
      );
    END IF;
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
$function$;
