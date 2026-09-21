DO $mig$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure);
  a := 'CROSS JOIN LATERAL (VALUES
        (''logged''::text, x.logged_for, true),
        (x.effect, x.sale_owner, x.effect IN (''charged_back'', ''removed''))
      ) AS v(what, owner_id, keep)';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'change log shape changed'; END IF;
  d := replace(d, a,
    '-- One line per cancelation. If it moved points, it shows the effect under the
      -- policy''s owner; otherwise it shows as logged under who it was logged for.
      CROSS JOIN LATERAL (VALUES
        (CASE WHEN x.effect IN (''charged_back'', ''removed'') THEN x.effect ELSE ''logged'' END,
         CASE WHEN x.effect IN (''charged_back'', ''removed'') THEN COALESCE(x.sale_owner, x.logged_for) ELSE x.logged_for END,
         true)
      ) AS v(what, owner_id, keep)');
  a := ''' logged a cancelation on this policy''';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'change log wording changed'; END IF;
  d := replace(d, a, ''' logged a cancelation''');
  EXECUTE d;
END
$mig$;
