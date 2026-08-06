CREATE TABLE IF NOT EXISTS public.interview_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  code text NOT NULL,
  construct text NOT NULL CHECK (construct IN ('capability','character','commitment')),
  subconstruct text NOT NULL,
  question_kind text NOT NULL CHECK (question_kind IN
    ('past_behavior','situational','background','motivation','exercise')),
  question_text text NOT NULL,
  listen_for text NOT NULL,
  concern text NOT NULL,
  followups text[] NOT NULL DEFAULT '{}',
  selection_mode text NOT NULL CHECK (selection_mode IN
    ('universal_core','universal_stretch','triggered','legacy_triggered','gap_fill')),
  trigger_codes text[] NOT NULL DEFAULT '{}',
  est_minutes numeric(3,1) NOT NULL DEFAULT 4.0,
  priority smallint NOT NULL DEFAULT 50,
  applies_to_positions text[] NULL,
  is_active boolean NOT NULL DEFAULT true,
  source text NOT NULL CHECK (source IN ('final_interview_manual','authored_2026_08')),
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, code),
  CHECK (
    (construct='character'  AND subconstruct IN ('honesty','hard_work_ethic','personal_responsibility','concern_for_others'))
    OR (construct='commitment' AND subconstruct IN ('role_attitude','product_buy_in','motivation_type','motivation_level'))
    OR (construct='capability' AND subconstruct IN ('sales_skill','communication','learning_cognition','composure',
        'initiative_autonomy','coachability','organization_detail','customer_service','teamwork'))
  ),
  CHECK ( (selection_mode IN ('triggered','legacy_triggered')) = (cardinality(trigger_codes) > 0) )
);

ALTER TABLE public.interview_questions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS interview_questions_read ON public.interview_questions;
CREATE POLICY interview_questions_read ON public.interview_questions
  FOR SELECT TO authenticated USING (true);
