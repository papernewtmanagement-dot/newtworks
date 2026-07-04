-- Migration: huddle_calendar_sync_recipe
-- Applied to production: 2026-07-04
--
-- Purpose: Ship the Google Calendar sync side of the huddle canonical system.
-- Adds event_first_date anchor (so time/duration edits don't shift recurrence
-- forward), huddle_calendar_sync() function (CREATE-or-UPDATE routing via
-- pg_net -> Composio v3), automation_recipes row + pg_cron */5 schedule.

-- Anchor date for the recurring event
ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS event_first_date DATE;

-- Include event_first_date in the sync-flag trigger
CREATE OR REPLACE FUNCTION public.trg_ahc_before_upd()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
BEGIN
  IF row(OLD.*) IS DISTINCT FROM row(NEW.*) THEN
    NEW.updated_at := NOW();
  END IF;
  IF (OLD.start_time_local, OLD.duration_regular_min, OLD.duration_fri_min,
      OLD.days_of_week, COALESCE(OLD.event_title,''), COALESCE(OLD.calendar_id,''),
      OLD.event_first_date)
     IS DISTINCT FROM
     (NEW.start_time_local, NEW.duration_regular_min, NEW.duration_fri_min,
      NEW.days_of_week, COALESCE(NEW.event_title,''), COALESCE(NEW.calendar_id,''),
      NEW.event_first_date) THEN
    NEW.calendar_needs_sync := true;
  END IF;
  RETURN NEW;
END;
$fn$;

-- Sync function: reads config, fires Composio call (CREATE or UPDATE), clears flag
CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(
  p_agency_id UUID DEFAULT '126794dd-25ff-47d2-a436-724499733365'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','net'
AS $fn$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb;
  v_start_ts text;
  v_action text;
  v_arguments jsonb;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id
    AND calendar_needs_sync = true
    AND calendar_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no rows flagged');
  END IF;

  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_googlecalendar_account_id';
  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;

  -- Attendees: both emails per active non-admin agency teammate
  SELECT jsonb_agg(email) INTO v_attendees FROM (
    SELECT email_sf AS email FROM public.team
    WHERE agency_id = p_agency_id AND category='agency'
      AND is_admin_backoffice=false AND is_active=true
      AND email_sf IS NOT NULL AND email_sf <> ''
    UNION ALL
    SELECT email_personal FROM public.team
    WHERE agency_id = p_agency_id AND category='agency'
      AND is_admin_backoffice=false AND is_active=true
      AND email_personal IS NOT NULL AND email_personal <> ''
  ) e;

  v_start_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
                || 'T' || TO_CHAR(v.start_time_local, 'HH24:MI:SS');

  IF v.calendar_event_id IS NULL THEN
    v_action := 'GOOGLECALENDAR_CREATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'summary',                v.event_title,
      'description',            'Story Agency team huddle. Managed by BCC agency_huddle_config. Rhythm + this week''s leader in BCC → Playbook → Team Huddle → Daily Rhythm.',
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'create_meeting_room',    true,
      'exclude_organizer',      true,
      'send_updates',           'all',
      'guestsCanInviteOthers',  false,
      'guestsCanSeeOtherGuests', true
    );
  ELSE
    v_action := 'GOOGLECALENDAR_UPDATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'event_id',               v.calendar_event_id,
      'summary',                v.event_title,
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'send_updates',           'all'
    );
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/' || v_action,
    headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'user_id',              v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments',            v_arguments
    )
  ) INTO v_pg_net_id;

  UPDATE public.agency_huddle_config
  SET calendar_needs_sync = false,
      calendar_last_synced_at = NOW()
  WHERE agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'status','dispatched',
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'start_datetime', v_start_ts
  );
END;
$fn$;

-- Recipe-signature overload for recipe-runner style invocation
CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id UUID, p_recipe_id UUID)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public','net'
AS $$
  SELECT public.huddle_calendar_sync(p_agency_id);
$$;

-- Register recipe (idempotent)
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression, composio_action, internal_handler,
  is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Huddle Calendar Sync',
  'Polls agency_huddle_config for calendar_needs_sync=true. Pushes changes to the Story Agency — Team Huddle Google Calendar via Composio v3 (GOOGLECALENDAR_CREATE_EVENT if event_id null, otherwise GOOGLECALENDAR_UPDATE_EVENT). Direct pg_cron + pg_net dispatch — no edge function. Leader field intentionally excluded from sync (leader displays only in the Daily Checklist summary, not on the calendar event). Anchor start-date pinned via event_first_date so time/duration edits don''t shift the recurrence forward.',
  'cron', '*/5 * * * *', 'INTERNAL', 'huddle_calendar_sync',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Huddle Calendar Sync'
);

-- pg_cron schedule (idempotent)
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'huddle_calendar_sync') THEN
    PERFORM cron.schedule(
      'huddle_calendar_sync',
      '*/5 * * * *',
      $c$SELECT public.huddle_calendar_sync('126794dd-25ff-47d2-a436-724499733365'::uuid);$c$
    );
  END IF;
END
$do$;
