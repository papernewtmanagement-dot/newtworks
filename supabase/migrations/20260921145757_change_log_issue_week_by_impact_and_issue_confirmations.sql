-- The CPR week a change actually moved. An issue change moves the week the policy
-- issued, or, if that week is already locked by payroll, the next unlocked one.
-- Anything else lands on the most recent unlocked CPR.
CREATE OR REPLACE FUNCTION public.change_impact_week(p_agency uuid, p_table text, p_old jsonb, p_new jsonb, p_at timestamptz)
 RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $f$
  SELECT CASE
    WHEN p_table = 'sales_log_products'
     AND COALESCE(NULLIF(p_old ->> 'issued_date', ''), NULLIF(p_new ->> 'issued_date', '')) IS NOT NULL
    THEN GREATEST(public.rp_week_end(LEAST(NULLIF(p_old ->> 'issued_date', '')::date,
                                           NULLIF(p_new ->> 'issued_date', '')::date)),
                  public.cpr_week_for(p_agency, p_at))
    ELSE public.cpr_week_for(p_agency, p_at) END
$f$;

DO $mig$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure);

  a := 'AND public.cpr_week_for(p_agency_id, c.changed_at) BETWEEN p_start AND p_end';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'A: shape changed'; END IF;
  d := replace(d, a, 'AND public.change_impact_week(p_agency_id, c.table_name, c.old_row, c.new_row, c.changed_at) BETWEEN p_start AND p_end');

  a := '                ELSE ''corrected'' END AS what,';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'B: shape changed'; END IF;
  d := replace(d, a,
'                -- Issued premium filled in on a policy already marked issued, date
                -- unchanged: that is the policy being confirmed issued, not a correction.
                WHEN (r.old_row ->> ''issued_premium'') IS NULL
                 AND (r.old_row -> ''issued_date'') = (r.new_row -> ''issued_date'') THEN ''issued''
                ELSE ''corrected'' END AS what,');

  a := '''was_issued_premium'', (r.old_row ->> ''issued_premium'')::numeric) AS policy,';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'C: shape changed'; END IF;
  d := replace(d, a,
'''was_issued_premium'', (r.old_row ->> ''issued_premium'')::numeric,
             ''before_quarter'', GREATEST(NULLIF(r.new_row ->> ''issued_date'', '''')::date, NULLIF(r.old_row ->> ''issued_date'', '''')::date)
                                < (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, p_end) cci)) AS policy,');

  a := 'END) || '')'') AS line,
           i.phone
      FROM issues_all i';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'D: shape changed'; END IF;
  d := replace(d, a,
'END) || '')'' ||
            CASE WHEN (i.policy ->> ''before_quarter'')::boolean
                 THEN '' · issued before this quarter, no effect on sales points'' ELSE '''' END) AS line,
           i.phone
      FROM issues_all i');

  EXECUTE d;
END
$mig$;
