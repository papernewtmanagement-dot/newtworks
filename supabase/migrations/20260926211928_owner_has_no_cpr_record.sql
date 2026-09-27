-- Peter 2026-09-26 ("I shouldn't even have a CPR record", 1A): the owner never gets a weekly_cpr_team_detail row.
-- One guard on the table covers every writer (wrap-up save/finish, code flags, quote sync, check-in sync, prefill).
CREATE OR REPLACE FUNCTION public.trg_cpr_detail_no_owner()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF public.team_is_owner(NEW.team_member_id) THEN
    RETURN NULL;  -- skip silently: the owner has no CPR record
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS cpr_detail_no_owner ON public.weekly_cpr_team_detail;
CREATE TRIGGER cpr_detail_no_owner
  BEFORE INSERT ON public.weekly_cpr_team_detail
  FOR EACH ROW EXECUTE FUNCTION public.trg_cpr_detail_no_owner();

-- His Wrap-up screen: save and finish answer quietly instead of writing (or erroring on a missing row).
DO $mig$
DECLARE v_src text;
BEGIN
  v_src := pg_get_functiondef('public.my_wrapup_save(jsonb,date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    E'  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;\n',
    E'  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;\n  IF public.team_is_owner(v_me) THEN\n    RETURN jsonb_build_object(''ok'', true, ''owner'', true, ''note'', ''the owner has no CPR record; nothing saved'');\n  END IF;\n', 1);
  EXECUTE v_src;

  v_src := pg_get_functiondef('public.my_wrapup_finish(boolean,date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    E'  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;\n',
    E'  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;\n  IF public.team_is_owner(v_me) THEN\n    RETURN jsonb_build_object(''ok'', true, ''owner'', true, ''wrapup_finished'', false, ''note'', ''the owner has no CPR record'');\n  END IF;\n', 1);
  EXECUTE v_src;
END $mig$;
