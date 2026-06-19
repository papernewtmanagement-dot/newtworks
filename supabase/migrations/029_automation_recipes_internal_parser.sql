-- Add `internal_parser` to automation_recipes so recipes can opt into a
-- deterministic in-runner parser instead of the Groq LLM step. Used by
-- automation-runner when recipe.internal_parser is set and matches a key
-- in INTERNAL_PARSERS (e.g., 'sf_crm_analytics_email'). Removes Groq from
-- the critical path for stable-format upstream payloads and eliminates
-- daily-TPD failures for those recipes.
ALTER TABLE public.automation_recipes
  ADD COLUMN IF NOT EXISTS internal_parser text;

COMMENT ON COLUMN public.automation_recipes.internal_parser IS
  'If set, automation-runner uses the named deterministic parser instead of Groq. Bypasses LLM. Known parsers: sf_crm_analytics_email.';
