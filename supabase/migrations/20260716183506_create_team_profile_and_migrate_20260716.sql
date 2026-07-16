
-- Create team_profile: one row per hired team member
-- Consolidates: team_context (8 drafting fields) + team_behavioral_notes (log stream, folded to markdown) 
-- + team_trajectory_summaries (LLM rollup) + linked_assessment_id pointer to hiring_assessments

CREATE TABLE IF NOT EXISTS public.team_profile (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  team_member_id UUID NOT NULL UNIQUE REFERENCES public.team(id) ON DELETE CASCADE,
  linked_assessment_id UUID REFERENCES public.hiring_assessments(id) ON DELETE SET NULL,
  -- Drafting inputs (from team_context) — INPUT-ONLY, never surfaces in output
  communication_style TEXT,
  recognition_style TEXT,
  pushback_style TEXT,
  current_focus TEXT,
  recent_wins TEXT,
  watch_items TEXT,
  surface_avoid TEXT,
  personal_context TEXT,
  -- Behavioral observation log (from team_behavioral_notes) — append-only markdown, dated entries
  behavioral_log TEXT,
  -- LLM trajectory rollup (from team_trajectory_summaries)
  trajectory_summary TEXT,
  trajectory_notes_analyzed_count INTEGER,
  trajectory_notes_range_start DATE,
  trajectory_notes_range_end DATE,
  trajectory_model_used TEXT,
  trajectory_updated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_team_profile_agency ON public.team_profile(agency_id);
CREATE INDEX IF NOT EXISTS ix_team_profile_linked_assessment ON public.team_profile(linked_assessment_id) 
  WHERE linked_assessment_id IS NOT NULL;

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.tg_touch_team_profile_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$fn$;

DROP TRIGGER IF EXISTS tg_team_profile_updated_at ON public.team_profile;
CREATE TRIGGER tg_team_profile_updated_at
BEFORE UPDATE ON public.team_profile
FOR EACH ROW EXECUTE FUNCTION public.tg_touch_team_profile_updated_at();

-- RLS
ALTER TABLE public.team_profile ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS team_profile_agency_isolation ON public.team_profile;
CREATE POLICY team_profile_agency_isolation ON public.team_profile
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365')
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365');

-- Populate: one row per team member who has data in any of the 3 source tables
WITH members AS (
  SELECT DISTINCT t.id AS team_member_id, t.agency_id
  FROM public.team t
  WHERE t.id IN (
    SELECT team_member_id FROM public.team_context WHERE team_member_id IS NOT NULL
    UNION
    SELECT team_member_id FROM public.team_behavioral_notes WHERE team_member_id IS NOT NULL
    UNION
    SELECT team_member_id FROM public.team_trajectory_summaries WHERE team_member_id IS NOT NULL
  )
),
behavioral_folded AS (
  -- Fold behavioral_notes rows into a single markdown log per person, newest first
  SELECT team_member_id,
         string_agg(
           format(E'## %s · %s%s%s\n%s',
             observation_date::text,
             COALESCE(pattern_type, 'observation'),
             CASE WHEN source IS NOT NULL THEN ' · source: ' || source ELSE '' END,
             CASE WHEN is_resolved THEN ' · **RESOLVED** ' || COALESCE(resolved_date::text, '') ELSE '' END,
             COALESCE(observation_text, '(no text)')
           ),
           E'\n\n---\n\n' ORDER BY observation_date DESC, created_at DESC
         ) AS log_markdown
  FROM public.team_behavioral_notes
  GROUP BY team_member_id
),
hiring_link AS (
  -- For each team member, pick the hiring_assessments row for them (if any)
  -- Prefer is_team_member=true; otherwise take most recent
  SELECT team_member_id,
         (SELECT id FROM public.hiring_assessments ha
          WHERE ha.team_member_id = m.team_member_id
          ORDER BY (is_team_member IS TRUE) DESC NULLS LAST, created_at DESC
          LIMIT 1) AS linked_assessment_id
  FROM members m
)
INSERT INTO public.team_profile (
  agency_id, team_member_id, linked_assessment_id,
  communication_style, recognition_style, pushback_style,
  current_focus, recent_wins, watch_items, surface_avoid, personal_context,
  behavioral_log, trajectory_summary,
  trajectory_notes_analyzed_count, trajectory_notes_range_start, trajectory_notes_range_end,
  trajectory_model_used, trajectory_updated_at
)
SELECT
  m.agency_id, m.team_member_id, hl.linked_assessment_id,
  tc.communication_style, tc.recognition_style, tc.pushback_style,
  tc.current_focus, tc.recent_wins, tc.watch_items, tc.surface_avoid, tc.personal_context,
  bf.log_markdown, tts.summary,
  tts.notes_analyzed_count, tts.notes_range_start, tts.notes_range_end,
  tts.model_used, tts.updated_at
FROM members m
LEFT JOIN public.team_context tc ON tc.team_member_id = m.team_member_id
LEFT JOIN behavioral_folded bf ON bf.team_member_id = m.team_member_id
LEFT JOIN public.team_trajectory_summaries tts ON tts.team_member_id = m.team_member_id
LEFT JOIN hiring_link hl ON hl.team_member_id = m.team_member_id;
;
