-- Peter 2026-08-28: earnings_projection_base_ladder folded into pay_scale
-- and dropped.
--
-- What that table actually held was 60 rows of base pay by role x performer
-- tier x year one to five. Every dollar figure in it is already a pay_scale
-- row: retention's 33,280 / 37,440 / 41,600 are the $16 / $18 / $20 licence
-- steps, and life specialist's 40,000 / 45,000 / 50,000 are the rows those
-- were fitted to ($19 / $22 / $24). The only thing it added was WHEN each
-- performer tier reaches each step. That is now two jsonb columns on the
-- step rows: tier key -> the year of employment that tier first reaches
-- this step. A tier missing from the map never reaches that step.
--
-- Its sales rows were already dead — the chart takes sales base from
-- pay_scale.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS retention_reached_year       jsonb,
  ADD COLUMN IF NOT EXISTS life_specialist_reached_year jsonb;

COMMENT ON COLUMN public.pay_scale.retention_reached_year IS
  'Performer tier -> the year of employment that tier first reaches this pay step, for a Retention seat. Absent tier = never reaches it.';
COMMENT ON COLUMN public.pay_scale.life_specialist_reached_year IS
  'Performer tier -> the year of employment that tier first reaches this pay step, for a Life Specialist.';

UPDATE public.pay_scale p SET retention_reached_year = v.m::jsonb
  FROM (VALUES
    (1, '{"rock":1,"rock_n_roll":1}'),
    (3, '{"rock":2,"rock_n_roll":2,"rockstar":1,"rock_legend":1}'),
    (5, '{"rock_n_roll":3,"rockstar":2,"rock_legend":2}')
  ) AS v(tier, m)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.tier_starts_here AND p.raise_tier = v.tier;

UPDATE public.pay_scale p SET life_specialist_reached_year = v.m::jsonb
  FROM (VALUES
    (4, '{"rock":1,"rock_n_roll":1,"rockstar":1,"rock_legend":1}'),
    (7, '{"rock":2,"rock_n_roll":2,"rockstar":2,"rock_legend":2}'),
    (9, '{"rock_n_roll":3,"rockstar":3,"rock_legend":3}')
  ) AS v(tier, m)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.tier_starts_here AND p.raise_tier = v.tier;

