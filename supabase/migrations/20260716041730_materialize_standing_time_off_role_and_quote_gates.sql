-- Add role-eligibility + personal-quote gate to materialize_standing_time_off.
--
-- Gate 1 unchanged: team WtW win prior week.
-- Gate 2 (new): only Account Manager / Unit Manager rows can fire on
-- trigger_type='wtw_won_prior_week'. Even eligible roles must clear the
-- canonical personal_minimum threshold (AM-Sales/UM-Sales 15 net quotes,
-- AM-Retention/UM-Retention 8 net quotes; Life half deferred until schema
-- ships). Any non-AM/UM row on wtw_won_prior_week is silently ignored and
-- counted under skipped_ineligible.
--
-- Return jsonb adds skipped_personal_min + skipped_ineligible_role counters.

CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_week_start date DEFAULT NULL::date, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_week_start DATE; v_week_end DATE; v_prior_sat DATE; v_won_prior BOOLEAN;
  v_created INT := 0; v_skipped_dup INT := 0; v_skipped_trig INT := 0;
  v_skipped_personal INT := 0; v_skipped_ineligible INT := 0;
  v_pref RECORD; v_target_date DATE; v_dow_int INT;
  v_partial TEXT; v_request_type TEXT; v_new_id UUID;
  v_role_level TEXT; v_role_category TEXT;
  v_personal_min INT; v_net_quotes INT; v_hit_personal BOOLEAN;
BEGIN
  IF p_week_start IS NOT NULL THEN
    v_week_start := p_week_start;
  ELSE
    v_week_start := (CURRENT_DATE + (((1 - EXTRACT(ISODOW FROM CURRENT_DATE)::INT + 7) % 7))::INT)::DATE;
    IF v_week_start <= CURRENT_DATE THEN v_week_start := v_week_start + 7; END IF;
  END IF;
  IF EXTRACT(ISODOW FROM v_week_start) <> 1 THEN
    RAISE EXCEPTION 'p_week_start must be a Monday, got % (isodow=%)', v_week_start, EXTRACT(ISODOW FROM v_week_start);
  END IF;

  IF NOT p_force AND v_week_start > CURRENT_DATE + INTERVAL '2 days' THEN
    RETURN jsonb_build_object(
      'error', 'lookahead_too_far',
      'message', format('week_start %s is more than 2 days beyond today %s; pass p_force := true to override', v_week_start, CURRENT_DATE),
      'week_start', v_week_start, 'today', CURRENT_DATE
    );
  END IF;

  v_week_end := v_week_start + 4;
  v_prior_sat := v_week_start - 2;

  SELECT won_the_week INTO v_won_prior FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_prior_sat;

  FOR v_pref IN
    SELECT p.id, p.team_member_id, p.day_of_week, p.day_part, p.pattern,
           p.is_paid, p.trigger_type, p.effective_from, p.effective_until
    FROM public.standing_time_off_preferences p
    WHERE p.agency_id = p_agency_id AND p.archived_at IS NULL
      AND p.effective_from <= v_week_end
      AND (p.effective_until IS NULL OR p.effective_until >= v_week_start)
  LOOP
    -- Gate 1: team WtW win prior week
    IF v_pref.trigger_type = 'wtw_won_prior_week' AND COALESCE(v_won_prior, false) = false THEN
      v_skipped_trig := v_skipped_trig + 1; CONTINUE;
    END IF;

    -- Gate 2: role eligibility + personal-quote minimum for prior week.
    -- Only Account Managers and Unit Managers qualify for 4-day-workweek WtW perk.
    -- AAs and any other role are hard-skipped: they don't get the perk regardless
    -- of quote hit. Any wtw_won_prior_week pref row on a non-AM teammate is a
    -- data mistake — silently ignored here, counted under skipped_ineligible.
    -- Thresholds per canonical WtW personal_minimum rule (Life half deferred):
    --   AM-Sales / UM-Sales:     net_quotes >= 15
    --   AM-Retention/UM-Retention: net_quotes >= 8
    IF v_pref.trigger_type = 'wtw_won_prior_week' THEN
      SELECT t.role_level, t.role_category INTO v_role_level, v_role_category
      FROM public.team t WHERE t.id = v_pref.team_member_id;

      IF v_role_level NOT IN ('Account Manager','Unit Manager') THEN
        v_skipped_ineligible := v_skipped_ineligible + 1;
        CONTINUE;
      END IF;

      v_personal_min := CASE v_role_category
                          WHEN 'Sales'     THEN 15
                          WHEN 'Retention' THEN 8
                          ELSE 15
                        END;

      SELECT req.net_quotes INTO v_net_quotes
      FROM public.get_weekly_cpr_requirements(p_agency_id, v_prior_sat) req
      WHERE req.team_member_id = v_pref.team_member_id;

      v_hit_personal := (COALESCE(v_net_quotes, 0) >= v_personal_min);

      IF NOT v_hit_personal THEN
        v_skipped_personal := v_skipped_personal + 1;
        CONTINUE;
      END IF;
    END IF;

    v_dow_int := CASE v_pref.day_of_week
      WHEN 'monday' THEN 0 WHEN 'tuesday' THEN 1 WHEN 'wednesday' THEN 2
      WHEN 'thursday' THEN 3 WHEN 'friday' THEN 4 END;
    v_target_date := v_week_start + v_dow_int;
    IF v_target_date < v_pref.effective_from THEN v_skipped_trig := v_skipped_trig + 1; CONTINUE; END IF;
    IF v_pref.effective_until IS NOT NULL AND v_target_date > v_pref.effective_until THEN
      v_skipped_trig := v_skipped_trig + 1; CONTINUE;
    END IF;

    IF v_pref.pattern = 'off' THEN
      IF v_pref.day_part = 'full' THEN v_request_type := 'time_off_full_day'; v_partial := 'none';
      ELSE v_request_type := 'time_off_half_day'; v_partial := v_pref.day_part; END IF;
    ELSE
      IF v_pref.day_part = 'full' THEN v_request_type := 'remote_day'; v_partial := 'none';
      ELSE v_request_type := 'remote_half_day'; v_partial := v_pref.day_part; END IF;
    END IF;

    BEGIN
      INSERT INTO public.time_off_requests (
        agency_id, requester_team_id, request_type, start_date, end_date, partial_day,
        notes, status, is_paid, is_planned, submitted_at, decided_at, decision_note,
        derived_from_standing_pref_id, decision_notified_at
      ) VALUES (
        p_agency_id, v_pref.team_member_id, v_request_type, v_target_date, v_target_date, v_partial,
        'Auto-generated from standing preference. Trigger: ' || v_pref.trigger_type
          || CASE WHEN v_pref.trigger_type='wtw_won_prior_week'
                  THEN ' (prior week ' || v_prior_sat::text || ' won + personal quotes hit)'
                  ELSE '' END,
        'approved', v_pref.is_paid, true, NOW(), NOW(),
        'Auto-approved via standing preference', v_pref.id, NOW()
      ) RETURNING id INTO v_new_id;
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN v_skipped_dup := v_skipped_dup + 1; END;
  END LOOP;

  RETURN jsonb_build_object(
    'week_start', v_week_start, 'week_end', v_week_end, 'prior_cpr_sat', v_prior_sat,
    'won_prior_week', v_won_prior, 'created', v_created,
    'skipped_dup', v_skipped_dup, 'skipped_trigger', v_skipped_trig,
    'skipped_personal_min', v_skipped_personal,
    'skipped_ineligible_role', v_skipped_ineligible
  );
END $function$;
