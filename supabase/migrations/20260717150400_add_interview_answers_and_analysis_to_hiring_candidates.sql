-- Phase 2 of interview probe unification (session 2026-07-17)
-- Adds answer-capture + chat-analysis columns to hiring_candidates.
-- Governed by op-rule "Interview probe analysis protocol" (Phase 4 pending).

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS interview_answers jsonb DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS interview_analysis_text text,
  ADD COLUMN IF NOT EXISTS interview_analysis_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.interview_answers IS 'JSONB keyed by probe.source. Shape: {"<source>": {"answer": "text", "saved_at": "ISO8601"}}. Captured during final interview via CandidateDetail textareas.';
COMMENT ON COLUMN public.hiring_candidates.interview_analysis_text IS 'Claude-written per-probe analysis output. Populated when Peter says "analyze [name]''s interview answers" in chat. Governed by op-rule "Interview probe analysis protocol".';
COMMENT ON COLUMN public.hiring_candidates.interview_analysis_at IS 'When interview_analysis_text was last written.';
