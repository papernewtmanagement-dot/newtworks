DO $mig$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure);
  a := 'WHEN ''removed'' THEN '', taken off its '' || public.change_value_text(p_agency_id, ''issued_date'', i.policy -> ''issued_date'')
                                        || '' issue ('' || public.change_value_text(p_agency_id, ''premium'', i.policy -> ''charge'') || '' unearned)''';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'shape changed'; END IF;
  d := replace(d, a,
'WHEN ''removed'' THEN '', canceled the same quarter it issued ('' || public.change_value_text(p_agency_id, ''issued_date'', i.policy -> ''issued_date'')
                                        || ''), so it no longer counts except the ''
                                        || public.change_value_text(p_agency_id, ''premium'',
                                             to_jsonb(round((i.policy ->> ''issued_premium'')::numeric - (i.policy ->> ''charge'')::numeric, 2)))
                                        || '' earned before it canceled''');
  EXECUTE d;
END
$mig$;
