-- 1. Set Cassandra's nickname so future name-matching works
UPDATE public.team
SET nickname = 'Cassie',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND first_name = 'Cassandra'
  AND last_name = 'Alves';

-- 2. Manually map the existing Cassie telegram entry to Cassandra's team_id
UPDATE public.team_telegram_map
SET team_id = (
      SELECT id FROM public.team
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND first_name = 'Cassandra' AND last_name = 'Alves'
      LIMIT 1),
    mapping_method = 'manual',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND telegram_first_name = 'Cassie'
  AND team_id IS NULL;
