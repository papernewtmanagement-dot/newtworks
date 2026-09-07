-- Digest Weekly Pay table: a teammate terminated during the week (end_date <= that Saturday)
-- shows no benefits value (health + life stipend) in their week total (Peter 2026-09-07).
-- Companion to the CPRDetail Payroll section change in the same session.

DO $do$
DECLARE
  v_src text;
BEGIN
  v_src := pg_get_functiondef('public.compose_weekly_cpr_html(uuid, date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    $q$             + COALESCE(t.annual_benefits_value,0)/52.0),$q$,
    $q$             /* left during the week: no benefits value (Peter 2026-09-07) */
             + CASE WHEN t.end_date IS NOT NULL AND t.end_date <= p_week_ending_date THEN 0
                    ELSE COALESCE(t.annual_benefits_value,0)/52.0 END),$q$, 1);
  EXECUTE v_src;
END
$do$;
