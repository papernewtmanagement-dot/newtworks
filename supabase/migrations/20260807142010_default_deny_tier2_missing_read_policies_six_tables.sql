-- Six tables were left with row security ENABLED, SELECT granted to authenticated,
-- and ZERO policies. Result: every read from a logged-in user returned zero rows
-- with no error. Same silent-failure class as hiregauge_verdict_thresholds
-- (fixed earlier 2026-08-07 in 034c36355 / migration hiregauge_verdict_thresholds_rls_read_policy).
--
-- Confirmed live before this migration (service_role -> authenticated):
--   hiregauge_item_extra_traits           18 -> 0
--   hiregauge_competency_facet_canonical  12 -> 0
--   hiregauge_trait_documentation         31 -> 0
--   transaction_tags                      69 -> 0
--   account_master_codes                 176 -> 0
--   account_reclassifications             49 -> 0
--
-- Real consumers, all SECURITY INVOKER so RLS applies to them:
--   compute_newtworks_v2_facets_as_row, hiregauge_v2_impression_management,
--   hiregauge_facet_item_count, hiregauge_item_purge_guard -> hiregauge_item_extra_traits
--   hiregauge_detect_facet_input_drift                     -> hiregauge_competency_facet_canonical
--   get_pnl_history_for_entity, get_pnl_history_own_only,
--   pnl_drill_transactions                                 -> transaction_tags
--
-- Policy shape matches the sibling table hiregauge_instrument_items
-- (items_read_authenticated: FOR SELECT TO authenticated USING (is_agency_admin())).
-- DROP IF EXISTS first so this is idempotent and safe against a concurrent session.
--
-- DELIBERATELY LEFT LOCKED: gl_sign_audit_20260805 and
-- hiregauge_role_fit_pre_facet_snapshot are dated point-in-time audit snapshots.
-- Their only readers (cc_gl_writer, payroll_gl_writer) are SECURITY DEFINER owned
-- by postgres and bypass RLS as table owner, so they need no authenticated policy.

DROP POLICY IF EXISTS hiregauge_item_extra_traits_admin_read ON public.hiregauge_item_extra_traits;
CREATE POLICY hiregauge_item_extra_traits_admin_read
  ON public.hiregauge_item_extra_traits
  FOR SELECT TO authenticated
  USING (is_agency_admin());

DROP POLICY IF EXISTS hiregauge_competency_facet_canonical_admin_read ON public.hiregauge_competency_facet_canonical;
CREATE POLICY hiregauge_competency_facet_canonical_admin_read
  ON public.hiregauge_competency_facet_canonical
  FOR SELECT TO authenticated
  USING (is_agency_admin());

DROP POLICY IF EXISTS hiregauge_trait_documentation_admin_read ON public.hiregauge_trait_documentation;
CREATE POLICY hiregauge_trait_documentation_admin_read
  ON public.hiregauge_trait_documentation
  FOR SELECT TO authenticated
  USING (is_agency_admin());

DROP POLICY IF EXISTS transaction_tags_admin_read ON public.transaction_tags;
CREATE POLICY transaction_tags_admin_read
  ON public.transaction_tags
  FOR SELECT TO authenticated
  USING (is_agency_admin());

DROP POLICY IF EXISTS account_master_codes_admin_read ON public.account_master_codes;
CREATE POLICY account_master_codes_admin_read
  ON public.account_master_codes
  FOR SELECT TO authenticated
  USING (is_agency_admin());

DROP POLICY IF EXISTS account_reclassifications_admin_read ON public.account_reclassifications;
CREATE POLICY account_reclassifications_admin_read
  ON public.account_reclassifications
  FOR SELECT TO authenticated
  USING (is_agency_admin());
