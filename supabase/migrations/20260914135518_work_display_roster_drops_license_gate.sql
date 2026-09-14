-- work_display roster: license no longer required (Peter 2026-09-14).
-- The status block now carries marketing points and retention points alongside
-- quotes and sales points, so an unlicensed teammate has real numbers to show.
-- Cassie gets a row. Matches the work_checkin change in 20260914121807; both
-- reminder and display rosters are now the same people.
DO $migration$
DECLARE
  v_def text;
  v_old text := '      (p_purpose = ''work_display''
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = ''agency'' AND r.role != ''Owner''))
        AND (COALESCE(r.license_pc, false)
             OR COALESCE(r.license_lh, false)
             OR COALESCE(r.license_ips, false)))';
  v_new text := '      -- No license requirement: the status block carries marketing and retention
      -- points as well as quotes and sales, so every teammate on the check-ins
      -- has a row (Peter 2026-09-14).
      (p_purpose = ''work_display''
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = ''agency'' AND r.role != ''Owner'')))';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_expected_teammates';

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'work_display branch not found in get_expected_teammates - reconcile before rerunning';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$migration$;