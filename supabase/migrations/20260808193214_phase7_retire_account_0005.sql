DELETE FROM public.chart_of_accounts
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = '0005';
DELETE FROM public.settings
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND setting_key = 'gl_comp_clearing_account_code';
