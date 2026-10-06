-- Peter 2026-10-05: every new hire starts as an hourly Account Associate for
-- their first 13 weeks, even when the offer is a salary. The offer itself is
-- unchanged; only the team record this builds from it starts hourly. A salary
-- offer converts to the hourly rate at 40 hours a week.
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
         date_of_birth, offer_start_date, offer_role_key, team_member_id,
         offer_role, offer_role_category, offer_role_level,
         offer_pay_type, offer_pay_amount, offer_pay_period, languages
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
    date_of_birth, start_date, category, is_active,
    role, role_category, role_level,
    employment_type, pay_type, pay_rate, pay_frequency,
    login_invite_due, languages
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
    false,
    NULLIF(btrim(COALESCE(c.offer_role,'')), ''),
    COALESCE(NULLIF(btrim(COALESCE(c.offer_role_category,'')), ''),
      CASE c.offer_role_key
        WHEN 'retention' THEN 'Retention'
        WHEN 'sales' THEN 'Sales'
        WHEN 'life_specialist' THEN 'Sales'
        ELSE NULL
      END),
    -- Everyone starts as an Account Associate.
    'Account Associate',
    'Full Time',
    -- Everyone starts hourly.
    'HOURLY',
    CASE
      WHEN c.offer_pay_amount IS NULL THEN NULL
      WHEN lower(COALESCE(c.offer_pay_type,'')) = 'hourly' THEN c.offer_pay_amount
      WHEN c.offer_pay_period = 'year' THEN round(c.offer_pay_amount / 2080.0, 2)
      WHEN c.offer_pay_period = 'week' THEN round(c.offer_pay_amount / 40.0, 2)
      ELSE NULL
    END,
    'weekly',
    c.offer_start_date,
    COALESCE(c.languages, '[]'::jsonb)
  )
  RETURNING id INTO v_team;

  UPDATE public.hiring_candidates
  SET team_member_id = v_team, updated_at = now()
  WHERE id = c.id;

  RETURN v_team;
END;
$function$;

-- Bryson: hired on a $31,200 salary offer, starts hourly at $15 (31,200 / 2,080).
UPDATE public.team
SET pay_type = 'HOURLY', pay_rate = 15.00, role_level = 'Account Associate', updated_at = now()
WHERE id = 'f0531100-d0ed-4c78-be81-986cfb339b3c' AND pay_type = 'SALARY' AND pay_rate = 600;
