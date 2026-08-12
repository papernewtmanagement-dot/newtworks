CREATE TABLE IF NOT EXISTS public.quiz_night_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  host_team_member_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'lobby'
    CHECK (status IN ('lobby','question','reveal','finished','abandoned')),
  item_ids jsonb,
  current_index integer NOT NULL DEFAULT 0,
  current_started_at timestamptz,
  seconds_per_question integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.quiz_night_players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.quiz_night_sessions(id) ON DELETE CASCADE,
  team_member_id uuid NOT NULL,
  attempt_id uuid REFERENCES public.quiz_attempts(id),
  joined_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_quiz_night_players_session_member
  ON public.quiz_night_players (session_id, team_member_id);

CREATE INDEX IF NOT EXISTS ix_quiz_night_sessions_agency_status
  ON public.quiz_night_sessions (agency_id, status);

ALTER TABLE public.quiz_night_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_night_players  ENABLE ROW LEVEL SECURITY;

-- Deliberately no policies. Definer functions are the only door.

UPDATE public.quiz_modes SET wager_allowed = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND mode_key = 'trivia_night';
