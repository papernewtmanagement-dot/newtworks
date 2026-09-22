-- Peter ruling 2026-09-21: the offer sets salary, role, role category and role
-- level, and acceptance carries them onto the team record.
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_role text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_role_category text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_role_level text;

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
         offer_pay_type, offer_pay_amount, offer_pay_period
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
    login_invite_due
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
    NULLIF(btrim(COALESCE(c.offer_role_level,'')), ''),
    'Full Time',
    CASE lower(COALESCE(c.offer_pay_type,''))
      WHEN 'salary' THEN 'SALARY'
      WHEN 'hourly' THEN 'HOURLY'
      ELSE NULL
    END,
    -- Salaries are held as the weekly paycheck, hourly as the hourly rate.
    CASE
      WHEN c.offer_pay_amount IS NULL THEN NULL
      WHEN lower(COALESCE(c.offer_pay_type,'')) = 'salary' AND c.offer_pay_period = 'year'
        THEN round(c.offer_pay_amount / 52.0, 2)
      WHEN lower(COALESCE(c.offer_pay_type,'')) = 'hourly'
        THEN c.offer_pay_amount
      ELSE NULL
    END,
    'weekly',
    c.offer_start_date
  )
  RETURNING id INTO v_team;

  UPDATE public.hiring_candidates
  SET team_member_id = v_team, updated_at = now()
  WHERE id = c.id;

  RETURN v_team;
END;
$function$;
