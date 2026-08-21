-- Switch time-off functions from work_checkin (semantic mismatch) to time_off_participant.
-- Preserves current behavior for everyone; Cassie continues to vote after the
-- work_checkin unlicensed exclusion added in prior migration.

-- process_time_off_email_vote_reply: voter eligibility gate
CREATE OR REPLACE FUNCTION public.process_time_off_email_vote_reply()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_voter_id uuid;
  v_request_id uuid;
  v_vote text;
  v_request record;
BEGIN
  IF NEW.processed_at IS NOT NULL THEN RETURN NEW; END IF;

  v_request_id := NEW.request_id;
  v_voter_id := NEW.voter_team_id;
  v_vote := NEW.vote;

  SELECT * INTO v_request FROM public.time_off_requests WHERE id = v_request_id;
  IF NOT FOUND THEN
    NEW.processing_status := 'request_not_found';
    NEW.processing_note   := 'time_off_requests row missing';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF v_request.status <> 'voting' THEN
    NEW.processing_status := 'request_not_voting';
    NEW.processing_note   := format('Request status is %s, not voting', v_request.status);
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF v_request.vote_closes_at IS NOT NULL AND NOW() > v_request.vote_closes_at THEN
    NEW.processing_status := 'vote_closed';
    NEW.processing_note   := 'Reply arrived after vote window closed';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF v_voter_id = v_request.requester_team_id THEN
    NEW.processing_status := 'voter_is_requester';
    NEW.processing_note   := 'Voter is the requester';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.get_expected_teammates(NEW.agency_id, 'time_off_participant')
    WHERE team_id = v_voter_id
  ) THEN
    NEW.processing_status := 'voter_not_eligible';
    NEW.processing_note   := 'Voter not on time_off_participant roster (canonical)';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  INSERT INTO public.time_off_votes (
    request_id, voter_team_id, vote, source, source_reference,
    voted_at, agency_id
  ) VALUES (
    v_request_id, v_voter_id, v_vote, 'email', NEW.id,
    NEW.received_at, NEW.agency_id
  )
  ON CONFLICT (request_id, voter_team_id) DO UPDATE
    SET vote = EXCLUDED.vote,
        source = EXCLUDED.source,
        source_reference = EXCLUDED.source_reference,
        voted_at = EXCLUDED.voted_at,
        updated_at = NOW();

  NEW.processing_status := 'vote_recorded';
  NEW.processing_note   := format('Vote %s recorded for voter %s', v_vote, v_voter_id);
  NEW.processed_at      := NOW();
  RETURN NEW;
END;
$function$;
