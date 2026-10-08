-- Onboarding form answers become part of the team record once the form is
-- submitted (Peter 2026-10-08). The team table is readable only by the person
-- and admins (team_admin_or_own_read), so the private answers stay private.

ALTER TABLE public.team ADD COLUMN IF NOT EXISTS born_raised       text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS moved_here        text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS started_industry  text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS biggest_impact    text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS why_statement     text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS need_to_make      numeric;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS want_to_make      numeric;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS motivator_ranking jsonb;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS gift_card         text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS fun_relax         text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS fav_restaurant    text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS fav_lunch         text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS fav_snack         text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS fav_beverage      text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS shirt_size        text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS shoe_size         text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS fav_color         text;
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS travel_spots      jsonb;

-- The one copy from a submitted Onboarding form to the team record. A blank
-- answer leaves what the team record already has.
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
    shoe_size        = COALESCE(NULLIF(btrim(d->>'shoe_size'), ''), t.shoe_size),
    fav_color        = COALESCE(NULLIF(btrim(d->>'fav_color'), ''), t.fav_color),
    travel_spots     = COALESCE(
                         (SELECT CASE WHEN count(*) > 0 THEN jsonb_agg(btrim(x)) END
                            FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(d->'travel') = 'array'
                                                                THEN d->'travel' ELSE '[]'::jsonb END) x
                           WHERE btrim(x) <> ''),
                         t.travel_spots)
  WHERE t.id = s.team_id;
END;
$$;
REVOKE ALL ON FUNCTION public.onboarding_form_to_team(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.tg_onboarding_form_to_team()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.form_type = 'combined_onboarding' AND NEW.locked_at IS NOT NULL
     AND (TG_OP = 'INSERT' OR OLD.locked_at IS NULL) THEN
    PERFORM public.onboarding_form_to_team(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS team_form_onboarding_to_team ON public.team_form_submissions;
CREATE TRIGGER team_form_onboarding_to_team
  AFTER INSERT OR UPDATE ON public.team_form_submissions
  FOR EACH ROW EXECUTE FUNCTION public.tg_onboarding_form_to_team();

-- Forms already submitted (Bryson's) go onto the team record now.
SELECT public.onboarding_form_to_team(s.id)
  FROM public.team_form_submissions s
 WHERE s.form_type = 'combined_onboarding' AND s.locked_at IS NOT NULL
   AND s.status <> 'superseded' AND NOT (s.data ? 'legacy_paper');

-- Earnings chart points read the goals, the why and the travel spots off the team
-- record, for the person and an admin only. People with no points yet come back
-- too (x null), so their need and want lines still show.
CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everyone sees every team point on their curve (Peter 2026-10-07, Team view toggle);
-- the gap stays admin-or-self inside raise_gap_scenario, and so do the goals, the
-- why and the travel spots (Peter 2026-10-08).
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
           'need_to_make',    CASE WHEN s.mine THEN s.need_to_make END,
           'want_to_make',    CASE WHEN s.mine THEN s.want_to_make END,
           'why_statement',   CASE WHEN s.mine THEN s.why_statement END,
           'travel_spots',    CASE WHEN s.mine THEN s.travel_spots END,
           'gap',             (SELECT g FROM jsonb_array_elements(gp.j) g WHERE g->>'team_member_id' = s.id::text LIMIT 1)
         ) ORDER BY s.first_name), '[]'::jsonb) || public.earnings_test_point(p_agency_id)
    FROM (
      SELECT t.id, t.first_name, t.role_category, t.role_level,
             t.need_to_make, t.want_to_make, t.why_statement, t.travel_spots,
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

