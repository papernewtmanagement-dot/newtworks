-- Peter directive 2026-07-29: hard trigger preventing journal_lines from booking
-- against income/expense root parent COAs (parent_account_id IS NULL). Root
-- parents are organizational buckets only — all bookings must land on leaves.
-- Applies to INSERT + UPDATE. Balance sheet parents (asset/liability/equity
-- headers 1000/1500/2000/2500/3000) are NOT enforced by this trigger since
-- they can legitimately hold direct bookings.
CREATE OR REPLACE FUNCTION public.tg_reject_direct_to_parent_booking_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_type text;
  v_parent uuid;
  v_code text;
  v_name text;
BEGIN
  SELECT account_type::text, parent_account_id, account_code, account_name
    INTO v_type, v_parent, v_code, v_name
  FROM public.chart_of_accounts
  WHERE id = NEW.account_id;

  IF v_type IN ('income','expense') AND v_parent IS NULL THEN
    RAISE EXCEPTION
      'Direct-to-parent booking refused: account % (%) is a root % parent and cannot receive journal_lines directly. Route to a specific leaf child instead.',
      v_code, v_name, v_type
    USING HINT = 'Update the classification rule or writer to target a leaf account_code that chains up to this root.',
          ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_reject_direct_to_parent_booking ON public.journal_lines;
CREATE TRIGGER tg_reject_direct_to_parent_booking
BEFORE INSERT OR UPDATE ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.tg_reject_direct_to_parent_booking_fn();

-- Note: this trigger only affects NEW/UPDATED rows. The 165 existing direct-
-- to-parent lines are backfilled by the next migration. Trigger will refuse
-- any attempt to re-book them to a parent going forward.

