-- Tag the Stephanie 6/12 $79 + Jason 6/22 $311.26 team-licensing reimbursements
-- at 6710 with budget_category='growth' per prior *Payroll split 2 session designation.

INSERT INTO public.transaction_tags (id, agency_id, journal_line_id, tag_key, tag_value, created_by)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365'::uuid, jl_id,
       'budget_category', 'growth', 'phase4_coa_reorg'
FROM (VALUES
  ('e9ec3b5e-fb47-4664-ba62-cdf32809ffa9'::uuid),  -- Stephanie 6/12 $79.00
  ('8dfe9233-5517-40ca-b8b0-647ca2beb941'::uuid)   -- Jason 6/22 $311.26
) AS t(jl_id);
