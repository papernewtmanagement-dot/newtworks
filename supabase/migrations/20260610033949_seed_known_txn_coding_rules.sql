
-- Seed known recurring transactions from Peter's books
-- These are things we already know from comp_recap and journal history
INSERT INTO txn_coding_rules (agency_id, match_merchant, match_merchant_mode, match_direction, debit_account, credit_account, description_template, rule_name, rule_source, confidence) VALUES

-- SF Commission deposits into 3977 (income account)
('126794dd-25ff-47d2-a436-724499733365', 'STATE FARM', 'contains', 'credit', '1010-USBank-3977', '4000-SF-Commission', 'State Farm Commission Deposit', 'SF Commission Credit', 'system_seed', 'high'),

-- Payroll ACH out of 4335
('126794dd-25ff-47d2-a436-724499733365', 'GUSTO', 'contains', 'debit', '6100-Payroll-Wages', '1020-USBank-4335', 'Gusto Payroll Run', 'Gusto Payroll Debit', 'system_seed', 'high'),
('126794dd-25ff-47d2-a436-724499733365', 'ADP', 'contains', 'debit', '6100-Payroll-Wages', '1020-USBank-4335', 'ADP Payroll Run', 'ADP Payroll Debit', 'system_seed', 'high'),

-- Rent
('126794dd-25ff-47d2-a436-724499733365', 'RENT', 'contains', 'debit', '6300-Rent', '1020-USBank-4335', 'Office Rent', 'Rent Payment', 'system_seed', 'medium'),

-- Utilities / phone
('126794dd-25ff-47d2-a436-724499733365', 'VERIZON', 'contains', 'debit', '6400-Telephone', '1020-USBank-4335', 'Verizon Business Cell', 'Verizon Phone', 'system_seed', 'high'),
('126794dd-25ff-47d2-a436-724499733365', 'AT&T', 'contains', 'debit', '6400-Telephone', '1020-USBank-4335', 'AT&T Service', 'ATT Phone', 'system_seed', 'high'),

-- Common office / operating expenses
('126794dd-25ff-47d2-a436-724499733365', 'AMAZON', 'contains', 'debit', '6500-Office-Supplies', '1030-USBankCC-3439', 'Amazon Office Purchase', 'Amazon Office', 'system_seed', 'medium'),
('126794dd-25ff-47d2-a436-724499733365', 'STAPLES', 'contains', 'debit', '6500-Office-Supplies', '1030-USBankCC-3439', 'Staples Office Supplies', 'Staples', 'system_seed', 'high'),

-- Marketing / advertising
('126794dd-25ff-47d2-a436-724499733365', 'META', 'contains', 'debit', '6200-Advertising', '1030-USBankCC-3439', 'Meta/Facebook Ads', 'Meta Ads', 'system_seed', 'high'),
('126794dd-25ff-47d2-a436-724499733365', 'GOOGLE ADS', 'contains', 'debit', '6200-Advertising', '1030-USBankCC-3439', 'Google Advertising', 'Google Ads', 'system_seed', 'high'),

-- SF deductions (pull from 3977)
('126794dd-25ff-47d2-a436-724499733365', 'STATE FARM DEDUCTION', 'contains', 'debit', '6700-SF-Deductions', '1010-USBank-3977', 'State Farm Deduction / Charge', 'SF Deduction Debit', 'system_seed', 'high'),

-- CC payment (transfer, not a GL expense)
('126794dd-25ff-47d2-a436-724499733365', 'PAYMENT THANK YOU', 'contains', 'credit', '2100-CreditCard-Payable', '1020-USBank-4335', 'Credit Card Payment', 'CC Payment Credit', 'system_seed', 'high')

ON CONFLICT DO NOTHING;

