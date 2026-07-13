-- get_weekly_cpr_hours + get_expected_teammates: switch snapshot lookup
-- from team_weekly_snapshot (being dropped) to weekly_cpr_team_detail.
-- Both prefer detail row cols when a detail row exists for the target week;
-- live team fallback otherwise.

-- Bodies applied live; migration file is a marker.
