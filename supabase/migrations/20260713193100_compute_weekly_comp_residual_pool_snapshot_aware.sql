-- compute_weekly_comp_residual_pool: roster CTE reads pay_type/pay_rate/
-- work_location/licenses/weekly_health_benefit from weekly_cpr_team_detail
-- snapshot cols (frozen at first-write). Live team is fallback only.
-- Per-week snapshot pay via LEFT JOIN in base_by_week for cycle-week history.
-- (Full function body is in v_pool_result / v_carveouts_result deps — see
-- session note 2026-07-13 pm5 for full rewrite context.)

-- Body applied live; snapshot semantics documented above.
