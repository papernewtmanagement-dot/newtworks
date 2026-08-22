-- Phase 3A: Align Personal entity chart_of_accounts to master codes,
-- and deactivate zero-activity rows across all entities.
-- Date: 2026-07-30

CREATE OR REPLACE FUNCTION public._phase3_rekey_account(
  p_agency uuid,
  p_old_code text,
  p_new_code text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.chart_of_accounts SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.gl_classification_rules SET debit_account_code = p_new_code
   WHERE agency_id = p_agency AND debit_account_code = p_old_code;
  UPDATE public.gl_classification_rules SET credit_account_code = p_new_code
   WHERE agency_id = p_agency AND credit_account_code = p_old_code;
  UPDATE public.statement_balances SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.opening_balances SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.documents SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;
  UPDATE public.gmail_label_classification_map SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;
  UPDATE public.envelope_budget_targets SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.prior_year_pl_account_map SET newtworks_account_code = p_new_code
   WHERE agency_id = p_agency AND newtworks_account_code = p_old_code;
END;
$$;

-- Personal (45 rows): strip COA-PERSONAL- prefix, map to master codes
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-0353', '1070');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-2545', '1071');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6730', '1072');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6755', '1073');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6608', '1075');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6596', '1076');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9615', '1400');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9971', '1911');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-3000', '3900');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9980', '3050');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9985', '3070');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9990', '3090');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9970', '2903');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9972', '2902');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-1006', '2170');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-3208', '2171');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-7435', '2172');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-8847', '2173');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8110', '8110');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8120', '8120');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8200', '8200');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8300', '8300');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8400', '8400');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8500', '8500');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8600', '8600');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9100', '9100');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9110', '9110');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9120', '9120');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9200', '9200');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9210', '9210');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9250', '9250');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9300', '9300');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9310', '9310');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9320', '9320');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9400', '9400');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9500', '9500');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9600', '9600');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9610', '9610');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9620', '9620');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9700', '9700');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9800', '9800');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9820', '9820');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9900', '9900');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9910', '9910');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9999', '0004');

-- Zero-activity deactivations
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('1100','1110','1120','1200','1210','1220','1230','2010','2020','2030','2070','COA-030')
   AND is_active = true;

UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('1000','1500','2000','2100','2500','3000','4900','6000','6700')
   AND account_subtype = 'header'
   AND is_active = true;

UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('2110','2120')
   AND account_name IN ('Business Credit Card — Chase','Business Credit Card — Other')
   AND is_active = true;

UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6011','6012','6013','6031','6032','6033','6034','6040','6050','6130','6230','6312','6313','6314','6340','6420','6430','6440','6450','6460','6540','6630','6715','6730','6820','6830','6840','6920','6930','6941','6942','8020','8040')
   AND is_active = true;

UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-002','COA-003','COA-004','COA-005','COA-008','COA-015','COA-016','COA-017','COA-018','COA-024','COA-026','COA-029','COA-033','COA-034','COA-035','COA-SUSP','COA-UNCL-PSS','COA-UNCL-PSS-INC','COA-027','COA-019','COA-020','COA-021','COA-022','COA-031','COA-032','COA-PN-020')
   AND is_active = true;

DROP FUNCTION IF EXISTS public._phase3_rekey_account(uuid, text, text);
