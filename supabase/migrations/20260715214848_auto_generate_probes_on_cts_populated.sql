-- Broaden auto-generate trigger. Original only fired on status→email_screen.
-- New: fires on INSERT with CTS present OR on UPDATE that first populates CTS.
-- Gate: all 9 trait cols non-null AND custom_probes still NULL AND row is not
-- an admin-backoffice/hired teammate. Idempotent — won't re-fire if probes exist.
--
-- Rationale: standard process is "assessment lands → probes generated
-- automatically before Peter opens the candidate card." Priscilla was inserted
-- direct-to-interview and skipped email_screen, so old trigger never fired.

CREATE OR REPLACE FUNCTION public.auto_generate_probes_on_cts_populated()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','net'
AS $$
DECLARE
  v_service_key text;
  v_url text := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/generate-custom-probes';
  v_had_cts boolean;
  v_has_cts boolean;
BEGIN
  -- Skip team-member rows (already hired) and calibration-only rows
  IF NEW.is_team_member IS TRUE THEN RETURN NEW; END IF;
  IF NEW.decline_reason = 'calibration_only' THEN RETURN NEW; END IF;

  -- Probes already generated → nothing to do
  IF NEW.custom_probes IS NOT NULL THEN RETURN NEW; END IF;

  -- Do the 9 trait cols all have values now?
  v_has_cts := NEW.deadline_motivation IS NOT NULL
           AND NEW.recognition_drive   IS NOT NULL
           AND NEW.assertiveness       IS NOT NULL
           AND NEW.independent_spirit  IS NOT NULL
           AND NEW.analytical          IS NOT NULL
           AND NEW.compassion          IS NOT NULL
           AND NEW.self_promotion      IS NOT NULL
           AND NEW.belief_in_others    IS NOT NULL
           AND NEW.optimism            IS NOT NULL;

  IF NOT v_has_cts THEN RETURN NEW; END IF;

  -- On UPDATE, only fire if CTS just transitioned from missing → present
  -- (avoids re-firing on unrelated column edits when CTS already present)
  IF TG_OP = 'UPDATE' THEN
    v_had_cts := OLD.deadline_motivation IS NOT NULL
             AND OLD.recognition_drive   IS NOT NULL
             AND OLD.assertiveness       IS NOT NULL
             AND OLD.independent_spirit  IS NOT NULL
             AND OLD.analytical          IS NOT NULL
             AND OLD.compassion          IS NOT NULL
             AND OLD.self_promotion      IS NOT NULL
             AND OLD.belief_in_others    IS NOT NULL
             AND OLD.optimism            IS NOT NULL;
    -- CTS already present in OLD → this UPDATE is a routine edit, not a fresh
    -- assessment; skip. (Custom probes null implies deliberate reset or
    -- pre-existing candidate w/o probes — those should be manually regenerated
    -- via the button, not silently re-fired here.)
    IF v_had_cts THEN RETURN NEW; END IF;
  END IF;

  -- Look up service key
  SELECT setting_value INTO v_service_key
  FROM public.settings
  WHERE agency_id = NEW.agency_id
    AND setting_key = 'supabase_service_role_key'
  LIMIT 1;

  IF v_service_key IS NULL THEN
    RAISE WARNING 'auto_generate_probes_on_cts_populated: settings.supabase_service_role_key missing for agency %', NEW.agency_id;
    RETURN NEW;
  END IF;

  -- Fire-and-forget. Edge fn persists via service-role client.
  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||v_service_key
    ),
    body := jsonb_build_object('assessment_id', NEW.id),
    timeout_milliseconds := 90000
  );

  RETURN NEW;
END;
$$;

-- Drop the narrow email_screen-only trigger + its function
DROP TRIGGER IF EXISTS trg_auto_generate_probes_on_email_screen ON public.team_assessments;
DROP FUNCTION IF EXISTS public.auto_generate_probes_on_email_screen();

-- New trigger — fires on INSERT and on UPDATE OF the 9 trait cols
CREATE TRIGGER trg_auto_generate_probes_on_cts
AFTER INSERT OR UPDATE OF 
  deadline_motivation, recognition_drive, assertiveness, independent_spirit,
  analytical, compassion, self_promotion, belief_in_others, optimism
ON public.team_assessments
FOR EACH ROW
EXECUTE FUNCTION public.auto_generate_probes_on_cts_populated();
