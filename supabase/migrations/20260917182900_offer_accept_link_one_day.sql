-- Peter's ruling 2026-09-17: the candidate gets ONE DAY to reply to the offer,
-- and the letter has to say so. The acceptance link now expires on the same
-- clock as the deadline instead of running a week.
CREATE OR REPLACE FUNCTION public.hiring_issue_offer_accept_token(
  p_candidate_id uuid,
  p_days         integer DEFAULT 1
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_token text;
BEGIN
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  UPDATE public.hiring_candidates
  SET offer_accept_token      = v_token,
      offer_accept_expires_at = now() + make_interval(days => GREATEST(p_days, 1)),
      updated_at              = now()
  WHERE id = p_candidate_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Candidate % not found', p_candidate_id;
  END IF;

  RETURN v_token;
END;
$function$;

REVOKE ALL ON FUNCTION public.hiring_issue_offer_accept_token(uuid, integer) FROM public, anon, authenticated;

COMMENT ON FUNCTION public.hiring_issue_offer_accept_token(uuid, integer) IS
  'Mints a fresh acceptance link and starts its one day clock. Called at the moment the offer email is sent, so re-sending the offer always replaces a stale or spent link.';
