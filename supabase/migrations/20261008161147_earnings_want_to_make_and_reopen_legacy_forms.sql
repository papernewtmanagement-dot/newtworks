-- 1. A dollar figure typed as text ("$100,000", "100k", "100000") as a number.
CREATE OR REPLACE FUNCTION public.parse_money_text(p text)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN m IS NULL THEN NULL
    WHEN lower(coalesce(p, '')) ~ '[0-9.,]\s*k' THEN m * 1000
    ELSE m END
  FROM (SELECT NULLIF(substring(replace(coalesce(p, ''), ',', '') FROM '[0-9]+(?:\.[0-9]+)?'), '')::numeric AS m) x;
$$;
GRANT EXECUTE ON FUNCTION public.parse_money_text(text) TO authenticated;

-- 2. Earnings chart points carry the person's "want to make" from their Onboarding
--    form. Private: only the person and an admin get it back; everyone else gets null.
CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everyone sees every team point on their curve (Peter 2026-10-07, Team view toggle);
-- the gap stays admin-or-self inside raise_gap_scenario, and so does want_to_make.
SELECT public.require_login('staff');
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'team_member_id',  s.id,
           'first_name',      s.first_name,
           'is_me',           s.id = public.current_team_member_id(),
           'role_key',        lower(s.role_category),
           'x',               s.avg_sp,
           'window_weeks',    s.window_wk,
           'y',               p.on_time_annual,
           'ytd_paid',        p.ytd_paid,
           'as_of_week',      p.week_ending_date,
           'current_hourly',  s.current_hourly,
           'step_hourly',     s.tier_hourly,
           'title_hourly',    s.title_increment,
           'title_label',     CASE WHEN COALESCE(s.title_increment,0) > 0 THEN s.role_level END,
           'next_hourly',     s.next_hourly,
           'next_step_hourly', s.next_hourly - COALESCE(s.title_increment, 0),
           'on_track',        COALESCE(s.on_track, false),
           'want_to_make',    CASE WHEN s.id = public.current_team_member_id() OR public.is_agency_admin()
                                   THEN (SELECT public.parse_money_text(f.data->>'want_to_make')
                                           FROM public.team_form_submissions f
                                          WHERE f.team_id = s.id AND f.form_type = 'combined_onboarding'
                                            AND f.status <> 'superseded'
                                          ORDER BY f.created_at DESC LIMIT 1) END,
           'gap',             (SELECT g FROM jsonb_array_elements(gp.j) g WHERE g->>'team_member_id' = s.id::text LIMIT 1)
         ) ORDER BY s.first_name), '[]'::jsonb) || public.earnings_test_point(p_agency_id)
    FROM (
      SELECT t.id, t.first_name, t.role_category, t.role_level,
             rp.current_hourly, rp.tier_hourly, rp.title_increment, rp.next_hourly, rp.on_track,
             CASE WHEN lower(t.role_category) = 'retention'
                    THEN (SELECT r.weeks_counted FROM public.retention_raise_track(p_agency_id) r WHERE r.team_member_id = t.id)
                  WHEN rp.avg_weekly_sp IS NOT NULL THEN rp.lookback_quarters * 13
                  ELSE GREATEST(1, LEAST(52, COALESCE(rp.weeks_employed, 52))) END AS window_wk,
             CASE WHEN lower(t.role_category) = 'retention'
                  THEN (SELECT r.avg_total_points FROM public.retention_raise_track(p_agency_id) r WHERE r.team_member_id = t.id)
             ELSE COALESCE(rp.avg_weekly_sp,
                      ROUND(public.team_member_sales_points_avg_nwk(
                        t.id, GREATEST(1, LEAST(52, COALESCE(rp.weeks_employed, 52))), CURRENT_DATE, true), 2)) END AS avg_sp
        FROM public.team t
        LEFT JOIN public.team_raise_progress(p_agency_id, CURRENT_DATE, true) rp ON rp.team_member_id = t.id
       WHERE t.agency_id                  = p_agency_id
         AND t.category                   = 'agency'
         AND COALESCE(t.role_level, '')  <> 'Owner'
         AND t.is_active = true AND t.archived_at IS NULL
         AND t.is_test_user IS NOT TRUE
         AND lower(COALESCE(t.role_category, '')) IN ('sales', 'retention')
    ) s
    LEFT JOIN public.team_on_time_annual_pay(p_agency_id) p
      ON p.team_member_id = s.id
    CROSS JOIN (SELECT public.raise_gap_scenario(p_agency_id) AS j) gp
   WHERE s.avg_sp IS NOT NULL;
$function$;

-- 3. Stephanie, Cassandra and Thomas had placeholder Onboarding forms from the paper
--    days (Peter 2026-10-08: get the form from them, other than bank info). Reopened so
--    they fill it in. Their payroll is already set up, so the bank and Social Security
--    number count as given (secure_purged_at), the same way destroyed details do.
UPDATE public.team_form_submissions
   SET status = 'in_progress', locked_at = NULL,
       secure_purged_at = COALESCE(secure_purged_at, now())
 WHERE id IN ('96b6e0b6-cf6e-4603-b36c-f80349905c39',
              'edf750c7-7496-4079-8e7b-dde3801cc4d6',
              '7491a798-154e-4821-a930-e3aff45290c1');

