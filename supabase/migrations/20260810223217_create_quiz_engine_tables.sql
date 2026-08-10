-- Wave 2 Block A — quiz engine tables (7 tables per handoff spec)

CREATE TABLE IF NOT EXISTS public.quiz_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  source_faq_id uuid NULL REFERENCES public.knowledge_faqs(id) ON DELETE SET NULL,
  stem text NOT NULL CHECK (length(stem) BETWEEN 8 AND 160),
  shape text NOT NULL DEFAULT 'choice'
    CHECK (shape IN ('choice','violation','owner','bucket','phrase')),
  category text NULL,
  difficulty text NOT NULL
    CHECK (difficulty IN ('basic','intermediate','advanced')),
  explanation text NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','approved','retired')),
  approved_at timestamptz NULL,
  approved_by uuid NULL,
  report_blocked boolean NOT NULL DEFAULT false,
  times_served integer NOT NULL DEFAULT 0,
  times_correct integer NOT NULL DEFAULT 0,
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_quiz_items_stem ON public.quiz_items (agency_id, lower(stem));

CREATE TABLE IF NOT EXISTS public.quiz_item_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES public.quiz_items(id) ON DELETE CASCADE,
  option_text text NOT NULL CHECK (length(option_text) BETWEEN 1 AND 120),
  is_correct boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_quiz_item_options_item_id ON public.quiz_item_options (item_id);

CREATE TABLE IF NOT EXISTS public.quiz_modes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  mode_key text NOT NULL,
  title text NOT NULL,
  description text NULL,
  question_count integer NOT NULL,
  seconds_per_question integer NULL,
  passing_score integer NULL CHECK (passing_score IS NULL OR (passing_score BETWEEN 0 AND 100)),
  allowed_shapes text[] NOT NULL DEFAULT ARRAY['choice'],
  is_gating boolean NOT NULL DEFAULT false,
  wager_allowed boolean NOT NULL DEFAULT false,
  speed_clock boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, mode_key)
);

CREATE TABLE IF NOT EXISTS public.quiz_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL REFERENCES public.team(id),
  mode_key text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz NULL,
  question_count integer NOT NULL DEFAULT 0,
  correct_count integer NOT NULL DEFAULT 0,
  score integer NULL CHECK (score IS NULL OR (score BETWEEN 0 AND 100)),
  passed boolean NULL,
  points_earned integer NOT NULL DEFAULT 0,
  opponent_attempt_id uuid NULL REFERENCES public.quiz_attempts(id) ON DELETE SET NULL,
  context jsonb NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_quiz_attempts_agency_member_mode_started
  ON public.quiz_attempts (agency_id, team_member_id, mode_key, started_at DESC);

CREATE TABLE IF NOT EXISTS public.quiz_answers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  attempt_id uuid NOT NULL REFERENCES public.quiz_attempts(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.quiz_items(id),
  chosen_option_id uuid NULL REFERENCES public.quiz_item_options(id),
  was_correct boolean NULL,
  seconds_taken numeric NULL,
  points integer NOT NULL DEFAULT 0,
  wager integer NOT NULL DEFAULT 0,
  answered_at timestamptz NULL
);
CREATE INDEX IF NOT EXISTS ix_quiz_answers_attempt_id ON public.quiz_answers (attempt_id);

CREATE TABLE IF NOT EXISTS public.quiz_item_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  item_id uuid NOT NULL REFERENCES public.quiz_items(id) ON DELETE CASCADE,
  reported_by uuid NOT NULL REFERENCES public.team(id),
  reason text NULL,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','fixed','dismissed')),
  resolved_at timestamptz NULL,
  resolution_note text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_quiz_item_reports_agency_status ON public.quiz_item_reports (agency_id, status);

CREATE TABLE IF NOT EXISTS public.quiz_topic_sets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  set_key text NOT NULL,
  title text NOT NULL,
  description text NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, set_key)
);

CREATE TABLE IF NOT EXISTS public.quiz_topic_set_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id uuid NOT NULL REFERENCES public.quiz_topic_sets(id) ON DELETE CASCADE,
  category text NULL,
  tag_label text NULL,
  difficulty text NULL,
  item_id uuid NULL REFERENCES public.quiz_items(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- updated_at triggers — quiz_items, quiz_modes, quiz_topic_sets only
DROP TRIGGER IF EXISTS set_updated_at_quiz_items ON public.quiz_items;
CREATE TRIGGER set_updated_at_quiz_items BEFORE UPDATE ON public.quiz_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_quiz_modes ON public.quiz_modes;
CREATE TRIGGER set_updated_at_quiz_modes BEFORE UPDATE ON public.quiz_modes
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_quiz_topic_sets ON public.quiz_topic_sets;
CREATE TRIGGER set_updated_at_quiz_topic_sets BEFORE UPDATE ON public.quiz_topic_sets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
