-- The Composio GOOGLECALENDAR_CREATE_EVENT version Newtworks' account runs takes
-- send_updates as true/false, not 'all'/'none'. Both creates on 2026-09-25 came
-- back "Input should be a valid boolean ... send_updates" and nothing was built.
-- PATCH_EVENT on the same account takes the words, so only the create changes.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.huddle_calendar_sync_meeting(uuid,text)'::regprocedure);
  v_old text := '''send_updates'',           v_send_updates,';
  v_new text := '-- The create tool on this account takes true/false here (true = email'
             || E'\n' || '      -- every guest). PATCH_EVENT takes the words. Refused 2026-09-25.'
             || E'\n' || '      ''send_updates'',           true,';
  v_count int;
BEGIN
  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'create send_updates anchor found % times, expected 1', v_count;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
