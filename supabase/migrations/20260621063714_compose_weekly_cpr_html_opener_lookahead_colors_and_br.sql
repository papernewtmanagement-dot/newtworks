
DO $migration$
DECLARE
  v_def text;
  v_new text;
  v_old_opener text;
  v_new_opener text;
  v_old_look text;
  v_new_look text;
BEGIN
  SELECT pg_get_functiondef('public.compose_weekly_cpr_html'::regproc) INTO v_def;

  v_old_opener := $$'<div style="font-size:15px;line-height:1.55;color:#1e293b;white-space:pre-wrap;margin-bottom:18px">'
    ||     COALESCE(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), '<em style="color:#94a3b8">(no opener written)</em>')$$;

  v_new_opener := $$'<div style="font-size:15px;line-height:1.55;color:#b91c1c;margin-bottom:18px">'
    ||     COALESCE(replace(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), '<em style="color:#94a3b8">(no opener written)</em>')$$;

  v_old_look := $$'<div style="font-size:14px;line-height:1.55;color:#1e293b;white-space:pre-wrap;margin-bottom:18px">'
    ||     COALESCE(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), '<em style="color:#94a3b8">(not written)</em>')$$;

  v_new_look := $$'<div style="font-size:14px;line-height:1.55;color:#1e40af;margin-bottom:18px">'
    ||     COALESCE(replace(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), '<em style="color:#94a3b8">(not written)</em>')$$;

  v_new := replace(v_def, v_old_opener, v_new_opener);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'Opener pattern did not match — no replacement made';
  END IF;

  v_new := replace(v_new, v_old_look, v_new_look);
  IF v_new = replace(v_def, v_old_opener, v_new_opener) THEN
    RAISE EXCEPTION 'Looking-ahead pattern did not match — no replacement made';
  END IF;

  EXECUTE v_new;
END $migration$;

