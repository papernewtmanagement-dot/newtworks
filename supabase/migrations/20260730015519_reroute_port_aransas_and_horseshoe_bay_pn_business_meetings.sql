-- Port Aransas (Mar 22-26) and Horseshoe Bay (Jun 19-24) were PaperNewt LLC business meetings,
-- not personal spend. Create Business Travel + Meals COAs on PaperNewt (mirrors PSF pattern),
-- route the 31 pending JEs, flip status.
--
-- Split rationale (matches Peter's PSF structure — COA-SUB-002 Business Travel, COA-SUB-008 Meals 50%):
--   MEALS (restaurants, bars, food/beverage — 50% deductible per IRC §274)
--   TRAVEL (lodging, transit, activities, meeting supplies — 100% deductible)

INSERT INTO public.chart_of_accounts
  (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype,
   is_active, created_at)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'b1111111-1111-1111-1111-111111111111',
   'COA-PN-TRAVEL', 'Business Travel', 'expense', 'travel', true, NOW()),
  ('126794dd-25ff-47d2-a436-724499733365', 'b1111111-1111-1111-1111-111111111111',
   'COA-PN-MEALS', 'Meals (50%)', 'expense', 'meals', true, NOW())
ON CONFLICT DO NOTHING;

WITH meals_target AS (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-PN-MEALS' LIMIT 1
),
travel_target AS (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-PN-TRAVEL' LIMIT 1
),
meals_jes AS (
  SELECT unnest(ARRAY[
    '5e3d4158-e0e9-412d-93d3-45cd97c22edf'::uuid,
    '5c216ba2-7f59-4424-8893-4e5365de2da8'::uuid,
    '6ca5ad40-3692-46a4-bed2-93ff95dea6e3'::uuid,
    '4ec50ca3-2c2f-41b2-88ec-3c541a36d6e2'::uuid,
    'afde0ad3-6716-4e16-acd7-506ff8cb4988'::uuid,
    '986379bc-bf33-452d-b405-69789efd2cb9'::uuid,
    '7150d418-c6e5-42e6-a226-2906ea89475a'::uuid,
    '0b2a50c8-c3fa-47f1-ab67-f91c4e9f9579'::uuid,
    '997d528a-e161-40d5-bfac-09b76492e421'::uuid,
    '8fe07b20-c1b3-4079-bd8d-d0375a14ee03'::uuid,
    'def78c8b-8d97-4c76-a6c9-170858164cf0'::uuid,
    '5a135328-ea83-430b-a427-91fcb66e82b3'::uuid,
    '84b4f8e7-950e-41cc-93da-6f50b8107c4b'::uuid,
    'ddde6cbb-adfb-4f8c-a7cb-87250994230a'::uuid,
    '5677c44f-0f1b-4277-b711-0ae1360b1ff9'::uuid,
    '7111b340-a460-4fda-9841-68834aa75a72'::uuid
  ]) AS je_id
),
travel_jes AS (
  SELECT unnest(ARRAY[
    'b41af1e9-d7a2-45fa-b41d-0ac1965834ac'::uuid,
    'e9405af2-d344-414d-b520-4d2523236985'::uuid,
    '8459e6db-a569-43d0-9dfe-7aba14de0e5d'::uuid,
    'cea21b4b-3481-486d-bb25-542ade1ec95e'::uuid,
    'e8e25948-0436-4a61-8759-565a4c00a58a'::uuid,
    '7484e776-f195-42c1-b40b-1a9b26af3283'::uuid,
    'b3880685-4909-4af2-90f1-3305e0747efe'::uuid,
    'dc97e23d-8a98-4a14-9875-fe3e6599923e'::uuid,
    '298be171-d509-414b-b57e-36e039aa13ce'::uuid,
    'fe4a98ad-5f3a-4e2d-ae8d-38127d5a0491'::uuid,
    '89416a8c-abf3-4dd6-90fb-d031d26c3fe8'::uuid,
    '3a53d492-1655-4852-ac95-4f3e397d4015'::uuid,
    'fe5f496b-039e-434f-8993-4cf33b13d97c'::uuid,
    'c1c2ecd9-d708-4d32-918b-8bfc100121b1'::uuid,
    '60a462f3-5818-4552-b879-7b8da117180a'::uuid
  ]) AS je_id
),
upd_meals_lines AS (
  UPDATE public.journal_lines
  SET account_id = (SELECT id FROM meals_target)
  WHERE id IN (
    SELECT jl.id FROM public.journal_lines jl
    JOIN meals_jes mj ON mj.je_id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_name = '*Unclassified'
  )
  RETURNING journal_entry_id
),
upd_travel_lines AS (
  UPDATE public.journal_lines
  SET account_id = (SELECT id FROM travel_target)
  WHERE id IN (
    SELECT jl.id FROM public.journal_lines jl
    JOIN travel_jes tj ON tj.je_id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_name = '*Unclassified'
  )
  RETURNING journal_entry_id
),
upd_status AS (
  UPDATE public.journal_entries
  SET classification_status = 'classified',
      classified_by = 'pn_business_meetings_reroute_2026_07_30',
      classified_at = NOW()
  WHERE id IN (SELECT je_id FROM meals_jes)
     OR id IN (SELECT je_id FROM travel_jes)
  RETURNING id
)
SELECT
  (SELECT COUNT(*) FROM upd_meals_lines) AS meals_rerouted,
  (SELECT COUNT(*) FROM upd_travel_lines) AS travel_rerouted,
  (SELECT COUNT(*) FROM upd_status) AS jes_flipped;
