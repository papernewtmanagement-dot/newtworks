-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-23 00:44:25 UTC (ledger name: hiring_candidates_sync_candidate_name_from_parts) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260723004425.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Backfill any nulls or mismatched values from first_name + last_name
UPDATE public.hiring_candidates
SET candidate_name = NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), '')
WHERE candidate_name IS DISTINCT FROM NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), '');

-- Trigger fn: always derive candidate_name from first_name + last_name on insert/update
CREATE OR REPLACE FUNCTION public.sync_candidate_name_from_parts()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.candidate_name := NULLIF(TRIM(COALESCE(NEW.first_name, '') || ' ' || COALESCE(NEW.last_name, '')), '');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_candidate_name ON public.hiring_candidates;
CREATE TRIGGER trg_sync_candidate_name
BEFORE INSERT OR UPDATE ON public.hiring_candidates
FOR EACH ROW
EXECUTE FUNCTION public.sync_candidate_name_from_parts();
