-- Peter confirmed 2026-08-09: 5784 is the correct HSA account number.
-- 9615 was read off the Drive folder/Gmail label names Peter's reorg created
-- this morning — those names appear to have the wrong digits. Deleting the
-- erroneous duplicate account row and moving the folder/label mapping onto
-- the pre-existing, correct 5784 row instead.
DELETE FROM public.accounts
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_number_last4 = '9615'
  AND chart_account_id = '826e7b0f-aaad-4821-b508-578dd1acbd53';

UPDATE public.accounts
SET drive_folder_id = '1PYZEt785PVbcH4HNoFpAtk1SNFGpQrSa',
    gmail_label_id = 'Label_2326968232492154417',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_number_last4 = '5784'
  AND chart_account_id = '826e7b0f-aaad-4821-b508-578dd1acbd53';
