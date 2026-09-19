-- When the OWNER ticks a shared team checklist item, the team is told.
-- Peter 2026-09-18: "If I check something off for the team checklist, there
-- should be a way of highlighting this to the team so they know that I did it."
--
-- One Telegram message per day to the team group, EDITED IN PLACE as he clears
-- more, so the chat never fills up. Untick everything and the message is removed.
-- The checklist row itself also marks an owner tick so it stands out on screen.

-- One place that answers "is this team member the owner".
CREATE OR REPLACE FUNCTION public.team_is_owner(p_team_member uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(t.role_level, '') = 'Owner'
  FROM public.team t
  WHERE t.id = p_team_member;
$function$;

-- Holds the one message per day so it can be edited instead of reposted.
-- RLS on with no policies: reached only through SECURITY DEFINER functions.
CREATE TABLE IF NOT EXISTS public.checklist_owner_notices (
  agency_id   uuid        NOT NULL,
  notice_date date        NOT NULL,
  chat_id     bigint      NOT NULL,
  message_id  bigint      NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, notice_date)
);
ALTER TABLE public.checklist_owner_notices ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.checklist_owner_clear_notify(p_agency_id uuid, p_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_chat   bigint;
  v_msg    bigint;
  v_lines  text;
  v_count  int;
  v_who    text;
  v_text   text;
  v_resp   jsonb;
BEGIN
  SELECT c.chat_id, c.message_id INTO v_chat, v_msg
  FROM public.checklist_owner_notices c
  WHERE c.agency_id = p_agency_id AND c.notice_date = p_date;

  SELECT string_agg('• ' || i.title, E'\n' ORDER BY i.sort_order, i.title),
         count(*)::int,
         max(COALESCE(NULLIF(tm.nickname, ''), tm.first_name))
  INTO v_lines, v_count, v_who
  FROM public.daily_checklist_ticks k
  JOIN public.checklist_items i ON i.id = k.item_id
  JOIN public.team tm           ON tm.id = k.ticked_by
  WHERE k.agency_id = p_agency_id
    AND k.tick_date = p_date
    AND i.scope     = 'team'
    AND public.team_is_owner(k.ticked_by);

  -- Nothing left on the list: take the message down.
  IF COALESCE(v_count, 0) = 0 THEN
    IF v_msg IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat, v_msg);
      DELETE FROM public.checklist_owner_notices
      WHERE agency_id = p_agency_id AND notice_date = p_date;
    END IF;
    RETURN jsonb_build_object('ok', true, 'items', 0);
  END IF;

  v_text := '✅ ' || COALESCE(v_who, 'The owner')
            || ' cleared these off the team list today:' || E'\n' || v_lines;

  IF v_msg IS NOT NULL THEN
    v_resp := public.telegram_edit_message_text(v_chat, v_msg, v_text);
    IF COALESCE((v_resp->>'ok')::boolean, false) THEN
      UPDATE public.checklist_owner_notices
      SET updated_at = now()
      WHERE agency_id = p_agency_id AND notice_date = p_date;
      RETURN jsonb_build_object('ok', true, 'items', v_count, 'edited', true);
    END IF;
    -- Edit failed (message gone, or the text was already identical). Drop the
    -- record so the next tick starts a fresh message rather than going silent.
    DELETE FROM public.checklist_owner_notices
    WHERE agency_id = p_agency_id AND notice_date = p_date;
    IF COALESCE(v_resp->'description' ->> 0, v_resp->>'description') ILIKE '%not modified%' THEN
      RETURN jsonb_build_object('ok', true, 'items', v_count, 'edited', false);
    END IF;
    v_msg := NULL;
  END IF;

  v_resp := public.telegram_send('team', v_text, p_agency_id);
  IF COALESCE((v_resp->>'ok')::boolean, false) THEN
    INSERT INTO public.checklist_owner_notices (agency_id, notice_date, chat_id, message_id)
    VALUES (p_agency_id, p_date,
            (v_resp->'result'->'chat'->>'id')::bigint,
            (v_resp->'result'->>'message_id')::bigint)
    ON CONFLICT (agency_id, notice_date)
    DO UPDATE SET chat_id    = EXCLUDED.chat_id,
                  message_id = EXCLUDED.message_id,
                  updated_at = now();
    RETURN jsonb_build_object('ok', true, 'items', v_count, 'sent', true);
  END IF;

  RETURN jsonb_build_object('ok', false, 'items', v_count, 'response', v_resp);
END;
$function$;

