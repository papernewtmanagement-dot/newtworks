-- Peter 2026-10-04: the Retention Points stack resets every week instead of every
-- quarter, at +5% per earlier same-kind item that week, capped at +50% (10 earlier).
-- Bank and Cancelation Logged go flat. Starts with the week ending 2026-10-10;
-- earlier weeks keep the old quarter stack (+1% per earlier one, cap 99).
ALTER TABLE public.retention_point_values
  ADD COLUMN IF NOT EXISTS kicker_from_week_end date,
  ADD COLUMN IF NOT EXISTS prior_step_pct_before numeric,
  ADD COLUMN IF NOT EXISTS prior_cap_before integer;

COMMENT ON COLUMN public.retention_point_values.kicker_from_week_end IS
  'First week (Saturday) the stack counts within the week. Weeks before it use prior_step_pct_before / prior_cap_before counted across the quarter.';

UPDATE public.retention_point_values
   SET prior_step_pct_before = prior_step_pct,
       prior_cap_before      = prior_cap,
       kicker_from_week_end  = DATE '2026-10-10',
       prior_step_pct = CASE WHEN activity_key IN ('bank_product_funded','cancelation_logged') THEN 0 ELSE 5.0 END,
       prior_cap      = CASE WHEN activity_key IN ('bank_product_funded','cancelation_logged') THEN 0 ELSE 10 END,
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND COALESCE(prior_cap,0) > 0 AND kicker_from_week_end IS NULL;

CREATE OR REPLACE FUNCTION public.rp_kicker_bucket(p_weekly_from date, p_week date, p_occurred date, p_anchor date)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_weekly_from IS NOT NULL AND p_week >= p_weekly_from
              THEN 'w' || p_week::text
              ELSE 'q' || floor((p_occurred - COALESCE(p_anchor, DATE '2026-04-05'))::numeric / 91.0)::text END
$$;

CREATE OR REPLACE FUNCTION public.rp_kicked_points(p_base numeric, p_step numeric, p_cap integer,
  p_step_before numeric, p_cap_before integer, p_weekly_from date, p_week date, p_prior bigint)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  WITH s AS (
    SELECT CASE WHEN p_weekly_from IS NOT NULL AND p_week >= p_weekly_from THEN COALESCE(p_step,0)
                ELSE COALESCE(p_step_before, p_step, 0) END AS step,
           CASE WHEN p_weekly_from IS NOT NULL AND p_week >= p_weekly_from THEN COALESCE(p_cap,0)
                ELSE COALESCE(p_cap_before, p_cap, 0) END AS cap)
  SELECT CASE WHEN p_base > 0 AND s.step > 0 AND s.cap > 0
              THEN round(p_base * (1 + s.step / 100.0 * LEAST(s.cap::bigint, COALESCE(p_prior,0))::numeric), 2)
              ELSE p_base END
  FROM s
$$;

CREATE OR REPLACE VIEW public.retention_activity_now WITH (security_invoker = true) AS
 WITH x AS (
   SELECT l.id, l.agency_id, l.team_member_id, l.activity_key, l.occurred_on, l.week_end_date,
          l.credited_week_end_date, l.credit_available_on, l.customer_first_name, l.customer_last_initial,
          customer_label(l.*) AS customer_label, l.ecrm_url, l.note, l.save_reason, l.save_line, l.points,
          l.status, l.source, l.source_id, l.created_by, l.created_at, l.updated_at, l.voided_at, l.voided_by,
          l.void_reason, l.verified_at, l.verified_by, l.policy_line, l.product_type, l.premium, l.phone_last4,
          l.review_platform, l.spot_check_note, l.customer_kind,
          v.prior_step_pct, v.prior_cap, v.prior_step_pct_before, v.prior_cap_before, v.kicker_from_week_end,
          COALESCE(l.credited_week_end_date, l.week_end_date) AS wk,
          count(*) FILTER (WHERE (l.status <> ALL (ARRAY['void'::text, 'voided'::text])) AND l.points > 0::numeric)
            OVER (PARTITION BY l.agency_id, l.team_member_id, l.activity_key,
                  public.rp_kicker_bucket(v.kicker_from_week_end, COALESCE(l.credited_week_end_date, l.week_end_date), l.occurred_on, a.d)
                  ORDER BY l.occurred_on, l.created_at, l.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior
     FROM retention_activity_log l
     LEFT JOIN retention_point_values v ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
     LEFT JOIN LATERAL (SELECT s.setting_value::date AS d FROM settings s
                         WHERE s.agency_id = l.agency_id AND s.setting_key = 'cycle_anchor_date'::text) a ON true
 )
 SELECT id, agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        credit_available_on, customer_first_name, customer_last_initial, customer_label, ecrm_url, note,
        save_reason, save_line,
        public.rp_kicked_points(points, prior_step_pct, prior_cap, prior_step_pct_before, prior_cap_before,
                                kicker_from_week_end, wk, prior) AS points,
        status, source, source_id, created_by, created_at, updated_at, voided_at, voided_by, void_reason,
        verified_at, verified_by, policy_line, product_type, premium, phone_last4, review_platform,
        spot_check_note, customer_kind, points AS base_points
   FROM x;

CREATE OR REPLACE FUNCTION public.rp_next_values(p_team_member_id uuid DEFAULT NULL, p_on date DEFAULT NULL)
RETURNS TABLE(activity_key text, base_points numeric, next_points numeric, earlier_this_week integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  act record; v_on date; v_wk date; v_anchor date;
BEGIN
  SELECT * INTO act FROM public.rp_resolve_actor(p_team_member_id);
  v_on := COALESCE(p_on, (now() AT TIME ZONE 'America/Chicago')::date);
  v_wk := public.rp_week_end(v_on);
  SELECT s.setting_value::date INTO v_anchor FROM public.settings s
   WHERE s.agency_id = act.agency_id AND s.setting_key = 'cycle_anchor_date';
  RETURN QUERY
  SELECT v.activity_key, v.points,
         public.rp_kicked_points(v.points, v.prior_step_pct, v.prior_cap, v.prior_step_pct_before, v.prior_cap_before,
                                 v.kicker_from_week_end, v_wk, c.n),
         c.n::int
    FROM public.retention_point_values v
    CROSS JOIN LATERAL (
      SELECT count(*) AS n FROM public.retention_activity_log l
       WHERE l.agency_id = v.agency_id AND l.team_member_id = act.team_member_id AND l.activity_key = v.activity_key
         AND (l.status <> ALL (ARRAY['void','voided'])) AND l.points > 0
         AND public.rp_kicker_bucket(v.kicker_from_week_end, COALESCE(l.credited_week_end_date, l.week_end_date), l.occurred_on, v_anchor)
           = public.rp_kicker_bucket(v.kicker_from_week_end, v_wk, v_on, v_anchor)) c
   WHERE v.agency_id = act.agency_id AND v.is_active AND v.points > 0;
END $$;
REVOKE ALL ON FUNCTION public.rp_next_values(uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.rp_next_values(uuid, date) TO authenticated;
