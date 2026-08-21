-- ============================================================
-- staff → team: full rename, new columns, FK rename, view & function rebuild
-- ============================================================

-- 1. Rename main table
ALTER TABLE public.staff RENAME TO team;

-- 2. Rename existing columns to clearer names
ALTER TABLE public.team RENAME COLUMN email TO email_personal;
ALTER TABLE public.team RENAME COLUMN phone TO phone_personal;

-- 3. Add new columns
ALTER TABLE public.team ADD COLUMN sf_alias text;
ALTER TABLE public.team ADD COLUMN account_alpha text;
ALTER TABLE public.team ADD COLUMN email_sf text;
ALTER TABLE public.team ADD COLUMN phone_extension text;

-- 4. Partial unique indexes (only enforce when value is present)
CREATE UNIQUE INDEX team_sf_alias_unique
  ON public.team (agency_id, sf_alias) WHERE sf_alias IS NOT NULL;
CREATE UNIQUE INDEX team_phone_extension_unique
  ON public.team (agency_id, phone_extension) WHERE phone_extension IS NOT NULL;
CREATE UNIQUE INDEX team_email_sf_unique
  ON public.team (agency_id, email_sf) WHERE email_sf IS NOT NULL;

-- 5. Rename FK columns in all 8 child tables: staff_id → team_member_id
ALTER TABLE public.payroll_detail         RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.onboarding_checklists  RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.commission_structures  RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.staff_performance      RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.producer_production    RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.staff_assessments      RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.staff_behavioral_notes RENAME COLUMN staff_id TO team_member_id;
ALTER TABLE public.time_clock_entries     RENAME COLUMN staff_id TO team_member_id;

-- 6. Rename child tables
ALTER TABLE public.staff_performance      RENAME TO team_performance;
ALTER TABLE public.staff_assessments      RENAME TO team_assessments;
ALTER TABLE public.staff_behavioral_notes RENAME TO team_behavioral_notes;

-- 7. Rename RLS policy
ALTER POLICY anon_read_staff ON public.team RENAME TO anon_read_team;

-- 8. Rebuild views with team_member_id aliases
DROP VIEW IF EXISTS public.v_producer_complacency;
CREATE VIEW public.v_producer_complacency AS
WITH periods AS (
  SELECT pp.team_member_id, pp.agency_id,
    COALESCE(SUM(pp.premium_issued) FILTER (
      WHERE make_date(pp.period_year, pp.period_month, 1) >= date_trunc('month', CURRENT_DATE - INTERVAL '2 months')
        AND make_date(pp.period_year, pp.period_month, 1) <  date_trunc('month', CURRENT_DATE::timestamptz)), 0) / 2.0 AS avg_recent_2mo,
    COALESCE(SUM(pp.premium_issued) FILTER (
      WHERE make_date(pp.period_year, pp.period_month, 1) >= date_trunc('month', CURRENT_DATE - INTERVAL '6 months')
        AND make_date(pp.period_year, pp.period_month, 1) <  date_trunc('month', CURRENT_DATE - INTERVAL '2 months')), 0) / 4.0 AS avg_baseline_4mo,
    COUNT(*) FILTER (WHERE make_date(pp.period_year, pp.period_month, 1) >= date_trunc('month', CURRENT_DATE - INTERVAL '6 months')) AS data_points_available
  FROM producer_production pp
  WHERE pp.premium_type = 'new'
  GROUP BY pp.team_member_id, pp.agency_id
)
SELECT t.id AS team_member_id, t.agency_id,
  (t.first_name || ' ' || t.last_name) AS producer_name,
  t.primary_function, t.complacency_risk,
  ROUND(p.avg_recent_2mo, 2)  AS avg_premium_recent_2mo,
  ROUND(p.avg_baseline_4mo,2) AS avg_premium_baseline_4mo,
  CASE WHEN p.avg_baseline_4mo > 0
       THEN ROUND((p.avg_recent_2mo - p.avg_baseline_4mo) / p.avg_baseline_4mo * 100, 1)
       ELSE NULL END AS pct_change,
  COALESCE(p.data_points_available, 0) AS data_points_available,
  CASE WHEN p.avg_baseline_4mo > 0
        AND p.avg_recent_2mo < (p.avg_baseline_4mo * 0.90)
        AND COALESCE(p.data_points_available, 0) >= 4
       THEN true ELSE false END AS complacency_alert,
  CURRENT_DATE AS as_of_date
