-- Rule scope sweep. The cash register only ever sees a merchant name off a
-- card alert, and merchant is NULL for every checking transaction. So any rule
-- keyed to bank-statement description language -- transfer legs, electronic
-- deposits, payment-thank-you lines, payroll descriptors, overdraft and
-- interest lines -- can never legitimately fire in the register path. Marking
-- them statement-only is a correctness change, not a behaviour change: they
-- had nothing to match there anyway.
--
-- Two also close real over-match risks in the register:
--   d5de441c "Electronic Deposit From Amazon.com" carries an alternative
--     'amazon\.com\s+servi' that a card alert merchant string could hit,
--     which would post a purchase as print-sales income.
--   5800fc46 "Airbnb — Champions Circle lodging" narrows on the memo. Without
--     a memo the register would send ANY Airbnb charge to SF Conference &
--     Travel.
--   744cc45c "Employee meals" keys on wording that is memo text, not a
--     merchant name.
-- ff7e76be "Vault Fundraiser" stays on both: its payee regex is a genuine
-- merchant string that stands on its own.

UPDATE public.gl_classification_rules
SET rule_scope = 'statement', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_scope = 'both'
  AND id IN (
    '74dbcf04-9f4e-412e-8987-36eb2a335efa','a8f407b6-11d6-49c7-b02b-c7e5981c6779',
    '03f84c33-ddb1-4fff-b2a2-eb703dcb5a86','dceac058-c63c-4c36-9c63-94cdb2a18323',
    'd5de441c-2a66-4ad2-b6b3-70c113330a91','5b1680af-bab5-46c2-a059-e9e826e1b6d4',
    'be5a4ff8-398c-4568-9b50-f80d8b2afe48','28c75e5d-be1e-472a-ba21-8163456c6727',
    '14ca7962-6416-4927-844d-423d0a53888c','607d18ba-6fb0-4138-af39-07bbe133659a',
    'e6138295-5d4a-4634-b3c0-e325e9b0f1b7','bc567ce7-a762-40e3-92e6-97697165e6ae',
    '341e18fb-6fb3-4517-a20e-efa88686bb26','84451f1e-d2b5-4c04-9509-5f5dad677f86',
    '89ab719f-9b8c-45b0-98bd-d9eba20e9466','6718bc91-96d6-42b1-bc87-bef13e34b972',
    '71402824-9cc0-485c-8dd7-18c4dd569a32','9c60dc9f-3d21-4a2d-a41e-9810e9461adb',
    '31121c71-9f1c-4365-9eaa-90ac14ca0522','6c7ece39-025e-465f-8ba9-dcd000ed5aa3',
    '1ef8ec20-8e77-47ef-9158-05e5e349e3c9','0f138bb3-d691-4380-9293-3c81de2a3132',
    'cea3b31a-c799-4380-ac08-a65dbb2b83b7','d02100a4-54fb-46c2-ab3f-0dbf7e5b310f',
    'fa24c5e4-3049-48fa-9edd-8fc4e7221e7d','39dd6d8a-499d-425b-bb05-5fda29789392',
    '132bd936-ec76-4c34-8600-b3213bf2839e','4f1d0b73-e364-4284-8b60-f8a05f8858bb',
    '5800fc46-6bce-47e1-9ca2-b95a3ea50e73','744cc45c-9a88-4bd9-ba3f-46abaa4802b9'
  );
