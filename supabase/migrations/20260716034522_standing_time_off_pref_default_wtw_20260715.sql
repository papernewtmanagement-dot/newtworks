-- WtW is the only trigger. Change the column default so it can never
-- silently default back to "always" for future prefs.
ALTER TABLE public.standing_time_off_preferences
  ALTER COLUMN trigger_type SET DEFAULT 'wtw_won_prior_week';

COMMENT ON COLUMN public.standing_time_off_preferences.trigger_type IS
  'Currently always ''wtw_won_prior_week'' — WtW day off patterns apply only in weeks after we win Win the Week the prior week. The ''always'' value is retained in the CHECK constraint for future flexibility but not offered in the UI and not the DB default.';
