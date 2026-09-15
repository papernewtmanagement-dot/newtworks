-- Read and write for the payroll benefits editor in the Team module.
CREATE OR REPLACE FUNCTION public.team_payroll_lines_list()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $fn$
  SELECT COALESCE(jsonb_agg(p ORDER BY p->>'name'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
      'team_member_id', t.id,
      'name', TRIM(t.first_name || ' ' || COALESCE(t.last_name,'')),
      'pay_type', t.pay_type,
      'weekly_life_benefit_agency_paid', t.weekly_life_benefit_agency_paid,
      'weekly_health_benefit_agency_paid', t.weekly_health_benefit_agency_paid,
      'annual_benefits_value', t.annual_benefits_value,
      'lines', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', l.id, 'line_type', l.line_type, 'label', l.label,
          'weekly_amount', l.weekly_amount, 'monthly_premium', l.monthly_premium,
          'agency_paid_weekly', l.agency_paid_weekly, 'notes', l.notes
        ) ORDER BY l.line_type, l.label)
        FROM public.team_payroll_lines l
        WHERE l.team_member_id = t.id AND l.is_active
      ), '[]'::jsonb)
    ) AS p
    FROM public.team t
    WHERE t.is_active
  ) s;
$fn$;

CREATE OR REPLACE FUNCTION public.team_payroll_line_save(
  p_team_member_id uuid, p_line_type text, p_label text,
  p_weekly_amount numeric, p_monthly_premium numeric DEFAULT NULL,
  p_agency_paid_weekly numeric DEFAULT NULL, p_notes text DEFAULT NULL,
  p_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $fn$
DECLARE v_id uuid;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO public.team_payroll_lines
      (agency_id, team_member_id, line_type, label, weekly_amount, monthly_premium, agency_paid_weekly, notes)
    VALUES ('126794dd-25ff-47d2-a436-724499733365', p_team_member_id, p_line_type, p_label,
            COALESCE(p_weekly_amount,0), p_monthly_premium, p_agency_paid_weekly, p_notes)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.team_payroll_lines
       SET line_type=p_line_type, label=p_label, weekly_amount=COALESCE(p_weekly_amount,0),
           monthly_premium=p_monthly_premium, agency_paid_weekly=p_agency_paid_weekly,
           notes=p_notes, updated_at=NOW()
     WHERE id=p_id RETURNING id INTO v_id;
  END IF;

  -- Keep the column the CPR and the comp pool read in step with the life line.
  IF p_line_type = 'life_stipend' THEN
    UPDATE public.team SET weekly_life_benefit_agency_paid = COALESCE(p_weekly_amount,0), updated_at=NOW()
     WHERE id = p_team_member_id;
  END IF;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.team_payroll_line_delete(p_id uuid)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public
AS $fn$
  UPDATE public.team_payroll_lines SET is_active=false, updated_at=NOW() WHERE id=p_id
  RETURNING true;
$fn$;

GRANT EXECUTE ON FUNCTION public.team_payroll_lines_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.team_payroll_line_save(uuid,text,text,numeric,numeric,numeric,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.team_payroll_line_delete(uuid) TO authenticated;
