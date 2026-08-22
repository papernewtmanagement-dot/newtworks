-- Two fixes. The first is mine to own: I carried 4200's 'sales' subtype onto
-- 4018 but not its section label, so US Bank rendered under Sales instead of
-- Alliances. The profit-and-loss section for an agency income account comes
-- from section_label_override, and 4018's was NULL.
--
-- 4016 Trupanion - New had the same hole: NULL subtype AND NULL label, so it
-- would have surfaced in the wrong section the moment anything posted to it.
--
-- Both now mirror 4131 Trupanion - Renewal exactly, which is the established
-- shape for an alliance income account.
--
-- Chart of accounts is locked by trigger by design; using the drop / change /
-- recreate procedure the lock's own error message prescribes.

DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;

UPDATE chart_of_accounts
SET section_label_override = 'Alliances - SF Comp',
    account_subtype        = 'sales'
WHERE account_code IN ('4018', '4016')
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222';

CREATE TRIGGER lock_chart_of_accounts
  BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION public.block_chart_of_accounts_writes();

-- Wire Trupanion new business to the Trupanion - New account. It was pointing
-- at 4131 Trupanion - Renewal, so new pet business was landing in the renewal
-- account while the new account sat empty. Low volume through the year does not
-- change that it has to be wired.
UPDATE comp_category_map
SET source_account_code = '4016',
    notes = COALESCE(notes || ' ', '')
            || 'Repointed 4131 (Trupanion - Renewal) -> 4016 (Trupanion - New), Peter 2026-08-19: new pet business was posting into the renewal account.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND comp_category = 'pet_new'
  AND source_account_code = '4131';
