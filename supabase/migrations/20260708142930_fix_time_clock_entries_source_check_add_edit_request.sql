-- approve_time_clock_edit inserts source='edit_request' for missed_clock_in/missed_shift
-- but the CHECK constraint didn't allow it. Add it.
ALTER TABLE public.time_clock_entries
  DROP CONSTRAINT IF EXISTS time_clock_entries_source_check;

ALTER TABLE public.time_clock_entries
  ADD CONSTRAINT time_clock_entries_source_check
  CHECK (source = ANY (ARRAY['kiosk'::text, 'admin_create'::text, 'admin_edit'::text, 'self'::text, 'admin'::text, 'edit_request'::text]));
