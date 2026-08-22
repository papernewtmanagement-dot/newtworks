-- 2026-07-14 migration (extend_agency_snapshot_prefill_ytd_with_premium) added auto_premium,
-- fire_premium, life_premium to the BEFORE INSERT prefill so CPR Agency Performance
-- rows had non-NULL values Mon-Thu before the Friday CRM Analytics email arrived.
--
-- That created a bug: weekly_cpr_upsert_in_progress() inserts a stub row on the first
-- weekday of the new week, the prefill trigger copied prior week's premiums onto it,
-- and the Friday CRM email parser (fill_nulls_only merge strategy) then saw the premium
-- columns already populated and skipped the update. Result: current-week row stayed
-- pinned to prior-week's premium values indefinitely.
--
-- Premiums are point-in-time weekly widget totals, NOT YTD counters. They belong to
-- the CRM email as the sole source. Trigger keeps its YTD-counter carry-forward
-- (auto_new_ytd, auto_lost_ytd, fire_new_ytd, fire_lost_ytd, life_new_ytd,
-- life_lost_ytd, life_paid_for_count_ytd, life_paid_for_premium_ytd) because those
-- columns are supplied by manual entry and legitimately need to survive across weeks
-- that lack fresh manual input.
--
-- v_agency_snapshot_with_changes uses NULL-safe CASE WHEN patterns, so Mon-Thu NULL
-- premiums on the current row surface as NULL WoW/MoM/QoQ/YoY (correct — no data
-- yet), not stale. Prior-week rows are untouched and comparisons still work.

CREATE OR REPLACE FUNCTION public.agency_snapshot_prefill_ytd_from_prior()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_prior record;
BEGIN
  IF COALESCE(NEW.cadence, '') <> 'weekly' THEN RETURN NEW; END IF;

  SELECT auto_new_ytd, auto_lost_ytd,
         fire_new_ytd, fire_lost_ytd,
         life_new_ytd, life_lost_ytd,
         life_paid_for_count_ytd, life_paid_for_premium_ytd
    INTO v_prior
    FROM public.agency_snapshot
   WHERE agency_id     = NEW.agency_id
     AND snapshot_date < NEW.snapshot_date
     AND cadence       = 'weekly'
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
$function$;
