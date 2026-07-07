-- ============================================================================
-- Migration: cpr_ytd_snapshot_backfill_trigger_ensure_row
-- Applied: 2026-07-07 00:08:57 UTC (Supabase)
-- ============================================================================
-- Refactors the 8 Agency Performance YTD fields so agency_snapshot is the single
-- source of truth. Sets up backfill + prefill trigger + row-existence guarantee.

-- Step 1: Backfill agency_snapshot from CPR _manual overrides (preserves Peter's work)
UPDATE public.agency_snapshot s
SET auto_new_ytd              = COALESCE(s.auto_new_ytd,              r.auto_new_ytd_manual),
    auto_lost_ytd             = COALESCE(s.auto_lost_ytd,             r.auto_lost_ytd_manual),
    fire_new_ytd              = COALESCE(s.fire_new_ytd,              r.fire_new_ytd_manual),
    fire_lost_ytd             = COALESCE(s.fire_lost_ytd,             r.fire_lost_ytd_manual),
    life_new_ytd              = COALESCE(s.life_new_ytd,              r.life_new_ytd_manual),
    life_lost_ytd             = COALESCE(s.life_lost_ytd,             r.life_lost_ytd_manual),
    life_paid_for_count_ytd   = COALESCE(s.life_paid_for_count_ytd,   r.life_paid_for_count_ytd_manual),
    life_paid_for_premium_ytd = COALESCE(s.life_paid_for_premium_ytd, r.life_paid_for_premium_ytd_manual::numeric),
    updated_at = NOW()
FROM public.weekly_cpr_reports r
WHERE s.agency_id      = r.agency_id
  AND s.snapshot_date  = r.week_ending_date
  AND s.cadence        = 'weekly'
  AND (r.auto_new_ytd_manual              IS NOT NULL
    OR r.auto_lost_ytd_manual             IS NOT NULL
    OR r.fire_new_ytd_manual              IS NOT NULL
    OR r.fire_lost_ytd_manual             IS NOT NULL
    OR r.life_new_ytd_manual              IS NOT NULL
    OR r.life_lost_ytd_manual             IS NOT NULL
    OR r.life_paid_for_count_ytd_manual   IS NOT NULL
    OR r.life_paid_for_premium_ytd_manual IS NOT NULL);

-- Step 2: BEFORE INSERT trigger — prefill 8 YTD fields from prior weekly row
CREATE OR REPLACE FUNCTION public.agency_snapshot_prefill_ytd_from_prior()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_prior record;
BEGIN
  IF COALESCE(NEW.cadence, '') <> 'weekly' THEN RETURN NEW; END IF;
  SELECT auto_new_ytd, auto_lost_ytd, fire_new_ytd, fire_lost_ytd,
         life_new_ytd, life_lost_ytd,
         life_paid_for_count_ytd, life_paid_for_premium_ytd
    INTO v_prior FROM public.agency_snapshot
   WHERE agency_id = NEW.agency_id
     AND snapshot_date < NEW.snapshot_date
     AND cadence = 'weekly'
   ORDER BY snapshot_date DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NEW; END IF;
  NEW.auto_new_ytd              := COALESCE(NEW.auto_new_ytd,              v_prior.auto_new_ytd);
  NEW.auto_lost_ytd             := COALESCE(NEW.auto_lost_ytd,             v_prior.auto_lost_ytd);
  NEW.fire_new_ytd              := COALESCE(NEW.fire_new_ytd,              v_prior.fire_new_ytd);
  NEW.fire_lost_ytd             := COALESCE(NEW.fire_lost_ytd,             v_prior.fire_lost_ytd);
  NEW.life_new_ytd              := COALESCE(NEW.life_new_ytd,              v_prior.life_new_ytd);
  NEW.life_lost_ytd             := COALESCE(NEW.life_lost_ytd,             v_prior.life_lost_ytd);
  NEW.life_paid_for_count_ytd   := COALESCE(NEW.life_paid_for_count_ytd,   v_prior.life_paid_for_count_ytd);
  NEW.life_paid_for_premium_ytd := COALESCE(NEW.life_paid_for_premium_ytd, v_prior.life_paid_for_premium_ytd);
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_agency_snapshot_prefill_ytd ON public.agency_snapshot;
CREATE TRIGGER trg_agency_snapshot_prefill_ytd
  BEFORE INSERT ON public.agency_snapshot
  FOR EACH ROW EXECUTE FUNCTION public.agency_snapshot_prefill_ytd_from_prior();

-- Step 3: Ensure current CPR week's snapshot row exists (trigger prefills from 7/4)
INSERT INTO public.agency_snapshot (agency_id, snapshot_date, cadence, source, updated_at)
VALUES ('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-11'::date, 'weekly', 'cpr_weekly_manual', NOW())
ON CONFLICT (agency_id, snapshot_date, cadence) DO NOTHING;

-- Step 4: weekly_cpr_upsert_in_progress adds trailing INSERT to agency_snapshot
-- (ON CONFLICT DO NOTHING) so the row exists for the current Saturday. Prefill
-- trigger fills the 8 YTD fields from the prior weekly row.
-- Full body: SELECT pg_get_functiondef('public.weekly_cpr_upsert_in_progress(uuid,date)'::regprocedure);
