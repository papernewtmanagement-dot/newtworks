-- Recurring forms get a standing record per person, same shape as team_licenses:
-- a due date, a cycle, a last-completed date, a status. The submissions table
-- keeps the individual completions behind it.
CREATE TABLE IF NOT EXISTS public.team_form_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  team_member_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  form_type text NOT NULL CHECK (form_type IN ('annual_certification','handbook_ack')),
  due_date date NOT NULL,
  cycle_months integer,
  initial_completed_at date,
  last_completed_at date,
  last_submission_id uuid REFERENCES public.team_form_submissions(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','due','complete','waived','inactive')),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_form_requirements_uq
  ON public.team_form_requirements (team_member_id, form_type);

ALTER TABLE public.team_form_requirements ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER team_form_requirements_touch BEFORE UPDATE
  ON public.team_form_requirements
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE POLICY tfr_read_own ON public.team_form_requirements FOR SELECT TO authenticated
  USING (team_member_id = public.current_team_member_id() OR public.is_agency_admin());
CREATE POLICY tfr_admin_all ON public.team_form_requirements FOR ALL TO authenticated
  USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

-- Completing a recurring form rolls the standing record forward.
CREATE OR REPLACE FUNCTION public.tg_roll_form_requirement()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cycle integer;
BEGIN
  IF NEW.form_type NOT IN ('annual_certification','handbook_ack') THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('submitted','locked') THEN RETURN NEW; END IF;

  SELECT cycle_months INTO v_cycle FROM public.team_form_requirements
   WHERE team_member_id = NEW.team_id AND form_type = NEW.form_type;

  INSERT INTO public.team_form_requirements
    (team_member_id, form_type, due_date, cycle_months,
     initial_completed_at, last_completed_at, last_submission_id, status)
  VALUES (NEW.team_id, NEW.form_type,
          CASE WHEN NEW.form_type='annual_certification'
               THEN (CURRENT_DATE + INTERVAL '12 months')::date
               ELSE CURRENT_DATE END,
          CASE WHEN NEW.form_type='annual_certification' THEN 12 ELSE NULL END,
          CURRENT_DATE, CURRENT_DATE, NEW.id, 'complete')
  ON CONFLICT (team_member_id, form_type) DO UPDATE SET
    last_completed_at  = CURRENT_DATE,
    initial_completed_at = COALESCE(public.team_form_requirements.initial_completed_at, CURRENT_DATE),
    last_submission_id = NEW.id,
    status             = 'complete',
    due_date           = CASE WHEN COALESCE(v_cycle, 0) > 0
                              THEN (CURRENT_DATE + (COALESCE(v_cycle,12) || ' months')::interval)::date
                              ELSE CURRENT_DATE END,
    updated_at         = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER team_form_roll_requirement AFTER INSERT OR UPDATE
  ON public.team_form_submissions
  FOR EACH ROW EXECUTE FUNCTION public.tg_roll_form_requirement();

-- Publishing a new handbook version makes everyone stale.
CREATE OR REPLACE FUNCTION public.tg_handbook_version_published()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.doc_type = 'handbook' AND NEW.is_current IS TRUE THEN
    INSERT INTO public.team_form_requirements
      (team_member_id, form_type, due_date, cycle_months, status)
    SELECT t.id, 'handbook_ack', COALESCE(NEW.effective_date, CURRENT_DATE), NULL, 'due'
      FROM public.team t
     WHERE t.agency_id = NEW.agency_id AND t.is_active IS TRUE
       AND COALESCE(t.is_test_user,false) = false
    ON CONFLICT (team_member_id, form_type) DO UPDATE SET
      due_date = COALESCE(NEW.effective_date, CURRENT_DATE),
      status   = 'due',
      updated_at = now();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER handbook_version_published AFTER INSERT OR UPDATE OF is_current
  ON public.form_documents
  FOR EACH ROW EXECUTE FUNCTION public.tg_handbook_version_published();
