DO $s$
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
      ('IRS USATAXPYMT',    'PERSONAL-9900'),
      ('PURE MANA CBD',     'PERSONAL-9800'),
      ('H-E-B #',           'PERSONAL-9200'),
      ('TEXAS.GOV',         'PERSONAL-9320'),
      ('GOOGLE*TV',         'PERSONAL-9800')
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
         classified_by = 'pf4d_classify_stragglers',
         classified_at = NOW()
   WHERE je.source = 'pf4_personal_backfill'
     AND je.classification_status = 'pending_review'
     AND je.business_entity_id = v_entity_id
     AND NOT EXISTS (
       SELECT 1 FROM public.journal_lines jl
        WHERE jl.journal_entry_id = je.id
          AND jl.account_id IN (v_susp_in_id, v_susp_out_id)
     );
END $s$;
