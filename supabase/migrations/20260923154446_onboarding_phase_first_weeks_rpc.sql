-- The first week number of every major card, for the template page (week
-- pickers, week names). Same rule as onboarding_phase_first_week().
CREATE OR REPLACE FUNCTION public.onboarding_phase_first_weeks(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS TABLE(phase integer, first_week integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT ph.phase, public.onboarding_phase_first_week(ph.agency_id, ph.phase)
  FROM public.onboarding_phases ph
  WHERE ph.agency_id = p_agency_id;
$$;
GRANT EXECUTE ON FUNCTION public.onboarding_phase_first_weeks(uuid) TO authenticated;
