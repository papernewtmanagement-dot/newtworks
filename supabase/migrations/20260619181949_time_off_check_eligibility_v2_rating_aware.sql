-- v2: rating-aware eligibility check.
-- Changes from v1:
--  1. Handles all manager tiers (Account Manager, Unit Manager, Section Manager, Office Manager) — v1 only handled Account Manager.
--  2. Actually computes Sales Points / TRUE PAY ratings using rolling 13-week avg + sales_points_band_config.
--  3. Rule: post-probation managers/AMs are 'eligible' iff BOTH their individual rating AND the agency rating are Good or better.
--  4. Graceful degradation: if no weekly data exists yet (NULL avg), returns 'pending_review' with that reason rather than implicit Danger.
CREATE OR REPLACE FUNCTION public.time_off_check_eligibility(p_requester_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_team                    RECORD;
  v_weeks_employed          integer;
  v_is_post_probation       boolean;
  v_role_level              text;
  v_is_owner                boolean;
  v_is_account_associate    boolean;
  v_is_manager_tier         boolean;  -- Account Manager OR any *Manager* tier
  v_individual_avg          numeric;
  v_individual_rating       text;
  v_individual_passes       boolean;
  v_agency_avg              numeric;
  v_agency_rating           text;
  v_agency_passes           boolean;
  v_overall                 text;
  v_reasons                 text[] := ARRAY[]::text[];
BEGIN
  SELECT first_name, last_name, role, role_level, hire_date, category, archived_at, agency_id
    INTO v_team
    FROM public.team
   WHERE id = p_requester_team_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'overall_eligibility', 'ineligible',
      'reasons', ARRAY['team member not found']);
  END IF;

  IF v_team.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'overall_eligibility', 'ineligible',
      'reasons', ARRAY['team member is archived']);
  END IF;

  v_weeks_employed := CASE
    WHEN v_team.hire_date IS NULL THEN 0
    ELSE FLOOR((CURRENT_DATE - v_team.hire_date) / 7.0)::integer
  END;
  v_is_post_probation := v_weeks_employed >= 13;

  v_role_level           := COALESCE(v_team.role_level, '');
  v_is_owner             := v_role_level = 'Owner';
  v_is_account_associate := v_role_level = 'Account Associate';
  v_is_manager_tier      := v_role_level IN ('Account Manager', 'Unit Manager', 'Section Manager', 'Office Manager');

  IF v_is_owner THEN
    v_overall := 'eligible';

  ELSIF v_is_manager_tier AND v_is_post_probation THEN
    -- Compute both rolling 13-week averages
    v_individual_avg := public.team_member_sales_points_avg_13wk(p_requester_team_id);
    v_agency_avg     := public.agency_sales_points_avg_13wk(v_team.agency_id);

    IF v_individual_avg IS NULL OR v_agency_avg IS NULL THEN
      -- Insufficient data — degrade to manual review
      v_overall := 'pending_review';
      v_reasons := array_append(v_reasons,
        'Insufficient weekly Sales Points data for rating — manual review by agent required');
    ELSE
      v_individual_rating := public.compute_sales_points_rating(v_team.agency_id, v_individual_avg);
      v_agency_rating     := public.compute_sales_points_rating(v_team.agency_id, v_agency_avg);
      v_individual_passes := v_individual_rating IN ('Good', 'Great', 'Elite');
      v_agency_passes     := v_agency_rating     IN ('Good', 'Great', 'Elite');

      IF v_individual_passes AND v_agency_passes THEN
        v_overall := 'eligible';
      ELSE
        v_overall := 'ineligible';
        IF NOT v_individual_passes THEN
          v_reasons := array_append(v_reasons,
            format('Individual Sales Points 13-wk avg is %s ($%s/wk) — Good ($1000+) or better required',
                   v_individual_rating, ROUND(v_individual_avg, 0)));
        END IF;
        IF NOT v_agency_passes THEN
          v_reasons := array_append(v_reasons,
            format('Agency Sales Points 13-wk avg is %s ($%s/wk) — Good ($1000+) or better required',
                   v_agency_rating, ROUND(v_agency_avg, 0)));
        END IF;
      END IF;
    END IF;

  ELSIF v_is_manager_tier AND NOT v_is_post_probation THEN
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      format('%s in 13-week probation (%s of 13 weeks) — case-by-case approval required',
             v_role_level, v_weeks_employed));

  ELSIF v_is_account_associate THEN
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      'Account Associate uses accrued PTO model (5 days year 1, 10/year after) — balance check not yet implemented, manual review required');

  ELSE
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      format('Role level "%s" not mapped to PTO eligibility — manual review required',
             COALESCE(v_team.role_level, 'unknown')));
  END IF;

  RETURN jsonb_build_object(
    'overall_eligibility',         v_overall,
    'is_owner',                    v_is_owner,
    'is_account_manager',          v_role_level = 'Account Manager',
    'is_manager_tier',             v_is_manager_tier,
    'is_account_associate',        v_is_account_associate,
    'is_post_probation',           v_is_post_probation,
    'weeks_employed',              v_weeks_employed,
    'role_level',                  v_team.role_level,
    'individual_avg_sales_points', v_individual_avg,
    'individual_rating',           v_individual_rating,
    'agency_avg_sales_points',     v_agency_avg,
    'agency_rating',               v_agency_rating,
    'reasons',                     v_reasons,
    'team_name',                   v_team.first_name || ' ' || v_team.last_name
  );
END;
$function$;
