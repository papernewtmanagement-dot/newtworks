-- Two wording fixes to statement_reminder_send, applied by exact replacement so
-- nothing else in the function moves:
--   1. Do not print the last four digits twice when the account name already
--      carries them ("US Bank Business Cash Rewards 3447 ••3447").
--   2. A dry run says "would be sent", not "sent".
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.statement_reminder_send(uuid,uuid,int,boolean)'::regprocedure);
  v_old1 text := 'COALESCE('' ••'' || r.last4, '''')';
  v_new1 text := 'CASE WHEN r.last4 IS NULL OR position(r.last4 IN r.account_name) > 0 THEN '''' ELSE '' ••'' || r.last4 END';
  v_old2 text := 'CASE WHEN v_new > 0 THEN '' sent to '' || v_route ELSE '''' END';
  v_new2 text := 'CASE WHEN v_new > 0 THEN CASE WHEN p_dry_run THEN '' would be sent to '' ELSE '' sent to '' END || v_route ELSE '''' END';
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 2 THEN
    RAISE EXCEPTION 'expected the last-4 expression exactly twice';
  END IF;
  IF position(v_old2 IN v_def) = 0 THEN
    RAISE EXCEPTION 'expected the summary wording once';
  END IF;
  EXECUTE replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
END $$;
