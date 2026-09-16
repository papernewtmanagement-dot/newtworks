-- One function answers "is this week locked because it has been paid, or is it
-- still pulling fresh numbers". Both the CPR Payroll section and the Team >
-- Payroll tab read it, so they can never show different lock states.
--
-- A week locks automatically when the payroll summary arrives (weekly_pool_lock,
-- lock_source = 'payroll_paid'). From that point the envelope, the pool percent
-- and the bonus actually paid are frozen.

CREATE OR REPLACE FUNCTION public.week_pay_lock(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'week_end_date',       p_week_end_date,
    'locked',              (l.week_end_date IS NOT NULL),
    'locked_at',           l.locked_at,
    'lock_source',         l.lock_source,
    'bonus_actually_paid', l.bonus_actually_paid,
    'notes',               l.notes,
    'payroll_received',    EXISTS (
      SELECT 1
      FROM public.payroll_runs pr
      JOIN public.payroll_detail pd ON pd.payroll_run_id = pr.id
      WHERE pr.pay_period_end = p_week_end_date
        AND pd.agency_id = p_agency_id
    )
  )
  FROM (SELECT 1) one
  LEFT JOIN public.weekly_pool_lock l
    ON l.agency_id = p_agency_id
   AND l.week_end_date = p_week_end_date;
$function$;

GRANT EXECUTE ON FUNCTION public.week_pay_lock(uuid, date) TO anon, authenticated, service_role;

-- team_payroll_week hands the same object through, instead of keeping its own
-- private payroll-arrival check.
DO $mig$
DECLARE
  v_def text;
  v_old text := $a$    'payroll_received', EXISTS (
      SELECT 1 FROM public.payroll_runs pr
      WHERE pr.pay_period_end = v_week_end
        AND EXISTS (SELECT 1 FROM public.payroll_detail pd
                    WHERE pd.payroll_run_id = pr.id AND pd.agency_id = p_agency_id)
    ),$a$;
  v_new text := $a$    'lock',             v_lock,
    'payroll_received', COALESCE((v_lock->>'payroll_received')::boolean, false),$a$;
  v_old_decl text := $b$  v_people     jsonb;
  v_goals      jsonb;$b$;
  v_new_decl text := $b$  v_people     jsonb;
  v_goals      jsonb;
  v_lock       jsonb;$b$;
  v_old_set text := $c$  SELECT r.id INTO v_report_id
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_end;$c$;
  v_new_set text := $c$  SELECT r.id INTO v_report_id
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_end;

  v_lock := public.week_pay_lock(p_agency_id, v_week_end);$c$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_payroll_week';

  IF v_def IS NULL                     THEN RAISE EXCEPTION 'team_payroll_week not found'; END IF;
  IF position(v_old_decl in v_def) = 0 THEN RAISE EXCEPTION 'declare block did not match'; END IF;
  IF position(v_old_set  in v_def) = 0 THEN RAISE EXCEPTION 'report lookup did not match'; END IF;
  IF position(v_old      in v_def) = 0 THEN RAISE EXCEPTION 'payroll_received block did not match'; END IF;

  v_def := replace(v_def, v_old_decl, v_new_decl);
  v_def := replace(v_def, v_old_set,  v_new_set);
  v_def := replace(v_def, v_old,      v_new);

  EXECUTE v_def;
END
$mig$;
