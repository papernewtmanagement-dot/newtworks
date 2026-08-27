-- Peter 2026-08-26: "If someone doesn't have an average, they don't earn unlimited PTO."
-- Two paths used to return 'pending_review', which the request screen treated as a data
-- gap needing a case-by-case call. Both now return 'ineligible' outright:
--   1. Account Manager and above, past the thirteen-week window, but no rolling average.
--   2. Account Manager and above, still inside the thirteen-week onboarding window.
-- Unlimited paid time off is earned by holding a Good rating. No rating means not earned.
-- The agent can still approve and mark any request paid by hand; this only sets the answer
-- the app gives on its own.

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
  v_is_manager_tier         boolean;
  v_req_weight              numeric;
  v_individual_avg          numeric;
  v_individual_rel          numeric;
  v_individual_rating       text;
  v_individual_passes       boolean;
  v_agency_avg              numeric;
  v_agency_rating           text;
  v_good_floor              numeric;
  v_overall                 text;
  v_reasons                 text[] := ARRAY[]::text[];
  v_aa_year_band            text;
  v_aa_pto_days_per_year    integer;
  v_may_first_four_weeks    boolean := false;
  v_may_exceed_one_week     boolean := false;
BEGIN
  SELECT first_name, last_name, role, role_level, role_category, hire_date, category, archived_at, agency_id
    INTO v_team FROM public.team WHERE id = p_requester_team_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('overall_eligibility','ineligible','reasons',ARRAY['team member not found']);
  END IF;
  IF v_team.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('overall_eligibility','ineligible','reasons',ARRAY['team member is archived']);
  END IF;

  v_weeks_employed := CASE WHEN v_team.hire_date IS NULL THEN 0
                      ELSE FLOOR((CURRENT_DATE - v_team.hire_date) / 7.0)::integer END;
  v_is_post_probation := v_weeks_employed >= 13;

  v_role_level           := COALESCE(v_team.role_level, '');
  v_is_owner             := v_role_level = 'Owner';
  v_is_account_associate := v_role_level = 'Account Associate';
  v_is_manager_tier      := v_role_level IN ('Account Manager', 'Unit Manager', 'Section Manager', 'Office Manager');

  -- Retention seats carry half the requirement; sales seats carry the whole one.
  v_req_weight := CASE WHEN v_team.role_category = 'Retention' THEN 0.5 ELSE 1.0 END;

  IF v_is_owner THEN
    v_overall := 'eligible';
    v_may_first_four_weeks := true;
    v_may_exceed_one_week  := true;

  ELSIF v_is_manager_tier AND v_is_post_probation THEN
    v_individual_avg := public.team_member_sales_points_avg_13wk(p_requester_team_id);
    -- Agency figure is informational only (Peter 2026-08-25) — never gates.
    v_agency_avg     := public.agency_sales_points_avg_13wk(v_team.agency_id);
    IF v_agency_avg IS NOT NULL THEN
      v_agency_rating := public.compute_sales_points_rating(v_team.agency_id, v_agency_avg);
    END IF;

    IF v_individual_avg IS NULL THEN
      -- No average means no rating, and no rating means unlimited paid time off is not earned.
      v_overall := 'ineligible';
      v_reasons := array_append(v_reasons,
        'No rolling 13-week Sales Points average available — unlimited paid time off requires a Good rating or better, so it is not earned. Agent can still grant it by hand.');
    ELSE
      v_individual_rel    := ROUND(v_individual_avg / v_req_weight, 2);
      v_individual_rating := public.compute_sales_points_rating(v_team.agency_id, v_individual_rel);
      v_individual_passes := v_individual_rating IN ('Good', 'Great', 'Elite');

      -- Band freedoms (locked 2026-08-25).
      v_may_first_four_weeks := v_individual_rating IN ('Great', 'Elite');
      v_may_exceed_one_week  := v_individual_rating = 'Elite';

      SELECT min_threshold INTO v_good_floor
      FROM public.sales_points_band_config
      WHERE agency_id = v_team.agency_id AND rating_name = 'Good';

      IF v_individual_passes THEN
        v_overall := 'eligible';
      ELSE
        v_overall := 'ineligible';
        v_reasons := array_append(v_reasons,
          format('Individual Sales Points 13-wk avg is %s (%s points/wk against a %s+ requirement) — Good or better required',
                 v_individual_rating,
                 ROUND(v_individual_avg, 0),
                 ROUND(COALESCE(v_good_floor, 0) * v_req_weight, 0)));
      END IF;
    END IF;

  ELSIF v_is_manager_tier AND NOT v_is_post_probation THEN
    -- Inside the thirteen-week onboarding window there is no average yet, so the same
    -- rule applies: not earned. The handbook gives unlimited paid time off to people who
    -- have COMPLETED onboarding and hold a Good rating.
    v_overall := 'ineligible';
    v_reasons := array_append(v_reasons,
      format('%s is in week %s of the 13-week onboarding window — no Sales Points rating exists yet, so unlimited paid time off is not earned. Agent can still grant it by hand.',
             v_role_level, v_weeks_employed));

  ELSIF v_is_account_associate THEN
    -- Per handbook (02 Hours & Time Off): 0 PTO in year 1, 5 days after year 1, 10 days after year 2.
    IF v_weeks_employed < 52 THEN
      v_aa_year_band := 'year_1';
      v_aa_pto_days_per_year := 0;
      v_overall := 'ineligible';
      v_reasons := array_append(v_reasons,
        format('Account Associate in first year (week %s of 52) — no PTO accrued yet per handbook',
               v_weeks_employed));
    ELSIF v_weeks_employed < 104 THEN
      v_aa_year_band := 'year_2';
      v_aa_pto_days_per_year := 5;
      v_overall := 'pending_review';
      v_reasons := array_append(v_reasons,
        format('Account Associate in year 2 (week %s of 104) — entitled to 5 PTO days/year per handbook; balance check not yet implemented, manual review required',
               v_weeks_employed));
    ELSE
      v_aa_year_band := 'year_3_plus';
      v_aa_pto_days_per_year := 10;
      v_overall := 'pending_review';
      v_reasons := array_append(v_reasons,
        format('Account Associate in year 3+ (week %s) — entitled to 10 PTO days/year per handbook; balance check not yet implemented, manual review required',
               v_weeks_employed));
    END IF;

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
    'requirement_weight',          v_req_weight,
    'individual_avg_sales_points', v_individual_avg,
    'individual_rel_sales_points', v_individual_rel,
    'individual_rating',           v_individual_rating,
    'agency_avg_sales_points',     v_agency_avg,
    'agency_rating',               v_agency_rating,
    'aa_year_band',                v_aa_year_band,
    'aa_pto_days_per_year',        v_aa_pto_days_per_year,
    'may_start_in_first_four_weeks', v_may_first_four_weeks,
    'may_exceed_one_week',           v_may_exceed_one_week,
    'reasons',                     v_reasons,
    'team_name',                   v_team.first_name || ' ' || v_team.last_name
  );
END;
$function$;
