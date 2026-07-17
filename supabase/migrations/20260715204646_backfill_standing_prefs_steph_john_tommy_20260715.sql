-- Backfill existing schedule patterns into standing_time_off_preferences.
-- Retire the ad-hoc team.four_day_off_day text field by nulling out the
-- three actively-used values; leave column present for now (many read
-- sites; separate deprecation sprint will drop it).

DO $$
DECLARE
  v_steph UUID;
  v_john UUID;
  v_tommy UUID;
  v_peter UUID;
BEGIN
  SELECT id INTO v_steph  FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND first_name='Stephanie' AND last_name='Rogers';
  SELECT id INTO v_john   FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND first_name='John'      AND last_name='Kostov';
  SELECT id INTO v_tommy  FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND first_name='Thomas'    AND last_name='Lynch';
  SELECT id INTO v_peter  FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND role_level='Owner' AND is_admin_backoffice=false LIMIT 1;

  -- STEPHANIE: Mon+Wed AM remote, PM off, WtW-conditional on prior week won
  INSERT INTO public.standing_time_off_preferences
    (agency_id, team_member_id, day_of_week, day_part, pattern, is_paid, trigger_type, effective_from, approved_by_team_id, approved_at, notes)
  VALUES
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'monday',    'morning',   'remote', true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Mon AM, off Mon PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'monday',    'afternoon', 'off',    true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Mon AM, off Mon PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'wednesday', 'morning',   'remote', true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Wed AM, off Wed PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'wednesday', 'afternoon', 'off',    true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Wed AM, off Wed PM, when prior week won WtW.');

  -- JOHN: Friday full off, WtW-conditional (per his 7/2 note "so when we win the week...")
  INSERT INTO public.standing_time_off_preferences
    (agency_id, team_member_id, day_of_week, day_part, pattern, is_paid, trigger_type, effective_from, approved_by_team_id, approved_at, notes)
  VALUES
    ('126794dd-25ff-47d2-a436-724499733365', v_john, 'friday', 'full', 'off', true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from John 7/2 approved request. WtW-won-prior-week Friday off (family visit day). Retires prior team.four_day_off_day="wednesday".');

  -- TOMMY: Tue PM off + Thu PM off, always (no WtW gate)
  INSERT INTO public.standing_time_off_preferences
    (agency_id, team_member_id, day_of_week, day_part, pattern, is_paid, trigger_type, effective_from, approved_by_team_id, approved_at, notes)
  VALUES
    ('126794dd-25ff-47d2-a436-724499733365', v_tommy, 'tuesday',  'afternoon', 'off', true, 'always', '2026-07-20', v_peter, NOW(), 'Backfill from team.four_day_off_day="tuesday_pm+thursday_pm". Standing pattern, no WtW gate.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_tommy, 'thursday', 'afternoon', 'off', true, 'always', '2026-07-20', v_peter, NOW(), 'Backfill from team.four_day_off_day="tuesday_pm+thursday_pm". Standing pattern, no WtW gate.');

  -- Retire team.four_day_off_day values (column retained; NULL out active users)
  UPDATE public.team
     SET four_day_off_day = NULL
   WHERE id IN (v_john, v_tommy, v_steph)
     AND four_day_off_day IS NOT NULL;
END $$;

-- Deprecate the column via comment
COMMENT ON COLUMN public.team.four_day_off_day IS
  'DEPRECATED 2026-07-15. Use standing_time_off_preferences table instead. Column retained temporarily for legacy reads; nulled out for John, Tommy, Steph on 2026-07-15 backfill. Do not write to this column in new code.';;