-- 20260707223115_handbook_cross_ref_link_retrofit

-- Add anchors on the 2 most-referenced sections
UPDATE public.handbook
SET content = REPLACE(
  content,
  '## The Thirteen-Week Onboarding Period',
  '## <a id="thirteen-week-onboarding-period"></a>The Thirteen-Week Onboarding Period'
)
WHERE title = 'Your Path';

UPDATE public.handbook
SET content = REPLACE(
  content,
  '## How Do We Win the Week?',
  '## <a id="how-do-we-win-the-week"></a>How Do We Win the Week?'
)
WHERE title = 'Winning & Learning';

-- Getting Paid: 2 refs to link
UPDATE public.handbook
SET content = REPLACE(REPLACE(
  content,
  E'See the Thirteen-Week Onboarding Period section on the Your Path page for how new hires reach Account Manager status.',
  E'See [The Thirteen-Week Onboarding Period](/handbook/newtworks-native-handbook-01-path#thirteen-week-onboarding-period) for how new hires reach Account Manager status.'
),
  E'see the Winning & Learning page for',
  E'see the [Winning & Learning](/handbook/newtworks-native-handbook-04-winning) page for'
)
WHERE title = 'Getting Paid';

-- Health, Safety, & Security: 1 ref
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'See the Employment & Termination page for the property-return procedure on separation.',
  E'See the [Employment & Termination](/handbook/341540867) page for the property-return procedure on separation.'
)
WHERE title = 'Health, Safety, & Security';

-- Hours & Time Off: 2 refs
UPDATE public.handbook
SET content = REPLACE(REPLACE(
  content,
  E'See the Thirteen-Week Onboarding Period section on the Your Path page for how new hires progress from Account Associate to Account Manager.',
  E'See [The Thirteen-Week Onboarding Period](/handbook/newtworks-native-handbook-01-path#thirteen-week-onboarding-period) for how new hires progress from Account Associate to Account Manager.'
),
  E'see the How Do We Win the Week? section on the Winning & Learning page for how their targets differ from sales specialists',
  E'see [How Do We Win the Week?](/handbook/newtworks-native-handbook-04-winning#how-do-we-win-the-week) for how their targets differ from sales specialists'
)
WHERE title = 'Hours & Time Off';

-- Your Path: 3 refs to link (2 already have Winning & Learning linked, but page-level only)
UPDATE public.handbook
SET content = REPLACE(REPLACE(REPLACE(
  content,
  E'see the Licensing Reimbursement section on the Getting Paid page',
  E'see the Licensing Reimbursement section on the [Getting Paid](/handbook/newtworks-native-handbook-03-pay) page'
),
  E'see the Winning & Learning page for details',
  E'see the [Winning & Learning](/handbook/newtworks-native-handbook-04-winning) page for details'
),
  E'See the Manager Bonus section on the Getting Paid page for the weekly bonus rates.',
  E'See the Manager Bonus section on the [Getting Paid](/handbook/newtworks-native-handbook-03-pay) page for the weekly bonus rates.'
)
WHERE title = 'Your Path';
