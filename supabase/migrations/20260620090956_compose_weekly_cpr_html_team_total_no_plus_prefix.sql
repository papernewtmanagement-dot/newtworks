-- Drop the "+" prefix on Team Total Net Quotes in the email so it matches the webpage.
-- Negative numbers still render with their "-" sign via to_char of a negative value.

DO $migration$
DECLARE
  v_src text;
  v_new text;
  v_old_pattern text;
  v_new_pattern text;
BEGIN
  v_src := pg_get_functiondef('public.compose_weekly_cpr_html'::regproc);

  v_old_pattern :=
    '|| CASE WHEN v_team_net_quotes > 0 THEN ''+'' WHEN v_team_net_quotes < 0 THEN ''-'' ELSE '''' END' || E'\n' ||
    '       || to_char(ABS(v_team_net_quotes), ''FM999,999'') || ''</td>''';
  v_new_pattern :=
    '|| to_char(v_team_net_quotes, ''FM999,999'') || ''</td>''';

  IF position(v_old_pattern in v_src) = 0 THEN
    RAISE EXCEPTION 'Sign-prefix pattern not found in compose_weekly_cpr_html';
  END IF;

  v_new := replace(v_src, v_old_pattern, v_new_pattern);
  EXECUTE v_new;
  RAISE NOTICE 'compose_weekly_cpr_html patched: Team Total no longer shows "+" prefix on positives';
END;
$migration$;
