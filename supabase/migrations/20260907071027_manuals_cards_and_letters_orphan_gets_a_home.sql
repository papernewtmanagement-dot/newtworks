-- The Cards & Letters fragment (thank-you, congratulations, sympathy notes) is
-- an orphan: no page anywhere, active or inactive, carries a marker for it. It
-- has been unreachable since it was created on 2026-09-02, so nobody can find
-- those templates in the manual today. It is proactive customer contact, so it
-- lands on Retention > Outbound Touches.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old text; v_new text; v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND manual_type='excerpt' AND is_active AND title='Cards & Letters';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Expected one active Cards & Letters fragment, found %', v_n; END IF;

  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND is_active AND content ILIKE '%Cards & Letters]%';
  IF v_n <> 0 THEN RAISE EXCEPTION 'Cards & Letters already has a host (% rows)', v_n; END IF;

  SELECT content INTO v_old FROM manuals
   WHERE agency_id=v_agency AND confluence_page_id='newtworks-native-outbound-touches-2026-09-04';
  IF v_old IS NULL THEN RAISE EXCEPTION 'Outbound Touches not found'; END IF;

  v_new := v_old || E'\n\n\n\n<details>\n<summary>Send a card or letter</summary>\n\n*[Embedded excerpt from: Cards & Letters]*\n\n</details>';

  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='newtworks-native-outbound-touches-2026-09-04';

  UPDATE manuals SET parent_page_id = 'newtworks-native-outbound-touches-2026-09-04', updated_at = now()
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='Cards & Letters';
END $$;
