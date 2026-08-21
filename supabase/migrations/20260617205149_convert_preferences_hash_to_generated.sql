-- Convert user_preferences_history.preferences_hash from a regular column
-- to a STORED generated column derived from preferences_text.
-- All existing rows have stored_hash = computed_hash (verified before migration),
-- so this is a no-op on data; it removes the ability for future writes to
-- introduce a wrong hash.

ALTER TABLE public.user_preferences_history
  DROP COLUMN preferences_hash;

ALTER TABLE public.user_preferences_history
  ADD COLUMN preferences_hash text
  GENERATED ALWAYS AS (encode(digest(preferences_text, 'sha256'), 'hex')) STORED
  NOT NULL;
