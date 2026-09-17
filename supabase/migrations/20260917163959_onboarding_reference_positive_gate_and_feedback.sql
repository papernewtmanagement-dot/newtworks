-- =========================================================================
-- Reference gate: we ask for three, we move at two positive
-- =========================================================================
-- The step no longer ticks on "two arrived". It ticks on "two came back
-- positive", which is what unblocks Order equipment. The summary now
-- carries the feedback and any red flags, not just a count.
-- =========================================================================

INSERT INTO public.settings (agency_id, setting_key, setting_value)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'onboarding_reference_requested', '3'
WHERE NOT EXISTS (SELECT 1 FROM public.settings
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND setting_key='onboarding_reference_requested');

UPDATE public.settings SET setting_value = '2'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND setting_key='onboarding_reference_minimum';

COMMENT ON COLUMN public.team_onboarding_steps.auto_summary IS
  'Short read-only summary the onboarding page shows where the hand checkboxes would be. For references: how many we asked for, how many came back positive, each referee with their feedback and any red flags.';

-- ── what counts as a positive reference ─────────────────────────────────
-- Willingness to rehire is the single most predictive thing a referee
-- says, so it carries the gate. Honesty and personal responsibility are
-- the agency's own character floor and have to clear too. A referee who
-- will not criticise tells us nothing, so low candor holds a reference
-- back from counting even when every number is high.
CREATE OR REPLACE FUNCTION public.reference_is_positive(p_analysis jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT COALESCE(
    (p_analysis -> 'signals' ->> 'rehire_intent')::numeric >= 70
    AND (p_analysis -> 'signals' ->> 'honesty')::numeric >= 60
    AND (p_analysis -> 'signals' ->> 'personal_responsibility')::numeric >= 60
    AND COALESCE((p_analysis ->> 'candor')::numeric, 0) >= 50
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_each_text(COALESCE(p_analysis -> 'signals', '{}'::jsonb)) s
      WHERE s.value ~ '^[0-9.]+$' AND s.value::numeric < 50
    ),
  false);
$function$;

COMMENT ON FUNCTION public.reference_is_positive(jsonb) IS
  'True when a scored reference counts toward the two we need. Rehire intent 70+, honesty and personal responsibility 60+, candor 50+, nothing under 50.';

-- ── red flags, in plain English ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reference_red_flags(p_analysis jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $function$
  WITH named AS (
    SELECT CASE s.key
             WHEN 'honesty' THEN 'Honesty'
             WHEN 'motivation' THEN 'Motivation'
             WHEN 'work_ethic' THEN 'Work ethic'
             WHEN 'communication' THEN 'Communication'
             WHEN 'rehire_intent' THEN 'Would not rehire'
             WHEN 'learning_speed' THEN 'Learning speed'
             WHEN 'concern_for_others' THEN 'Concern for others'
             WHEN 'attitude_toward_work' THEN 'Attitude toward work'
             WHEN 'personal_responsibility' THEN 'Personal responsibility'
             WHEN 'demonstrated_sales_ability' THEN 'Selling'
             ELSE replace(initcap(s.key), '_', ' ')
           END AS label,
           s.value::numeric AS score
    FROM jsonb_each_text(COALESCE(p_analysis -> 'signals', '{}'::jsonb)) s
    WHERE s.value ~ '^[0-9.]+$'
  )
  SELECT COALESCE(
    array_agg(f ORDER BY f),
    ARRAY[]::text[]
  )
  FROM (
    SELECT label || ' is low (' || round(score)::text || ')' AS f
    FROM named WHERE score < 50
    UNION ALL
    SELECT 'The referee would not say anything critical, so read this one as an upper bound'
    WHERE COALESCE((p_analysis ->> 'candor')::numeric, 100) < 50
    UNION ALL
    SELECT 'Would rehire is only ' || round((p_analysis -> 'signals' ->> 'rehire_intent')::numeric)::text
    WHERE COALESCE((p_analysis -> 'signals' ->> 'rehire_intent')::numeric, 100) BETWEEN 50 AND 69
  ) q;
$function$;

COMMENT ON FUNCTION public.reference_red_flags(jsonb) IS
  'Anything on a scored reference that should stop someone in their tracks, written so it can be read straight off the page.';

-- ── sync now gates on positive, and carries the feedback ────────────────
CREATE OR REPLACE FUNCTION public.onboarding_sync_reference_steps(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r          record;
  v_need     int;
  v_asked    int;
  v_count    int;
  v_positive int;
  v_lines    jsonb;
  v_summary  jsonb;
  v_done     boolean;
  v_changed  int := 0;
  v_checked  int := 0;
BEGIN
  SELECT COALESCE(NULLIF(setting_value,'')::int, 2) INTO v_need
  FROM public.settings WHERE agency_id=p_agency_id AND setting_key='onboarding_reference_minimum';
  v_need := COALESCE(v_need, 2);

  SELECT COALESCE(NULLIF(setting_value,'')::int, 3) INTO v_asked
  FROM public.settings WHERE agency_id=p_agency_id AND setting_key='onboarding_reference_requested';
  v_asked := COALESCE(v_asked, 3);

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
      WHERE cr.candidate_id = r.candidate_id
    ) x;

    v_done := v_positive >= v_need;

    v_summary := jsonb_build_object(
      'kind',      'references',
      'asked_for', v_asked,
      'count',     v_count,
      'positive',  v_positive,
      'minimum',   v_need,
      'complete',  v_done,
      'items',     v_lines
    );

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

  RETURN jsonb_build_object('checked', v_checked, 'updated', v_changed,
                            'asked_for', v_asked, 'positive_needed', v_need);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reference_is_positive(jsonb) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.reference_red_flags(jsonb) TO authenticated, anon, service_role;

SELECT public.onboarding_sync_reference_steps('126794dd-25ff-47d2-a436-724499733365');
