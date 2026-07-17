-- Weekly materialization: for a target work week (Mon-Fri), read every
-- active standing_time_off_preferences row for the agency, evaluate its
-- trigger (against weekly_cpr_reports.won_the_week for the prior week if
-- trigger_type='wtw_won_prior_week'), and INSERT concrete time_off_requests
-- rows with status='approved', is_planned=true, derived_from_standing_pref_id.
-- Idempotent via ux_tor_derived_pref_date unique index.

CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(
  p_agency_id UUID DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_week_start DATE DEFAULT NULL  -- Monday of target work week; NULL = next Monday
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_week_start   DATE;
  v_week_end     DATE;              -- Friday of target week
  v_prior_sat    DATE;              -- Saturday ending prior CPR week (Sun-Sat)
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
  v_week_start := COALESCE(p_week_start, (CURRENT_DATE + ((8 - EXTRACT(ISODOW FROM CURRENT_DATE)::INT) % 7)::INT)::DATE);
  -- If today is Monday, "next Monday" should be 7 days out
  IF EXTRACT(ISODOW FROM v_week_start) <> 1 THEN
    RAISE EXCEPTION 'p_week_start must be a Monday, got % (isodow=%)', v_week_start, EXTRACT(ISODOW FROM v_week_start);
  END IF;
  v_week_end := v_week_start + 4;  -- Friday

  -- Prior CPR week (Sun-Sat) — the Saturday immediately before v_week_start (Monday)
  -- If v_week_start = Monday 7/20/2026, prior CPR week ended Sat 7/18/2026.
  v_prior_sat := v_week_start - 2;

  SELECT won_the_week INTO v_won_prior
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_prior_sat;
  -- If no CPR row, treat as NULL (=false for WtW gate)

  -- Walk each active pref
  FOR v_pref IN
    SELECT p.id, p.team_member_id, p.day_of_week, p.day_part, p.pattern,
           p.is_paid, p.trigger_type, p.effective_from, p.effective_until
    FROM public.standing_time_off_preferences p
    WHERE p.agency_id = p_agency_id
      AND p.archived_at IS NULL
      AND p.effective_from <= v_week_end
      AND (p.effective_until IS NULL OR p.effective_until >= v_week_start)
  LOOP
    -- Trigger gate
    IF v_pref.trigger_type = 'wtw_won_prior_week' AND COALESCE(v_won_prior, false) = false THEN
      v_skipped_trig := v_skipped_trig + 1;
      CONTINUE;
    END IF;

    -- Map day_of_week text to date within target week
    v_dow_int := CASE v_pref.day_of_week
      WHEN 'monday'    THEN 0
      WHEN 'tuesday'   THEN 1
      WHEN 'wednesday' THEN 2
      WHEN 'thursday'  THEN 3
      WHEN 'friday'    THEN 4
    END;
    v_target_date := v_week_start + v_dow_int;

    -- Skip if target date outside pref effective window
    IF v_target_date < v_pref.effective_from THEN
      v_skipped_trig := v_skipped_trig + 1;
      CONTINUE;
    END IF;
    IF v_pref.effective_until IS NOT NULL AND v_target_date > v_pref.effective_until THEN
      v_skipped_trig := v_skipped_trig + 1;
      CONTINUE;
    END IF;

    -- Map (day_part, pattern) → (request_type, partial_day)
    IF v_pref.pattern = 'off' THEN
      IF v_pref.day_part = 'full' THEN
        v_request_type := 'time_off_full_day';
        v_partial := 'none';
      ELSE
        v_request_type := 'time_off_half_day';
        v_partial := v_pref.day_part;  -- 'morning' or 'afternoon'
      END IF;
    ELSE  -- remote
      IF v_pref.day_part = 'full' THEN
        v_request_type := 'remote_day';
        v_partial := 'none';
      ELSE
        v_request_type := 'remote_half_day';
        v_partial := v_pref.day_part;
      END IF;
    END IF;

    -- Insert (idempotent on ux_tor_derived_pref_date)
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
        derived_from_standing_pref_id
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
        true,  -- planned
        NOW(),
        NOW(),
        'Auto-approved via standing preference',
        v_pref.id
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

COMMENT ON FUNCTION public.materialize_standing_time_off IS
  'For a target work week (Mon-Fri), materializes concrete time_off_requests from standing_time_off_preferences. Gates wtw_won_prior_week prefs on weekly_cpr_reports.won_the_week for the prior CPR week. Idempotent via ux_tor_derived_pref_date. Default p_week_start = next Monday.';;