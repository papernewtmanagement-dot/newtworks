-- ONE place that answers "where is this candidate's reference check up to".
--
-- onboarding_sync_reference_steps used to compute this inline. Item 3 and item
-- 4 both need the same answer, so the computation moves here and the step sync
-- is rewritten to call it. Three callers, one function — nothing recomputes a
-- positive count of its own.
--
-- The shape returned is exactly what team_onboarding_steps.auto_summary has
-- always held, so the step sync stores the return value unchanged and no
-- reader downstream has to change.

CREATE OR REPLACE FUNCTION public.hiring_reference_progress(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_agency   uuid;
  v_need     int;
  v_asked    int;
  v_count    int;
  v_positive int;
  v_lines    jsonb;
BEGIN
  SELECT agency_id INTO v_agency FROM public.hiring_candidates WHERE id = p_candidate_id;

  SELECT COALESCE(NULLIF(setting_value,'')::int, 2) INTO v_need
  FROM public.settings
  WHERE agency_id = v_agency AND setting_key = 'onboarding_reference_minimum';
  v_need := COALESCE(v_need, 2);

  SELECT COALESCE(NULLIF(setting_value,'')::int, 3) INTO v_asked
  FROM public.settings
  WHERE agency_id = v_agency AND setting_key = 'onboarding_reference_requested';
  v_asked := COALESCE(v_asked, 3);

  SELECT count(*),
         count(*) FILTER (WHERE x.positive),
         COALESCE(jsonb_agg(jsonb_build_object(
           'n',         x.reference_number,
           'referee',   x.referee,
           'received',  to_char(x.received_at, 'Mon FMDD'),
           'positive',  x.positive,
           'feedback',  x.narrative,
           'red_flags', to_jsonb(x.red_flags)
         ) ORDER BY x.reference_number), '[]'::jsonb)
  INTO v_count, v_positive, v_lines
  FROM (
    SELECT cr.reference_number, cr.received_at,
           COALESCE(NULLIF(TRIM(cr.reference_analysis ->> 'referee'),''),
                    'Reference ' || cr.reference_number::text) AS referee,
           NULLIF(TRIM(COALESCE(cr.reference_analysis ->> 'narrative','')),'') AS narrative,
           public.reference_is_positive(cr.reference_analysis) AS positive,
           public.reference_red_flags(cr.reference_analysis)   AS red_flags
    FROM public.hiring_candidate_references cr
    WHERE cr.candidate_id = p_candidate_id
  ) x;

  RETURN jsonb_build_object(
    'kind',      'references',
    'asked_for', v_asked,
    'count',     COALESCE(v_count, 0),
    'positive',  COALESCE(v_positive, 0),
    'minimum',   v_need,
    'complete',  COALESCE(v_positive, 0) >= v_need,
    'items',     COALESCE(v_lines, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.hiring_reference_progress(uuid) IS
  'The single answer to how far a candidate reference check has got. Counts write-ups, scores each one through reference_is_positive, and reports against the agency minimum. Called by onboarding_sync_reference_steps, the caller notices and the escalation ladder. Never recompute a positive count anywhere else.';

-- Step sync now calls it instead of carrying its own copy of the arithmetic.
CREATE OR REPLACE FUNCTION public.onboarding_sync_reference_steps(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r          record;
  v_summary  jsonb;
  v_done     boolean;
  v_changed  int := 0;
  v_checked  int := 0;
BEGIN
  FOR r IN
    SELECT s.id, s.completed_at, s.auto_summary,
           COALESCE(p.candidate_id, hc.id) AS candidate_id
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    LEFT JOIN public.hiring_candidates hc
      ON p.candidate_id IS NULL AND p.team_member_id IS NOT NULL
     AND hc.team_member_id = p.team_member_id
    WHERE p.agency_id = p_agency_id
      AND p.status IN ('active','paused')
      AND s.auto_source = 'references'
  LOOP
    v_checked := v_checked + 1;

    v_summary := public.hiring_reference_progress(r.candidate_id);
    v_done    := COALESCE((v_summary ->> 'complete')::boolean, false);

    IF r.auto_summary IS DISTINCT FROM v_summary
       OR (v_done AND r.completed_at IS NULL)
       OR (NOT v_done AND r.completed_at IS NOT NULL) THEN

      PERFORM set_config('app.onboarding_autotick','on',true);

      UPDATE public.team_onboarding_steps
      SET auto_summary  = v_summary,
          substeps      = NULL,
          substeps_done = NULL,
          completed_at  = CASE WHEN v_done THEN COALESCE(completed_at, now()) ELSE NULL END,
          completed_by  = CASE WHEN v_done THEN completed_by ELSE NULL END,
          updated_at    = now()
      WHERE id = r.id;

      PERFORM set_config('app.onboarding_autotick','off',true);
      v_changed := v_changed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('checked', v_checked, 'updated', v_changed);
END;
$function$;

-- ONE place that answers "who is calling this candidate's references".
-- The picker in the offer letter stores a kind, not a list of people, because
-- "the retention team" is a standing group whose membership changes. Resolving
-- it here means the notice, the nudge and the calling page all agree.
CREATE OR REPLACE FUNCTION public.hiring_reference_callers(p_candidate_id uuid)
RETURNS TABLE(team_member_id uuid, caller_name text, caller_email text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE c record;
BEGIN
  SELECT hc.agency_id, hc.reference_caller_kind, hc.reference_caller_team_id,
         hc.reference_caller_name, hc.reference_caller_email
  INTO c
  FROM public.hiring_candidates hc WHERE hc.id = p_candidate_id;

  IF NOT FOUND THEN RETURN; END IF;

  IF c.reference_caller_kind = 'team' AND c.reference_caller_team_id IS NOT NULL THEN
    RETURN QUERY
      SELECT t.id,
             NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name,'')), ''),
             COALESCE(NULLIF(t.email_personal,''), NULLIF(t.email_sf,''))
      FROM public.team t
      WHERE t.id = c.reference_caller_team_id;

  ELSIF c.reference_caller_kind = 'outside' THEN
    RETURN QUERY SELECT NULL::uuid, c.reference_caller_name, c.reference_caller_email;

  ELSE
    -- retention, and the fallback for anything unset
    RETURN QUERY
      SELECT t.id,
             NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name,'')), ''),
             COALESCE(NULLIF(t.email_personal,''), NULLIF(t.email_sf,''))
      FROM public.team t
      WHERE t.agency_id = c.agency_id
        AND t.is_active
        AND t.archived_at IS NULL
        AND t.role_category = 'Retention'
      ORDER BY t.first_name;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.hiring_reference_callers(uuid) IS
  'Who is calling this candidate references. Turns the stored caller kind (team, outside, retention) into actual people. Retention resolves live off role_category so a change of staff needs no re-pick on the candidate.';
