-- agency_snapshot was created in the 2026-06-20 merge with RLS enabled but no
-- policies, which silently blocks all anon/authenticated reads from the frontend.
-- This caused CPR Detail Section 10 (Agency Performance) to show empty and
-- Section 11 (SMVC) to return null on_time/current/dollar_diff because
-- get_cpr_section_11 (not SECURITY DEFINER) reads agency_snapshot as the caller's
-- role. Restore frontend access via the agency-standard anon-read + auth-write
-- policy pair. Matches the BCC RLS audit protocol pattern.

ALTER TABLE public.agency_snapshot ENABLE ROW LEVEL SECURITY;

CREATE POLICY agency_snapshot_anon_read
  ON public.agency_snapshot
  FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY agency_snapshot_auth_write
  ON public.agency_snapshot
  FOR ALL
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
