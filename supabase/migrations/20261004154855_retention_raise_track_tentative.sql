-- Retention raise track, TENTATIVE (Peter 2026-10-04). Not live.
-- The retention track lives on the same pay_scale tier rows as the sales ladder.
-- retention_points = weekly TOTAL points (sales points + retention points + marketing points)
-- a retention seat needs for that tier, averaged over the tier's lookback_quarters.
-- Licence flags (retention_requires_pc / retention_requires_lh) stay as the automatic bump:
-- holding the licence grants that tier even short of the points.
-- Nothing changes pay until settings.retention_ladder_live = 'true' and team_raise_progress
-- reads retention_raise_track for retention seats.

DO $guard$
BEGIN
  IF (SELECT md5(pg_get_functiondef('public.reseed_pay_scale(uuid)'::regprocedure)))
     <> '0895960ab2164fc1496d455e06975060' THEN
    RAISE EXCEPTION 'reseed_pay_scale changed since it was read; re-read before replacing it';
  END IF;
END
$guard$;

ALTER TABLE public.pay_scale ADD COLUMN IF NOT EXISTS retention_points integer;

COMMENT ON COLUMN public.pay_scale.retention_points IS
  'Retention track (TENTATIVE, not live): weekly total of sales + retention + marketing points a retention seat needs for this raise tier, averaged over lookback_quarters. NULL on tier 1 = starting pay. Licence flags on the same row still grant the tier as an override. Read only by retention_raise_track.';

UPDATE public.pay_scale p
   SET retention_points = CASE WHEN p.raise_tier <= 1 THEN NULL ELSE p.sales_points END,
       updated_at = now()
 WHERE p.role_key = 'sales' AND p.tier_starts_here;

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description, updated_by, updated_at, created_at)
SELECT a.id, v.k, v.val, 'boolean', v.d, 'claude', now(), now()
  FROM public.agency a
 CROSS JOIN (VALUES
   ('retention_ladder_live', 'false',
    'Retention raise track on pay_scale.retention_points. false = tentative: retention_raise_track previews only, raise reviews stay licence-only.'),
   ('retention_ladder_lapse_check', 'true',
    'Retention raise track: an earned (points) step needs the blended State Farm lapse rate at the last completed week to be no worse than 13 weeks earlier. Licence bumps are not checked.')
 ) AS v(k, val, d)
 WHERE a.id = '126794dd-25ff-47d2-a436-724499733365'
ON CONFLICT (agency_id, setting_key) DO NOTHING;

