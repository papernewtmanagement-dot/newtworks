-- 20260707225609_rename_renewals_to_licenses
-- Renames the Renewals module data model to Licenses:
--   team_renewals -> team_licenses
--   renewal_notification_log -> license_notification_log
--   renewal_type -> license_type
--   team_renewal_id -> team_license_id
-- Includes index, policy, and trigger renames. Function bodies restored in
-- companion migration 20260707230200_restore_license_functions_correctly_v2.

-- Tables
ALTER TABLE IF EXISTS public.team_renewals RENAME TO team_licenses;
ALTER TABLE IF EXISTS public.renewal_notification_log RENAME TO license_notification_log;

-- Columns
ALTER TABLE public.team_licenses RENAME COLUMN renewal_type TO license_type;
ALTER TABLE public.license_notification_log RENAME COLUMN team_renewal_id TO team_license_id;

-- Indexes (7)
ALTER INDEX IF EXISTS team_renewals_pkey             RENAME TO team_licenses_pkey;
ALTER INDEX IF EXISTS idx_team_renewals_agency       RENAME TO idx_team_licenses_agency;
ALTER INDEX IF EXISTS idx_team_renewals_member       RENAME TO idx_team_licenses_member;
ALTER INDEX IF EXISTS idx_team_renewals_due          RENAME TO idx_team_licenses_due;
ALTER INDEX IF EXISTS renewal_notification_log_pkey  RENAME TO license_notification_log_pkey;
ALTER INDEX IF EXISTS idx_renewal_notif_log_renewal  RENAME TO idx_license_notif_log_license;
ALTER INDEX IF EXISTS ux_renewal_notif_log_dedupe    RENAME TO ux_license_notif_log_dedupe;

-- Trigger
ALTER TRIGGER team_renewals_updated_at ON public.team_licenses RENAME TO team_licenses_updated_at;

-- Policy renames (6) — policies stayed on the renamed tables. Rename them for clarity.
ALTER POLICY anon_read_team_renewals              ON public.team_licenses               RENAME TO anon_read_team_licenses;
ALTER POLICY authenticated_insert_team_renewals   ON public.team_licenses               RENAME TO authenticated_insert_team_licenses;
ALTER POLICY authenticated_update_team_renewals   ON public.team_licenses               RENAME TO authenticated_update_team_licenses;
ALTER POLICY authenticated_delete_team_renewals   ON public.team_licenses               RENAME TO authenticated_delete_team_licenses;
ALTER POLICY anon_read_renewal_notification_log   ON public.license_notification_log    RENAME TO anon_read_license_notification_log;
ALTER POLICY authenticated_write_renewal_log      ON public.license_notification_log    RENAME TO authenticated_write_license_log;
