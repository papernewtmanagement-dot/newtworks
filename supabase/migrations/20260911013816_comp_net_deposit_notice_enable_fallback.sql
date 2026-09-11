-- document-processor v171 now writes documents.stated_net_payable from the
-- comp statement's ACTUAL DEPOSIT line. The summed-lines fallback is turned on
-- so a statement missing that line still sends a message rather than none.
DO $$
DECLARE v_def text;
  v_old text := $q$current_setting('newtworks.comp_notice_fallback', true), 'off')$q$;
  v_new text := $q$current_setting('newtworks.comp_notice_fallback', true), 'on')$q$;
BEGIN
  v_def := pg_get_functiondef('public.comp_net_deposit_notice(uuid,int,int,int,boolean)'::regprocedure);
  IF strpos(v_def, v_old) = 0 THEN
    RAISE EXCEPTION 'comp_net_deposit_notice changed since read; fallback default not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;