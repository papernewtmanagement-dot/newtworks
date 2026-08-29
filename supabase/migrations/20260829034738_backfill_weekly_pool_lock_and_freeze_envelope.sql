-- Backfill the seven paid weeks of the 7/11 rollout quarter.
INSERT INTO public.weekly_pool_lock
  (agency_id, week_end_date, annual_basis_locked, pool_pct_locked, weekly_envelope_locked, bonus_actually_paid, lock_source, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','2026-07-11',533910.20,45.22710,533910.20*45.22710/100.0/52.0,917.84,'payroll_paid','basis clean - diag predates the 08-26 statement'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-07-18',533642.93,45.15832,533642.93*45.15832/100.0/52.0,746.85,'payroll_paid','basis clean - diag predates the 08-26 statement'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-07-25',533785.69,45.08954,533785.69*45.08954/100.0/52.0,907.14,'payroll_paid','basis clean - diag predates the 08-26 statement'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-08-01',530544.84,45.02077,530544.84*45.02077/100.0/52.0,756.17,'payroll_paid','pre-statement basis restored: 525423.24 + 5121.60'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-08-08',531723.78,44.95199,531723.78*44.95199/100.0/52.0,591.27,'payroll_paid','pre-statement basis restored: 526602.18 + 5121.60'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-08-15',532042.34,44.88321,532042.34*44.88321/100.0/52.0,608.45,'payroll_paid','pre-statement basis restored: 526920.74 + 5121.60'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-08-22',529324.40,44.81443,529324.40*44.81443/100.0/52.0,311.20,'payroll_paid','pre-statement basis restored: 524202.80 + 5121.60')
ON CONFLICT (agency_id, week_end_date) DO NOTHING;

-- Point the envelope sum at the lock where one exists. Anchored textual patch so
-- the rest of the 200-line function is untouched; aborts if the anchor moved.
DO $mig$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  v_new := replace(v_src,
    'SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0) INTO v_qtd_envelope FROM public.team_comp_pool_schedule WHERE agency_id = p_agency_id AND week_end_date >= v_cycle_start AND week_end_date <= p_week_end_date;',
    'SELECT COALESCE(SUM(COALESCE(l.weekly_envelope_locked, (v_annual_basis * s.pool_pct / 100.0) / 52.0)), 0) INTO v_qtd_envelope FROM public.team_comp_pool_schedule s LEFT JOIN public.weekly_pool_lock l ON l.agency_id = s.agency_id AND l.week_end_date = s.week_end_date WHERE s.agency_id = p_agency_id AND s.week_end_date >= v_cycle_start AND s.week_end_date <= p_week_end_date;');

  IF v_new = v_src THEN
    RAISE EXCEPTION 'qtd_envelope anchor not found - aborting, function unchanged';
  END IF;

  EXECUTE v_new;
END
$mig$;