FROM team t
LEFT JOIN periods p ON p.team_member_id = t.id
WHERE t.is_active = true
  AND t.primary_function = ANY (ARRAY['new_business','inside_sales']);

DROP VIEW IF EXISTS public.v_producer_roi_inputs;
CREATE VIEW public.v_producer_roi_inputs AS
WITH cfg AS (
  SELECT agency.id AS agency_id,
    COALESCE(agency.smvc_rate_pc, 0.10)            AS smvc_rate_pc,
    COALESCE(agency.blended_rate_other, 0.09)       AS blended_rate_other,
    COALESCE(agency.lapse_rate_annual, 0.11)        AS lapse_rate_annual,
    COALESCE(agency.payroll_burden_multiplier,1.15) AS burden,
    agency.rates_are_defaults
  FROM agency
), team_cost AS (
  SELECT t.id AS team_member_id, t.agency_id,
    (t.first_name || ' ' || t.last_name) AS producer_name,
    t.role, t.pay_type, t.pay_rate, t.pay_frequency, t.role_level,
    CASE lower(COALESCE(t.pay_frequency, 'weekly'))
      WHEN 'weekly'      THEN t.pay_rate * 52
      WHEN 'biweekly'    THEN t.pay_rate * 26
      WHEN 'semimonthly' THEN t.pay_rate * 24
      WHEN 'monthly'     THEN t.pay_rate * 12
      WHEN 'annual'      THEN t.pay_rate
      WHEN 'hourly'      THEN t.pay_rate * 2080
      ELSE t.pay_rate * 52
    END AS annual_pay
  FROM team t
  WHERE t.is_active = true AND t.archived_at IS NULL AND t.category = 'agency'
), recent AS (
  SELECT pp.team_member_id, pp.agency_id,
    SUM(pp.premium_issued)             AS new_premium_3mo,
    SUM(pp.premium_issued) / 3.0        AS new_premium_monthly_avg,
    COUNT(DISTINCT (pp.period_year || '-' || pp.period_month)) AS months_counted
  FROM producer_production pp
  WHERE pp.premium_type = 'new'
    AND make_date(pp.period_year, pp.period_month, 1) >= (date_trunc('month', CURRENT_DATE) - INTERVAL '3 months')
  GROUP BY pp.team_member_id, pp.agency_id
)
SELECT tc.team_member_id, tc.agency_id, tc.producer_name, tc.role, tc.annual_pay,
  ROUND(tc.annual_pay * cfg.burden, 2)         AS fully_loaded_annual_cost,
  ROUND(tc.annual_pay * cfg.burden / 12, 2)    AS fully_loaded_monthly_cost,
  COALESCE(ROUND(r.new_premium_monthly_avg,2), 0) AS new_premium_monthly_avg,
  cfg.smvc_rate_pc, cfg.lapse_rate_annual, cfg.burden, cfg.rates_are_defaults,
  COALESCE(ROUND(r.new_premium_monthly_avg * cfg.smvc_rate_pc, 2), 0) AS monthly_new_commission,
  COALESCE(ROUND(r.new_premium_monthly_avg * 12 * cfg.smvc_rate_pc * (1 - cfg.lapse_rate_annual), 2), 0) AS yr1_renewal_commission_est,
  tc.role_level
FROM team_cost tc
LEFT JOIN cfg    ON cfg.agency_id = tc.agency_id
LEFT JOIN recent r   ON r.team_member_id = tc.team_member_id
WHERE tc.role = ANY (ARRAY['Acquisition','Inside Sales','Owner']);

DROP VIEW IF EXISTS public.v_time_clock_status;
CREATE VIEW public.v_time_clock_status AS
SELECT t.id AS team_member_id, t.agency_id, t.first_name, t.last_name, t.pay_rate,
  t.time_clock_pin_hash IS NOT NULL AS pin_set,
  e.id AS open_entry_id, e.clock_in_at,
  e.id IS NOT NULL AS is_clocked_in,
  CASE WHEN e.clock_in_at IS NULL THEN NULL
       ELSE ROUND(EXTRACT(EPOCH FROM now() - e.clock_in_at) / 3600.0, 2)
  END AS hours_this_block
FROM team t
LEFT JOIN time_clock_entries e ON e.team_member_id = t.id AND e.clock_out_at IS NULL
WHERE t.is_active = true AND t.pay_type = 'HOURLY' AND t.archived_at IS NULL;

