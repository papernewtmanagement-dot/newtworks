-- Retention > Appointments: the Welcome step becomes real content.
--
-- The restructure left this step as a parenthetical note ("this script lives
-- in the Admin manual") because an [Included from:] marker could not reach
-- across manual boundaries. Commit 69dbaa17 fixes that in the renderer, so the
-- note is replaced with an actual include of the Admin manual's Welcome page
-- (confluence_page_id 949288961). One copy of the script, two places it shows.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old text;
  v_new text;
  v_n int;
BEGIN
  -- The include target must exist, be active, and be unique by title.
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND is_active AND lower(trim(title)) = 'welcome';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Expected exactly one active row titled Welcome, found %', v_n; END IF;

  SELECT content INTO v_old FROM manuals
   WHERE agency_id = v_agency AND confluence_page_id = '1747025922';
  IF position('This script lives in the Admin manual' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Welcome placeholder not found on Appointments';
  END IF;

  v_new := replace(v_old,
    E'*(This script lives in the Admin manual under "Welcome" — not shown here since it''s a different manual.)*',
    E'*[Included from: Welcome]*');
  IF v_new = v_old THEN RAISE EXCEPTION 'Welcome placeholder replace failed'; END IF;

  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '1747025922';
END $$;
