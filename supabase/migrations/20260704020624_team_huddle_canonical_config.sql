-- Migration: team_huddle_canonical_config
-- Applied to production: 2026-07-04 (Path A resolution for canonical huddle source)
--
-- Purpose: Establish agency_huddle_config as the canonical structured source of
-- truth for team huddle scheduling. Any UPDATE triggers regeneration of the
-- summary block inside 04 Daily Checklist (between HUDDLE_SUMMARY delimiters).

CREATE TABLE IF NOT EXISTS public.agency_huddle_config (
  agency_id UUID PRIMARY KEY,
  start_time_local TIME NOT NULL DEFAULT '08:30:00',
  duration_regular_min INT NOT NULL DEFAULT 30,
  duration_fri_min INT NOT NULL DEFAULT 20,
  days_of_week TEXT[] NOT NULL DEFAULT ARRAY['MO','TU','WE','TH','FR'],
  meeting_notes TEXT,
  calendar_event_id TEXT,
  calendar_needs_sync BOOLEAN NOT NULL DEFAULT true,
  calendar_last_synced_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Renders the summary block that goes into 04 Daily Checklist between delimiters
CREATE OR REPLACE FUNCTION public.render_huddle_summary_md(p_agency_id UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_time TEXT;
  v_days TEXT;
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

  RETURN
    '**📅 ' || v_time || ' ' || v_days || '** — '
    || v.duration_regular_min || ' min Mon–Thu, '
    || v.duration_fri_min || ' min Fri retrospective'
    || CASE WHEN COALESCE(v.meeting_notes,'') <> ''
            THEN E'  \n*' || v.meeting_notes || '*'
            ELSE '' END
    || E'\n\n📄 **Full rhythm:** Team Huddle → Daily Rhythm (Playbook)'
    || E'\n\n> ⚙️ Auto-generated from `agency_huddle_config`. Don''t hand-edit between the delimiters — edits will be overwritten on next config change.';
END;
$fn$;

-- Rewrites the block between HUDDLE_SUMMARY delimiters in 04 Daily Checklist
CREATE OR REPLACE FUNCTION public.refresh_daily_checklist_huddle_summary(p_agency_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE
  v_summary TEXT;
  v_current TEXT;
  v_new TEXT;
BEGIN
  v_summary := public.render_huddle_summary_md(p_agency_id);

  SELECT content INTO v_current
  FROM public.playbook
  WHERE agency_id = p_agency_id AND title = '04 Daily Checklist';
  IF NOT FOUND THEN RETURN; END IF;

  IF v_current NOT LIKE '%<!-- HUDDLE_SUMMARY:START -->%' THEN
    RETURN; -- delimiters not in place yet; caller must install them first
  END IF;

  v_new := regexp_replace(
    v_current,
    '<!-- HUDDLE_SUMMARY:START -->[\s\S]*?<!-- HUDDLE_SUMMARY:END -->',
    '<!-- HUDDLE_SUMMARY:START -->' || E'\n' || v_summary || E'\n' || '<!-- HUDDLE_SUMMARY:END -->',
    'g'
  );

  IF v_new IS DISTINCT FROM v_current THEN
    UPDATE public.playbook
    SET content = v_new, updated_at = NOW()
    WHERE agency_id = p_agency_id AND title = '04 Daily Checklist';
  END IF;
END;
$fn$;

-- BEFORE UPDATE: flag calendar sync + bump updated_at on real changes
CREATE OR REPLACE FUNCTION public.trg_ahc_before_upd()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
BEGIN
  IF (OLD.start_time_local, OLD.duration_regular_min, OLD.duration_fri_min,
      OLD.days_of_week, COALESCE(OLD.meeting_notes,''))
     IS DISTINCT FROM
     (NEW.start_time_local, NEW.duration_regular_min, NEW.duration_fri_min,
      NEW.days_of_week, COALESCE(NEW.meeting_notes,'')) THEN
    NEW.calendar_needs_sync := true;
    NEW.updated_at := NOW();
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS agency_huddle_config_before_update ON public.agency_huddle_config;
CREATE TRIGGER agency_huddle_config_before_update
BEFORE UPDATE ON public.agency_huddle_config
FOR EACH ROW
EXECUTE FUNCTION public.trg_ahc_before_upd();

-- AFTER INSERT/UPDATE: rewrite the daily checklist summary block
CREATE OR REPLACE FUNCTION public.trg_ahc_after_upd_ins()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM public.refresh_daily_checklist_huddle_summary(NEW.agency_id);
  RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS agency_huddle_config_after_upd_ins ON public.agency_huddle_config;
CREATE TRIGGER agency_huddle_config_after_upd_ins
AFTER INSERT OR UPDATE ON public.agency_huddle_config
FOR EACH ROW
EXECUTE FUNCTION public.trg_ahc_after_upd_ins();
