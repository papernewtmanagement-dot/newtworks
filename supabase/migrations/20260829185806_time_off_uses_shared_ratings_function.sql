-- Peter 2026-08-28: one function for the band question.
--
-- time_off_check_eligibility was already calling compute_sales_points_rating,
-- but it rebuilt the input itself — pull the 13-week average, divide by the
-- retention weight, then rate it. That is the same three steps
-- team_sales_points_ratings performs for the CPR and Team badges, written a
-- second time. If the weighting ever changes in one place it silently
-- disagrees with the other. It now reads the person's row out of the shared
-- function.
--
-- A fallback stays for a seat that function leaves out (it only rates people
-- with a Property & Casualty licence on file), so nobody who was getting a
-- rating before stops getting one.

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='time_off_check_eligibility';
  v_new := v_def;

  v_new := replace(v_new,
$a$    v_individual_avg := public.team_member_sales_points_avg_13wk(p_requester_team_id);$a$,
$b$    -- One definition of the band question, shared with the CPR and Team
    -- badges: team_sales_points_ratings does the average, the retention
    -- weighting and the rating in one place.
    SELECT r.avg_13wk, r.rel_13wk, r.rating
      INTO v_individual_avg, v_individual_rel, v_individual_rating
      FROM public.team_sales_points_ratings(v_team.agency_id) r
     WHERE r.team_member_id = p_requester_team_id;

    IF v_individual_avg IS NULL THEN
      -- That function only rates seats with a P&C licence on file; fall back
      -- so nobody who had a rating before loses one.
      v_individual_avg := public.team_member_sales_points_avg_13wk(p_requester_team_id);
    END IF;$b$);

  v_new := replace(v_new,
$a$      v_individual_rel    := ROUND(v_individual_avg / v_req_weight, 2);
      v_individual_rating := public.compute_sales_points_rating(v_team.agency_id, v_individual_rel);
      v_individual_passes := v_individual_rating IN ('Good', 'Great', 'Elite');$a$,
$b$      IF v_individual_rating IS NULL THEN
        v_individual_rel    := ROUND(v_individual_avg / v_req_weight, 2);
        v_individual_rating := public.compute_sales_points_rating(v_team.agency_id, v_individual_rel);
      END IF;
      v_individual_passes := v_individual_rating IN ('Good', 'Great', 'Elite');$b$);

  IF v_new = v_def THEN RAISE EXCEPTION 'time-off rating block not found'; END IF;
  IF v_new NOT LIKE '%team_sales_points_ratings%' THEN
    RAISE EXCEPTION 'shared ratings function not wired in';
  END IF;
  EXECUTE v_new;
END
$mig$;
