CREATE OR REPLACE FUNCTION public.payroll_benefit_deduction(p_payroll_detail_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  WITH pd AS (SELECT * FROM payroll_detail WHERE id = p_payroll_detail_id),
  keys AS (SELECT k.key, (k.value->>'period')::numeric v
             FROM pd, jsonb_each(COALESCE(pd.raw_deductions->'items', pd.raw_deductions)) k
            WHERE pd.raw_deductions IS NOT NULL AND jsonb_typeof(k.value) = 'object'),
  person AS (SELECT k.key, (k.value->>'period')::numeric v
               FROM payroll_detail p2, jsonb_each(COALESCE(p2.raw_deductions->'items', p2.raw_deductions)) k
              WHERE p2.team_member_id = (SELECT team_member_id FROM pd) AND p2.raw_deductions IS NOT NULL
                AND jsonb_typeof(k.value) = 'object' AND COALESCE((k.value->>'period')::numeric, 0) <> 0)
  SELECT CASE
    -- Itemized deductions: only the benefit premium lines.
    WHEN (SELECT raw_deductions FROM pd) IS NOT NULL THEN
      COALESCE((SELECT sum(v) FROM keys WHERE key IN ('HEALTH','MEDICAL','DENTAL','VISION')), 0)
    -- Older imports carry one lump. Count it as premiums only for someone whose itemized runs show
    -- benefit premiums and nothing else besides taxes (no garnishment, child support, retirement, etc.).
    WHEN EXISTS (SELECT 1 FROM person WHERE key IN ('HEALTH','MEDICAL','DENTAL','VISION'))
     AND NOT EXISTS (SELECT 1 FROM person WHERE key NOT IN ('HEALTH','MEDICAL','DENTAL','VISION','FICA','FED WTH','MEDFICA','STATE-TX','STATE-VA','MISC 1T'))
    THEN COALESCE((SELECT other_deductions FROM pd), 0)
    ELSE 0 END;
$$;
