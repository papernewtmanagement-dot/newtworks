-- One answer to "is this person's form done?", used by the onboarding sync and
-- the step gate alike.
CREATE OR REPLACE FUNCTION public.onboarding_form_done(p_team_id uuid, p_form_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.v_team_form_status v
    WHERE v.team_id = p_team_id
      AND v.form_type = p_form_id
      AND v.state IN ('complete', 'waived'));
$function$;

REVOKE EXECUTE ON FUNCTION public.onboarding_form_done(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_form_done(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.onboarding_sync_form_steps(p_team_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s       record;
  v_done  jsonb;
  v_n     int := 0;
BEGIN
  FOR s IN
    SELECT st.id, st.substeps, st.substeps_done, st.completed_at, st.unlocks_on, p.team_member_id
    FROM public.team_onboarding_steps st
    JOIN public.team_onboarding_plans p ON p.id = st.plan_id
    WHERE p.status IN ('active', 'paused')
      AND p.team_member_id IS NOT NULL
      AND (p_team_id IS NULL OR p.team_member_id = p_team_id)
      AND EXISTS (SELECT 1 FROM unnest(public.onboarding_substep_labels(st.substeps)) l
                  WHERE public.onboarding_substep_form_id(l) IS NOT NULL)
  LOOP
    -- Hand-ticked lines stay as they are; form lines follow the form.
    SELECT COALESCE(jsonb_agg(l ORDER BY l), '[]'::jsonb) INTO v_done
    FROM (
      SELECT d AS l
      FROM unnest(public.onboarding_substep_labels(
             CASE WHEN jsonb_typeof(s.substeps_done) = 'array' THEN s.substeps_done ELSE '[]'::jsonb END)) d
      WHERE public.onboarding_substep_form_id(d) IS NULL
      UNION
      SELECT l
      FROM unnest(public.onboarding_substep_labels(s.substeps)) l
      WHERE public.onboarding_form_done(s.team_member_id, public.onboarding_substep_form_id(l))
    ) x;

    IF v_done IS DISTINCT FROM (
         SELECT COALESCE(jsonb_agg(d ORDER BY d), '[]'::jsonb)
         FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(s.substeps_done) = 'array' THEN s.substeps_done ELSE '[]'::jsonb END) d) THEN
      UPDATE public.team_onboarding_steps SET substeps_done = v_done, updated_at = now() WHERE id = s.id;
      v_n := v_n + 1;
    END IF;

    IF s.completed_at IS NULL
       AND public.onboarding_unlocked(s.unlocks_on)
       AND public.onboarding_substeps_missing(s.substeps, v_done) = 0 THEN
      UPDATE public.team_onboarding_steps SET completed_at = now(), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_step_complete_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_missing int;
  v_team    uuid;
  v_label   text;
  v_form    text;
  v_was     boolean;
  v_now     boolean;
  v_should  boolean;
BEGIN
  -- The Orientation line (the sub-item named by an onboarding_instructions row with kind 'orientation') is ticked by
  -- Peter at orientation, from its pop-up or on the card. Nobody else can tick or untick it. Work with nobody signed
  -- in (the template sync, a migration) is not a person ticking a box.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.substeps_done IS DISTINCT FROM OLD.substeps_done
       AND auth.uid() IS NOT NULL
       AND COALESCE(public.current_app_user_role(), '') <> 'owner'
       AND EXISTS (
         SELECT 1
         FROM public.onboarding_instructions i
         JOIN public.team_onboarding_plans p ON p.id = NEW.plan_id AND p.agency_id = i.agency_id
         WHERE i.kind = 'orientation'
           AND (CASE WHEN jsonb_typeof(OLD.substeps_done) = 'array' THEN OLD.substeps_done ? i.substep_label ELSE false END)
               IS DISTINCT FROM
               (CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array' THEN NEW.substeps_done ? i.substep_label ELSE false END)
       ) THEN
      RAISE EXCEPTION 'Peter checks off Orientation at orientation.';
    END IF;
  END IF;

  -- A line that links to a form (…?form=handbook_ack) is ticked by the form, never by hand: it is ticked
  -- exactly when that form is done. A signed-in change to such a line that disagrees with the form is put
  -- back, whoever sends it. The form sync agrees with the form, so it passes. Work with nobody signed in
  -- (a migration, a rebuild) is left alone.
  IF TG_OP = 'UPDATE'
     AND NEW.substeps_done IS DISTINCT FROM OLD.substeps_done
     AND auth.uid() IS NOT NULL THEN
    SELECT p.team_member_id INTO v_team FROM public.team_onboarding_plans p WHERE p.id = NEW.plan_id;
    FOR v_label, v_form IN
      SELECT l, public.onboarding_substep_form_id(l)
      FROM unnest(public.onboarding_substep_labels(NEW.substeps)) l
      WHERE public.onboarding_substep_form_id(l) IS NOT NULL
    LOOP
      v_was := CASE WHEN jsonb_typeof(OLD.substeps_done) = 'array' THEN OLD.substeps_done ? v_label ELSE false END;
      v_now := CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array' THEN NEW.substeps_done ? v_label ELSE false END;
      CONTINUE WHEN v_was = v_now;
      v_should := v_team IS NOT NULL AND public.onboarding_form_done(v_team, v_form);
      CONTINUE WHEN v_now = v_should;
      IF v_should THEN
        NEW.substeps_done := (CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array'
                                   THEN NEW.substeps_done ELSE '[]'::jsonb END) || to_jsonb(v_label);
      ELSE
        NEW.substeps_done := NEW.substeps_done - v_label;
      END IF;
    END LOOP;
  END IF;

  -- Only guard the moment a step goes from open to done.
  IF NEW.completed_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.completed_at IS NOT NULL THEN RETURN NEW; END IF;

  IF NEW.auto_source IS NOT NULL
     AND COALESCE(current_setting('app.onboarding_autotick', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This step fills itself in from the rest of Newtworks. It cannot be ticked by hand.';
  END IF;

  IF NOT public.onboarding_unlocked(NEW.unlocks_on) THEN
    RAISE EXCEPTION 'This step opens on %.', to_char(NEW.unlocks_on, 'Dy Mon FMDD');
  END IF;

  IF array_length(public.onboarding_substep_labels(NEW.substeps), 1) IS NULL THEN
    RETURN NEW;
  END IF;

  v_missing := public.onboarding_substeps_missing(NEW.substeps, NEW.substeps_done);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'Finish all the sub-items first. % still open.', v_missing;
  END IF;

  RETURN NEW;
END;
$function$;