-- Tick: fire the notice when the OWNER changes a TEAM item for today.
CREATE OR REPLACE FUNCTION public.daily_checklist_tick(p_item_id uuid, p_date date, p_on boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_scope text;
  v_key text;
  v_for uuid;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  IF p_date IS NULL OR p_date > v_today OR p_date < v_today - 14 THEN
    RAISE EXCEPTION 'tick date must be within the last two weeks' USING ERRCODE = '22023';
  END IF;
  SELECT i.scope, i.item_key INTO v_scope, v_key
  FROM public.checklist_items i WHERE i.id = p_item_id AND i.agency_id = v_agency;
  IF v_scope IS NULL THEN
    RAISE EXCEPTION 'unknown checklist item' USING ERRCODE = '22023';
  END IF;

  -- A personal item is ticked once per person. A team item stays one shared tick.
  v_for := CASE WHEN v_scope = 'personal' THEN v_me ELSE NULL END;

  IF p_on THEN
    INSERT INTO public.daily_checklist_ticks (agency_id, item_id, tick_date, ticked_by, ticked_for, ticked_at)
    VALUES (v_agency, p_item_id, p_date, v_me, v_for, now())
    ON CONFLICT (agency_id, item_id, tick_date, COALESCE(ticked_for, '00000000-0000-0000-0000-000000000000'::uuid))
    DO NOTHING;
  ELSE
    DELETE FROM public.daily_checklist_ticks
    WHERE agency_id = v_agency AND item_id = p_item_id AND tick_date = p_date
      AND ticked_for IS NOT DISTINCT FROM v_for;
  END IF;

  IF v_scope = 'personal' AND v_key = 'inbox' THEN
    PERFORM public.sync_wrapup_inbox_done(v_me, p_date);
  END IF;

  -- The owner clearing a shared item for the team gets told to the team, so
  -- nobody does the work twice. A Telegram failure must never fail the tick.
  IF v_scope = 'team' AND p_date = v_today AND public.team_is_owner(v_me) THEN
    BEGIN
      PERFORM public.checklist_owner_clear_notify(v_agency, p_date);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'checklist_owner_clear_notify failed: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'item_id', p_item_id, 'date', p_date, 'on', p_on, 'scope', v_scope);
END;
$function$;

-- State: mark which team rows the owner ticked, so the row can say so loudly.
CREATE OR REPLACE FUNCTION public.daily_checklist_state(p_date date DEFAULT NULL::date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_me uuid := public.current_team_member_id();
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_day date;
  v_week_end date;
  v_week_start date;
  v_prev date;
  v_leader text;
  v_items jsonb;
  v_personal jsonb;
  v_carry jsonb;
  v_last_workday boolean;
BEGIN
  v_day := COALESCE(p_date, v_today);
  IF v_day > v_today THEN v_day := v_today; END IF;
  IF NOT public.checklist_is_workday(v_agency, v_day) THEN
    v_day := COALESCE(public.checklist_prev_workday(v_agency, v_day), v_day);
  END IF;
  v_week_end := v_day + (6 - EXTRACT(DOW FROM v_day)::int);
  v_week_start := v_week_end - 6;
  v_prev := public.checklist_prev_workday(v_agency, v_day);

  -- No workday left in this CPR week after today, so the week wraps here.
  SELECT NOT EXISTS (
    SELECT 1 FROM generate_series(v_day + 1, v_week_end, interval '1 day') g
    WHERE public.checklist_is_workday(v_agency, g::date)
  ) INTO v_last_workday;

  SELECT COALESCE(NULLIF(t.nickname, ''), t.first_name) INTO v_leader
  FROM public.agency_huddle_config c
  JOIN public.team t ON t.id = c.current_week_leader_team_id
  WHERE c.agency_id = v_agency;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'title', i.title, 'sort_order', i.sort_order,
           'help_text', i.help_text, 'help_excerpt_id', i.help_excerpt_id,
           'link_url', i.link_url,
           'ticked_by', COALESCE(NULLIF(tm.nickname, ''), tm.first_name),
           'by_owner', COALESCE(public.team_is_owner(k.ticked_by), false),
           'ticked_at', k.ticked_at) ORDER BY i.sort_order, i.title), '[]'::jsonb)
  INTO v_items
  FROM public.checklist_items_for_week(v_agency, v_week_end) i
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_day
  LEFT JOIN public.team tm ON tm.id = k.ticked_by;

  -- Personal items: everyone ticks their own, and the whole team sees who has.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'title', i.title, 'sort_order', i.sort_order,
           'help_text', i.help_text, 'help_excerpt_id', i.help_excerpt_id,
           'link_url', i.link_url,
           'mine', EXISTS (
             SELECT 1 FROM public.daily_checklist_ticks k
             WHERE k.item_id = i.id AND k.tick_date = v_day AND k.ticked_for = v_me
           ),
           'ticked_by', COALESCE((
             SELECT jsonb_agg(nm ORDER BY nm)
             FROM (
               SELECT COALESCE(NULLIF(tm.nickname, ''), tm.first_name) AS nm
               FROM public.daily_checklist_ticks k
               JOIN public.team tm ON tm.id = k.ticked_for
               WHERE k.item_id = i.id AND k.tick_date = v_day
             ) s
           ), '[]'::jsonb)
         ) ORDER BY i.sort_order, i.title), '[]'::jsonb)
  INTO v_personal
  FROM public.checklist_items i
  WHERE i.agency_id = v_agency AND i.scope = 'personal'
    AND i.effective_from <= v_week_end
    AND (i.effective_to IS NULL OR i.effective_to >= v_week_end);

  IF v_prev IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title) ORDER BY i.sort_order, i.title), '[]'::jsonb)
    INTO v_carry
    FROM public.checklist_items_for_week(v_agency, v_prev + (6 - EXTRACT(DOW FROM v_prev)::int)) i
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
    WHERE k.id IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'date', v_day,
    'today', v_today,
    'is_today', v_day = v_today,
    'label', to_char(v_day, 'Dy Mon FMDD'),
    'me', v_me,
    'leader', v_leader,
    'can_edit', COALESCE(public.current_app_user_role() = 'owner', false),
    'week_ending', v_week_end,
    'is_last_workday', COALESCE(v_last_workday, false),
    'items', v_items,
    'personal', v_personal,
    'carry', CASE WHEN v_prev IS NULL THEN NULL
                  ELSE jsonb_build_object('date', v_prev, 'label', to_char(v_prev, 'Dy Mon FMDD'), 'open', COALESCE(v_carry, '[]'::jsonb)) END
  );
END;
$function$;
