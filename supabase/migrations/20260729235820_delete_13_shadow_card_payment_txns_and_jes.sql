-- Pass 2: delete 13 shadow credit_transactions + 12 corresponding JEs.
-- Card-side payment/thank-you lines are informational; bank-side JEs are authoritative.
--
-- Delete order: credit_transactions first (FK to journal_entries), then journal_lines, then journal_entries.

DELETE FROM public.credit_transactions
WHERE journal_entry_id IN (
  '560f04d4-7646-4dd3-91a0-8d1cc29a5167',
  '66bab837-2d4f-4dfc-9e8e-c5886df45962',
  '83cd8588-ee2d-409b-b46b-f0062a01e127',
  '4cfaefbf-38c1-4015-8336-63a8ab9c4d17',
  '1e40661e-38b6-4611-a0b4-ea4df71e0f22',
  '31c0266c-7b4f-4ec7-9c9a-c5051ad27901',
  'f58f07a2-6253-46e8-a0fe-00c65a0f31b3',
  'b0f4005c-7209-469d-9982-83006138ee35',
  '532727db-7565-4b39-851f-b524911ee844',
  'e692306b-da19-4dad-8738-6c1fd45621c6',
  '0b1818d4-75a6-4579-a96c-c12565a661d9',
  '71b136b2-5e10-4206-8371-e65ae2223930',
  'cba50423-a0b4-49e1-b898-30c0341466c5'
);

DELETE FROM public.journal_lines
WHERE journal_entry_id IN (
  '560f04d4-7646-4dd3-91a0-8d1cc29a5167',
  '66bab837-2d4f-4dfc-9e8e-c5886df45962',
  '83cd8588-ee2d-409b-b46b-f0062a01e127',
  '4cfaefbf-38c1-4015-8336-63a8ab9c4d17',
  '1e40661e-38b6-4611-a0b4-ea4df71e0f22',
  '31c0266c-7b4f-4ec7-9c9a-c5051ad27901',
  'f58f07a2-6253-46e8-a0fe-00c65a0f31b3',
  'b0f4005c-7209-469d-9982-83006138ee35',
  '532727db-7565-4b39-851f-b524911ee844',
  'e692306b-da19-4dad-8738-6c1fd45621c6',
  '0b1818d4-75a6-4579-a96c-c12565a661d9',
  '71b136b2-5e10-4206-8371-e65ae2223930',
  'cba50423-a0b4-49e1-b898-30c0341466c5'
);

DELETE FROM public.journal_entries
WHERE id IN (
  '560f04d4-7646-4dd3-91a0-8d1cc29a5167',
  '66bab837-2d4f-4dfc-9e8e-c5886df45962',
  '83cd8588-ee2d-409b-b46b-f0062a01e127',
  '4cfaefbf-38c1-4015-8336-63a8ab9c4d17',
  '1e40661e-38b6-4611-a0b4-ea4df71e0f22',
  '31c0266c-7b4f-4ec7-9c9a-c5051ad27901',
  'f58f07a2-6253-46e8-a0fe-00c65a0f31b3',
  'b0f4005c-7209-469d-9982-83006138ee35',
  '532727db-7565-4b39-851f-b524911ee844',
  'e692306b-da19-4dad-8738-6c1fd45621c6',
  '0b1818d4-75a6-4579-a96c-c12565a661d9',
  '71b136b2-5e10-4206-8371-e65ae2223930',
  'cba50423-a0b4-49e1-b898-30c0341466c5'
);
