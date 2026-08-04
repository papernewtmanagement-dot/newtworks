-- approve_time_clock_edit creates and rewrites paid time entries and had no
-- authorisation test of any kind. It also took the reviewer's identity as an
-- argument, so a teammate could approve their own timesheet correction and
-- stamp somebody else's name on the approval. The screen was admin-only; the
-- function was not, and the screen is not the control.
--
-- Two changes, body otherwise untouched:
--   1. A real signed-in caller must be owner or manager.
--   2. The approval is attributed to whoever is actually signed in, not to
--      whatever id was passed in.
-- The service key still passes through with the supplied reviewer id, so the
-- scheduler and edge functions are unaffected.

CREATE OR REPLACE FUNCTION public.approve_time_clock_edit(p_request_id uuid, p_reviewer_user_id uuid, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  req public.time_clock_edit_requests%ROWTYPE;
  new_entry_id UUID;
  target_agency_id UUID;
  absorbable_id UUID;
  v_caller_users_id UUID;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' THEN
    IF NOT public.is_agency_admin() THEN
      RAISE EXCEPTION 'not authorized to approve time-clock edits';
    END IF;
    SELECT u.id INTO v_caller_users_id
    FROM public.users u
    WHERE u.auth_user_id = auth.uid()
    LIMIT 1;
    IF v_caller_users_id IS NULL THEN
      RAISE EXCEPTION 'approver could not be identified';
    END IF;
    p_reviewer_user_id := v_caller_users_id;
  END IF;

  SELECT * INTO req FROM public.time_clock_edit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit request % not found', p_request_id;
  END IF;
  IF req.status <> 'pending' THEN
    RAISE EXCEPTION 'Edit request % already resolved (status: %)', p_request_id, req.status;
  END IF;

  target_agency_id := req.agency_id;

  IF req.edit_type IN ('missed_clock_in', 'missed_shift') THEN
    SELECT id INTO absorbable_id
    FROM public.time_clock_entries
    WHERE team_member_id = req.team_member_id
      AND agency_id      = target_agency_id
      AND clock_out_at IS NULL
      AND DATE(clock_in_at AT TIME ZONE 'America/Chicago') = req.punch_date
      AND clock_in_at > req.requested_clock_in_at
    ORDER BY clock_in_at
    LIMIT 1;

    IF absorbable_id IS NOT NULL THEN
      UPDATE public.time_clock_entries
         SET original_clock_in_at  = COALESCE(original_clock_in_at, clock_in_at),
             original_clock_out_at = COALESCE(original_clock_out_at, clock_out_at),
             clock_in_at           = req.requested_clock_in_at,
             clock_out_at          = COALESCE(req.requested_clock_out_at, clock_out_at),
             edited_by_user_id     = p_reviewer_user_id,
             edited_at             = NOW(),
             edit_request_id       = req.id,
             notes                 = COALESCE(notes || E'\n', '') || 'Backfilled via edit request (absorbed open self-punch): ' || req.reason
       WHERE id = absorbable_id
       RETURNING id INTO new_entry_id;
    ELSE
      INSERT INTO public.time_clock_entries (
        agency_id, team_member_id, clock_in_at, clock_out_at,
        notes, source, edited_by_user_id, edited_at, edit_request_id
      ) VALUES (
        target_agency_id, req.team_member_id, req.requested_clock_in_at, req.requested_clock_out_at,
        'Backfilled via edit request: ' || req.reason,
        'edit_request', p_reviewer_user_id, NOW(), req.id
      ) RETURNING id INTO new_entry_id;
    END IF;

  ELSIF req.edit_type = 'missed_clock_out' THEN
    IF req.target_entry_id IS NULL THEN
      RAISE EXCEPTION 'missed_clock_out requires target_entry_id';
    END IF;
    UPDATE public.time_clock_entries
       SET original_clock_out_at = COALESCE(original_clock_out_at, clock_out_at),
           clock_out_at          = req.requested_clock_out_at,
           edited_by_user_id     = p_reviewer_user_id,
           edited_at             = NOW(),
           edit_request_id       = req.id,
           notes                 = COALESCE(notes || E'\n', '') || 'Clock-out backfilled via edit request: ' || req.reason
     WHERE id = req.target_entry_id
     RETURNING id INTO new_entry_id;

  ELSIF req.edit_type = 'wrong_time' THEN
    IF req.target_entry_id IS NULL THEN
      RAISE EXCEPTION 'wrong_time requires target_entry_id';
    END IF;
    UPDATE public.time_clock_entries
       SET original_clock_in_at  = COALESCE(original_clock_in_at, clock_in_at),
           original_clock_out_at = COALESCE(original_clock_out_at, clock_out_at),
           clock_in_at           = COALESCE(req.requested_clock_in_at, clock_in_at),
           clock_out_at          = COALESCE(req.requested_clock_out_at, clock_out_at),
           edited_by_user_id     = p_reviewer_user_id,
           edited_at             = NOW(),
           edit_request_id       = req.id,
           notes                 = COALESCE(notes || E'\n', '') || 'Time corrected via edit request: ' || req.reason
     WHERE id = req.target_entry_id
     RETURNING id INTO new_entry_id;
  ELSE
    RAISE EXCEPTION 'Unknown edit_type: %', req.edit_type;
  END IF;

  PERFORM public.set_time_clock_edit_status(
    p_request_id, 'approved', p_reviewer_user_id, p_note, new_entry_id
  );

  RETURN new_entry_id;
END $function$;

REVOKE ALL ON ROUTINE public.approve_time_clock_edit(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON ROUTINE public.approve_time_clock_edit(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON ROUTINE public.approve_time_clock_edit(uuid, uuid, text) TO authenticated, service_role;
