-- A change or note on a cancelation is filed under the teammate whose policy it
-- canceled (their points moved), not whoever logged it. Falls back to the
-- logger when the cancelation matched no policy.
DO $mig$
DECLARE d text; o text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;
  o := $o$             WHEN 'quote_log_products' THEN (SELECT ql.team_member_id FROM public.quote_log ql
                                              WHERE ql.id = (COALESCE(s.new_row, s.old_row) ->> 'quote_log_id')::uuid)$o$;
  IF (length(d) - length(replace(d, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'owner block not found once'; END IF;
  d := replace(d, o, o || $n$
             WHEN 'cancelation_log' THEN COALESCE(
               (SELECT sl.team_member_id FROM public.sales_log_products sp
                  JOIN public.sales_log sl ON sl.id = sp.sales_log_id
                 WHERE sp.id = NULLIF(COALESCE(s.new_row, s.old_row) ->> 'matched_sale_product_id', '')::uuid),
               NULLIF(COALESCE(s.new_row, s.old_row) ->> 'team_member_id', '')::uuid)$n$);
  EXECUTE d;
END $mig$;
