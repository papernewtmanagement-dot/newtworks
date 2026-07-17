-- Part 4: Uniform +4pp lift on pool_pct schedule to offset new goals-bonus carveouts

UPDATE public.team_comp_pool_schedule
SET pool_pct = pool_pct + 4,
    plan_note = COALESCE(plan_note, '') ||
      ' | 2026-07-14: +4pp uniform lift to offset $20,800/yr new goals-bonus carveouts (WtW/Gain/Leaderboard/All-Star/Trailblazer). Compensation ~$19.6K/yr net-of-burden vs $20.8K max carve at N=4. Peter directive: a little higher at endpoint.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';;