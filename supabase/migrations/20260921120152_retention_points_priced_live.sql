-- Peter 2026-09-21: retention points are worked out when they are read, never
-- stored. The 1%-per-prior step was baked into each row when it was logged
-- (trigger rp_scale_points_by_prior), so removing an earlier Policy Review left
-- every later one priced as if it were still there.
--
-- Now:
--  * retention_activity_log.points holds the BASE value only: what the activity
--    is worth on its own (catalog value, or an admin's override).
--  * retention_activity_now is the table with points priced live: base x (1 +
--    step% x earlier ones of the same kind by the same person this quarter,
--    up to the cap), counting only entries still standing, in date order.
--  * Every reader of retention points reads the view.

SET LOCAL session_replication_role = replica;  -- a repricing, not a change anyone made

-- 1. Take the baked-in step back out. Rows inside the step range of their
--    catalog value go back to the catalog value; anything else was set by hand
--    and is kept as its base.
UPDATE public.retention_activity_log l
   SET points = v.points
  FROM public.retention_point_values v
 WHERE v.agency_id = l.agency_id AND v.activity_key = l.activity_key
   AND COALESCE(v.prior_step_pct, 0) > 0 AND COALESCE(v.prior_cap, 0) > 0
   AND v.points > 0 AND l.points > 0 AND l.points <> v.points
   AND l.points BETWEEN v.points AND v.points * (1 + v.prior_step_pct / 100.0 * v.prior_cap) + 0.01;

-- 2. No more pricing at insert.
DROP TRIGGER IF EXISTS trg_rp_scale_points_by_prior ON public.retention_activity_log;
DROP FUNCTION IF EXISTS public.rp_scale_points_by_prior();

-- 3. The live price.
CREATE OR REPLACE VIEW public.retention_activity_now
WITH (security_invoker = true) AS
WITH x AS (
  SELECT l.*,
         v.prior_step_pct, v.prior_cap,
         count(*) FILTER (WHERE l.status NOT IN ('void', 'voided') AND l.points > 0) OVER (
           PARTITION BY l.agency_id, l.team_member_id, l.activity_key,
                        floor((l.occurred_on - COALESCE(a.d, DATE '2026-04-05')) / 91.0)
           ORDER BY l.occurred_on, l.created_at, l.id
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior
    FROM public.retention_activity_log l
    LEFT JOIN public.retention_point_values v
      ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
    LEFT JOIN LATERAL (SELECT s.setting_value::date AS d FROM public.settings s
                        WHERE s.agency_id = l.agency_id AND s.setting_key = 'cycle_anchor_date') a ON true
)
SELECT x.id, x.agency_id, x.team_member_id, x.activity_key, x.occurred_on, x.week_end_date,
       x.credited_week_end_date, x.credit_available_on, x.customer_first_name, x.customer_last_initial,
       x.customer_label, x.ecrm_url, x.note, x.save_reason, x.save_line,
       CASE WHEN x.points > 0 AND COALESCE(x.prior_step_pct, 0) > 0 AND COALESCE(x.prior_cap, 0) > 0
            THEN round(x.points * (1 + x.prior_step_pct / 100.0 * LEAST(x.prior_cap, COALESCE(x.prior, 0))), 2)
            ELSE x.points END AS points,
       x.status, x.source, x.source_id, x.created_by, x.created_at, x.updated_at, x.voided_at, x.voided_by,
       x.void_reason, x.verified_at, x.verified_by, x.policy_line, x.product_type, x.premium, x.phone_last4,
       x.review_platform, x.spot_check_note, x.customer_kind,
       x.points AS base_points
  FROM x;

COMMENT ON VIEW public.retention_activity_now IS
'retention_activity_log with points priced live: base points x (1 + step% x earlier standing entries of the same kind by the same person in the same 13-week quarter, capped), in date order. Read retention points from here, never from the table. Peter 2026-09-21.';

GRANT SELECT ON public.retention_activity_now TO authenticated;

-- 4. Every reader of retention points reads the view.
DO $mig$
DECLARE f text; d text;
BEGIN
  FOREACH f IN ARRAY ARRAY['compute_weekly_retention_points', 'rp_entry_rows', 'rp_rollup_for',
                           'rp_spot_check_pool', 'rp_spot_check_sample', 'rp_week_scoreboard_for'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f;
    IF d IS NULL THEN RAISE EXCEPTION '% not found', f; END IF;
    IF position('DELETE FROM public.retention_activity_log' IN d) > 0
       OR position('UPDATE public.retention_activity_log' IN d) > 0
       OR position('INTO public.retention_activity_log' IN d) > 0 THEN
      RAISE EXCEPTION '% also writes the table; not patching blind', f;
    END IF;
    IF position('FROM public.retention_activity_log' IN d) = 0 THEN
      RAISE EXCEPTION '% does not read the table the expected way', f;
    END IF;
    EXECUTE replace(replace(d, 'FROM public.retention_activity_log ', 'FROM public.retention_activity_now '),
                    'JOIN public.retention_activity_log ', 'JOIN public.retention_activity_now ');
  END LOOP;

  -- The multiline chargeback prorates the credit as it is priced now.
  SELECT pg_get_functiondef('public.cancelation_log_chargeback()'::regprocedure) INTO d;
  IF position('SELECT * INTO cr FROM public.retention_activity_log WHERE' IN d) = 0 THEN
    RAISE EXCEPTION 'cancelation_log_chargeback not the expected shape';
  END IF;
  EXECUTE replace(d, 'SELECT * INTO cr FROM public.retention_activity_log WHERE', 'SELECT * INTO cr FROM public.retention_activity_now WHERE');
END $mig$;
