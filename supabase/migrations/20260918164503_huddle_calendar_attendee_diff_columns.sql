ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS calendar_pushed_attendees jsonb,
  ADD COLUMN IF NOT EXISTS calendar_pending_attendees jsonb;

COMMENT ON COLUMN public.agency_huddle_config.calendar_pushed_attendees IS
  'The guest list Google confirmed it accepted on the last successful sync. Diffed against the live roster so huddle_calendar_sync can tell an add from a removal.';
COMMENT ON COLUMN public.agency_huddle_config.calendar_pending_attendees IS
  'The guest list currently in flight. Promoted to calendar_pushed_attendees when the dispatch comes back clean, discarded when it fails.';