-- 9. Rebuild functions referencing staff / staff_id
DROP FUNCTION IF EXISTS public.check_producer_complacency();
CREATE FUNCTION public.check_producer_complacency()
 RETURNS TABLE(team_member_id uuid, agency_id uuid, producer_name text, pct_change numeric, recent_avg numeric, baseline_avg numeric, alert_title text, alert_message text)
 LANGUAGE sql STABLE
AS $function$
  SELECT v.team_member_id, v.agency_id, v.producer_name, v.pct_change,
    v.avg_premium_recent_2mo, v.avg_premium_baseline_4mo,
    'Producer complacency signal: ' || v.producer_name AS alert_title,
    v.producer_name || ' trailing 2-month average new P&C premium is '
      || ABS(v.pct_change) || '% below their trailing 4-month baseline ($'
      || v.avg_premium_recent_2mo || ' vs $' || v.avg_premium_baseline_4mo
      || '). Time for a check-in before the slip deepens into a full bad quarter.' AS alert_message
  FROM public.v_producer_complacency v
  WHERE v.complacency_alert = true;
$function$;

CREATE OR REPLACE FUNCTION public.producer_complacency_check(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_inserted integer := 0;
  v_names    text[]  := '{}';
  v_summary  text;
  r          RECORD;
BEGIN
  FOR r IN
    SELECT v.team_member_id, v.producer_name, v.pct_change,
           v.avg_premium_recent_2mo, v.avg_premium_baseline_4mo
    FROM public.v_producer_complacency v
    WHERE v.agency_id = p_agency_id AND v.complacency_alert = true
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.alerts a
      WHERE a.agency_id = p_agency_id AND a.is_resolved = false
        AND a.title = 'Producer complacency signal: ' || r.producer_name
        AND a.created_at >= date_trunc('day', now())
    ) THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved)
      VALUES (p_agency_id, 'producer_complacency', 'warning',
              'Producer complacency signal: ' || r.producer_name,
              r.producer_name || ' trailing 2-month average new P&C premium is '
                || ABS(r.pct_change) || '% below their trailing 4-month baseline ($'
                || r.avg_premium_recent_2mo || ' vs $' || r.avg_premium_baseline_4mo
                || '). Time for a check-in before the slip deepens into a full bad quarter.',
              'HR', r.team_member_id, false, false);
      v_inserted := v_inserted + 1;
      v_names := v_names || r.producer_name;
    END IF;
  END LOOP;

  v_summary := CASE WHEN v_inserted = 0
    THEN 'No new complacency alerts. All producers within 10% of baseline (or already alerted today).'
    ELSE 'Fired complacency alerts for: ' || array_to_string(v_names, ', ')
  END;

  RETURN jsonb_build_object('records_processed', v_inserted, 'output_summary', v_summary);
END;
$function$;

