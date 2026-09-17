-- =========================================================================
-- Onboarding part 1: self-ticking reference steps + parent-tick gate
-- =========================================================================
-- A step "opens" when it is not done, it is assigned to someone, and
-- everything it was waiting on is finished. Part 2 sends that notice.
-- Here: reference-check steps tick themselves from the hiring module's
-- reference emails and carry a short summary instead of hand checkboxes,
-- and a step with sub-items cannot be ticked until every sub-item is ticked.
-- =========================================================================

ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS opened_notified_at timestamptz,
  ADD COLUMN IF NOT EXISTS auto_source text,
  ADD COLUMN IF NOT EXISTS auto_summary jsonb;

ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS auto_source text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'team_onboarding_steps_auto_source_chk') THEN
    ALTER TABLE public.team_onboarding_steps
      ADD CONSTRAINT team_onboarding_steps_auto_source_chk
      CHECK (auto_source IS NULL OR auto_source IN ('references'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'onboarding_step_templates_auto_source_chk') THEN
    ALTER TABLE public.onboarding_step_templates
      ADD CONSTRAINT onboarding_step_templates_auto_source_chk
      CHECK (auto_source IS NULL OR auto_source IN ('references'));
  END IF;
END $$;

COMMENT ON COLUMN public.team_onboarding_steps.auto_source IS
  'Set when this step is filled in by another part of Newtworks instead of by hand. "references" reads the hiring module reference emails. A step with an auto_source cannot be ticked or unticked manually.';
COMMENT ON COLUMN public.team_onboarding_steps.auto_summary IS
  'Short read-only summary the onboarding page shows where the hand checkboxes would be. Written by the matching sync function.';
COMMENT ON COLUMN public.team_onboarding_steps.opened_notified_at IS
  'When the person this step is assigned to was told it opened. Set once, by onboarding_open_step_notices.';

-- How many references have to be on file before the reference step counts
-- as done. Change the number here and the step follows on the next hour.
INSERT INTO public.settings (agency_id, setting_key, setting_value)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'onboarding_reference_minimum', '2'
WHERE NOT EXISTS (
  SELECT 1 FROM public.settings
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND setting_key = 'onboarding_reference_minimum'
);

-- Sub-items are stored either as a flat list of strings or as groups
-- ({group, items}). This returns every label from either shape, which is
-- what the page does in JavaScript.
CREATE OR REPLACE FUNCTION public.onboarding_substep_labels(p_substeps jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $function$
  WITH src AS (
    SELECT e
    FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(p_substeps) = 'array' THEN p_substeps ELSE '[]'::jsonb END
         ) e
  ),
  labels AS (
    SELECT e #>> '{}' AS lbl FROM src WHERE jsonb_typeof(e) = 'string'
    UNION ALL
    SELECT i #>> '{}'
    FROM src,
         LATERAL jsonb_array_elements(
           CASE WHEN jsonb_typeof(e) = 'object' AND jsonb_typeof(e -> 'items') = 'array'
                THEN e -> 'items' ELSE '[]'::jsonb END
         ) i
    WHERE jsonb_typeof(i) = 'string'
  )
  SELECT COALESCE(array_agg(lbl), ARRAY[]::text[]) FROM labels;
$function$;

COMMENT ON FUNCTION public.onboarding_substep_labels(jsonb) IS
  'Every sub-item label on a step, flat list or grouped. One place, so the gate trigger and the page agree.';

CREATE OR REPLACE FUNCTION public.onboarding_step_complete_gate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_labels  text[];
  v_done    text[];
  v_missing int;
BEGIN
  -- Only guard the moment a step goes from open to done.
  IF NEW.completed_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.completed_at IS NOT NULL THEN RETURN NEW; END IF;

  IF NEW.auto_source IS NOT NULL
     AND COALESCE(current_setting('app.onboarding_autotick', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This step fills itself in from the rest of Newtworks. It cannot be ticked by hand.';
  END IF;

  v_labels := public.onboarding_substep_labels(NEW.substeps);
  IF array_length(v_labels, 1) IS NULL THEN RETURN NEW; END IF;

  v_done := public.onboarding_substep_labels(
              CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array'
                   THEN NEW.substeps_done ELSE '[]'::jsonb END);

  SELECT count(*) INTO v_missing
  FROM unnest(v_labels) l
  WHERE NOT (l = ANY (v_done));

  IF v_missing > 0 THEN
    RAISE EXCEPTION 'Finish all % sub-items first. % still open.',
      array_length(v_labels, 1), v_missing;
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.onboarding_step_complete_gate() IS
  'Stops a step being marked done while any sub-item under it is still open, and stops self-filling steps being ticked by hand.';

DROP TRIGGER IF EXISTS trg_onboarding_step_complete_gate ON public.team_onboarding_steps;
CREATE TRIGGER trg_onboarding_step_complete_gate
  BEFORE INSERT OR UPDATE ON public.team_onboarding_steps
  FOR EACH ROW EXECUTE FUNCTION public.onboarding_step_complete_gate();

CREATE OR REPLACE FUNCTION public.onboarding_sync_reference_steps(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r            record;
  v_min        int;
  v_count      int;
  v_lines      jsonb;
  v_summary    jsonb;
  v_done       boolean;
  v_changed    int := 0;
  v_checked    int := 0;
BEGIN
  SELECT COALESCE(NULLIF(setting_value, '')::int, 2) INTO v_min
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'onboarding_reference_minimum';
  v_min := COALESCE(v_min, 2);

  FOR r IN
    SELECT s.id, s.completed_at, s.auto_summary,
           COALESCE(p.candidate_id, hc.id) AS candidate_id
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    LEFT JOIN public.hiring_candidates hc
      ON p.candidate_id IS NULL
     AND p.team_member_id IS NOT NULL
     AND hc.team_member_id = p.team_member_id
    WHERE p.agency_id = p_agency_id
      AND p.status IN ('active', 'paused')
      AND s.auto_source = 'references'
  LOOP
    v_checked := v_checked + 1;

    SELECT count(*),
           COALESCE(jsonb_agg(jsonb_build_object(
             'n',        x.reference_number,
             'referee',  x.referee,
             'received', to_char(x.received_at, 'Mon FMDD')
           ) ORDER BY x.reference_number), '[]'::jsonb)
    INTO v_count, v_lines
    FROM (
      SELECT cr.reference_number,
             cr.received_at,
             COALESCE(NULLIF(TRIM(cr.reference_analysis ->> 'referee'), ''),
                      'Reference ' || cr.reference_number::text) AS referee
      FROM public.hiring_candidate_references cr
      WHERE cr.candidate_id = r.candidate_id
    ) x;

    v_done := v_count >= v_min;

    v_summary := jsonb_build_object(
      'kind',     'references',
      'count',    v_count,
      'minimum',  v_min,
      'complete', v_done,
      'items',    v_lines
    );

    -- Nothing to write unless the summary or the done-state actually moved.
    IF r.auto_summary IS DISTINCT FROM v_summary
       OR (v_done AND r.completed_at IS NULL)
       OR (NOT v_done AND r.completed_at IS NOT NULL) THEN

      PERFORM set_config('app.onboarding_autotick', 'on', true);

      UPDATE public.team_onboarding_steps
      SET auto_summary  = v_summary,
          substeps      = NULL,
          substeps_done = NULL,
          completed_at  = CASE WHEN v_done THEN COALESCE(completed_at, now()) ELSE NULL END,
          completed_by  = CASE WHEN v_done THEN completed_by ELSE NULL END,
          updated_at    = now()
      WHERE id = r.id;

      PERFORM set_config('app.onboarding_autotick', 'off', true);
      v_changed := v_changed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('checked', v_checked, 'updated', v_changed, 'minimum', v_min);
END;
$function$;

COMMENT ON FUNCTION public.onboarding_sync_reference_steps(uuid) IS
  'Reads the hiring module reference emails for each running plan and ticks the reference step once enough are on file. Writes the short summary the page shows in place of hand checkboxes.';

GRANT EXECUTE ON FUNCTION public.onboarding_substep_labels(jsonb) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.onboarding_sync_reference_steps(uuid) TO authenticated, service_role;

UPDATE public.onboarding_step_templates
SET auto_source = 'references',
    substeps    = NULL,
    description = 'Ticks itself once the references are in. The summary comes straight from the reference emails in the hiring module.',
    updated_at  = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'p0_references_requested';

UPDATE public.team_onboarding_steps s
SET auto_source   = 'references',
    substeps      = NULL,
    substeps_done = NULL,
    description   = 'Ticks itself once the references are in. The summary comes straight from the reference emails in the hiring module.',
    updated_at    = now()
FROM public.team_onboarding_plans p
WHERE p.id = s.plan_id
  AND p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND s.template_key = 'p0_references_requested';

SELECT public.onboarding_sync_reference_steps('126794dd-25ff-47d2-a436-724499733365');
