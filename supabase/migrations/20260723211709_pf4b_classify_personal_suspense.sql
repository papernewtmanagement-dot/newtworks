-- =====================================================================
-- Phase 4b: Classify personal suspense using vendor patterns
-- =====================================================================
DO $classify$
DECLARE
  v_agency_id   UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_entity_id   UUID := 'b3333333-3333-3333-3333-333333333333';
  v_susp_in_id  UUID;
  v_susp_out_id UUID;
  v_map RECORD;
  v_target_id   UUID;
BEGIN
  SELECT id INTO v_susp_in_id  FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-8999';
  SELECT id INTO v_susp_out_id FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9999';

  FOR v_map IN
    SELECT desc_pattern, target_code FROM (VALUES
      ('PAPERNEWT LLC PAYROLL',          'PERSONAL-8100'),
      ('GLOELE LLC PAYROLL',             'PERSONAL-8100'),
      ('CD INT TRANSFER INTEREST',       'PERSONAL-8200'),
      ('Interest Paid',                  'PERSONAL-8200'),
      ('Dividend',                       'PERSONAL-8200'),
      ('Credit Balance Refund',          'PERSONAL-8300'),
      ('Amazon.com Servi PAYMENTS',      'PERSONAL-8300'),
      ('STATE FARM INSURANCE',           'PERSONAL-9600'),
      ('MORTGAGE SERV CT',               'PERSONAL-9100'),
      ('CITY PUBLIC SRV',                'PERSONAL-9110'),
      ('SA WATER SYSTEM',                'PERSONAL-9110'),
      ('REPUBLIC SERVICES TRASH',        'PERSONAL-9110'),
      ('HEB CURBSIDE',                   'PERSONAL-9200'),
      ('SAMS CLUB',                      'PERSONAL-9200'),
      ('SAMSCLUB',                       'PERSONAL-9200'),
      ('BEXAR VEHREG',                   'PERSONAL-9320'),
      ('SANANTONIOEXPERTTAEKW',          'PERSONAL-9400'),
      ('Champions Cheer',                'PERSONAL-9400'),
      ('LIVE OAK PERIODONTICS',          'PERSONAL-9500'),
      ('TPC DENTAL CARE',                'PERSONAL-9500'),
      ('AMAZON MKTPL',                   'PERSONAL-9800'),
      ('Amazon.com*',                    'PERSONAL-9800'),
      ('PLAYSTATION',                    'PERSONAL-9800'),
      ('Google TV',                      'PERSONAL-9800'),
      ('ROVER.COM',                      'PERSONAL-9800'),
      ('Dons Tropical Pets',             'PERSONAL-9800'),
      ('BUCK AND DOE',                   'PERSONAL-9800'),
      ('SP SAFERINGZ',                   'PERSONAL-9800'),
      ('DAVIDS LAWN SERVICES',           'PERSONAL-9120'),
      ('CCM*CINCH HOME SERVICE',         'PERSONAL-9120'),
      ('CAPITAL ONE ONLINE',             'PERSONAL-9990'),
      ('U.S. BANK WEB PYMT 8847',        'PERSONAL-9990'),
      ('Mobile Banking Payment To Credit Card 8847', 'PERSONAL-9990'),
      ('MOBILE PAYMENT THANK YOU',       'PERSONAL-9990'),
      ('PAYMENT THANK YOU',              'PERSONAL-9990'),
      ('INTERNET PAYMENT THANK YOU',     'PERSONAL-9990'),
      ('ACH W/D CAPITAL ONE',            'PERSONAL-9990')
    ) AS t(desc_pattern, target_code)
  LOOP
    SELECT id INTO v_target_id FROM public.chart_of_accounts
      WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code=v_map.target_code;

    UPDATE public.journal_lines jl
       SET account_id = v_target_id
     WHERE jl.journal_entry_id IN (
       SELECT je.id FROM public.journal_entries je
        WHERE je.source = 'pf4_personal_backfill'
          AND je.classification_status = 'pending_review'
          AND je.business_entity_id = v_entity_id
          AND je.description ILIKE '%' || v_map.desc_pattern || '%'
     )
       AND jl.account_id IN (v_susp_in_id, v_susp_out_id);
  END LOOP;

  UPDATE public.journal_entries je
     SET classification_status = 'classified',
         classified_by = 'pf4b_classify_personal_suspense',
         classified_at = NOW()
   WHERE je.source = 'pf4_personal_backfill'
     AND je.classification_status = 'pending_review'
     AND je.business_entity_id = v_entity_id
     AND NOT EXISTS (
       SELECT 1 FROM public.journal_lines jl
        WHERE jl.journal_entry_id = je.id
          AND jl.account_id IN (v_susp_in_id, v_susp_out_id)
     );
END
$classify$;
