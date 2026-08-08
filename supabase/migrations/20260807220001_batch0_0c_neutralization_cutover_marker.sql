-- Batch 0 / 0C — neutralization cutover marker
-- Stays NULL until the FINAL item-neutralization batch ships. While NULL,
-- all pool-based comparisons (0D) return nothing and display falls back to
-- published-norm only. settings table uses agency-scoped key/value rows
-- with a UNIQUE (agency_id, setting_key) constraint -- matched here rather
-- than restructuring the table.

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'hiregauge_neutralization_cutover_at',
  NULL,
  'timestamp',
  'Timestamp after which HireGauge applicant-pool comparisons begin including assessments (item-neutralization cutover). NULL until final item-neutralization batch ships. Set per Batch 0 spec 0C -- do not set manually.'
)
ON CONFLICT (agency_id, setting_key) DO NOTHING;
