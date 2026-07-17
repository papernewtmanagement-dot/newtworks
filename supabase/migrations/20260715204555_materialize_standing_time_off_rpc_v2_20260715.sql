-- v2: pre-stamp decision_notified_at on auto-generated rows so the
-- decision-email loop in time_off_notification_dispatch doesn't spam
-- the whole team with "Steph's Mon+Wed pattern approved" every week.
-- Calendar dispatch still runs (calendar_dispatched_at left NULL).

CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(
  p_agency_id UUID DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_week_start DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_week_start   DATE;
  v_week_end     DATE;
  v_prior_sat    DATE;
  v_won_prior    BOOLEAN;
  v_created      INT := 0;
  v_skipped_dup  INT := 0;
  v_skipped_trig INT := 0;
  v_pref RECORD;
  v_target_date DATE;
  v_dow_int INT;
  v_partial TEXT;
  v_request_type TEXT;
  v_new_id UUID;
BEGIN
  -- Resolve target Monday: default = next Monday relative to today
  IF p_week_start IS NOT NULL THEN
    v_week_start := p_week_start;
  ELSE
    -- Next Monday: today plus days-until-next-Mon (7 if today IS Monday)
    v_week_start := (CURRENT_DATE + ((8 - EXTRACT(ISODOW FROM CURRENT_DATE)::INT) % 7 + CASE WHEN EXTRACT(ISODOW FROM CURRENT_DATE)::INT = 1 THEN 7 ELSE 0 END)::INT)::DATE;
    -- Simplified: just skip forward until we hit ISODOW=1 next
    IF EXTRACT(ISODOW FROM v_week_start) <> 1 THEN
      v_week_start := (CURRENT_DATE + (((1 - EXTRACT(ISODOW FROM CURRENT_DATE)::INT + 7) % 7))::INT)::DATE;
      IF v_week_start <= CURRENT_DATE THEN
        v_week_start := v_week_start + 7;
      END IF;
    END IF;
  END IF;

  IF EXTRACT(ISODOW FROM v_week_start) <> 1 THEN
    RAISE EXCEPTION 'p_week_start must be a Monday, got % (isodow=%)', v_week_start, EXTRACT(ISODOW FROM v_week_start);
  END IF;
  v_week_end := v_week_start + 4;
  v_prior_sat := v_week_start - 2;

  SELECT won_the_week INTO v_won_prior
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_prior_sat;

  FOR v_pref IN
    SELECT p.id, p.team_member_id, p.day_of_week, p.day_part, p.pattern,
           p.is_paid, p.trigger_type, p.effective_from, p.effective_until
    FROM public.standing_time_off_preferences p
    WHERE p.agency_id = p_agency_id
      AND p.archived_at IS NULL
      AND p.effective_from <= v_week_end
      AND (p.effective_until IS NULL OR p.effective_until >= v_week_start)
  LOOP
    IF v_pref.trigger_type = 'wtw_won_prior_week' AND COALESCE(v_won_prior, false) = false THEN
      v_skipped_trig := v_skipped_trig + 1;
      CONTINUE;
    END IF;

    v_dow_int := CASE v_pref.day_of_week
      WHEN 'monday'    THEN 0
      WHEN 'tuesday'   THEN 1
      WHEN 'wednesday' THEN 2
      WHEN 'thursday'  THEN 3
      WHEN 'friday'    THEN 4
    END;
    v_target_date := v_week_start + v_dow_int;

    IF v_target_date < v_pref.effective_from THEN
      v_skipped_trig := v_skipped_trig + 1;
      CONTINUE;
    END IF;
    IF v_pref.effective_until IS NOT NULL AND v_target_date > v_pref.effective_until THEN
      v_skipped_trig := v_skipped_trig + 1;
      CONTINUE;
    END IF;

    IF v_pref.pattern = 'off' THEN
      IF v_pref.day_part = 'full' THEN
        v_request_type := 'time_off_full_day';
        v_partial := 'none';
      ELSE
        v_request_type := 'time_off_half_day';
        v_partial := v_pref.day_part;
      END IF;
    ELSE
      IF v_pref.day_part = 'full' THEN
        v_request_type := 'remote_day';
        v_partial := 'none';
      ELSE
        v_request_type := 'remote_half_day';
        v_partial := v_pref.day_part;
      END IF;
    END IF;

    BEGIN
      INSERT INTO public.time_off_requests (
        agency_id,
        requester_team_id,
        request_type,
        start_date,
        end_date,
        partial_day,
        notes,
        status,
        is_paid,
        is_planned,
        submitted_at,
        decided_at,
        decision_note,
        derived_from_standing_pref_id,
        decision_notified_at  -- pre-stamp: suppresses decision-email spam
      ) VALUES (
        p_agency_id,
        v_pref.team_member_id,
        v_request_type,
        v_target_date,
        v_target_date,
        v_partial,
        'Auto-generated from standing preference. Trigger: ' || v_pref.trigger_type
          || CASE WHEN v_pref.trigger_type='wtw_won_prior_week'
                  THEN ' (prior week ' || v_prior_sat::text || ' won)'
                  ELSE '' END,
        'approved',
        v_pref.is_paid,
        true,
        NOW(),
        NOW(),
        'Auto-approved via standing preference',
        v_pref.id,
        NOW()  -- suppress email notification
      )
      RETURNING id INTO v_new_id;
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN
      v_skipped_dup := v_skipped_dup + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'week_start',      v_week_start,
    'week_end',        v_week_end,
    'prior_cpr_sat',   v_prior_sat,
    'won_prior_week',  v_won_prior,
    'created',         v_created,
    'skipped_dup',     v_skipped_dup,
    'skipped_trigger', v_skipped_trig
  );
END $$;

-- Overload for automation-runner shape (agency_id, recipe_id)
CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(
  p_agency_id UUID,
  p_recipe_id UUID
)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.materialize_standing_time_off(p_agency_id, NULL::date);
$$;

COMMENT ON FUNCTION public.materialize_standing_time_off(uuid, date) IS
  'For a target work week (Mon-Fri), materializes concrete time_off_requests from standing_time_off_preferences. Gates wtw_won_prior_week prefs on weekly_cpr_reports.won_the_week for the prior CPR week. Idempotent via ux_tor_derived_pref_date. Pre-stamps decision_notified_at to suppress email spam. Calendar dispatch runs normally. Default p_week_start = next Monday.';;