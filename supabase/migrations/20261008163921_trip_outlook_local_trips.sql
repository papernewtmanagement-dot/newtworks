-- Peter 2026-10-08:
--  * Favorite color and shoe size come off the Onboarding form and the team record (decision 1A).
--  * Each teammate gives local trip ideas too.
--  * Travel spots tie to the Win the Quarter trip and show whether each is in reach.

ALTER TABLE public.team ADD COLUMN IF NOT EXISTS local_trip_ideas jsonb;
-- Estimated cost of each trip for one person, keyed by the place as written: {"Italy": 3200}.
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS trip_costs jsonb;

-- Text list out of a form answer: trimmed, blanks dropped, null when empty.
CREATE OR REPLACE FUNCTION public.form_text_list(p jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN count(*) > 0 THEN jsonb_agg(btrim(x) ORDER BY n) END
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END)
         WITH ORDINALITY AS a(x, n)
   WHERE btrim(x) <> '';
$$;

CREATE OR REPLACE FUNCTION public.onboarding_form_to_team(p_submission_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE s record; d jsonb;
BEGIN
  SELECT id, team_id, data INTO s FROM public.team_form_submissions
   WHERE id = p_submission_id AND form_type = 'combined_onboarding';
  IF NOT FOUND THEN RETURN; END IF;
  d := COALESCE(s.data, '{}'::jsonb);
  UPDATE public.team t SET
    born_raised      = COALESCE(NULLIF(btrim(d->>'born_raised'), ''), t.born_raised),
    moved_here       = COALESCE(NULLIF(btrim(d->>'moved_here'), ''), t.moved_here),
    started_industry = COALESCE(NULLIF(btrim(d->>'started_industry'), ''), t.started_industry),
    biggest_impact   = COALESCE(NULLIF(btrim(d->>'biggest_impact'), ''), t.biggest_impact),
    why_statement    = COALESCE(NULLIF(btrim(d->>'why_statement'), ''), t.why_statement),
    need_to_make     = COALESCE(public.parse_money_text(d->>'need_to_make'), t.need_to_make),
    want_to_make     = COALESCE(public.parse_money_text(d->>'want_to_make'), t.want_to_make),
    motivator_ranking = CASE WHEN jsonb_typeof(d->'ranking') = 'object' AND d->'ranking' <> '{}'::jsonb
                             THEN d->'ranking' ELSE t.motivator_ranking END,
    gift_card        = COALESCE(NULLIF(btrim(d->>'gift_card'), ''), t.gift_card),
    fun_relax        = COALESCE(NULLIF(btrim(d->>'fun_relax'), ''), t.fun_relax),
    fav_restaurant   = COALESCE(NULLIF(btrim(d->>'fav_restaurant'), ''), t.fav_restaurant),
    fav_lunch        = COALESCE(NULLIF(btrim(d->>'fav_lunch'), ''), t.fav_lunch),
    fav_snack        = COALESCE(NULLIF(btrim(d->>'fav_snack'), ''), t.fav_snack),
    fav_beverage     = COALESCE(NULLIF(btrim(d->>'fav_beverage'), ''), t.fav_beverage),
    shirt_size       = COALESCE(NULLIF(btrim(d->>'shirt_size'), ''), t.shirt_size),
    travel_spots     = COALESCE(public.form_text_list(d->'travel'), t.travel_spots),
    local_trip_ideas = COALESCE(public.form_text_list(d->'local_trips'), t.local_trip_ideas)
  WHERE t.id = s.team_id;
END;
$$;
REVOKE ALL ON FUNCTION public.onboarding_form_to_team(uuid) FROM PUBLIC, anon, authenticated;

ALTER TABLE public.team DROP COLUMN IF EXISTS fav_color;
ALTER TABLE public.team DROP COLUMN IF EXISTS shoe_size;

-- One person's Win the Quarter trip outlook: what the trip pays this quarter (as
-- MVP and as everyone else), their travel spots and local trip ideas, each with
-- its estimated cost and whether that amount covers it. The person and an admin only.
CREATE OR REPLACE FUNCTION public.trip_outlook(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  t       record;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week  date;
  w       jsonb;
  v_mvp   numeric;
  v_rest  numeric;
  v_on    boolean;
  v_items jsonb;
BEGIN
  PERFORM public.require_login('staff');
  IF NOT (p_team_id = public.current_team_member_id() OR public.is_agency_admin()) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  SELECT id, agency_id, travel_spots, local_trip_ideas, trip_costs INTO t
    FROM public.team WHERE id = p_team_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  -- The CPR week this falls in ends on Saturday.
  v_week := v_today + (6 - EXTRACT(DOW FROM v_today)::int);
  w      := public.compute_pool_carveouts(t.agency_id, v_week) -> 'wtq_trip';
  v_on   := NOT COALESCE((w->>'halted')::boolean, false)
            AND COALESCE(NULLIF(w->>'quarterly_dollars','')::numeric, 0) > 0;
  v_mvp  := CASE WHEN v_on THEN COALESCE(NULLIF(w->>'mvp_dollars','')::numeric, 0) ELSE 0 END;
  v_rest := CASE WHEN v_on THEN COALESCE(NULLIF(w->>'rest_per_person_dollars','')::numeric, 0) ELSE 0 END;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'kind', x.kind, 'place', x.place, 'cost', x.cost,
           'reach', CASE WHEN x.cost IS NULL THEN 'unknown'
                         WHEN x.cost <= v_rest THEN 'yes'
                         WHEN x.cost <= v_mvp  THEN 'mvp'
                         ELSE 'no' END)
         ORDER BY x.kind DESC, x.n), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT 'local' AS kind, p AS place, n,
             NULLIF(t.trip_costs->>p, '')::numeric AS cost
        FROM jsonb_array_elements_text(COALESCE(t.local_trip_ideas, '[]'::jsonb)) WITH ORDINALITY a(p, n)
      UNION ALL
      SELECT 'travel', p, n, NULLIF(t.trip_costs->>p, '')::numeric
        FROM jsonb_array_elements_text(COALESCE(t.travel_spots, '[]'::jsonb)) WITH ORDINALITY a(p, n)
    ) x;

  RETURN jsonb_build_object(
    'on_pace',        v_on,
    'projected_wins', (w->>'projected_wins')::int,
    'wins_needed',    (w->>'floor_wins')::int,
    'mvp_dollars',    v_mvp,
    'rest_dollars',   v_rest,
    'trips',          v_items);
