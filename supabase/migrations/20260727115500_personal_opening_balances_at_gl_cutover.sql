-- Snapshot personal cash + credit card balances at the 6/30/2026 GL anchor date.
-- Fixes v_bank_balances / v_card_balances showing blank/wrong values for personal
-- accounts. Both views anchor to gl_anchor_date=2026-06-30 and only match
-- opening_balances rows dated exactly that day; personal accounts previously had
-- only 1/1/2026 anchors that the views drop.

INSERT INTO public.opening_balances
  (agency_id, as_of_date, account_code, account_name, account_type, opening_balance, source, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-0353','US Bank Personal Checking','asset', 6836.68,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-2545','US Bank Other Income','asset', 1116.18,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-6596','RBFCU Primary Savings','asset', -279.64,'gl_cutover_snapshot_ANOMALY_review','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-6730','US Bank Kids Profit Disc','asset', 7669.44,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-6755','US Bank Tithe Tax','asset', 12145.46,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-CC-1006','AMEX Personal (1006)','liability', 493.01,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-CC-3208','Discover Tithe CC (3208)','liability', 7132.76,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-CC-7435','Capital One Personal Card (7435)','liability', 2710.21,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PERSONAL-CC-8847','US Bank Personal CC (8847)','liability', 113.02,'gl_cutover_snapshot','b3333333-3333-3333-3333-333333333333');

-- Align COA name for RBFCU 6596 to match bank_accounts (view joins on account_name)
UPDATE public.chart_of_accounts
SET account_name = 'RBFCU Savings'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code = 'COA-PERSONAL-6596';
