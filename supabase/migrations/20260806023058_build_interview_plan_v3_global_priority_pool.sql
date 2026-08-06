-- v3: triggered placement is a single pooled pass over ALL rows matching ANY fired
-- code, ordered by priority DESC (tie: code ASC), per spec — v2 looped per-code in
-- alphabetical order, letting L_* rows consume budget ahead of higher-value T_* rows.
-- A placed row satisfies every code it carries. Also: gap probes raised to priority 60
-- (they carry the layer-gap requirement and should outrank generic facet-low probes).

UPDATE public.interview_questions
SET priority = 60, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND code IN ('BANK_GAP_COMMIT','BANK_GAP_CHAR');

CREATE OR REPLACE FUNCTION public.build_interview_plan(p_candidate_id uuid, p_target_minutes numeric DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $fn$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_fixed_overhead numeric := 13.0;
  v_universal_core_minutes numeric := 0;
  v_remaining numeric;
  v_triggers text[];
  v_questions jsonb := '[]'::jsonb;
  v_unfit_triggers text[] := ARRAY[]::text[];
  v_triggered_minutes numeric := 0;
  v_stretch_minutes numeric := 0;
  v_satisfied_codes text[] := ARRAY[]::text[];
  v_subconstruct_counts jsonb := '{}'::jsonb;
  q RECORD;
  v_key text;
  v_current_count int;
  v_code text;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  -- Step 3: universal_core -- always included in full, regardless of budget.
  -- Core rows do NOT count toward the triggered-set subconstruct cap.
  FOR q IN
    SELECT * FROM public.interview_questions
    WHERE agency_id = v_row.agency_id
      AND selection_mode = 'universal_core'
      AND is_active = true
    ORDER BY priority DESC
  LOOP
    v_universal_core_minutes := v_universal_core_minutes + q.est_minutes;
    v_questions := v_questions || jsonb_build_object(
      'code', q.code, 'construct', q.construct, 'subconstruct', q.subconstruct,
      'question_text', q.question_text, 'listen_for', q.listen_for, 'concern', q.concern,
      'followups', to_jsonb(q.followups), 'selection_mode', q.selection_mode,
      'est_minutes', q.est_minutes, 'source', q.source
    );
  END LOOP;

  v_remaining := p_target_minutes - v_fixed_overhead - v_universal_core_minutes;

  -- Step 5: triggered questions — ONE pooled pass, global priority order,
  -- cap max 2 per construct::subconstruct within the triggered set.
  v_triggers := public.interview_candidate_triggers(p_candidate_id);

  IF v_triggers IS NOT NULL AND array_length(v_triggers, 1) > 0 THEN
    FOR q IN
      SELECT * FROM public.interview_questions
      WHERE agency_id = v_row.agency_id
        AND is_active = true
        AND selection_mode IN ('triggered', 'legacy_triggered')
        AND trigger_codes && v_triggers
      ORDER BY priority DESC, code ASC
    LOOP
      v_key := q.construct || '::' || q.subconstruct;
      v_current_count := COALESCE((v_subconstruct_counts ->> v_key)::int, 0);

      IF v_current_count >= 2 THEN
        CONTINUE; -- subconstruct cap hit within the triggered set
      END IF;

      IF v_remaining >= q.est_minutes THEN
        v_questions := v_questions || jsonb_build_object(
          'code', q.code, 'construct', q.construct, 'subconstruct', q.subconstruct,
          'question_text', q.question_text, 'listen_for', q.listen_for, 'concern', q.concern,
          'followups', to_jsonb(q.followups), 'selection_mode', q.selection_mode,
          'est_minutes', q.est_minutes, 'source', q.source
        );
        v_remaining := v_remaining - q.est_minutes;
        v_triggered_minutes := v_triggered_minutes + q.est_minutes;
        v_satisfied_codes := v_satisfied_codes ||
          (SELECT COALESCE(array_agg(tc), ARRAY[]::text[])
           FROM unnest(q.trigger_codes) tc WHERE tc = ANY(v_triggers));
        v_subconstruct_counts := jsonb_set(v_subconstruct_counts, ARRAY[v_key], to_jsonb(v_current_count + 1), true);
      END IF;
    END LOOP;

    -- unfit = fired codes that HAVE bank rows but got none placed (budget/cap)
    FOREACH v_code IN ARRAY v_triggers LOOP
      IF NOT (v_code = ANY(v_satisfied_codes)) THEN
        IF EXISTS (
          SELECT 1 FROM public.interview_questions
          WHERE agency_id = v_row.agency_id AND is_active = true
            AND selection_mode IN ('triggered','legacy_triggered')
            AND trigger_codes @> ARRAY[v_code]
        ) THEN
          v_unfit_triggers := array_append(v_unfit_triggers, v_code);
        END IF;
      END IF;
    END LOOP;
  END IF;

  -- Step 6: universal_stretch fill
  IF v_remaining > 0 THEN
    FOR q IN
      SELECT * FROM public.interview_questions
      WHERE agency_id = v_row.agency_id
        AND selection_mode = 'universal_stretch'
        AND is_active = true
      ORDER BY priority DESC
    LOOP
      IF v_remaining >= q.est_minutes THEN
        v_questions := v_questions || jsonb_build_object(
          'code', q.code, 'construct', q.construct, 'subconstruct', q.subconstruct,
          'question_text', q.question_text, 'listen_for', q.listen_for, 'concern', q.concern,
          'followups', to_jsonb(q.followups), 'selection_mode', q.selection_mode,
          'est_minutes', q.est_minutes, 'source', q.source
        );
        v_remaining := v_remaining - q.est_minutes;
        v_stretch_minutes := v_stretch_minutes + q.est_minutes;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id,
    'target_minutes', p_target_minutes,
    'fixed_overhead_minutes', v_fixed_overhead,
    'universal_core_minutes', v_universal_core_minutes,
    'triggered_minutes', v_triggered_minutes,
    'stretch_minutes', v_stretch_minutes,
    'total_planned_minutes', v_fixed_overhead + v_universal_core_minutes + v_triggered_minutes + v_stretch_minutes,
    'budget_exceeded', (p_target_minutes - v_fixed_overhead - v_universal_core_minutes) < 0,
    'overage_minutes', CASE WHEN (p_target_minutes - v_fixed_overhead - v_universal_core_minutes) < 0
                             THEN abs(p_target_minutes - v_fixed_overhead - v_universal_core_minutes)
                             ELSE NULL END,
    'triggers_fired', COALESCE(to_jsonb(v_triggers), '[]'::jsonb),
    'unfit_triggers', to_jsonb(v_unfit_triggers),
    'questions', v_questions
  );
END;
$fn$;
