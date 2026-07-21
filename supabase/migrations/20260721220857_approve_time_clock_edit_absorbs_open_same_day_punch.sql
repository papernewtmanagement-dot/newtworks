-- Migration: approve_time_clock_edit absorbs open same-day self-punch on missed_clock_in / missed_shift
--
-- Fix pattern: teammate forgets to clock in, self-punches later (open entry), then files a missed_clock_in
-- or missed_shift edit request to backdate the true start. Previously the approval unconditionally
-- INSERTed a new entry, producing two open rows covering the same day (real occurrence: Cassandra
-- 2026-07-21 — 08:28 backfill + 10:36 self-punch, both open). This version amends the existing
-- open entry in place when one exists whose clock_in_at is later than the requested backfill start.
--
-- Behavior unchanged for missed_clock_out and wrong_time branches.

CREATE OR REPLACE FUNCTION public.approve_time_clock_edit(p_request_id uuid, p_reviewer_user_id uuid, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  req public.time_clock_edit_requests%ROWTYPE;
  new_entry_id UUID;
  target_agency_id UUID;
  absorbable_id UUID;
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
    -- Look for an open (unclosed) same-day entry whose clock_in_at is later than
    -- the requested backfill start. This is the "forgot to clock in, then self-punched
    -- later, then filed backfill request" pattern. Absorb by amending in place.
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

  -- Status transition via canonical helper
  PERFORM public.set_time_clock_edit_status(
    p_request_id, 'approved', p_reviewer_user_id, p_note, new_entry_id
  );

  RETURN new_entry_id;
END $function$;
