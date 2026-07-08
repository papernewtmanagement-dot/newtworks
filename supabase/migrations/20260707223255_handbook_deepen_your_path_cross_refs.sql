-- 20260707223255_handbook_deepen_your_path_cross_refs

-- Add anchors to 2 more sections
UPDATE public.handbook
SET content = REPLACE(REPLACE(
  content,
  '## Licensing Reimbursement',
  '## <a id="licensing-reimbursement"></a>Licensing Reimbursement'
),
  '## Part 3 — Manager Bonus',
  '## <a id="manager-bonus"></a>Part 3 — Manager Bonus'
)
WHERE title = 'Getting Paid';

-- Deepen the 4 Your Path references to section-anchor links
UPDATE public.handbook
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
  content,
  'see the Licensing Reimbursement section on the [Getting Paid](/handbook/newtworks-native-handbook-03-pay) page',
  'see [Licensing Reimbursement](/handbook/newtworks-native-handbook-03-pay#licensing-reimbursement)'
),
  'Code Red Grace Period table in the Error Alert: Code Red/Code Yellow section on the [Winning & Learning](/handbook/newtworks-native-handbook-04-winning) page',
  'Code Red Grace Period table in [Error Alert: Code Red/Code Yellow](/handbook/newtworks-native-handbook-04-winning#error-alert-code-red-code-yellow)'
),
  'See the How Do We Win the Week? section on the [Winning & Learning](/handbook/newtworks-native-handbook-04-winning) page',
  'See [How Do We Win the Week?](/handbook/newtworks-native-handbook-04-winning#how-do-we-win-the-week)'
),
  'See the Manager Bonus section on the [Getting Paid](/handbook/newtworks-native-handbook-03-pay) page for the weekly bonus rates.',
  'See [Manager Bonus](/handbook/newtworks-native-handbook-03-pay#manager-bonus) for the weekly bonus rates.'
)
WHERE title = 'Your Path';