-- Base pay for a seat, straight off pay_scale.
CREATE OR REPLACE FUNCTION public.pay_scale_role_base(p_agency_id uuid, p_role text, p_tier text, p_year int)
 RETURNS TABLE(annual_base numeric, base_hourly numeric, step_label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.base_annual, p.base_hourly,
         CASE WHEN p_role = 'retention' THEN p.retention_requirement
              WHEN p_role = 'life_specialist' THEN p.life_specialist_requirement
              ELSE 'Starting rate' END
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
     AND CASE
           WHEN p_role = 'retention' THEN
             (p.retention_reached_year ->> p_tier) IS NOT NULL
             AND (p.retention_reached_year ->> p_tier)::int <= p_year
           WHEN p_role = 'life_specialist' THEN
             (p.life_specialist_reached_year ->> p_tier) IS NOT NULL
             AND (p.life_specialist_reached_year ->> p_tier)::int <= p_year
           ELSE p.raise_tier = 0
         END
   ORDER BY p.base_annual DESC
   LIMIT 1;
$function$;

-- Rewire the projection off the retired table.
DO $mig$
DECLARE v_def text; v_new text; v_hits int := 0;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='compute_role_earnings_projection';
  v_new := v_def;

  -- 1. Role list
  v_new := replace(v_new,
$a$      FROM public.earnings_projection_base_ladder l
     WHERE l.agency_id = p_agency_id
     ORDER BY ord$a$,
$b$      FROM (VALUES ('sales'),('retention'),('life_specialist')) AS l(role_key)
     ORDER BY ord$b$);

  -- 2. Base + step label for the year-by-year grid
  v_new := replace(v_new,
$a$          SELECT l.annual_base, l.step_label INTO v_base, v_step
            FROM public.earnings_projection_base_ladder l
           WHERE l.agency_id = p_agency_id
             AND l.role_key = r_role.role_key
             AND l.tier_key = r_tier.tier_key
             AND l.year_num = y;$a$,
$b$          SELECT b.annual_base, b.step_label INTO v_base, v_step
            FROM public.pay_scale_role_base(p_agency_id, r_role.role_key,
                                            r_tier.tier_key, y) b;$b$);

  -- 3. Entry base for the computed curves
  v_new := replace(v_new,
$a$        SELECT MIN(l.annual_base) INTO v_entry_base
          FROM public.earnings_projection_base_ladder l
         WHERE l.agency_id = p_agency_id AND l.role_key = r_role.role_key
           AND NOT (r_role.role_key = 'retention' AND l.annual_base <= 16 * 2080);$a$,
$b$        SELECT MIN(p.base_annual) INTO v_entry_base
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
           AND ((r_role.role_key = 'retention'
                 AND p.retention_reached_year IS NOT NULL
                 AND p.base_annual > 16 * 2080)
             OR (r_role.role_key = 'life_specialist'
                 AND p.life_specialist_reached_year IS NOT NULL));$b$);

  -- 4. Steady-state base per tier for the band definitions
  v_new := replace(v_new,
$a$                 (SELECT l.annual_base FROM public.earnings_projection_base_ladder l
                   WHERE l.agency_id = p_agency_id AND l.role_key = r_role.role_key
                     AND l.tier_key = t.tier_key AND l.year_num = 5) AS steady_base$a$,
$b$                 (SELECT b.annual_base FROM public.pay_scale_role_base(
                    p_agency_id, r_role.role_key, t.tier_key, 5) b) AS steady_base$b$);

  IF v_new LIKE '%earnings_projection_base_ladder%' THEN
    RAISE EXCEPTION 'projection still references the retired base ladder';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- reseed must carry the two new authored columns, or a rebuild blanks them.
DO $mig2$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='reseed_pay_scale';
  v_new := v_def;
  v_new := replace(v_new,
    $a$           'life', p.life_specialist_requirement$a$,
    $b$           'life', p.life_specialist_requirement,
           'ret_year', p.retention_reached_year,
           'life_year', p.life_specialist_reached_year$b$);
  v_new := replace(v_new,
    $a$  v_ls     text;$a$,
    $b$  v_ls     text;
  v_ret_yr jsonb;
  v_ls_yr  jsonb;$b$);
  v_new := replace(v_new,
    $a$           ((e->>'threshold')::int = v_x), e->>'retention', e->>'life'
      INTO v_tier, v_hourly, v_lb, v_starts, v_ret, v_ls$a$,
    $b$           ((e->>'threshold')::int = v_x), e->>'retention', e->>'life',
           e->'ret_year', e->'life_year'
      INTO v_tier, v_hourly, v_lb, v_starts, v_ret, v_ls, v_ret_yr, v_ls_yr$b$);
  v_new := replace(v_new,
    $a$      retention_requirement, life_specialist_requirement, updated_at$a$,
    $b$      retention_requirement, life_specialist_requirement,
      retention_reached_year, life_specialist_reached_year, updated_at$b$);
  v_new := replace(v_new,
    $a$      CASE WHEN v_starts THEN v_ls  ELSE NULL END,
      now()$a$,
    $b$      CASE WHEN v_starts THEN v_ls  ELSE NULL END,
      CASE WHEN v_starts THEN v_ret_yr ELSE NULL END,
      CASE WHEN v_starts THEN v_ls_yr  ELSE NULL END,
      now()$b$);
  IF v_new NOT LIKE '%retention_reached_year%' THEN
    RAISE EXCEPTION 'reseed capture not extended';
  END IF;
  EXECUTE v_new;
END
$mig2$;

DROP TABLE IF EXISTS public.earnings_projection_base_ladder;

-- CPR and Team badge: show the band, not the nickname (Peter 2026-08-28).
CREATE OR REPLACE FUNCTION public.team_sales_points_ratings(p_agency_id uuid)
 RETURNS TABLE(team_member_id uuid, first_name text, role_category text, weeks_employed integer, avg_13wk numeric, rel_13wk numeric, rating text, title text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  WITH seats AS (
    SELECT
      t.id,
      t.first_name,
      t.role_category,
      CASE WHEN t.hire_date IS NULL THEN 0
           ELSE FLOOR((CURRENT_DATE - t.hire_date) / 7.0)::integer END AS weeks_employed,
      CASE WHEN t.role_category = 'Retention' THEN 0.5 ELSE 1.0 END    AS req_weight,
      public.team_member_sales_points_avg_13wk(t.id)                   AS avg_13wk
    FROM public.team t
    WHERE t.agency_id             = p_agency_id
      AND t.category              = 'agency'
      AND COALESCE(t.role_level,'') <> 'Owner'
      AND COALESCE(t.license_pc, false) = true
      AND t.archived_at IS NULL
      AND t.is_test_user IS NOT TRUE
  ),
  rated AS (
    SELECT
      s.*,
      CASE WHEN s.avg_13wk IS NULL THEN NULL
           ELSE ROUND(s.avg_13wk / s.req_weight, 2) END AS rel_13wk
    FROM seats s
  )
  SELECT
    r.id,
    r.first_name,
    r.role_category,
    r.weeks_employed,
    r.avg_13wk,
    r.rel_13wk,
    CASE WHEN r.rel_13wk IS NULL OR r.weeks_employed < 13 THEN NULL
         ELSE public.compute_sales_points_rating(p_agency_id, r.rel_13wk) END AS rating,
    -- The badge is the band itself. Good, Great or Elite; nothing below.
    CASE
      WHEN r.rel_13wk IS NULL OR r.weeks_employed < 13 THEN NULL
      WHEN public.compute_sales_points_rating(p_agency_id, r.rel_13wk)
           IN ('Good','Great','Elite')
        THEN public.compute_sales_points_rating(p_agency_id, r.rel_13wk)
      ELSE NULL
    END AS title
  FROM rated r
  ORDER BY r.first_name;
$function$;
