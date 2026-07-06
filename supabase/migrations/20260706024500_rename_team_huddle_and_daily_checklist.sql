-- Rename "Team Huddle" → "Daily Kickoff" and "Daily Checklist" → "Daily Wrap-up"
-- Reorder top-level Processes to: Kickoff, Training, FIT, Reception, Retention Tasks, Retention Appts, Wrap-up

-- 1. Processes titles (2 rows)
UPDATE public.processes
SET title = 'Daily Kickoff', updated_at = NOW()
WHERE id = 'a80fdcc1-1928-488a-bb5d-0cf62a9524ec';

UPDATE public.processes
SET title = 'Daily Wrap-up', updated_at = NOW()
WHERE id = 'e427ccf0-1907-4b6a-8e7a-3e9376f3ac7b';

-- 2. Processes content (case-preserved replacements across every content row)
UPDATE public.processes
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
        content,
        'Team Huddle',      'Daily Kickoff'),
        'team huddle',      'daily kickoff'),
        'Daily Checklist',  'Daily Wrap-up'),
        'daily checklist',  'daily wrap-up'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND (content ILIKE '%huddle%' OR content ILIKE '%daily checklist%');

-- 3. Handbook content
UPDATE public.handbook
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
        content,
        'Team Huddle',      'Daily Kickoff'),
        'team huddle',      'daily kickoff'),
        'Daily Checklist',  'Daily Wrap-up'),
        'daily checklist',  'daily wrap-up'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND (content ILIKE '%huddle%' OR content ILIKE '%daily checklist%');

-- 4. Admin pages content
UPDATE public.admin_pages
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
        content,
        'Team Huddle',      'Daily Kickoff'),
        'team huddle',      'daily kickoff'),
        'Daily Checklist',  'Daily Wrap-up'),
        'daily checklist',  'daily wrap-up'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND (content ILIKE '%huddle%' OR content ILIKE '%daily checklist%');

-- 5. Reorder top-level Processes (sort_order)
UPDATE public.processes SET sort_order = 10, updated_at = NOW() WHERE id = 'a80fdcc1-1928-488a-bb5d-0cf62a9524ec'; -- Daily Kickoff
UPDATE public.processes SET sort_order = 20, updated_at = NOW() WHERE id = 'f998ea64-f5c7-4242-a30d-e65428f84205'; -- Training
UPDATE public.processes SET sort_order = 30, updated_at = NOW() WHERE id = 'c129f8b1-c128-4699-84b4-301cf9df0946'; -- FIT Conversations
UPDATE public.processes SET sort_order = 40, updated_at = NOW() WHERE id = 'a5d5e94a-7957-4dcd-aca0-7098d058b5bc'; -- Reception
UPDATE public.processes SET sort_order = 50, updated_at = NOW() WHERE id = '73db6711-3798-43b8-b1d0-6b889ceb5c1b'; -- Retention Tasks
UPDATE public.processes SET sort_order = 60, updated_at = NOW() WHERE id = '44ae4147-389e-4dd5-82d0-3df20f8cb6cb'; -- Retention Appointments
UPDATE public.processes SET sort_order = 70, updated_at = NOW() WHERE id = 'e427ccf0-1907-4b6a-8e7a-3e9376f3ac7b'; -- Daily Wrap-up

-- 6. Huddle config event_title — triggers calendar_needs_sync=true via BEFORE trigger
UPDATE public.agency_huddle_config
SET event_title = 'Daily Kickoff', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 7. Automation recipe rename
UPDATE public.automation_recipes
SET recipe_name = 'Daily Kickoff Calendar Sync',
    recipe_description = 'Polls agency_huddle_config for calendar_needs_sync=true. Pushes changes to the Story Agency — Daily Kickoff Google Calendar via Composio v3 (GOOGLECALENDAR_CREATE_EVENT if event_id null, otherwise GOOGLECALENDAR_UPDATE_EVENT). Direct pg_cron + pg_net dispatch — no edge function. Leader field intentionally excluded from sync (leader displays only in the Daily Wrap-up summary, not on the calendar event). Anchor start-date pinned via event_first_date so time/duration edits do not shift the recurrence forward.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Huddle Calendar Sync';

-- 8. Fix render function: replace stale "Team Huddle" and "Playbook" references
CREATE OR REPLACE FUNCTION public.render_huddle_summary_md(p_agency_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_time TEXT;
  v_days TEXT;
  v_leader_name TEXT;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config WHERE agency_id = p_agency_id;
  IF NOT FOUND THEN
    RETURN '⚠️ Kickoff config not set.';
  END IF;

  v_time := TO_CHAR(v.start_time_local, 'FMHH12:MI AM');

  IF v.days_of_week @> ARRAY['MO','TU','WE','TH','FR']
     AND array_length(v.days_of_week, 1) = 5 THEN
    v_days := 'every weekday';
  ELSE
    v_days := array_to_string(v.days_of_week, ', ');
  END IF;

  IF v.current_week_leader_team_id IS NOT NULL THEN
    SELECT COALESCE(NULLIF(nickname,''), first_name) INTO v_leader_name
    FROM public.team WHERE id = v.current_week_leader_team_id;
  END IF;

  RETURN
    '**📅 ' || v_time || ' ' || v_days || '** — '
    || v.duration_regular_min || ' min Mon–Thu, '
    || v.duration_fri_min || ' min Fri retrospective'
    || CASE WHEN COALESCE(v.meeting_notes,'') <> ''
            THEN E'  \n*' || v.meeting_notes || '*'
            ELSE '' END
    || E'\n\n👤 **This week''s leader:** '
       || COALESCE(v_leader_name, '_not set — UPDATE `agency_huddle_config.current_week_leader_team_id` to fill_')
    || E'\n\n📄 **Full rhythm:** Daily Kickoff (Processes)'
    || E'\n\n> ⚙️ Auto-generated from `agency_huddle_config`. Don''t hand-edit between the delimiters — edits will be overwritten on next config change.';
END;
$function$;

-- 9. Fix refresh function: point at new title "Daily Wrap-up" (was stale '04 Daily Checklist')
CREATE OR REPLACE FUNCTION public.refresh_daily_checklist_huddle_summary(p_agency_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_summary TEXT;
  v_current TEXT;
  v_new TEXT;
BEGIN
  v_summary := public.render_huddle_summary_md(p_agency_id);

  SELECT content INTO v_current
  FROM public.processes
  WHERE agency_id = p_agency_id AND title = 'Daily Wrap-up';
  IF NOT FOUND THEN RETURN; END IF;

  IF v_current NOT LIKE '%<!-- HUDDLE_SUMMARY:START -->%' THEN
    RETURN;
  END IF;

  v_new := regexp_replace(
    v_current,
    '<!-- HUDDLE_SUMMARY:START -->[\s\S]*?<!-- HUDDLE_SUMMARY:END -->',
    '<!-- HUDDLE_SUMMARY:START -->' || E'\n' || v_summary || E'\n' || '<!-- HUDDLE_SUMMARY:END -->',
    'g'
  );

  IF v_new IS DISTINCT FROM v_current THEN
    UPDATE public.processes
    SET content = v_new, updated_at = NOW()
    WHERE agency_id = p_agency_id AND title = 'Daily Wrap-up';
  END IF;
END;
$function$;

-- 10. Force one refresh so the block regenerates with new copy
SELECT public.refresh_daily_checklist_huddle_summary('126794dd-25ff-47d2-a436-724499733365');
