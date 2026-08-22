-- ====================================================================
-- Part 1: Extend the pattern_type and source CHECK constraints so the
-- termination/reactivation audit inserts actually land. Rename them to
-- team_behavioral_notes_* (the previous constraint-rename pass only touched
-- the team table; these are on team_behavioral_notes and were missed).
-- ====================================================================

ALTER TABLE public.team_behavioral_notes
  DROP CONSTRAINT staff_behavioral_notes_pattern_type_check;
ALTER TABLE public.team_behavioral_notes
  ADD CONSTRAINT team_behavioral_notes_pattern_type_check CHECK (
    pattern_type = ANY (ARRAY[
      'strength'::text, 'weakness'::text, 'coaching_focus'::text,
      'risk_pattern'::text, 'role_fit'::text, 'execution_gap'::text,
      'complacency'::text, 'mismatch'::text, 'fallback_role'::text,
      'note'::text, 'termination'::text, 'reactivation'::text
    ])
  );

ALTER TABLE public.team_behavioral_notes
  DROP CONSTRAINT staff_behavioral_notes_source_check;
ALTER TABLE public.team_behavioral_notes
  ADD CONSTRAINT team_behavioral_notes_source_check CHECK (
    source = ANY (ARRAY[
      'agent_observation'::text, 'call_review'::text,
      'personality_assessment'::text, 'performance_review'::text,
      'claude_conversation'::text, 'peer_feedback'::text, 'other'::text,
      'termination_action'::text, 'reactivation_action'::text
    ])
  );

-- ====================================================================
-- Part 2: Repair Jason Fuller's termination — the cascade was incomplete.
-- (a) Deactivate his user row, which never happened because user_id
--     wasn't in the frontend's React state.
-- (b) Backfill the missing termination audit row in team_behavioral_notes,
--     which silently failed against the old CHECK constraint above.
-- ====================================================================

UPDATE public.users
SET is_active = false,
    invite_status = 'deactivated',
    updated_at = NOW()
WHERE id = '4dd7e624-8106-409a-beb4-0bf3f773f0ed'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

INSERT INTO public.team_behavioral_notes
  (agency_id, team_member_id, observation_date, pattern_type, source, observation_text)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  t.id,
  COALESCE(t.end_date, CURRENT_DATE),
  'termination',
  'termination_action',
  E'TERMINATION — backfilled audit row.\n' ||
  'Original frontend termination on 2026-06-20 did not write this row ' ||
  'because team_behavioral_notes_pattern_type_check and ' ||
  'team_behavioral_notes_source_check did not allow pattern_type=' ||
  '''termination'' or source=''termination_action''. The corresponding ' ||
  'offboarding task (24d4b0d1) was created. The users.is_active flip ' ||
  'was also skipped — user_id was not loaded into React state by ' ||
  'useProducerROI. Both side-effects were repaired in this migration. ' ||
  'See session note 2026-06-20 — Jason Fuller termination cascade repair.'
FROM public.team t
WHERE t.first_name = 'Jason' AND t.last_name = 'Fuller'
  AND t.agency_id = '126794dd-25ff-47d2-a436-724499733365';
