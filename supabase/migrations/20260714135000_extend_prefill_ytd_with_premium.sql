-- Extend agency_snapshot_prefill_ytd_from_prior to also carry auto_premium /
-- fire_premium / life_premium forward from the prior weekly row.
-- These columns feed the new "Auto $ / Fire $ / Life $" premium rows and the
-- SMVC $ derived translation on the CPR Agency Performance table.
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
         life_paid_for_count_ytd, life_paid_for_premium_ytd,
         auto_premium, fire_premium, life_premium
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
  NEW.auto_premium              := COALESCE(NEW.auto_premium,              v_prior.auto_premium);
  NEW.fire_premium              := COALESCE(NEW.fire_premium,              v_prior.fire_premium);
  NEW.life_premium              := COALESCE(NEW.life_premium,              v_prior.life_premium);
  RETURN NEW;
END;
$function$;
