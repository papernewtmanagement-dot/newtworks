-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 18:55:44 UTC (ledger name: fix_reject_direct_to_parent_only_true_parents) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729185544.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Fix: only reject bookings to accounts that ACTUALLY have children.
-- Previously the trigger rejected any root income/expense account, including flat leaf accounts (like all personal expense codes and COA-PERSONAL-9999) that have no children.
-- That created a deadlock with redirect_prior_susp_line, which redirects lingering SUSP lines to the entity's Unclassified account — a leaf-root that this trigger then rejected.
CREATE OR REPLACE FUNCTION public.tg_reject_direct_to_parent_booking_fn()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_type text;
  v_parent uuid;
  v_code text;
  v_name text;
  v_has_children boolean;
BEGIN
  SELECT account_type::text, parent_account_id, account_code, account_name
    INTO v_type, v_parent, v_code, v_name
  FROM public.chart_of_accounts
  WHERE id = NEW.account_id;

  -- Only concerned with income/expense root accounts
  IF v_type NOT IN ('income','expense') OR v_parent IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Root account: only reject if it actually has child accounts.
  -- A flat "root" with no children is a valid leaf and should accept lines.
  SELECT EXISTS (
    SELECT 1 FROM public.chart_of_accounts
    WHERE parent_account_id = NEW.account_id
  ) INTO v_has_children;

  IF v_has_children THEN
    RAISE EXCEPTION
      'Direct-to-parent booking refused: account % (%) is a % parent with children and cannot receive journal_lines directly. Route to a specific leaf child instead.',
      v_code, v_name, v_type
    USING HINT = 'Update the classification rule or writer to target a leaf account_code that chains up to this root.',
          ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$function$;
