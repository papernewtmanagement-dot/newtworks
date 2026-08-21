-- write_weekly_pay: persists compute_weekly_pay output onto weekly_cpr_team_detail.
-- Volatile (does UPDATEs). Idempotent — safe to re-run any time.
-- Called from weekly_cpr_compute_outcome (Saturday writer) and from the
-- admin's "Recompute Pay" action when pay_paid_to_date_qtd is updated.
CREATE OR REPLACE FUNCTION public.write_weekly_pay(
  p_agency_id        uuid,
  p_week_ending_date date
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_rows_updated int := 0;
BEGIN
  WITH src AS (
    SELECT * FROM public.compute_weekly_pay(p_agency_id, p_week_ending_date)
  ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      weekly_pay          = s.weekly_pay,
      base_advance        = s.base_advance,
      health_bonus        = s.health_bonus,
      service_surge_share = s.service_surge_share,
      true_pay_bonus      = s.true_pay_bonus,
      manager_bonus       = s.manager_bonus,
      agency_profit_share = s.agency_profit_share,
      updated_at          = now()
    FROM src s,
         public.weekly_cpr_reports r
    WHERE r.id                  = wctd.weekly_cpr_report_id
      AND r.agency_id           = p_agency_id
      AND r.week_ending_date    = p_week_ending_date
      AND wctd.team_member_id   = s.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  RETURN jsonb_build_object(
    'agency_id',         p_agency_id,
    'week_ending_date',  p_week_ending_date,
    'rows_updated',      v_rows_updated,
    'written_at',        now()
  );
END;
$$;
