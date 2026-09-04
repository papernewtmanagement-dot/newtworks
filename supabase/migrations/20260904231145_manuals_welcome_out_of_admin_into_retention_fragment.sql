-- Welcome script moves out of the Admin manual and becomes a Retention fragment.
--
-- Peter, 2026-09-04: cross-manual embedding is not wanted, and the welcome
-- appointment script does not belong in the Admin manual in the first place.
-- It is a Retention > Appointments step, so it moves into the excerpt namespace
-- (already global, already how every other script on that checklist works) and
-- the marker on Appointments switches from [Included from:] to
-- [Embedded excerpt from:]. The cross-manual renderer support added earlier
-- today is reverted in the same push; this migration must land first so the
-- marker never points at an unreachable row.
--
-- Nothing else references Welcome — verified before writing this.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old text;
  v_new text;
  v_n int;
BEGIN
  -- Guard: exactly one active row titled Welcome, and it is the admin page.
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND is_active AND lower(trim(title)) = 'welcome';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Expected one active Welcome row, found %', v_n; END IF;

  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND confluence_page_id = '949288961' AND manual_type = 'admin';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Welcome is not where expected in the admin manual'; END IF;

  -- Guard: no OTHER page references it, so nothing breaks when it leaves admin.
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND is_active
     AND confluence_page_id <> '1747025922'
     AND (content ILIKE '%[Included from: Welcome]%' OR content ILIKE '%[Embedded excerpt from: Welcome]%');
  IF v_n <> 0 THEN RAISE EXCEPTION 'Welcome is referenced by % other page(s)', v_n; END IF;

  -- 1. Repoint the marker on Retention > Appointments.
  SELECT content INTO v_old FROM manuals
   WHERE agency_id = v_agency AND confluence_page_id = '1747025922';
  v_new := replace(v_old, '*[Included from: Welcome]*', '*[Embedded excerpt from: Welcome]*');
  IF v_new = v_old THEN RAISE EXCEPTION 'Welcome include marker not found on Appointments'; END IF;
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '1747025922';

  -- 2. Take Welcome out of the admin tree and into the shared fragment scope.
  --    parent_page_id is repointed at Retention > Appointments for lineage;
  --    excerpt rows are hidden from tree nav either way.
  UPDATE manuals
     SET manual_type = 'excerpt',
         parent_page_id = '1747025922',
         updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '949288961';
END $$;
