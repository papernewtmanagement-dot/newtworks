ALTER TABLE public.accounts ADD COLUMN IF NOT EXISTS gmail_label_id text;

WITH map(account_code, label_id) AS (
  VALUES
    ('1011','Label_15'),
    ('1012','Label_14'),
    ('1070','Label_4638151277633436837'),
    ('1071','Label_269755683553157275'),
    ('1072','Label_6289076751884054083'),
    ('1073','Label_333605209273012509'),
    ('1075','Label_116451142686388532'),
    ('1076','Label_2985497265413081452'),
    ('1400','Label_2326968232492154417'),
    ('2110','Label_750527633255510931'),
    ('2113','Label_19'),
    ('2140','Label_4169296779651490936'),
    ('2141','Label_1907300717006617004'),
    ('2170','Label_6076000820747012412'),
    ('2171','Label_2131460402459559974'),
    ('2172','Label_5396330977611002013'),
    ('2173','Label_2389866756064332330')
)
UPDATE public.accounts a
SET gmail_label_id = map.label_id
FROM map
JOIN public.chart_of_accounts coa ON coa.account_code = map.account_code
WHERE a.chart_account_id = coa.id
  AND a.agency_id = '126794dd-25ff-47d2-a436-724499733365';