-- reseed_pay_scale: carry retention_points AND the two licence flags through the rebuild.
-- Before this, a reseed blanked retention_requires_pc / retention_requires_lh (same trap
-- that once blanked retention_requirement).
CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- Band annotations (band_tier_*) sit on band-start rows and are preserved
-- wholesale by re-reading them after the rebuild.
-- The raise ladder lives in this same table, on the rows flagged
-- tier_starts_here; those rows define the rates, thresholds, look-back
-- windows, the retention track (retention_points + licence flags) and the
-- retention / life specialist requirements, and are read back out before
-- the grid is rebuilt around them.
DECLARE
  v_ladder jsonb;
  v_bandkeep jsonb;
  v_bounds   jsonb;
  v_goals    jsonb;
  v_draws    jsonb;
  v_x      integer;
  v_tier   integer;
  v_hourly numeric;
  v_next   numeric;
  v_lb     integer;
  v_starts boolean;
  v_ret    text;
  v_ls     text;
  v_ret_yr jsonb;
  v_ls_yr  jsonb;
  v_ret_pts integer;
  v_ret_pc  boolean;
  v_ret_lh  boolean;
  v_base   numeric;
  v_inputs jsonb;
  v_n      integer := 0;
  c_seat_wh numeric := 8;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
           'tier', p.raise_tier, 'hourly', p.base_hourly,
           'threshold', p.sales_points, 'lookback', p.lookback_quarters,
           'retention', p.retention_requirement,
           'life', p.life_specialist_requirement,
           'ret_year', p.retention_reached_year,
           'life_year', p.life_specialist_reached_year,
           'ret_points', p.retention_points,
           'ret_pc', p.retention_requires_pc,
           'ret_lh', p.retention_requires_lh
         ) ORDER BY p.raise_tier)
    INTO v_ladder
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here;

  IF v_ladder IS NULL THEN
    RAISE EXCEPTION 'No raise ladder found in pay_scale for this agency — seed the tier_starts_here rows first';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(z)), '[]'::jsonb) INTO v_bandkeep
    FROM (SELECT p.sales_points, p.band_tier_key, p.band_tier_label,
                 p.band_applicant_pct, p.band_tier_traits, p.band_production_multiplier
            FROM public.pay_scale p
           WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
             AND p.band_tier_key IS NOT NULL) z;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('fx', p.sales_points, 'band', p.band)
                                ORDER BY p.sales_points), '[]'::jsonb)
    INTO v_bounds
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.band_starts_here;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('fx', p.sales_points, 'wk', p.goals_weekly)
                                ORDER BY p.sales_points), '[]'::jsonb)
    INTO v_goals
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.goals_weekly IS NOT NULL;

  SELECT COALESCE(jsonb_object_agg(p.sales_points::text, p.mvp_draws), '{}'::jsonb)
    INTO v_draws
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.mvp_draws IS NOT NULL;

  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 10) LOOP
    SELECT (e->>'tier')::int, (e->>'hourly')::numeric, (e->>'lookback')::int,
           ((e->>'threshold')::int = v_x), e->>'retention', e->>'life',
           e->'ret_year', e->'life_year',
           (e->>'ret_points')::int, (e->>'ret_pc')::boolean, (e->>'ret_lh')::boolean
      INTO v_tier, v_hourly, v_lb, v_starts, v_ret, v_ls, v_ret_yr, v_ls_yr,
           v_ret_pts, v_ret_pc, v_ret_lh
      FROM jsonb_array_elements(v_ladder) e
     WHERE (e->>'threshold')::int <= v_x
     ORDER BY (e->>'tier')::int DESC
     LIMIT 1;

    SELECT MIN((e->>'threshold')::numeric) INTO v_next
      FROM jsonb_array_elements(v_ladder) e
     WHERE (e->>'threshold')::int > v_x;

    v_base := round(v_hourly * 2080, 0);

    INSERT INTO public.pay_scale (
      agency_id, role_key, sales_points, band, raise_tier,
      base_hourly, base_annual, next_raise_at,
      expected_commission_annual, goals_weekly, expected_goals_bonus_annual,
      expected_team_bonus_annual,
      tier_starts_here, lookback_quarters,
      retention_requirement, life_specialist_requirement,
      retention_reached_year, life_specialist_reached_year,
      retention_points, retention_requires_pc, retention_requires_lh, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      (SELECT e->>'band' FROM jsonb_array_elements(v_bounds) e
        WHERE (e->>'fx')::int <= v_x ORDER BY (e->>'fx')::int DESC LIMIT 1),
      v_tier, v_hourly, v_base, v_next,
      round(v_x * 52.0, 0),
      (SELECT (e->>'wk')::numeric FROM jsonb_array_elements(v_goals) e
        WHERE (e->>'fx')::int <= v_x ORDER BY (e->>'fx')::int DESC LIMIT 1),
      round(COALESCE((SELECT (e->>'wk')::numeric FROM jsonb_array_elements(v_goals) e
        WHERE (e->>'fx')::int <= v_x ORDER BY (e->>'fx')::int DESC LIMIT 1), 0) * 52.0, 0),
      public.projected_team_bonus(v_inputs, v_x, c_seat_wh, v_base),
      v_starts,
      CASE WHEN v_starts THEN v_lb  ELSE NULL END,
      CASE WHEN v_starts THEN v_ret ELSE NULL END,
      CASE WHEN v_starts THEN v_ls  ELSE NULL END,
      CASE WHEN v_starts THEN v_ret_yr ELSE NULL END,
      CASE WHEN v_starts THEN v_ls_yr  ELSE NULL END,
      CASE WHEN v_starts THEN v_ret_pts ELSE NULL END,
      CASE WHEN v_starts THEN v_ret_pc  ELSE NULL END,
      CASE WHEN v_starts THEN v_ret_lh  ELSE NULL END,
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  -- Restore the band boundary flags and the prize-cart draw counts.
  UPDATE public.pay_scale t SET band_starts_here = true
    FROM jsonb_array_elements(v_bounds) e
   WHERE t.agency_id = p_agency_id AND t.role_key = 'sales'
     AND t.sales_points = (e->>'fx')::int;

  UPDATE public.pay_scale t SET mvp_draws = (v_draws->>t.sales_points::text)::int
   WHERE t.agency_id = p_agency_id AND t.role_key = 'sales'
     AND v_draws ? t.sales_points::text;

  -- Put the band annotations back onto their band-start rows.
  UPDATE public.pay_scale t
     SET band_tier_key = k.band_tier_key, band_tier_label = k.band_tier_label,
         band_applicant_pct = k.band_applicant_pct, band_tier_traits = k.band_tier_traits,
         band_production_multiplier = k.band_production_multiplier
    FROM jsonb_to_recordset(v_bandkeep) AS k(sales_points int, band_tier_key text,
         band_tier_label text, band_applicant_pct numeric, band_tier_traits text,
         band_production_multiplier numeric)
   WHERE t.agency_id = p_agency_id AND t.role_key = 'sales'
     AND t.sales_points = k.sales_points;

  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.retention_raise_track(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(
   team_member_id uuid, first_name text, role_level text,
   current_hourly numeric, title_increment numeric, current_tier integer,
   license_tier integer, next_tier integer, next_points integer, next_lookback_quarters integer,
   weeks_counted integer, avg_sales_points numeric, avg_retention_points numeric,
   avg_marketing_points numeric, avg_total_points numeric, points_to_go numeric,
   lapse_now numeric, lapse_prior numeric, lapse_check_passed boolean,
   earned_by text, would_be_tier integer, would_be_hourly numeric, ladder_live boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Retention raise track (TENTATIVE, Peter 2026-10-04). The one place the track is computed.
-- Live only when settings.retention_ladder_live = 'true'; until then it previews and
-- nothing reads it to change pay (team_raise_progress stays licence-only for retention).
-- Measure: weekly TOTAL points = sales points (raw) + net retention points + marketing points,
-- averaged over the NEXT tier's lookback_quarters, capped at the weeks Retention Points have
-- existed (settings.retention_points_go_live_week_end) and at weeks since hire, the same short
-- first window a new hire gets.
-- Steps: a held licence grants every tier its flags allow (automatic bump, no lapse check);
-- otherwise one tier per review when the total meets the next tier's retention_points and,
-- if settings.retention_ladder_lapse_check is on, the blended lapse rate at the last completed
-- week is no worse than 13 weeks earlier. Pay never steps down. Manager title rides on top.
DECLARE
  v_live boolean;
  v_check boolean;
  v_go_live date;
  v_last date;
  v_lapse_now numeric;
  v_lapse_prior numeric;
  v_gate_ok boolean;
  v_max_n integer;
  v_weeks jsonb := '[]'::jsonb;
  s record;
  v_hourly numeric;
  v_title numeric;
  v_cur integer;
  v_lic integer;
  v_nx_tier integer;
  v_nx_pts integer;
  v_nx_lb integer;
  v_n integer;
  v_sp numeric;
  v_rp numeric;
  v_mp numeric;
  v_total numeric;
  v_target integer;
  v_by text;
  v_target_rate numeric;
BEGIN
  PERFORM public.require_login('admin');

  SELECT COALESCE(MAX(st.setting_value) FILTER (WHERE st.setting_key = 'retention_ladder_live'), 'false') = 'true',
         COALESCE(MAX(st.setting_value) FILTER (WHERE st.setting_key = 'retention_ladder_lapse_check'), 'true') = 'true',
         (MAX(st.setting_value) FILTER (WHERE st.setting_key = 'retention_points_go_live_week_end'))::date
    INTO v_live, v_check, v_go_live
    FROM public.settings st
   WHERE st.agency_id = p_agency_id;

  -- Last completed Sunday-to-Saturday week on or before the as-of date.
  v_last := public.rp_week_end(p_as_of);
  IF v_last > p_as_of THEN v_last := v_last - 7; END IF;

  SELECT l.annualized_rate INTO v_lapse_now
    FROM public.compute_lapse_rate(p_agency_id, v_last) l WHERE l.line = 'blended';
  SELECT l.annualized_rate INTO v_lapse_prior
    FROM public.compute_lapse_rate(p_agency_id, v_last - 91) l WHERE l.line = 'blended';
  v_gate_ok := NOT v_check
               OR (v_lapse_now IS NOT NULL AND v_lapse_prior IS NOT NULL AND v_lapse_now <= v_lapse_prior);

  -- Weekly retention + marketing points per person, computed once for the widest window.
  v_max_n := 52;
  IF v_go_live IS NOT NULL THEN
    v_max_n := LEAST(v_max_n, ((v_last - v_go_live) / 7) + 1);
  END IF;

  IF v_max_n > 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('wk', x.wk, 'tm', x.tm, 'rp', x.rp, 'mp', x.mp)), '[]'::jsonb)
      INTO v_weeks
      FROM (
        SELECT u.wk, u.tm, SUM(u.rp) AS rp, SUM(u.mp) AS mp
          FROM (
            SELECT (v_last - 7 * g.i) AS wk, w.team_member_id AS tm, w.net_points AS rp, 0::numeric AS mp
              FROM generate_series(0, v_max_n - 1) AS g(i)
             CROSS JOIN LATERAL public.compute_weekly_retention_points(p_agency_id, v_last - 7 * g.i) w
            UNION ALL
            SELECT m.week_end_date, m.team_member_id, 0::numeric, m.points
              FROM generate_series(0, v_max_n - 1) AS g(i)
             CROSS JOIN LATERAL public.marketing_points_weekly(p_agency_id, v_last - 7 * g.i) m
             WHERE m.week_end_date = v_last - 7 * g.i
          ) u
         GROUP BY u.wk, u.tm
      ) x;
  END IF;

  FOR s IN
    SELECT t.id, t.first_name, t.role_level, t.pay_type, t.pay_rate, t.hire_date,
           COALESCE(t.license_pc, false) AS has_pc, COALESCE(t.license_lh, false) AS has_lh
      FROM public.team t
     WHERE t.agency_id = p_agency_id AND t.category = 'agency'
       AND t.role_category = 'Retention'
       AND t.is_active = true AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
       AND t.pay_rate IS NOT NULL
     ORDER BY t.first_name
  LOOP
    v_hourly := CASE WHEN UPPER(COALESCE(s.pay_type, '')) = 'SALARY' THEN s.pay_rate / 40.0 ELSE s.pay_rate END;
    v_title := COALESCE((SELECT p.base_hourly FROM public.pay_scale p
                          WHERE p.agency_id = p_agency_id AND p.role_key = 'title_step'
                            AND p.title_label = s.role_level LIMIT 1), 0);

    SELECT p.raise_tier INTO v_cur
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.base_hourly <= (v_hourly - v_title)
     ORDER BY p.base_hourly DESC LIMIT 1;

    SELECT MAX(p.raise_tier) INTO v_lic
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.retention_requirement IS NOT NULL
       AND (s.has_pc OR NOT COALESCE(p.retention_requires_pc, false))
       AND (s.has_lh OR NOT COALESCE(p.retention_requires_lh, false));

    v_nx_tier := NULL; v_nx_pts := NULL; v_nx_lb := NULL;
    SELECT p.raise_tier, p.retention_points, p.lookback_quarters
      INTO v_nx_tier, v_nx_pts, v_nx_lb
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.raise_tier > GREATEST(COALESCE(v_cur, 0), COALESCE(v_lic, 0))
     ORDER BY p.raise_tier LIMIT 1;

    v_n := GREATEST(LEAST(COALESCE(v_nx_lb, 4) * 13, v_max_n), 0);
    IF s.hire_date IS NOT NULL THEN
      v_n := LEAST(v_n, GREATEST(((v_last - public.rp_week_end(s.hire_date)) / 7) + 1, 0));
    END IF;

    IF v_n > 0 THEN
      v_sp := COALESCE(public.team_member_sales_points_avg_nwk(s.id, v_n, v_last), 0);
      SELECT COALESCE(SUM((e->>'rp')::numeric), 0) / v_n,
             COALESCE(SUM((e->>'mp')::numeric), 0) / v_n
        INTO v_rp, v_mp
        FROM jsonb_array_elements(v_weeks) e
       WHERE (e->>'tm')::uuid = s.id
         AND (e->>'wk')::date > v_last - 7 * v_n;
      v_total := ROUND(v_sp + v_rp + v_mp, 2);
    ELSE
      v_sp := NULL; v_rp := NULL; v_mp := NULL; v_total := NULL;
    END IF;

    IF COALESCE(v_lic, 0) > COALESCE(v_cur, 0) THEN
      v_target := v_lic; v_by := 'license';
    ELSIF v_nx_pts IS NOT NULL AND v_total IS NOT NULL AND v_total >= v_nx_pts AND v_gate_ok THEN
      v_target := v_nx_tier; v_by := 'points';
    ELSE
      v_target := v_cur; v_by := NULL;
    END IF;

    SELECT p.base_hourly INTO v_target_rate
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.raise_tier = v_target;

    team_member_id := s.id;
    first_name := s.first_name;
    role_level := s.role_level;
    current_hourly := ROUND(v_hourly, 2);
    title_increment := v_title;
    current_tier := v_cur;
    license_tier := v_lic;
    next_tier := v_nx_tier;
    next_points := v_nx_pts;
    next_lookback_quarters := v_nx_lb;
    weeks_counted := v_n;
    avg_sales_points := ROUND(v_sp, 2);
    avg_retention_points := ROUND(v_rp, 2);
    avg_marketing_points := ROUND(v_mp, 2);
    avg_total_points := v_total;
    points_to_go := CASE WHEN v_nx_pts IS NULL OR v_total IS NULL THEN NULL
                         ELSE GREATEST(ROUND(v_nx_pts - v_total, 1), 0) END;
    lapse_now := ROUND(v_lapse_now * 100, 2);
    lapse_prior := ROUND(v_lapse_prior * 100, 2);
    lapse_check_passed := v_gate_ok;
    earned_by := v_by;
    would_be_tier := v_target;
    would_be_hourly := GREATEST(ROUND(v_hourly, 2), COALESCE(v_target_rate, 0) + v_title);
    ladder_live := v_live;
    RETURN NEXT;
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.retention_raise_track(uuid, date) IS
  'TENTATIVE retention raise track (Peter 2026-10-04). Preview only until settings.retention_ladder_live = true. Total points = sales + retention + marketing points vs pay_scale.retention_points; licence flags are an automatic bump; lapse check on earned steps.';

