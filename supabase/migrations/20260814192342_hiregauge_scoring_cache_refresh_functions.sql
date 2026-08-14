-- Batch refresh: recompute + write the cached assessment_composite (and
-- protocol validity companions) for every candidate whose cache is behind
-- the current scoring version. Single set-based UPDATE, not a per-row loop.
-- Scope 'active' = in-progress pipeline statuses only (what the Kanban
-- board's own background check uses). Scope 'all' = every candidate with a
-- completed assessment, regardless of status (what the admin-only Refresh
-- All button uses). Reads off v_hiring_candidates so the cache can never
-- drift from the formula the rest of the app already trusts -- one
-- source of truth for the weighted-sum logic.
CREATE OR REPLACE FUNCTION public.hiregauge_refresh_scoring_cache(p_agency_id uuid, p_scope text DEFAULT 'active')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_version bigint;
  v_count integer;
BEGIN
  INSERT INTO public.hiregauge_scoring_version (agency_id, version, updated_at)
  VALUES (p_agency_id, 1, now())
  ON CONFLICT (agency_id) DO NOTHING;

  SELECT version INTO v_version FROM public.hiregauge_scoring_version WHERE agency_id = p_agency_id;

  WITH targets AS (
    SELECT hc.id
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.assessment_completed_at IS NOT NULL
      AND (
        p_scope = 'all'
        OR hc.status IN ('applied','assessment_sent','assessed','interview','team_meet_and_greet','reference_check','offer')
      )
      AND hc.cached_scoring_version IS DISTINCT FROM v_version
  ),
  scored AS (
    SELECT v.id, v.assessment_composite, v.protocol_validity_v, v.protocol_validity_label
    FROM public.v_hiring_candidates v
    JOIN targets t ON t.id = v.id
  )
  UPDATE public.hiring_candidates hc
  SET cached_assessment_composite = s.assessment_composite,
      cached_protocol_validity_v = s.protocol_validity_v,
      cached_protocol_validity_label = s.protocol_validity_label,
      cached_scoring_version = v_version,
      cached_at = now()
  FROM scored s
  WHERE hc.id = s.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- Single-candidate heal, used by the candidate detail page. No-ops (returns
-- false, touches nothing) if the candidate's cache already matches the
-- current scoring version -- this is the cheap common case. Only recomputes
-- and writes when the version has moved since this candidate was last cached.
CREATE OR REPLACE FUNCTION public.hiregauge_refresh_candidate_cache_if_stale(p_candidate_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid;
  v_version bigint;
  v_cached_version bigint;
  v_composite numeric;
  v_pv_v numeric;
  v_pv_label text;
BEGIN
  SELECT agency_id, cached_scoring_version INTO v_agency, v_cached_version
  FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT version INTO v_version FROM public.hiregauge_scoring_version WHERE agency_id = v_agency;
  IF v_version IS NULL THEN v_version := 1; END IF;

  IF v_cached_version IS NOT DISTINCT FROM v_version THEN
    RETURN false;
  END IF;

  SELECT assessment_composite, protocol_validity_v, protocol_validity_label
  INTO v_composite, v_pv_v, v_pv_label
  FROM public.v_hiring_candidates WHERE id = p_candidate_id;

  UPDATE public.hiring_candidates
  SET cached_assessment_composite = v_composite,
      cached_protocol_validity_v = v_pv_v,
      cached_protocol_validity_label = v_pv_label,
      cached_scoring_version = v_version,
      cached_at = now()
  WHERE id = p_candidate_id;

  RETURN true;
END;
$function$;
