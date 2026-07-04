-- Migration: team_huddle_leader_and_calendar_fields
-- Applied to production: 2026-07-04
--
-- Purpose: Extend agency_huddle_config with weekly leader + calendar identity
-- fields. Refine trigger so leader changes update the checklist but do NOT
-- flag calendar for re-sync (leader lives in checklist only).

ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS current_week_leader_team_id UUID REFERENCES public.team(id),
  ADD COLUMN IF NOT EXISTS calendar_id TEXT,
  ADD COLUMN IF NOT EXISTS event_title TEXT NOT NULL DEFAULT 'Team Huddle';

-- Rewrite summary renderer to include weekly leader (JOINs team)
CREATE OR REPLACE FUNCTION public.render_huddle_summary_md(p_agency_id UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_time TEXT;
  v_days TEXT;
  v_leader_name TEXT;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config WHERE agency_id = p_agency_id;
  IF NOT FOUND THEN
    RETURN '⚠️ Huddle config not set.';
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
    || E'\n\n📄 **Full rhythm:** Team Huddle → Daily Rhythm (Playbook)'
    || E'\n\n> ⚙️ Auto-generated from `agency_huddle_config`. Don''t hand-edit between the delimiters — edits will be overwritten on next config change.';
END;
$fn$;

-- Refine BEFORE trigger: leader change bumps updated_at but does NOT flag calendar_needs_sync
-- (leader stays checklist-only, not on calendar event)
CREATE OR REPLACE FUNCTION public.trg_ahc_before_upd()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
BEGIN
  -- Any real change bumps updated_at
  IF row(OLD.*) IS DISTINCT FROM row(NEW.*) THEN
    NEW.updated_at := NOW();
  END IF;

  -- Only calendar-relevant fields flag re-sync
  IF (OLD.start_time_local, OLD.duration_regular_min, OLD.duration_fri_min,
      OLD.days_of_week, COALESCE(OLD.event_title,''), COALESCE(OLD.calendar_id,''))
     IS DISTINCT FROM
     (NEW.start_time_local, NEW.duration_regular_min, NEW.duration_fri_min,
      NEW.days_of_week, COALESCE(NEW.event_title,''), COALESCE(NEW.calendar_id,'')) THEN
    NEW.calendar_needs_sync := true;
  END IF;
  RETURN NEW;
END;
$fn$;
