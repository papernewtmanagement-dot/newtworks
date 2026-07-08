-- Tier-2 DRY (pair 2): extract set_time_clock_edit_status helper.
--
-- cancel_time_clock_edit + deny_time_clock_edit + approve_time_clock_edit all
-- shared the same tail: SELECT ... FOR UPDATE, check pending, UPDATE status/
-- reviewed_at/reviewed_by/review_note. Extract that tail. approve keeps its
-- complex time_clock_entries mutation logic (edit_type branching) but calls the
-- helper for the final status write.
--
-- Frontend (TimeClockEditRequests.jsx) calls all three wrappers by name via RPC
-- so surface preserved.

CREATE OR REPLACE FUNCTION public.set_time_clock_edit_status(
  p_request_id         UUID,
  p_new_status         TEXT,
  p_reviewer_user_id   UUID DEFAULT NULL,
  p_note               TEXT DEFAULT NULL,
  p_resulting_entry_id UUID DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
DECLARE
  req_status TEXT;
BEGIN
  IF p_new_status NOT IN ('approved','denied','cancelled') THEN
    RAISE EXCEPTION 'Invalid time_clock edit status: % (expected approved/denied/cancelled)', p_new_status;
  END IF;

  SELECT status INTO req_status FROM public.time_clock_edit_requests
   WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit request % not found', p_request_id;
  END IF;
  IF req_status <> 'pending' THEN
    RAISE EXCEPTION 'Edit request % already resolved (status: %)', p_request_id, req_status;
  END IF;

  UPDATE public.time_clock_edit_requests
     SET status              = p_new_status,
         reviewed_at         = CASE WHEN p_new_status IN ('approved','denied') THEN NOW() ELSE reviewed_at END,
         reviewed_by_user_id = COALESCE(p_reviewer_user_id, reviewed_by_user_id),
         review_note         = COALESCE(p_note, review_note),
         resulting_entry_id  = COALESCE(p_resulting_entry_id, resulting_entry_id),
         updated_at          = NOW()
   WHERE id = p_request_id;
END $fn$;

COMMENT ON FUNCTION public.set_time_clock_edit_status(UUID, TEXT, UUID, TEXT, UUID) IS
  'Canonical writer for public.time_clock_edit_requests status transitions.'
  ' Validates status enum, requires row to be pending, updates review metadata.'
  ' Used by cancel_/deny_/approve_time_clock_edit wrappers.';

DROP FUNCTION IF EXISTS public.cancel_time_clock_edit(UUID);
DROP FUNCTION IF EXISTS public.deny_time_clock_edit(UUID, UUID, TEXT);
DROP FUNCTION IF EXISTS public.approve_time_clock_edit(UUID, UUID, TEXT);

CREATE FUNCTION public.cancel_time_clock_edit(p_request_id UUID)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  PERFORM public.set_time_clock_edit_status(p_request_id, 'cancelled');
END $fn$;

CREATE FUNCTION public.deny_time_clock_edit(
  p_request_id       UUID,
  p_reviewer_user_id UUID,
  p_note             TEXT DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  PERFORM public.set_time_clock_edit_status(p_request_id, 'denied', p_reviewer_user_id, p_note);
END $fn$;

CREATE FUNCTION public.approve_time_clock_edit(
  p_request_id       UUID,
  p_reviewer_user_id UUID,
  p_note             TEXT DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  req public.time_clock_edit_requests%ROWTYPE;
  new_entry_id UUID;
  target_agency_id UUID;
BEGIN
  SELECT * INTO req FROM public.time_clock_edit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit request % not found', p_request_id;
  END IF;
  IF req.status <> 'pending' THEN
    RAISE EXCEPTION 'Edit request % already resolved (status: %)', p_request_id, req.status;
  END IF;

  target_agency_id := req.agency_id;

  IF req.edit_type IN ('missed_clock_in', 'missed_shift') THEN
    INSERT INTO public.time_clock_entries (
      agency_id, team_member_id, clock_in_at, clock_out_at,
      notes, source, edited_by_user_id, edited_at, edit_request_id
    ) VALUES (
      target_agency_id, req.team_member_id, req.requested_clock_in_at, req.requested_clock_out_at,
      'Backfilled via edit request: ' || req.reason,
      'edit_request', p_reviewer_user_id, NOW(), req.id
    ) RETURNING id INTO new_entry_id;

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
END $fn$;
