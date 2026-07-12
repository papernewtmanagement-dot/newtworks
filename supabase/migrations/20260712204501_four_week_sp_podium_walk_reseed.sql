-- Wipe smooth-avg provisional seeds and install tier-aware walk peaks.
-- Methodology: compute_person_qtd_at_week walks each (person, quarter) week-by-week under
-- SF Builder 2026-07-07 rate rules (steady weekly production pace + tier ladders applied
-- retroactively to full premium base). rolling_4wk(W) = cum_SP(W) - cum_SP(W-4) same-quarter,
-- or bridge sum from prior quarter tail for W<4. Take max per (person, quarter).
-- 2-per-person + distinct-quarter cap matches week_sp seed pattern.
-- Validation: cum_SP(13) matches every stored quarter total to the cent.

DELETE FROM public.leaderboards
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category = 'four_week_sp';

INSERT INTO public.leaderboards
  (agency_id, category, tier, team_member_id, record_value, record_period_label, record_week_ending, set_at, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'four_week_sp', 1,
   (SELECT id FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND first_name='John' LIMIT 1),
   3567.79,
   'Q1 2026 wk 13',
   '2026-03-28',
   NOW(),
   'Tier-aware walk peak. SF Builder 2026-07-07 rate rules. Life 71->77 + Fire 5->6 crossings retroactive to full Q1 prem base at wk 13. Prior smooth-avg seed $2260.85.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'four_week_sp', 2,
   (SELECT id FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND first_name='John' LIMIT 1),
   2642.76,
   'Q4 2025 wk 13',
   '2025-12-27',
   NOW(),
   'Tier-aware walk peak. SF Builder 2026-07-07 rate rules. Life 41->45 + Auto/Fire 9->10 crossings at wk 13. Prior smooth-avg seed $1711.38.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'four_week_sp', 3,
   (SELECT id FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND first_name='Thomas' LIMIT 1),
   2356.95,
   'Q2 2026 wk 13',
   '2026-06-27',
   NOW(),
   'Tier-aware walk peak. SF Builder 2026-07-07 rate rules. Prior smooth-avg seed $1593.61.');
