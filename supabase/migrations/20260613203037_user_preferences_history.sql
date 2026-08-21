-- Audit history of Peter's Claude.ai userPreferences field.
-- Populated by Claude during session_log protocol: hash current userPreferences,
-- compare to latest row's hash, INSERT if different, no-op if identical.

CREATE TABLE IF NOT EXISTS public.user_preferences_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  preferences_text text NOT NULL,
  preferences_hash text NOT NULL,            -- sha256 hex of preferences_text
  char_count integer GENERATED ALWAYS AS (length(preferences_text)) STORED,
  source text NOT NULL DEFAULT 'claude_session_log', -- claude_session_log | manual_capture | install_seed | other
  notes text,                                 -- optional: what changed and why
  captured_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_uph_agency_captured
  ON public.user_preferences_history (agency_id, captured_at DESC);

CREATE INDEX IF NOT EXISTS ix_uph_agency_hash
  ON public.user_preferences_history (agency_id, preferences_hash);

COMMENT ON TABLE public.user_preferences_history IS
  'Versioned audit trail of the Claude.ai userPreferences field. Claude writes a new row only when the current text hash differs from the most recent stored hash.';

COMMENT ON COLUMN public.user_preferences_history.preferences_hash IS
  'sha256(preferences_text) lowercase hex. Used as the equality check at session-log time.';

COMMENT ON COLUMN public.user_preferences_history.source IS
  'How this snapshot was captured. claude_session_log = automatic check at end-of-session; manual_capture = Peter or Claude explicitly snapshotted; install_seed = baseline row at table creation.';

ALTER TABLE public.user_preferences_history ENABLE ROW LEVEL SECURITY;

-- Mirror the pattern used on persistent_memory / core_principles
CREATE POLICY anon_read_user_preferences_history
  ON public.user_preferences_history FOR SELECT TO anon USING (true);

CREATE POLICY anon_write_user_preferences_history
  ON public.user_preferences_history FOR INSERT TO anon WITH CHECK (true);

GRANT SELECT, INSERT ON public.user_preferences_history TO anon;
GRANT ALL ON public.user_preferences_history TO authenticated, service_role;
