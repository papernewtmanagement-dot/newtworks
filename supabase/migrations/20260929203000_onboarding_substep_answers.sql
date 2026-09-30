-- A sub-item that asks for a reply ("What's one takeaway?") keeps what the new hire typed, keyed by the line's label.
ALTER TABLE public.team_onboarding_steps ADD COLUMN IF NOT EXISTS substep_answers jsonb NOT NULL DEFAULT '{}'::jsonb;
