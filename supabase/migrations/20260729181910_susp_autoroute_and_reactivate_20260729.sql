-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 18:19:10 UTC (ledger name: susp_autoroute_and_reactivate_20260729) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729181910.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Reactivate COA-SUSP as an active fallback account (existing writers keep working).
-- Add a deferred trigger: after both lines of a JE are inserted, if one is on SUSP,
-- redirect the SUSP line to the entity-specific *Unclassified derived from the OTHER line's entity.

UPDATE public.chart_of_accounts
SET is_active = true
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code = 'COA-SUSP';

-- Redirect function: called from trigger AFTER INSERT on journal_lines.
-- For each JE that has a SUSP line, look at the OTHER line's entity and redirect.
CREATE OR REPLACE FUNCTION public.redirect_susp_to_unclassified()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_susp_id uuid;
  v_susp_line RECORD;
  v_other_entity uuid;
  v_susp_type text;
  v_target_type text;
  v_target_account uuid;
BEGIN
  SELECT id INTO v_susp_id
  FROM public.chart_of_accounts
  WHERE agency_id = NEW.agency_id AND account_code = 'COA-SUSP' LIMIT 1;

  IF v_susp_id IS NULL THEN RETURN NEW; END IF;

  -- Only act if THIS newly-inserted line is on SUSP
  IF NEW.account_id != v_susp_id THEN RETURN NEW; END IF;

  -- Look up the OTHER line's entity (must exist by the time this row is inserted second)
  SELECT coa.business_entity_id INTO v_other_entity
  FROM public.journal_lines jl
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.journal_entry_id = NEW.journal_entry_id
    AND jl.id != NEW.id
    AND jl.account_id != v_susp_id
  LIMIT 1;

  -- If other line not present yet or has no entity, leave on SUSP (deferred trigger will catch)
  IF v_other_entity IS NULL THEN RETURN NEW; END IF;

  -- SUSP line direction determines target type. Debit on SUSP for a charge → expense.
  -- Credit on SUSP for a refund/income → depends on other side type.
  v_target_type := 'expense';

  v_target_account := public.get_unclassified_account_id(NEW.agency_id, v_other_entity, v_target_type);

  IF v_target_account IS NOT NULL THEN
    NEW.account_id := v_target_account;
  END IF;

  RETURN NEW;
END;
$function$;

-- Second-pass trigger: on INSERT of a line where the OTHER line is on SUSP,
-- retroactively redirect the SUSP line (catches the case where SUSP was inserted first).
CREATE OR REPLACE FUNCTION public.redirect_prior_susp_line()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_susp_id uuid;
  v_prior_susp_line_id uuid;
  v_this_entity uuid;
  v_target_account uuid;
BEGIN
  SELECT id INTO v_susp_id FROM public.chart_of_accounts
  WHERE agency_id = NEW.agency_id AND account_code = 'COA-SUSP' LIMIT 1;
  IF v_susp_id IS NULL OR NEW.account_id = v_susp_id THEN RETURN NEW; END IF;

  -- Is there a prior SUSP line in this JE?
  SELECT jl.id INTO v_prior_susp_line_id
  FROM public.journal_lines jl
  WHERE jl.journal_entry_id = NEW.journal_entry_id
    AND jl.account_id = v_susp_id
    AND jl.id != NEW.id
  LIMIT 1;

  IF v_prior_susp_line_id IS NULL THEN RETURN NEW; END IF;

  SELECT coa.business_entity_id INTO v_this_entity
  FROM public.chart_of_accounts coa WHERE coa.id = NEW.account_id;

  IF v_this_entity IS NULL THEN RETURN NEW; END IF;

  v_target_account := public.get_unclassified_account_id(NEW.agency_id, v_this_entity, 'expense');
  IF v_target_account IS NULL THEN RETURN NEW; END IF;

  UPDATE public.journal_lines SET account_id = v_target_account WHERE id = v_prior_susp_line_id;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_redirect_susp_incoming ON public.journal_lines;
CREATE TRIGGER trg_redirect_susp_incoming
BEFORE INSERT ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.redirect_susp_to_unclassified();

DROP TRIGGER IF EXISTS trg_redirect_prior_susp ON public.journal_lines;
CREATE TRIGGER trg_redirect_prior_susp
AFTER INSERT ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.redirect_prior_susp_line();
