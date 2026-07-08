
-- Approve: writes to time_clock_entries based on edit_type, marks request approved
CREATE OR REPLACE FUNCTION public.approve_time_clock_edit(
  p_request_id UUID,
  p_reviewer_user_id UUID,
  p_note TEXT DEFAULT NULL
) RETURNS UUID AS $$
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
    -- Create a new entry with the requested clock-in (and clock-out if provided)
    INSERT INTO public.time_clock_entries (
      agency_id, team_member_id, clock_in_at, clock_out_at,
      notes, source, edited_by_user_id, edited_at, edit_request_id
    ) VALUES (
      target_agency_id, req.team_member_id, req.requested_clock_in_at, req.requested_clock_out_at,
      'Backfilled via edit request: ' || req.reason,
      'edit_request', p_reviewer_user_id, NOW(), req.id
    ) RETURNING id INTO new_entry_id;

  ELSIF req.edit_type = 'missed_clock_out' THEN
    -- Update existing entry to add the missed clock-out
    IF req.target_entry_id IS NULL THEN
      RAISE EXCEPTION 'missed_clock_out requires target_entry_id';
    END IF;
    UPDATE public.time_clock_entries
    SET
      original_clock_out_at = COALESCE(original_clock_out_at, clock_out_at),
      clock_out_at = req.requested_clock_out_at,
      edited_by_user_id = p_reviewer_user_id,
      edited_at = NOW(),
      edit_request_id = req.id,
      notes = COALESCE(notes || E'\n', '') || 'Clock-out backfilled via edit request: ' || req.reason
    WHERE id = req.target_entry_id
    RETURNING id INTO new_entry_id;

  ELSIF req.edit_type = 'wrong_time' THEN
    -- Update existing entry, preserving originals
    IF req.target_entry_id IS NULL THEN
      RAISE EXCEPTION 'wrong_time requires target_entry_id';
    END IF;
    UPDATE public.time_clock_entries
    SET
      original_clock_in_at = COALESCE(original_clock_in_at, clock_in_at),
      original_clock_out_at = COALESCE(original_clock_out_at, clock_out_at),
      clock_in_at = COALESCE(req.requested_clock_in_at, clock_in_at),
      clock_out_at = COALESCE(req.requested_clock_out_at, clock_out_at),
      edited_by_user_id = p_reviewer_user_id,
      edited_at = NOW(),
      edit_request_id = req.id,
      notes = COALESCE(notes || E'\n', '') || 'Time corrected via edit request: ' || req.reason
    WHERE id = req.target_entry_id
    RETURNING id INTO new_entry_id;
  ELSE
    RAISE EXCEPTION 'Unknown edit_type: %', req.edit_type;
  END IF;

  UPDATE public.time_clock_edit_requests
  SET status = 'approved',
      reviewed_at = NOW(),
      reviewed_by_user_id = p_reviewer_user_id,
      review_note = p_note,
      resulting_entry_id = new_entry_id
  WHERE id = p_request_id;

  RETURN new_entry_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Deny: no entry changes, just mark denied with optional note
CREATE OR REPLACE FUNCTION public.deny_time_clock_edit(
  p_request_id UUID,
  p_reviewer_user_id UUID,
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  req_status TEXT;
BEGIN
  SELECT status INTO req_status FROM public.time_clock_edit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit request % not found', p_request_id;
  END IF;
  IF req_status <> 'pending' THEN
    RAISE EXCEPTION 'Edit request % already resolved (status: %)', p_request_id, req_status;
  END IF;

  UPDATE public.time_clock_edit_requests
  SET status = 'denied',
      reviewed_at = NOW(),
      reviewed_by_user_id = p_reviewer_user_id,
      review_note = p_note
  WHERE id = p_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Cancel: only the requester (or admin) can cancel a pending request
CREATE OR REPLACE FUNCTION public.cancel_time_clock_edit(
  p_request_id UUID
) RETURNS VOID AS $$
DECLARE
  req_status TEXT;
BEGIN
  SELECT status INTO req_status FROM public.time_clock_edit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit request % not found', p_request_id;
  END IF;
  IF req_status <> 'pending' THEN
    RAISE EXCEPTION 'Edit request % already resolved (status: %)', p_request_id, req_status;
  END IF;

  UPDATE public.time_clock_edit_requests
  SET status = 'cancelled', updated_at = NOW()
  WHERE id = p_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
