-- Set Jason's nickname to JD so the parser accepts both "Jason" and "JD"
UPDATE public.team
SET nickname = 'JD',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND first_name = 'Jason'
  AND last_name = 'Fuller';

-- Map the existing JD telegram entry to Jason's team_id
UPDATE public.team_telegram_map
SET team_id = (
      SELECT id FROM public.team
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND first_name = 'Jason' AND last_name = 'Fuller'
      LIMIT 1),
    mapping_method = 'manual',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND telegram_first_name = 'JD'
  AND team_id IS NULL;
