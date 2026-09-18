-- gen_random_bytes lives in pgcrypto, which is not on the search path here.
-- gen_random_uuid() is built in and its bits come from the same random source,
-- so two of them stripped of dashes give a 64 character token.
CREATE OR REPLACE FUNCTION public.hiring_issue_offer_accept_token(
  p_candidate_id uuid,
  p_days         integer DEFAULT 7
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
