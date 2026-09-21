-- window_fraction_left is worked out by the system when a cancelation is
-- saved. Nobody types it, so it is bookkeeping, not a change anyone made.
CREATE OR REPLACE FUNCTION public.change_field_hidden(p_field text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT p_field ~ '^(id|agency_id|created_by|created_by_user_id|created_at|updated_at|voided_by|voided_at|verified_by|source|source_id|sales_log_id|quote_log_id|multiline_credit_id|matched_sale_product_id|chargeback_activity_id|entry_source|tenure_tier_at_entry|entry_type|window_fraction_left)$';
$function$;
