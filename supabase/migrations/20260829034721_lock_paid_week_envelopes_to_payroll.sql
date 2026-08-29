-- Peter directive 2026-08-28: prior weeks must stop moving. Once payroll for a
-- week has been paid, that week's envelope is a historical fact and a later
-- State Farm statement must not reprice it.
--
-- Root cause: compute_weekly_comp_residual_pool built qtd_envelope by applying
-- TODAY'S annual basis to every week of the cycle. compute_pool_basis_and_envelope
-- anchors the commission side on the latest statement regardless of the week asked
-- for, so the 2026-08-26 statement (coverage through 08-31) bled backwards into
-- weeks that had already closed and been paid.

CREATE TABLE IF NOT EXISTS public.weekly_pool_lock (
  agency_id              uuid        NOT NULL,
  week_end_date          date        NOT NULL,
  annual_basis_locked    numeric     NOT NULL,
  pool_pct_locked        numeric     NOT NULL,
  weekly_envelope_locked numeric     NOT NULL,
  bonus_actually_paid    numeric,
  lock_source            text        NOT NULL DEFAULT 'payroll_paid',
  locked_at              timestamptz NOT NULL DEFAULT NOW(),
  notes                  text,
  PRIMARY KEY (agency_id, week_end_date)
);

ALTER TABLE public.weekly_pool_lock ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS weekly_pool_lock_read   ON public.weekly_pool_lock;
DROP POLICY IF EXISTS weekly_pool_lock_insert ON public.weekly_pool_lock;
DROP POLICY IF EXISTS weekly_pool_lock_update ON public.weekly_pool_lock;

CREATE POLICY weekly_pool_lock_read   ON public.weekly_pool_lock FOR SELECT TO authenticated USING (is_agency_admin());
CREATE POLICY weekly_pool_lock_insert ON public.weekly_pool_lock FOR INSERT TO authenticated WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY weekly_pool_lock_update ON public.weekly_pool_lock FOR UPDATE TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

COMMENT ON TABLE public.weekly_pool_lock IS
'One row per week whose payroll has been paid. Freezes that week''s pool envelope so a later statement cannot reprice a week the team was already paid for. Weeks 2026-08-01 through 2026-08-22 were recomputed against the 08-26 statement before locking; their basis is the pre-statement value restored by adding back the measured statement effect of 5121.60, cross-checked four independent ways (5118.9 / 5117.8 / 5120.2 / 5129.5).';

