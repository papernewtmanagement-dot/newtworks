-- Step 1e: automatic rebuild of the current set's compared-to-average norm
-- once enough people have taken it, so a provisional seed can never quietly
-- become permanent. A norm describes ONE item set; completions are never
-- pooled across sets (Nunnally & Bernstein 1994; AERA/APA/NCME Standards
-- 2014).

CREATE OR REPLACE FUNCTION public.hiregauge_gma_norm_rebuild_current_set(p_agency uuid, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
-- Rebuilds the current set's 'gma' (percent-correct) and 'gma_speed'
-- (correct items per minute) norm rows from completed sittings ON THAT SET
-- once N >= hiregauge_gma_item_sets.norm_rebuild_min_n, then refreshes the
-- scoring cache. No-op while the count is short or the set is already
-- rebuilt (p_force re-runs it, e.g. the N>=50 refresh). A completion = a
-- candidate locked to the set, with gma_total_accuracy written, who answered
-- every item of the set. The speed row is only rewritten with at least 10
-- usable timings -- a mean built on fewer moves candidates around for no
-- good reason.
DECLARE
  v_set text;
  v_status text;
  v_min_n int;
  v_n int;
  v_size int;
  v_mean numeric; v_sd numeric;
  v_speed_n int; v_speed_mean numeric; v_speed_sd numeric;
BEGIN
  SELECT set_key, norm_status, norm_rebuild_min_n INTO v_set, v_status, v_min_n
  FROM public.hiregauge_gma_item_sets WHERE agency_id = p_agency AND is_current;
  IF v_set IS NULL THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'no_current_set');
  END IF;
  IF v_status = 'rebuilt' AND NOT p_force THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'already_rebuilt', 'set_key', v_set);
  END IF;

  SELECT count(*)::int INTO v_size FROM public.hiregauge_gma_item_set_members WHERE set_key = v_set;

  WITH done AS (
    SELECT c.id, c.gma_total_accuracy
    FROM public.hiring_candidates c
    WHERE c.agency_id = p_agency
      AND c.gma_item_set = v_set
      AND c.gma_total_accuracy IS NOT NULL
      AND (SELECT count(*) FROM public.hiregauge_candidate_responses r
           JOIN public.hiregauge_gma_item_set_members m ON m.item_id = r.item_id AND m.set_key = v_set
           WHERE r.candidate_id = c.id) = v_size
  )
  SELECT count(*)::int,
         round(avg(gma_total_accuracy::numeric / v_size * 100.0), 2),
         round(stddev_samp(gma_total_accuracy::numeric / v_size * 100.0), 2)
    INTO v_n, v_mean, v_sd
  FROM done;

  IF v_n < v_min_n AND NOT p_force THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'waiting_for_n', 'set_key', v_set, 'n', v_n, 'min_n', v_min_n);
  END IF;
  IF v_n < 2 OR v_sd IS NULL OR v_sd <= 0 THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'too_few_or_no_spread', 'set_key', v_set, 'n', v_n);
  END IF;

  WITH done AS (
    SELECT c.id
    FROM public.hiring_candidates c
    WHERE c.agency_id = p_agency
      AND c.gma_item_set = v_set
      AND c.gma_total_accuracy IS NOT NULL
      AND (SELECT count(*) FROM public.hiregauge_candidate_responses r
           JOIN public.hiregauge_gma_item_set_members m ON m.item_id = r.item_id AND m.set_key = v_set
           WHERE r.candidate_id = c.id) = v_size
  ), sp AS (
    SELECT public.hiregauge_gma_speed_ipm(id) AS ipm FROM done
  )
  SELECT count(ipm)::int, round(avg(ipm), 4), round(stddev_samp(ipm), 4)
    INTO v_speed_n, v_speed_mean, v_speed_sd
  FROM sp WHERE ipm IS NOT NULL;

  UPDATE public.hiregauge_facet_norms
  SET ref_mean_0_100 = v_mean,
      ref_sd_0_100   = v_sd,
      retrieved_from = format('REBUILT %s from %s completed sittings on item set %s (hiregauge_gma_norm_rebuild_current_set)', now()::date, v_n, v_set),
      notes          = format('Local applicant-pool norm for item set %s, N=%s. Refresh at N>=50 on the same set (p_force). NORM IS TIED TO THE ITEM SET: reset to a provisional seed when the set changes; never pool across sets.', v_set, v_n),
      updated_by     = 'hiregauge_gma_norm_rebuild_current_set',
      updated_at     = now()
  WHERE agency_id = p_agency AND facet = 'gma';

  IF v_speed_n >= 10 AND v_speed_sd IS NOT NULL AND v_speed_sd > 0 THEN
    UPDATE public.hiregauge_facet_norms
    SET ref_mean_0_100 = v_speed_mean,
        ref_sd_0_100   = v_speed_sd,
        retrieved_from = format('REBUILT %s from the %s of %s completed sittings on item set %s at or above the reasoning floor (hiregauge_gma_norm_rebuild_current_set)', now()::date, v_speed_n, v_n, v_set),
        notes          = format('Local applicant-pool speed norm for item set %s, N=%s (correct items per minute on correct items, floor-gated). Refresh at N>=50 on the same set. Reset when the set changes.', v_set, v_speed_n),
        updated_by     = 'hiregauge_gma_norm_rebuild_current_set',
        updated_at     = now()
    WHERE agency_id = p_agency AND facet = 'gma_speed';
  END IF;

  UPDATE public.hiregauge_gma_item_sets SET norm_status = 'rebuilt', updated_at = now() WHERE set_key = v_set;

  -- the norm writes bumped hiregauge_scoring_version via trigger; recompute caches
  PERFORM public.hiregauge_refresh_scoring_cache(p_agency, 'all');

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
  VALUES (p_agency, 'assessment_norm_rebuilt', 'info',
          format('GMA norm rebuilt for item set %s', v_set),
          format('The compared-to-average GMA norm for item set %s was rebuilt from %s completed sittings: mean %s%%, SD %s. Speed norm: %s. Every candidate on this set was rescored.',
                 v_set, v_n, v_mean, v_sd,
                 CASE WHEN v_speed_n >= 10 THEN format('mean %s, SD %s, N=%s', v_speed_mean, v_speed_sd, v_speed_n) ELSE format('left on its seed (only %s timed completions above the floor)', v_speed_n) END),
          'hiring', false, false);

  RETURN jsonb_build_object('rebuilt', true, 'set_key', v_set, 'n', v_n, 'gma_mean', v_mean, 'gma_sd', v_sd,
                            'speed_n', v_speed_n, 'speed_mean', v_speed_mean, 'speed_sd', v_speed_sd);
END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_gma_norm_auto_rebuild_trg()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    PERFORM public.hiregauge_gma_norm_rebuild_current_set(NEW.agency_id, false);
  EXCEPTION WHEN OTHERS THEN
    -- Never let a norm rebuild block a candidate's scoring write.
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
    VALUES (NEW.agency_id, 'assessment_norm_rebuild_failed', 'warning',
            'GMA norm auto-rebuild failed',
            format('hiregauge_gma_norm_rebuild_current_set raised: %s. Run it by hand: SELECT public.hiregauge_gma_norm_rebuild_current_set(agency, false).', SQLERRM),
            'hiring', false, false);
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gma_norm_auto_rebuild ON public.hiring_candidates;
CREATE TRIGGER trg_gma_norm_auto_rebuild
  AFTER UPDATE OF gma_total_accuracy ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.gma_total_accuracy IS NOT NULL AND OLD.gma_total_accuracy IS DISTINCT FROM NEW.gma_total_accuracy)
  EXECUTE FUNCTION public.hiregauge_gma_norm_auto_rebuild_trg();

REVOKE ALL ON FUNCTION public.hiregauge_gma_norm_rebuild_current_set(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_norm_rebuild_current_set(uuid, boolean) TO authenticated, service_role;
