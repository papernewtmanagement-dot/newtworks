CREATE OR REPLACE FUNCTION public.tg_handbook_pages_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  cur  public.form_documents;
  snap jsonb;
BEGIN
  SELECT * INTO cur FROM public.form_documents
  WHERE doc_type = 'handbook' AND is_current IS TRUE
  ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;

  snap := public.handbook_snapshot(cur.agency_id);
  IF cur.snapshot IS NOT DISTINCT FROM snap THEN RETURN NULL; END IF;

  -- Peter 2026-10-06: cosmetic edits (wording, tidying) never publish a new version.
  -- The editing session sets newtworks.handbook_cosmetic = 'on' for the transaction;
  -- the current version absorbs the new text and no one is asked to re-confirm.
  IF cur.snapshot IS NULL
     OR COALESCE(current_setting('newtworks.handbook_cosmetic', true), '') = 'on'
     OR NOT EXISTS (
       SELECT 1 FROM public.team_form_submissions s
       WHERE s.agency_id = cur.agency_id AND s.form_type = 'handbook_ack'
         AND s.cycle_key = 'v' || cur.version AND s.status IN ('submitted', 'locked')) THEN
    UPDATE public.form_documents SET snapshot = snap WHERE id = cur.id;
    RETURN NULL;
  END IF;

  UPDATE public.form_documents SET is_current = false WHERE id = cur.id;
  INSERT INTO public.form_documents (agency_id, doc_type, version, title, effective_date, is_current, snapshot)
  VALUES (cur.agency_id, 'handbook', cur.version + 1, cur.title, CURRENT_DATE, true, snap);
  RETURN NULL;
END;
$function$;
