-- Bumps the per-agency scoring version counter whenever a table that feeds
-- the role-fit engine changes: role/facet weights, facet norms (this is the
-- one that captures pool-relative norm refreshes -- gma/sjt/gma_speed are
-- normed against the local applicant pool, not fixed external norms, so a
-- norm-table update here is exactly the "pool composition changed" event),
-- or role ideal ranges. Every cached score becomes stale the instant any of
-- these tables changes; nothing else needs to trigger a version bump.
CREATE OR REPLACE FUNCTION public.hiregauge_bump_scoring_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid;
BEGIN
  v_agency := COALESCE(NEW.agency_id, OLD.agency_id);
  INSERT INTO public.hiregauge_scoring_version (agency_id, version, updated_at)
  VALUES (v_agency, 2, now())
  ON CONFLICT (agency_id) DO UPDATE
    SET version = public.hiregauge_scoring_version.version + 1,
        updated_at = now();
  RETURN COALESCE(NEW, OLD);
END;
$function$;

DROP TRIGGER IF EXISTS trg_bump_scoring_version_weights ON public.hiregauge_role_facet_weights;
CREATE TRIGGER trg_bump_scoring_version_weights
AFTER INSERT OR UPDATE OR DELETE ON public.hiregauge_role_facet_weights
FOR EACH ROW EXECUTE FUNCTION public.hiregauge_bump_scoring_version();

DROP TRIGGER IF EXISTS trg_bump_scoring_version_norms ON public.hiregauge_facet_norms;
CREATE TRIGGER trg_bump_scoring_version_norms
AFTER INSERT OR UPDATE OR DELETE ON public.hiregauge_facet_norms
FOR EACH ROW EXECUTE FUNCTION public.hiregauge_bump_scoring_version();

DROP TRIGGER IF EXISTS trg_bump_scoring_version_ranges ON public.hiregauge_role_ideal_ranges;
CREATE TRIGGER trg_bump_scoring_version_ranges
AFTER INSERT OR UPDATE OR DELETE ON public.hiregauge_role_ideal_ranges
FOR EACH ROW EXECUTE FUNCTION public.hiregauge_bump_scoring_version();
