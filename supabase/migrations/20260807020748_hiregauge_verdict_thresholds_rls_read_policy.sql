-- hiregauge_verdict_thresholds had RLS enabled with ZERO policies -- every
-- other HireGauge reference table (competency_weights, role_ideal_ranges,
-- etc.) grants authenticated read/all access. With RLS on and no policy,
-- Postgres denies all rows to non-owner roles, so any function running
-- under the app's authenticated role (e.g. verdict_overall ->
-- _hiregauge_layer_verdict) got zero rows back from this table, the
-- pass/consider CASE never matched, and the result silently fell through
-- to NULL -> 'decline' regardless of actual score. Root cause of the
-- Total-row "decline" bug reported 2026-08-06 on an 84-scoring candidate.
CREATE POLICY authenticated_read_hiregauge_verdict_thresholds
  ON public.hiregauge_verdict_thresholds
  FOR SELECT
  TO authenticated
  USING (true);
