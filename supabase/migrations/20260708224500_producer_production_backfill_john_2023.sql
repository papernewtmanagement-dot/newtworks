-- Backfill John Kostov 2023 producer_production from SF full-year summary screenshot.
-- Source range: 01/08/2023-01/06/2024 (SF Digital Whiteboard). Effectively year-1 tenure.
-- Issued totals: Auto 111/$82,204.73, Fire 99/$95,412.68, Life 21/$43,405.00, Health 9/$2,308.40.

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
    WHERE team_member_id = v_team_id AND period_year = 2023
  ) THEN
    RAISE EXCEPTION 'John Kostov already has 2023 rows — aborting to avoid duplicates';
  END IF;

  INSERT INTO public.producer_production
    (agency_id, team_member_id, period_year, period_month, line_of_business,
     policies_issued, premium_issued, premium_type, source, notes)
  VALUES
    -- AUTO 111/$82,204.73
    (v_agency_id, v_team_id, 2023,  1, 'Auto', 10, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  2, 'Auto', 10, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  3, 'Auto', 10, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  4, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  5, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  6, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  7, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  8, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  9, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 10, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 11, 'Auto',  9, 6850.39, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 12, 'Auto',  9, 6850.44, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    -- FIRE 99/$95,412.68
    (v_agency_id, v_team_id, 2023,  1, 'Fire', 9, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  2, 'Fire', 9, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  3, 'Fire', 9, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  4, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  5, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  6, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  7, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  8, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  9, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 10, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 11, 'Fire', 8, 7951.06, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 12, 'Fire', 8, 7951.02, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    -- LIFE 21/$43,405.00
    (v_agency_id, v_team_id, 2023,  1, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  2, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  3, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  4, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  5, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  6, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  7, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  8, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  9, 'Life', 2, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 10, 'Life', 1, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 11, 'Life', 1, 3617.08, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 12, 'Life', 1, 3617.12, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    -- HEALTH 9/$2,308.40
    (v_agency_id, v_team_id, 2023,  1, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  2, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  3, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  4, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  5, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  6, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  7, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  8, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023,  9, 'Health', 1, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 10, 'Health', 0, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 11, 'Health', 0, 192.37, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)'),
    (v_agency_id, v_team_id, 2023, 12, 'Health', 0, 192.33, 'new_business', 'manual_backfill', 'John 2023 SF full-year summary (range 01/08/23-01/06/24)');

END $$;

-- Verify totals match source
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
  WHERE team_member_id = v_team_id AND period_year = 2023 AND line_of_business = 'Auto';

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_fire_prem, v_fire_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2023 AND line_of_business = 'Fire';

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_life_prem, v_life_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2023 AND line_of_business = 'Life';

  SELECT SUM(premium_issued), SUM(policies_issued) INTO v_hlth_prem, v_hlth_cnt
  FROM public.producer_production
  WHERE team_member_id = v_team_id AND period_year = 2023 AND line_of_business = 'Health';

  IF v_auto_prem <> 82204.73 OR v_auto_cnt <> 111 THEN
    RAISE EXCEPTION 'Auto reconciliation failed: got % / %, expected 82204.73 / 111', v_auto_prem, v_auto_cnt;
  END IF;
  IF v_fire_prem <> 95412.68 OR v_fire_cnt <> 99 THEN
    RAISE EXCEPTION 'Fire reconciliation failed: got % / %, expected 95412.68 / 99', v_fire_prem, v_fire_cnt;
  END IF;
  IF v_life_prem <> 43405.00 OR v_life_cnt <> 21 THEN
    RAISE EXCEPTION 'Life reconciliation failed: got % / %, expected 43405.00 / 21', v_life_prem, v_life_cnt;
  END IF;
  IF v_hlth_prem <> 2308.40 OR v_hlth_cnt <> 9 THEN
    RAISE EXCEPTION 'Health reconciliation failed: got % / %, expected 2308.40 / 9', v_hlth_prem, v_hlth_cnt;
  END IF;

  RAISE NOTICE 'John 2023 backfill reconciled: Auto 111/82204.73, Fire 99/95412.68, Life 21/43405.00, Health 9/2308.40';
END $$;
