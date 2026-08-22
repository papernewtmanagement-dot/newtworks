-- Per-person context table for Claude's drafting work (CPR, Telegram, reviews, etc.)
-- INPUT to Claude only. Never quoted, referenced, or exposed in any output other team members see.
-- RLS-locked: service role only. No UI surface.

CREATE TABLE IF NOT EXISTS public.team_context (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_member_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  agency_id uuid NOT NULL,

  -- How they receive feedback / recognition / correction
  communication_style text,
  recognition_style text,
  pushback_style text,

  -- What's true this season (changes over weeks/months)
  current_focus text,
  recent_wins text,
  watch_items text,

  -- Surface discipline — what NOT to put in team-wide content right now
  surface_avoid text,

  -- PRIVATE — life events, family, faith, health, anything that shapes how Claude approaches them.
  -- NEVER quoted in any output. NEVER visible in app. Informs drafting tone only.
  personal_context text,

  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(team_member_id)
);

-- Lock down access
ALTER TABLE public.team_context ENABLE ROW LEVEL SECURITY;
-- No policies = service role only. Anon / authenticated cannot read or write.

-- Documentation lives with the table
COMMENT ON TABLE public.team_context IS
  'Per-person context informing Claude''s drafting tone, callouts, and avoid-list for any team-facing or team-about content. INPUT to Claude only — never quoted verbatim or exposed in any output that other team members see. RLS-locked: service-role only, no UI surface.';

COMMENT ON COLUMN public.team_context.personal_context IS
  'PRIVATE. Life events, family, faith, health, anything personal that shapes how Claude approaches them. Never quoted in any output. Never visible in app. Informs drafting tone only.';

COMMENT ON COLUMN public.team_context.surface_avoid IS
  'Topics not to put in any team-wide content right now (sore spots, recent setbacks they''re working through privately, etc.).';

CREATE INDEX IF NOT EXISTS idx_team_context_team_member ON public.team_context(team_member_id);
CREATE INDEX IF NOT EXISTS idx_team_context_agency ON public.team_context(agency_id);
