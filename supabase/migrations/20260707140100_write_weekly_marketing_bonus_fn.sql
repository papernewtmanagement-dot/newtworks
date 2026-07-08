-- Snapshot the on-time marketing bonus pool into weekly_cpr_team_detail
CREATE OR REPLACE FUNCTION public.write_weekly_marketing_bonus(
  p_agency_id UUID,
  p_week_end_date DATE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_report_id UUID;
  v_result    JSONB;
  v_pool      JSONB;
  v_pool_meta JSONB;
  v_rows_updated INT := 0;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0,
      'note', 'no weekly_cpr_reports row exists for this week',
      'written_at', NOW()
    );
  END IF;

  v_pool := public.compute_weekly_marketing_bonus(p_agency_id, p_week_end_date);
  v_pool_meta := jsonb_build_object(
    'basis',    v_pool->'basis',
    'envelope', v_pool->'envelope',
    'spend',    v_pool->'spend',
    'pool',     v_pool->'pool'
  );

  WITH people AS (
    SELECT
      (elem->>'team_member_id')::uuid  AS team_member_id,
      COALESCE((elem->>'points_ytd')::numeric, 0)  AS points_ytd,
      COALESCE((elem->>'share_pct')::numeric, 0)   AS share_pct,
      COALESCE((elem->>'earned_ytd')::numeric, 0)  AS earned_ytd
    FROM jsonb_array_elements(v_pool->'people') AS elem
  ),
  prior AS (
    SELECT DISTINCT ON (d.team_member_id)
      d.team_member_id,
      COALESCE(d.marketing_pool_earned_ytd, 0) AS prior_earned_ytd
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date < p_week_end_date
    ORDER BY d.team_member_id, r.week_ending_date DESC
  ),
  merged AS (
    SELECT
      p.team_member_id,
      p.points_ytd,
      p.share_pct,
      p.earned_ytd,
      GREATEST(0, p.earned_ytd - COALESCE(pr.prior_earned_ytd, 0)) AS earned_weekly
    FROM people p
    LEFT JOIN prior pr ON pr.team_member_id = p.team_member_id
  ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      marketing_pool_points_ytd    = m.points_ytd,
      marketing_pool_share_pct     = m.share_pct,
      marketing_pool_earned_ytd    = m.earned_ytd,
      marketing_pool_earned_weekly = m.earned_weekly,
      marketing_pool_diag          = v_pool_meta,
      updated_at = NOW()
    FROM merged m
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = m.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
    'weekly_cpr_report_id', v_report_id,
    'rows_updated', v_rows_updated,
    'pool_ytd',    v_pool_meta->'pool'->>'pool_ytd',
    'envelope',    v_pool_meta->'envelope',
    'written_at',  NOW()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.write_weekly_marketing_bonus(UUID, DATE) TO anon, authenticated;
