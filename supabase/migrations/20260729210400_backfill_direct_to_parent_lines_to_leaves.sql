-- Peter directive 2026-07-29: backfill 165 existing journal_lines that were
-- booked directly to root parent COAs. Each pattern maps 1:1 to a leaf via the
-- updated gl_classification_rules. All lines matched a known vendor pattern —
-- no UNMATCHED remnants. Trigger tg_reject_direct_to_parent_booking will now
-- prevent future direct-to-parent inserts.

-- ============= 0001 ADMINISTRATION (COA-019) =============
UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='6315')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-019'
  AND je.description ~* 'Atlassian|ATLASSIAN';

UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='6315')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-019'
  AND je.description ~* 'OpenAi|OPENAI|ChatGPT|chatgpt';

-- ============= 0003 TEAM (COA-020) =============
UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-079')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-020'
  AND je.description ~* 'Ckautopilot|CKAutopilot|Autopilot';

-- ============= 0004 MARKETING (COA-021) =============
UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-052')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-021'
  AND je.description ~* 'EverQuote|EVERQUOTE|MediaAlpha|MEDIAALPHA|QuoteWizard|QUOTEWIZARD|SmartFinancial';

UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-048')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-021'
  AND je.description ~* 'Agent Tagged|AGENT TAG' AND je.description !~* 'BUTLER.?TILL|AGENTHOODPROG';

UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='6410')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-021'
  AND je.description ~* 'BUTLER.?TILL|AGENTHOODPROG';

UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-049')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-021'
  AND je.description ~* 'usps|USPS';

-- ============= 0006 PERSONAL (COA-022) =============
UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-090')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-022'
  AND je.description ~* 'PLARIUM';

-- ============= 0005 DISCRETIONARY (COA-031) =============
UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-008')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-031'
  AND je.description ~* 'H-E-B|HEB |Publix|Whole Foods';

UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND business_entity_id='b2222222-2222-2222-2222-222222222222' AND account_code='COA-SUB-002')
FROM public.journal_entries je, public.chart_of_accounts coa
WHERE jl.journal_entry_id = je.id AND jl.account_id = coa.id
  AND je.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND coa.account_code = 'COA-031'
  AND je.description ~* 'Airbnb';
