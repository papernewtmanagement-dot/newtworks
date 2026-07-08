-- bot_prompts: standalone AI system prompts / assistant personas authored for agency use
-- Distinct from chatbot_* (in-app BCC chatbot) and sops (human-process SOPs).
CREATE TABLE IF NOT EXISTS public.bot_prompts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  name TEXT NOT NULL,
  purpose TEXT,
  system_prompt TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'archived', 'deprecated')),
  source TEXT,
  target_model TEXT,
  deployment_notes TEXT,
  notes TEXT,
  char_count INT GENERATED ALWAYS AS (length(system_prompt)) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bot_prompts_agency_status
  ON public.bot_prompts(agency_id, status);

-- updated_at auto-touch
CREATE OR REPLACE FUNCTION public.bot_prompts_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_bot_prompts_touch ON public.bot_prompts;
CREATE TRIGGER trg_bot_prompts_touch
  BEFORE UPDATE ON public.bot_prompts
  FOR EACH ROW EXECUTE FUNCTION public.bot_prompts_touch_updated_at();

-- RLS: admin-tier (owner + manager) only, matching BCC default visibility
ALTER TABLE public.bot_prompts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bot_prompts_admin_all" ON public.bot_prompts;
CREATE POLICY "bot_prompts_admin_all"
  ON public.bot_prompts
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner', 'manager')
    )
  );

COMMENT ON TABLE public.bot_prompts IS
  'Standalone AI system prompts / assistant personas authored for agency use (Coach Phil, future training bots, leadership bot, etc.). Distinct from chatbot_* (BCC in-app chatbot) and sops (human-process SOPs).';