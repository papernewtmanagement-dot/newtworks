-- Customers that are organizations.
-- An organization has one name and no last initial. Until now an org was jammed
-- into the person format with a meaningless initial ("Premier Online Marketing
-- LLC P."). customer_kind says which it is, in plain words, so the change log
-- reads properly instead of a blank initial standing in for it (Peter 2026-09-20).
--
-- Household grouping keys on lower(btrim(customer_label)) plus phone_last4, so
-- nothing about grouping changes: an org stores its name in BOTH
-- customer_first_name and customer_label, with the initial left blank.

ALTER TABLE public.sales_log              ADD COLUMN IF NOT EXISTS customer_kind text NOT NULL DEFAULT 'person';
ALTER TABLE public.quote_log              ADD COLUMN IF NOT EXISTS customer_kind text NOT NULL DEFAULT 'person';
ALTER TABLE public.cancelation_log        ADD COLUMN IF NOT EXISTS customer_kind text NOT NULL DEFAULT 'person';
ALTER TABLE public.retention_activity_log ADD COLUMN IF NOT EXISTS customer_kind text NOT NULL DEFAULT 'person';
ALTER TABLE public.appointment_log        ADD COLUMN IF NOT EXISTS customer_kind text NOT NULL DEFAULT 'person';

ALTER TABLE public.sales_log              DROP CONSTRAINT IF EXISTS sales_log_customer_kind_chk;
ALTER TABLE public.quote_log              DROP CONSTRAINT IF EXISTS quote_log_customer_kind_chk;
ALTER TABLE public.cancelation_log        DROP CONSTRAINT IF EXISTS cancelation_log_customer_kind_chk;
ALTER TABLE public.retention_activity_log DROP CONSTRAINT IF EXISTS retention_activity_log_customer_kind_chk;
ALTER TABLE public.appointment_log        DROP CONSTRAINT IF EXISTS appointment_log_customer_kind_chk;

ALTER TABLE public.sales_log              ADD CONSTRAINT sales_log_customer_kind_chk              CHECK (customer_kind IN ('person','org'));
ALTER TABLE public.quote_log              ADD CONSTRAINT quote_log_customer_kind_chk              CHECK (customer_kind IN ('person','org'));
ALTER TABLE public.cancelation_log        ADD CONSTRAINT cancelation_log_customer_kind_chk        CHECK (customer_kind IN ('person','org'));
ALTER TABLE public.retention_activity_log ADD CONSTRAINT retention_activity_log_customer_kind_chk CHECK (customer_kind IN ('person','org'));
ALTER TABLE public.appointment_log        ADD CONSTRAINT appointment_log_customer_kind_chk        CHECK (customer_kind IN ('person','org'));

-- The initial was required on these three. An organization has none, so the
-- column loses NOT NULL and a paired check takes over: a person still has to
-- carry a single letter, an organization has to carry nothing.
ALTER TABLE public.sales_log       ALTER COLUMN customer_last_initial DROP NOT NULL;
ALTER TABLE public.quote_log       ALTER COLUMN customer_last_initial DROP NOT NULL;
ALTER TABLE public.cancelation_log ALTER COLUMN customer_last_initial DROP NOT NULL;

ALTER TABLE public.sales_log              DROP CONSTRAINT IF EXISTS sales_log_customer_name_chk;
ALTER TABLE public.quote_log              DROP CONSTRAINT IF EXISTS quote_log_customer_name_chk;
ALTER TABLE public.cancelation_log        DROP CONSTRAINT IF EXISTS cancelation_log_customer_name_chk;
ALTER TABLE public.retention_activity_log DROP CONSTRAINT IF EXISTS retention_activity_log_customer_name_chk;
ALTER TABLE public.appointment_log        DROP CONSTRAINT IF EXISTS appointment_log_customer_name_chk;

ALTER TABLE public.sales_log ADD CONSTRAINT sales_log_customer_name_chk CHECK (
  customer_first_name IS NULL
  OR (customer_kind = 'person' AND customer_last_initial ~ '^[A-Za-z]$')
  OR (customer_kind = 'org'    AND COALESCE(customer_last_initial, '') = ''));

ALTER TABLE public.quote_log ADD CONSTRAINT quote_log_customer_name_chk CHECK (
  customer_first_name IS NULL
  OR (customer_kind = 'person' AND customer_last_initial ~ '^[A-Za-z]$')
  OR (customer_kind = 'org'    AND COALESCE(customer_last_initial, '') = ''));

ALTER TABLE public.cancelation_log ADD CONSTRAINT cancelation_log_customer_name_chk CHECK (
  customer_first_name IS NULL
  OR (customer_kind = 'person' AND customer_last_initial ~ '^[A-Za-z]$')
  OR (customer_kind = 'org'    AND COALESCE(customer_last_initial, '') = ''));

ALTER TABLE public.retention_activity_log ADD CONSTRAINT retention_activity_log_customer_name_chk CHECK (
  customer_first_name IS NULL
  OR (customer_kind = 'person' AND customer_last_initial ~ '^[A-Za-z]$')
  OR (customer_kind = 'org'    AND COALESCE(customer_last_initial, '') = ''));

ALTER TABLE public.appointment_log ADD CONSTRAINT appointment_log_customer_name_chk CHECK (
  customer_first_name IS NULL
  OR (customer_kind = 'person' AND customer_last_initial ~ '^[A-Za-z]$')
  OR (customer_kind = 'org'    AND COALESCE(customer_last_initial, '') = ''));

COMMENT ON COLUMN public.sales_log.customer_kind              IS 'person or org. An organization has one name and no last initial.';
COMMENT ON COLUMN public.quote_log.customer_kind              IS 'person or org. An organization has one name and no last initial.';
COMMENT ON COLUMN public.cancelation_log.customer_kind        IS 'person or org. An organization has one name and no last initial.';
COMMENT ON COLUMN public.retention_activity_log.customer_kind IS 'person or org. An organization has one name and no last initial.';
COMMENT ON COLUMN public.appointment_log.customer_kind        IS 'person or org. An organization has one name and no last initial.';
