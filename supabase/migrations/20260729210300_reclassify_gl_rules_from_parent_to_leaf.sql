-- Peter directive 2026-07-29: 25 active gl_classification_rules were routing to
-- root parent COAs. Reclassify each to the correct leaf child so future bank/CC
-- ingest lands specifically. Payroll rules deactivated as duplicates of
-- payroll_gl_writer's authoritative bookings. See detailed mapping in
-- session_note 2026-07-29 direct-to-parent classifier fix.
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-052' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Internet leads vendor';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-043' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Tithe / Ghost Tithe to SF earnings';
UPDATE public.gl_classification_rules SET is_active=false WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name IN ('Payroll Service ACH','MINED: Payroll Service ACH (envelope)');
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-052' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: EverQuote leads';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-077' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Employee benefits / health insurance staff';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-078', sub_category_label='child support garnishment — reclassify to liability if needed' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: MyChildSupport (envelope)';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-008', credit_account_code='__SOURCE__' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='H-E-B / grocery — discretionary events';
UPDATE public.gl_classification_rules SET credit_account_code='COA-SUB-058', sub_category_label='SF income — verify memo for correct commission subtype' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='State Farm commission deposit (inbound checking)';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-075' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Employee meals (50% deductible)';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-048' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: Agent Tagged Media';
UPDATE public.gl_classification_rules SET debit_account_code='6315' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: Atlassian';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-079' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: CKAutopilot recruiting';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-052' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: MediaAlpha leads';
UPDATE public.gl_classification_rules SET debit_account_code='6315' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: OpenAI / ChatGPT';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-053' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='DAC Group online ads';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-090' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Plarium — personal mobile gaming';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-039' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Training & seminars — AGENT (Insight to Impact, i2i)';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-002' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Airbnb — other (default discretionary)';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-052' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: QuoteWizard leads';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-016' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: NSF / Overdraft';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-056' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Vault Fundraiser sponsorship';
UPDATE public.gl_classification_rules SET debit_account_code='6740' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Airbnb — Champions Circle lodging';
UPDATE public.gl_classification_rules SET debit_account_code='COA-SUB-049' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='MINED: USPS postage';
UPDATE public.gl_classification_rules SET debit_account_code='6410' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_name='Butler/Till Agenthood — SF marketing program';
