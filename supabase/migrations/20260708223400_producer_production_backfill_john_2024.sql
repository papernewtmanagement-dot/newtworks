-- Backfill John Kostov 2024 producer_production from SF full-year summary screenshot.
-- Source totals (Issued column): Auto 142/$136,386.69, Fire 111/$127,099.68,
-- Life 26/$24,000.51, Health 17/$3,025.39.
-- Yearly totals split evenly across 12 months. Policy counts distributed with base+remainder;
-- premium rounded to $0.01 with residual dropped into December so monthly sum = yearly exact.

DO $$
DECLARE
  v_team_id uuid;
  v_agency_id CONSTANT uuid := '126794dd-25ff-47d2-a436-724499733365';
BEGIN
  SELECT id INTO v_team_id
  FROM public.team
  WHERE agency_id = v_agency_id
    AND first_name = 'John' AND last_name = 'Kostov'
    AND is_active = true
  LIMIT 1;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'John Kostov not found — aborting backfill';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.producer_production
    WHERE team_member_id = v_team_id AND period_year = 2024
  ) THEN
    RAISE EXCEPTION 'John Kostov already has 2024 rows — aborting to avoid duplicates';
  END IF;

  INSERT INTO public.producer_production
    (agency_id, team_member_id, period_year, period_month, line_of_business,
     policies_issued, premium_issued, premium_type, source, notes)
  VALUES
    -- ============ AUTO — 142 policies / $136,386.69 ============
    (v_agency_id, v_team_id, 2024,  1, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  2, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  3, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  4, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  5, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  6, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  7, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  8, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  9, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 10, 'Auto', 12, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 11, 'Auto', 11, 11365.56, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 12, 'Auto', 11, 11365.53, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),

    -- ============ FIRE — 111 policies / $127,099.68 ============
    (v_agency_id, v_team_id, 2024,  1, 'Fire', 10, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  2, 'Fire', 10, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  3, 'Fire', 10, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  4, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  5, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  6, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  7, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  8, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  9, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 10, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 11, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 12, 'Fire',  9, 10591.64, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),

    -- ============ LIFE — 26 policies / $24,000.51 ============
    (v_agency_id, v_team_id, 2024,  1, 'Life', 3, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  2, 'Life', 3, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  3, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  4, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  5, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  6, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  7, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  8, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  9, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 10, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 11, 'Life', 2, 2000.04, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 12, 'Life', 2, 2000.07, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),

    -- ============ HEALTH — 17 policies / $3,025.39 ============
    (v_agency_id, v_team_id, 2024,  1, 'Health', 2, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  2, 'Health', 2, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  3, 'Health', 2, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  4, 'Health', 2, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  5, 'Health', 2, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  6, 'Health', 1, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  7, 'Health', 1, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  8, 'Health', 1, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024,  9, 'Health', 1, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 10, 'Health', 1, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 11, 'Health', 1, 252.12, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary'),
    (v_agency_id, v_team_id, 2024, 12, 'Health', 1, 252.07, 'new_business', 'manual_backfill', 'John 2024 SF full-year summary');

END $$;

-- Verify totals match the source screenshot
DO $$
DECLARE
  v_team_id uuid;
  v_auto_prem numeric; v_auto_cnt int;
  v_fire_prem numeric; v_fire_cnt int;
  v_life_prem numeric; v_life_cnt int;
  v_hlth_prem numeric; v_hlth_cnt int;
BEGIN
  SELECT id INTO v_team_id FROM public.team
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND first_name = 'John' AND last_name = 'Kostov' AND is_active = true;

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_auto_prem, v_auto_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2024 AND line_of_business = 'Auto';

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_fire_prem, v_fire_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2024 AND line_of_business = 'Fire';

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_life_prem, v_life_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2024 AND line_of_business = 'Life';

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_hlth_prem, v_hlth_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2024 AND line_of_business = 'Health';

  IF v_auto_prem <> 136386.69 OR v_auto_cnt <> 142 THEN
    RAISE EXCEPTION 'Auto reconciliation failed: got % / %, expected 136386.69 / 142', v_auto_prem, v_auto_cnt;
  END IF;
  IF v_fire_prem <> 127099.68 OR v_fire_cnt <> 111 THEN
    RAISE EXCEPTION 'Fire reconciliation failed: got % / %, expected 127099.68 / 111', v_fire_prem, v_fire_cnt;
  END IF;
  IF v_life_prem <> 24000.51 OR v_life_cnt <> 26 THEN
    RAISE EXCEPTION 'Life reconciliation failed: got % / %, expected 24000.51 / 26', v_life_prem, v_life_cnt;
  END IF;
  IF v_hlth_prem <> 3025.39 OR v_hlth_cnt <> 17 THEN
    RAISE EXCEPTION 'Health reconciliation failed: got % / %, expected 3025.39 / 17', v_hlth_prem, v_hlth_cnt;
  END IF;

  RAISE NOTICE 'John 2024 backfill reconciled: Auto 142/136386.69, Fire 111/127099.68, Life 26/24000.51, Health 17/3025.39';
END $$;
