ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS nickname text;
COMMENT ON COLUMN public.hiring_candidates.nickname IS
  'What the new hire asked to be called, typed by them on the offer-acceptance page.';

CREATE OR REPLACE FUNCTION public.hiring_create_team_row_from_candidate(p_candidate_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c      record;
  v_team uuid;
BEGIN
  SELECT id, agency_id, first_name, last_name, candidate_name, nickname,
         email, phone, address_line1, address_line2, city, state, zip_code,
         date_of_birth, offer_start_date, team_member_id
  INTO c
  FROM public.hiring_candidates
  WHERE id = p_candidate_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF c.team_member_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.team t WHERE t.id = c.team_member_id) THEN
    RETURN c.team_member_id;
  END IF;

  INSERT INTO public.team (
    agency_id, first_name, last_name, nickname,
    email_personal, phone_personal,
    address_line1, address_line2, city, state, zip_code,
    date_of_birth, start_date, category, is_active
  )
  VALUES (
    c.agency_id,
    COALESCE(NULLIF(btrim(COALESCE(c.first_name,'')), ''),
             NULLIF(split_part(COALESCE(c.candidate_name,''), ' ', 1), ''), ''),
    COALESCE(NULLIF(btrim(COALESCE(c.last_name,'')), ''),
             NULLIF(split_part(COALESCE(c.candidate_name,''), ' ', 2), ''), ''),
    NULLIF(btrim(COALESCE(c.nickname,'')), ''),
    NULLIF(btrim(COALESCE(c.email,'')), ''),
    NULLIF(btrim(COALESCE(c.phone,'')), ''),
    c.address_line1, c.address_line2, c.city, c.state, c.zip_code,
    c.date_of_birth,
    c.offer_start_date,
    'agency',
    false
  )
  RETURNING id INTO v_team;

  UPDATE public.hiring_candidates
  SET team_member_id = v_team, updated_at = now()
  WHERE id = c.id;

  RETURN v_team;
END;
$function$;

COMMENT ON FUNCTION public.hiring_create_team_row_from_candidate(uuid) IS
  'Creates the team row for an accepted candidate from their own entries. Idempotent. Never writes pay, role, licences, State Farm address, hire date or the active flag.';