CREATE OR REPLACE FUNCTION public.producer_underperformance_watcher(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_today DATE := CURRENT_DATE;
  v_curr_year INT := EXTRACT(YEAR FROM v_today)::INT;
  v_curr_month INT := EXTRACT(MONTH FROM v_today)::INT;
  v_day_of_month INT := EXTRACT(DAY FROM v_today)::INT;
  v_days_in_month INT := EXTRACT(DAY FROM (date_trunc('month', v_today) + INTERVAL '1 month - 1 day'))::INT;
  v_pace_factor NUMERIC := v_day_of_month::numeric / NULLIF(v_days_in_month, 0)::numeric;
  v_alert_count INTEGER := 0;
  v_producer RECORD;
  v_mtd_premium NUMERIC;
  v_3mra_premium NUMERIC;
  v_pace_ratio NUMERIC;
  v_mod_ref TEXT;
BEGIN
  IF v_day_of_month < 5 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'Skipped: too early in month');
  END IF;

  FOR v_producer IN
    SELECT id, first_name, last_name, role FROM public.team
    WHERE agency_id = p_agency_id AND COALESCE(is_active, true) = true
      AND role IS NOT NULL
      AND (role ILIKE '%LSP%' OR role ILIKE '%Producer%' OR role ILIKE '%Financial Services%')
  LOOP
    SELECT COALESCE(SUM(premium_issued), 0) INTO v_mtd_premium
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND team_member_id = v_producer.id
      AND period_year = v_curr_year AND period_month = v_curr_month;

    SELECT COALESCE(AVG(monthly_total), 0) INTO v_3mra_premium
    FROM (
      SELECT period_year, period_month, SUM(premium_issued) AS monthly_total
      FROM public.producer_production
      WHERE agency_id = p_agency_id AND team_member_id = v_producer.id
        AND (period_year, period_month) IN (
          SELECT EXTRACT(YEAR FROM (v_today - INTERVAL '1 month'))::int,
                 EXTRACT(MONTH FROM (v_today - INTERVAL '1 month'))::int
          UNION ALL SELECT EXTRACT(YEAR FROM (v_today - INTERVAL '2 month'))::int,
                 EXTRACT(MONTH FROM (v_today - INTERVAL '2 month'))::int
          UNION ALL SELECT EXTRACT(YEAR FROM (v_today - INTERVAL '3 month'))::int,
                 EXTRACT(MONTH FROM (v_today - INTERVAL '3 month'))::int
        )
      GROUP BY period_year, period_month
    ) prior_months;

    IF v_3mra_premium <= 0 THEN CONTINUE; END IF;

    v_pace_ratio := CASE
      WHEN v_3mra_premium * v_pace_factor > 0 THEN v_mtd_premium / (v_3mra_premium * v_pace_factor)
      ELSE NULL
    END;

    IF v_pace_ratio IS NOT NULL AND v_pace_ratio < 0.70 THEN
      v_mod_ref := 'producer_underperformance_watcher:' || v_producer.id::text;
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, created_at)
      SELECT p_agency_id, 'producer_underperformance', 'warning',
             v_producer.first_name || ' ' || v_producer.last_name || ': MTD pace ' || ROUND(v_pace_ratio * 100, 0) || '% of 3MRA',
             'Through day ' || v_day_of_month || ' of ' || v_days_in_month || ', producer issued $' || ROUND(v_mtd_premium, 0) || ' premium.',
             v_mod_ref, false, false, NOW()
      WHERE NOT EXISTS (SELECT 1 FROM public.alerts WHERE agency_id = p_agency_id
                        AND module_reference = v_mod_ref AND is_resolved = false AND created_at::date = v_today);
      v_alert_count := v_alert_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('records_processed', v_alert_count,
                            'output_summary', v_alert_count || ' producers flagged as underperforming MTD');
END;
$function$;

-- time_clock_punch: rebuild with team references; KEEP p_staff_id parameter name to avoid breaking the RPC contract from the frontend kiosk
CREATE OR REPLACE FUNCTION public.time_clock_punch(p_staff_id uuid, p_pin text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_member team%ROWTYPE;
  v_open   time_clock_entries%ROWTYPE;
  v_now    timestamptz := now();
  v_hours  numeric;
BEGIN
  SELECT * INTO v_member FROM team WHERE id = p_staff_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_team_member');
  END IF;
  IF v_member.is_active IS NOT TRUE OR v_member.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'inactive_team_member');
  END IF;
  IF v_member.pay_type <> 'HOURLY' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_hourly');
  END IF;
  IF v_member.time_clock_pin_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_not_set');
  END IF;
  IF v_member.time_clock_pin_hash <> time_clock_hash_pin(v_member.agency_id, p_pin) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_pin');
  END IF;

  SELECT * INTO v_open FROM time_clock_entries
  WHERE team_member_id = p_staff_id AND clock_out_at IS NULL
  ORDER BY clock_in_at DESC LIMIT 1;

  IF FOUND THEN
    UPDATE time_clock_entries SET clock_out_at = v_now WHERE id = v_open.id;
    v_hours := EXTRACT(EPOCH FROM (v_now - v_open.clock_in_at)) / 3600.0;
    RETURN jsonb_build_object('ok', true, 'action', 'clock_out',
      'team_member_name', v_member.first_name || ' ' || v_member.last_name,
      'at', v_now, 'hours_this_block', round(v_hours::numeric, 2));
  ELSE
    INSERT INTO time_clock_entries (agency_id, team_member_id, clock_in_at, source)
    VALUES (v_member.agency_id, p_staff_id, v_now, 'kiosk');
    RETURN jsonb_build_object('ok', true, 'action', 'clock_in',
      'team_member_name', v_member.first_name || ' ' || v_member.last_name,
      'at', v_now);
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.time_clock_set_pin(p_staff_id uuid, p_pin text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_member team%ROWTYPE;
BEGIN
  IF p_pin !~ '^\d{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_must_be_4_digits');
  END IF;
  SELECT * INTO v_member FROM team WHERE id = p_staff_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_team_member');
  END IF;
  UPDATE team
  SET time_clock_pin_hash = time_clock_hash_pin(v_member.agency_id, p_pin),
      updated_at = now()
  WHERE id = p_staff_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
