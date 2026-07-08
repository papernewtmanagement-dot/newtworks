-- 20260707183231_handbook_repetition_removal

-- Edit 1: Your Path — remove Manager Bonus % rates (canonical source is Getting Paid Part 3)
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'Managers are responsible for the weekly organization and motivation of the following groups:\n\n1. **Unit Manager**: 3-5 team members, including themselves — 0.1% of on-time Scorecard weekly\n2. **Section Manager**: 3-5 units — 0.2% of on-time Scorecard weekly\n3. **Office Manager**: 3-5 sections — 0.3% of on-time Scorecard weekly\n\nSee the Manager Bonus section on the Getting Paid page for how manager compensation is calculated.',
  E'Managers are responsible for the weekly organization and motivation of the following groups:\n\n1. **Unit Manager**: 3-5 team members, including themselves\n2. **Section Manager**: 3-5 units\n3. **Office Manager**: 3-5 sections\n\nSee the Manager Bonus section on the Getting Paid page for the weekly bonus rates.'
)
WHERE title = 'Your Path';

-- Edit 2: Hours & Time Off — Shift Hours: cut redundant 13-week AM onboarding paragraph
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'**ACCOUNT ASSOCIATES** are hourly or salary team members and are expected to work Monday - Friday. Every team member who aspires to become an Account Manager must start as an Account Associate for at least the first thirteen weeks.\n\n**ACCOUNT MANAGERS** are salaried team members. In their initial thirteen-week onboarding period, they are **ACCOUNT ASSOCIATES** and are expected to work Monday - Friday. Once this period is done, a decision will be made on whether or not to move forward with them as an **ACCOUNT MANAGER** where they will be eligible to work a four-day work week.',
  E'**ACCOUNT ASSOCIATES** are hourly or salary team members and are expected to work Monday - Friday.\n\n**ACCOUNT MANAGERS** are salaried team members eligible to work a four-day work week. See the Thirteen-Week Onboarding Period section on the Your Path page for how new hires progress from Account Associate to Account Manager.'
)
WHERE title = 'Hours & Time Off';

-- Edit 3: Hours & Time Off — Account Associate Time Off: cut redundant transition paragraph
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'Regular full time hourly **ACCOUNT ASSOCIATES** receive five days of PTO after their first year with the agency and ten days of PTO every year after that.\n\nOnce a full time **ACCOUNT ASSOCIATE** completes their initial thirteen-week probationary period and is fully licensed, they can instead choose (if the rest of the team agrees) to become an **ACCOUNT MANAGER** specializing in either sales or retention. This decision would make them a salaried team member and eligible for unlimited time off and the four-day work week.',
  E'Regular full time hourly **ACCOUNT ASSOCIATES** receive five days of PTO after their first year with the agency and ten days of PTO every year after that.'
)
WHERE title = 'Hours & Time Off';

-- Edit 4: Hours & Time Off — Account Manager Time Off: tighten, remove weekly-target mechanics (canonical in Winning & Learning)
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'Once an **ACCOUNT MANAGER** completes their initial thirteen-week probationary period and is fully licensed, time off is unlimited and paid if the following ratings are held as an average of "Good" or better:\n\n- Agency **SALES POINTS** (average the most recent rolling 13 weeks)\n- Team member **SALES POINTS** (average the most recent rolling 13 weeks)\n\nThe team can decide together to let go of the lowest producer at the end of the quarter in order to bring their team average into the rating of "Good" or better. The agent reserves the right to veto this decision.\n\nIf an **ACCOUNT MANAGER** specializes in retention, they only need to produce (or make possible for the rest of the team to produce) an additional half of the normal team member requirement for unlimited PTO and the four-day work week.\n\nThis means that an **ACCOUNT MANAGER** retention specialist would add on an additional 8 HH **QUOTES** and 500 **SALES POINTS** in order for the entire team to **WIN THE WEEK**. Accordingly, time off is unlimited and paid for them as long as the agency **SALES POINTS** average for the most recent rolling 13 weeks is "Good" or better.\n\nFor example, a team of one **Retention Specialist** and four **Sales Specialists** must have a total most recent 13 weeks rolling **SALES POINTS** of 4500 (1000 x 4.5).\n\nAn **ACCOUNT MANAGER** specializing in retention will affect **WIN THE WEEK** and Unlimited PTO for the rest of the team as well.',
  E'Account Managers who have completed onboarding get unlimited paid time off, provided both of the following rolling 13-week averages hold at a "Good" State Farm rating or better:\n\n- Agency **SALES POINTS** average\n- The team member''s own **SALES POINTS** average\n\nThe team can decide together to let go of the lowest producer at the end of the quarter in order to bring their team average into the rating of "Good" or better. The agent reserves the right to veto this decision.\n\nAccount Manager retention specialists work under the retention side of WIN THE WEEK — see the How Do We Win the Week? section on the Winning & Learning page for how their targets differ from sales specialists. Their contribution to the team''s rolling **SALES POINTS** threshold for unlimited PTO scales at 0.5x compared to a sales specialist. For example, a team of four Sales AMs and one Retention AM counts as 4.5 units against the threshold.'
)
WHERE title = 'Hours & Time Off';

-- Edit 5: Getting Paid — cut Account Manager status re-explanation in Group Health Eligibility
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'To qualify, you must:\n\n- Work full-time (30+ hours per week on a consistent basis), AND\n- Have reached **ACCOUNT MANAGER** status specializing in either sales or retention.\n\nAccount Manager status is a promotion given to **salaried** team members who have completed their **thirteen-week onboarding period** and have agreed with the existing team to take on the required level of **QUOTES** and **SALES POINTS** to **WIN THE WEEK**.\n\nOnce eligible, team members, their spouses, and their children may enroll in the benefits described here.',
  E'To qualify, you must:\n\n- Work full-time (30+ hours per week on a consistent basis), AND\n- Have reached **ACCOUNT MANAGER** status specializing in either sales or retention.\n\nSee the Thirteen-Week Onboarding Period section on the Your Path page for how new hires reach Account Manager status.\n\nOnce eligible, team members, their spouses, and their children may enroll in the benefits described here.'
)
WHERE title = 'Getting Paid';

-- Edit 6: Getting Paid — fix stale references to "Winning, Learning & Getting Better" (page is named "Winning & Learning")
UPDATE public.handbook
SET content = REPLACE(content, '*Winning, Learning & Getting Better*', 'Winning & Learning')
WHERE title = 'Getting Paid';
