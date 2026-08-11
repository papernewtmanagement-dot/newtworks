DELETE FROM public.interview_questions
  WHERE code = 'BANK_GATED_AREA'
    AND trigger_codes = ARRAY['T_COMPETENCY_GATE']::text[];
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS competency_gate_fired;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS competency_gate_detail;
ALTER TABLE public.team DROP COLUMN IF EXISTS role_fit_score;
DROP TABLE IF EXISTS public.hiregauge_competencies;
DROP TABLE IF EXISTS public.hiregauge_role_fit_pre_facet_snapshot;