END;
$$;
GRANT EXECUTE ON FUNCTION public.trip_outlook(uuid) TO authenticated;

-- Travel spots now come from trip_outlook; the Earnings points keep the goals and the why.
CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everyone sees every team point on their curve (Peter 2026-10-07, Team view toggle);
-- the gap stays admin-or-self inside raise_gap_scenario, and so do the goals and the
-- why (Peter 2026-10-08). Travel and local trips come from trip_outlook.
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
           'mine',            s.mine,
           'need_to_make',    CASE WHEN s.mine THEN s.need_to_make END,
           'want_to_make',    CASE WHEN s.mine THEN s.want_to_make END,
           'why_statement',   CASE WHEN s.mine THEN s.why_statement END,
           'gap',             (SELECT g FROM jsonb_array_elements(gp.j) g WHERE g->>'team_member_id' = s.id::text LIMIT 1)
         ) ORDER BY s.first_name), '[]'::jsonb) || public.earnings_test_point(p_agency_id)
    FROM (
      SELECT t.id, t.first_name, t.role_category, t.role_level,
             t.need_to_make, t.want_to_make, t.why_statement,
             (t.id = public.current_team_member_id() OR public.is_agency_admin()) AS mine,
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
   WHERE s.avg_sp IS NOT NULL OR s.need_to_make IS NOT NULL OR s.want_to_make IS NOT NULL;
$function$;

-- Bryson's form reopens so he can add local trip ideas and rank his motivators
-- 1 to 4 once each. His bank, income answers and everything else stay.
UPDATE public.team_form_submissions
   SET status = 'in_progress', locked_at = NULL
 WHERE id = 'db642a8b-a411-452c-999c-6446af0b3f8c';

