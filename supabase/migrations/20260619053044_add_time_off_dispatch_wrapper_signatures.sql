-- run_internal_recipe always calls handlers with (agency_id, recipe_id).
-- The existing time_off_*_dispatch functions only have (uuid) signatures.
-- Add (uuid, uuid) wrapper overloads that match the dispatcher convention
-- (mirrors the bank_gl_writer / gl_entry_writer pattern).

CREATE OR REPLACE FUNCTION public.time_off_calendar_dispatch(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $$
  SELECT public.time_off_calendar_dispatch(p_agency_id);
$$;

CREATE OR REPLACE FUNCTION public.time_off_notification_dispatch(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $$
  SELECT public.time_off_notification_dispatch(p_agency_id);
$$;
