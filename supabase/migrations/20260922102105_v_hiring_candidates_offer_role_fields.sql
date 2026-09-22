-- The candidate page reads v_hiring_candidates, so the offer form only
-- remembers role, role category and role level if the view carries them.
DO $mig$
DECLARE v text;
BEGIN
  v := pg_get_viewdef('public.v_hiring_candidates'::regclass);
  IF position('offer_role_level' in v) = 0 THEN
    v := replace(v, E'    hc.offer_sent_at\n   FROM ',
                    E'    hc.offer_sent_at,\n    hc.offer_role,\n    hc.offer_role_category,\n    hc.offer_role_level\n   FROM ');
    IF position('offer_role_level' in v) = 0 THEN
      RAISE EXCEPTION 'v_hiring_candidates anchor not found';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW public.v_hiring_candidates AS ' || v;
  END IF;
END
$mig$;
