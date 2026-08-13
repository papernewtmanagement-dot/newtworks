-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-04 03:57:39 UTC (ledger name: handbook_pool_split_chargebacks_glossary_apparel_cc_move) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260704035739.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Handbook: pool-split math + chargebacks restored + glossary restored (pay refs stripped) + apparel/CC moved to 01 Benefits
-- Also: append $10 Bumps and Manager Bonus % as open questions
-- 2026-07-04

-- (a) Update 03 Bonuses & Pay with v2 content
UPDATE public.handbook
SET content = $bcc$> **Effective the week of July 11, 2026.** This is our new bonus-and-pay structure. It replaces the prior weekly-pay mechanics.

*A plain-English guide for team members and new hires.*

---

## The Big Idea

You share in what the agency earns. Every week. The more we grow, the more you take home. When you write great business AND we keep it on the books, everybody's check goes up together.

This isn't a "hit a bonus target once a year and hope" plan. It's weekly. It's transparent. You can see exactly where you stand.

---

## Your Paycheck Has Two Parts

### Part 1 — Your Base Salary
Steady, predictable, paid every pay period. This is your floor. It never moves down based on production.

### Part 2 — Your Weekly Bonus Share
This is the exciting part. It rewards two things: the business you write, and the business we keep.

---

## Where the Bonus Money Comes From

The agency pools money from four sources every week:

1. Every dollar of P&C commission (new AND renewal)
2. Every dollar of Life & Health commission (new AND renewal)
3. The variable commission State Farm pays us on top of P&C
4. The annual Scorecard bonus State Farm pays us

After we pay salaries, taxes, workers comp, health stipends, and running costs, **what's left over is your bonus pool.** Every week, the pool refills. Every week, we split it.

---

## How Your Slice of the Pool Gets Determined

Your share is based on two things, weighted **65 / 35**:

### Your Sales Points Share (65% weight)

What you personally produced this quarter, measured in dollars via your P&C and L&H rates on the business you write.

**Your Sales Points share = your YTD Sales Points ÷ the team's total YTD Sales Points.**

Write more (and higher-leverage) business, your share goes up. Write less, someone else's share goes up.

### Your Retention Hours Share (35% weight)

How much of your working time counts as "keeping the book alive" work. Every seat has a five-factor weighted-hours calculation:

| Factor | What it does | Values |
|---|---|---|
| **Hours** | Baseline for a full workweek | 40 hours |
| **Role** | Reflects how much of your hour is retention work | Reception (Account Associate): 1.00 · Account Manager (Acquisition or Inside Sales): 0.25 · Support / Owner: not in the pool |
| **Location** | Applied per shift | In-office: 1.00 · Remote: 0.75 |
| **Tenure** | Ramps weekly from your start date | Week 0: 0.00 · Week 13: 0.25 · Week 26: 0.50 · Week 39: 0.75 · Week 52+: 1.00 |
| **License** | Reflects what value-added work you can do for customers | Base 0.50 · +0.35 P&C · +0.10 L&H · +0.05 IPS · capped at 1.00 |

**Your weighted hours = 40 × role × location × tenure × license.**

**Your Retention Hours share = your weighted hours ÷ the team's total weighted hours.**

### The Final Slice

**Your slice = (0.65 × your Sales Points share) + (0.35 × your Retention Hours share).**

Multiply that percentage by the bonus pool for the year → that's your annual bonus. Divide by 52 → that's what lands each week.

Everyone participates in both. Producers still earn retention hours for the time they spend helping the book. Retention team members still earn sales points when they contribute to a sale. There's no artificial wall.

---

## How to Earn Sales Points

This is where your effort translates into money. Sales points come from two commission rates the agency pays you on the business you write:

### Your P&C Rate — Applied to Every Auto and Fire Policy You Write

**Starting rate: 0.07% of premium**

But here's the key: **you have to write at least $100 of Life premium in the quarter to unlock the P&C rate at all.** No Life = no P&C rate = no P&C bonus that quarter.

Once you clear that gate, three things enhance your rate — and every enhancement stacks:

| What you did | Rate goes up by |
|---|---|
| Every $100 of Life premium written | +0.07% |
| Every 6 Auto apps issued | +0.07% |
| Every 3 Fire apps issued | +0.07% |

The rate can climb all the way to **6%** — that's almost 100 times your starting rate.

### Your L&H Rate — Applied to Every Life Policy You Write

**Starting rate: 0.18% of Life premium**

Every $200 of Life premium you write adds another 0.18% to your rate. Cap is 18%.

### Why Life is the Star

Life production doesn't just pay you the L&H rate on the Life policy itself. It also:
- Unlocks your P&C rate (Entry Point)
- Amplifies your P&C rate (every $100 of Life)
- Amplifies your L&H rate (every $200 of Life)

**One Life policy pays you three ways.** That's why writing Life makes every other policy you write worth more.

---

## Why This Design Works For You

**No Clawbacks.** When a policy lapses, you don't have money pulled back out of your check. The pool naturally adjusts — the renewal income drops, so next week's pool is a little smaller. But nobody comes to collect from you personally. Your paycheck is your paycheck.

**Auto and Fire Are Their Own Reward.** The more Auto and Fire you write, the more P&C premium you have earning your rate. You don't need to trigger enhancements to make Auto and Fire worth writing — every policy adds to what you're already earning.

**Growth Compounds Everyone's Check.** When we grow the book, the pool grows. When the pool grows, everyone's share grows. Your teammate's win is your win. Nobody is competing for a fixed piece — we're building a bigger pie together.

**Retention Matters as Much as Sales.** Every policy you keep on the books stays in the pool basis for the next year and every year after. The team member who writes 100 policies and keeps 90 of them contributes more to the pool than the team member who writes 120 and keeps 70.

---

## What a Great Week Looks Like

**A team member writes:**
- $400 Life premium (2 policies)
- 12 Auto apps
- 6 Fire apps

**Their enhancement triggers:**
- Life: 4 triggers (2 policies × 2 triggers each at $100)
- Auto: 2 triggers (12 apps ÷ 6)
- Fire: 2 triggers (6 apps ÷ 3)
- **Total: 8 triggers × 0.07% = 0.56% P&C rate this quarter**

Their L&H rate: 0.18% starting + 2 enhancements ($400 ÷ $200) × 0.18% = **0.54%**

Every $10,000 of Auto and Fire premium they write pays them $56 in P&C sales points. Every $10,000 of Life premium they write pays them $54 directly, PLUS boosts their P&C rate for the whole quarter.

Do that consistently for 12 weeks and their rates climb dramatically. **This plan rewards steady production more than heroic weeks.**

---

## The Bottom Line

- **Life production drives everything.** Life makes Auto and Fire worth more. Life is the highest-leverage activity you can do.
- **You share in the whole business.** New policies, renewals, State Farm variable comp, State Farm bonus — all of it flows into the pool.
- **You get paid every week.** Not once a year. Not deferred. Every Friday.
- **Nobody claws back your money.** The system self-adjusts.
- **The agency's growth is your raise.** No annual reviews needed to see it in your check.

Write great business. Keep it on the books. Watch your check grow.

---

## Employment Referral Bonus

If you know someone who would be a good fit for the agency, they should fill out an application and you should recommend them to Peter.

If the referral is hired, you'll receive a **$1,000 bonus** when the new hire completes their 13-week training program and becomes an Account Manager. Additionally, you'll receive a **$50 bonus every week** after that until the referral's first work anniversary.

---

## Chargebacks

When a policy cancels in its first policy period, State Farm charges the agency back for the commission on that policy. The first policy period is six months for Auto and twelve months for everything else. Chargebacks are pro-rated to account for earned premium.

**Chargebacks do not come out of your paycheck.** Under the residual-pool structure, no one claws money back from you personally. But chargebacks DO reduce the agency's commissions, which reduces the pool basis — so tracking them accurately matters to the whole team.

Chargebacks count for the quarter when the policy is recorded as lost to the agency. If a customer cancels on December 31st, it counts for that quarter.

The list of policy cancellations is included in the CPR report but may not be all-inclusive. If you know of a policy that was canceled but overlooked, handle the chargeback anyway.

Sometimes policies get listed as canceled but immediately get payment and come back — those are not chargebacks. They are also not new sales. Replacing a policy in its first policy period either won't count for the new writing OR will cause a chargeback of the prior policy. This includes a policy in its first year that lapsed and is rewritten. If a team member writes a policy and then leaves and someone else has to rewrite it, we always assume the person who left would be charged back.

ALL rewrites should be done appropriately and with the customer's best interests in mind. Gaming of the system is never tolerated.

All chargebacks should be recorded in Whiteboard for both count and premium. If the actual policy can be removed or edited to reflect the current quarter, that's ideal. Otherwise, remove the appropriate premium and count from other policies issued in the current quarter. When a Whiteboard record is edited this way, place a CB next to the customer's name.

**Chargebacks run on the honor system now.** Peter no longer audits chargebacks. Stay on top of yours — pool-basis accuracy depends on it, and the whole team benefits when everyone tracks honestly.

---

## Tracking

All qualifying production must be recorded in ECRM. If it isn't in ECRM, it didn't happen. Your Sales Points are computed from what State Farm has paid the agency — not from self-reported activity — so the ECRM record is what feeds everything downstream.

---

## Glossary

**APPLICATION** — Each fully **PAID, SUBMITTED, & ISSUED** application counts. Any application that is paid and submitted online does not count. Added auto policies always count. Added and replaced fire policies count as long as they are not in the first policy period.

- **Auto:** Each auto on an application receives one count. Autos will typically issue instantly. Replaced autos should always be handled by the retention team and should never have an opportunity associated. They are treated as a policy change and nothing more. Replaced autos do not count.
- **Fire:** Nothing changes on the definition of **PAID, SUBMITTED, & ISSUED** if a home policy is going through Escrow and they aren't closing on it until a later date.
- **Health:** Health applications count per insured per policy type.
- **Life:**
  - Life applications count per insured in a sixty day period.
  - Term to permanent conversions count per insured in a sixty day period, regardless of new applications being submitted during that time.
  - If a term life policy has reached its first anniversary date, converting it to a permanent policy gets a count and any increase of premium is recorded. When a conversion happens, we must still wait for it to be **PAID, SUBMITTED, & ISSUED**.
  - If a life policy has been in force for more than one year and is replaced and the new policy's death benefit increases by the new policy type's minimum benefit amount, it gets a count and any increase of premium is recorded.
  - Preferred health rating counts preferred premium.
  - Table rating counts standard premium for commission.
  - Single-pay policy premiums and other lump sum policies are treated as annuities and divided by 10.
- **Shadow:** Shadowing counts for applications at all times. If a new team member shadowed the sale AND shadows the process of getting a policy issued (life exam, etc.), they can count the sale.

**APPOINTMENT** — An APPOINTMENT is set when a team member schedules an escalated sales appointment with a customer. Only the following types count:

- Welcome appointment
- Any review appointment (claims, life, auto, home, etc.)
- Any escalated sales appointment (need/want help for joint appointment)

When the customer reschedules or we reschedule, it does not count again. When the customer cancels and we reinitiate and reschedule, it counts again. Only one appointment set per household is counted each week.

When a TM pivots and passes the quote conversation to a more capable co-worker, the person who set up the appointment gets credit for the appointment.

All appointments must be manually entered in Whiteboard.

**PREMIUM** — Full premium from the initial policy value: six months for auto and twelve months for fire, life, and health policies. Annuities, single-pay life policies, certificates of deposit, and other lump sum payments are divided by 10 before entering their premium into ECRM.

**REFERRAL** — A REFERRAL is counted if any prospect with actual intent to shop their insurance (not just as a favor to a team member) is received through any person without paying for it, once a proper household QUOTE using the agency-approved process has been discussed with the referral. Whoever got the referral information gets to record the referral. This includes referrals from Peter — they count for Peter and not for the person who discussed the quote with them.

**REVIEW** — A REVIEW counts if it's a new review posted to Google, Facebook, or YELP by a user account that has not left us one in the past on that site. The review must not get taken down by the customer or the platform.

---

*Ask Peter or your manager to walk you through the sales points dashboard. It shows exactly where you stand, updated daily.*
$bcc$,
    updated_at = NOW(),
    fetched_at = NOW(),
    notes = 'v2 (2026-07-04): pool-split math added (65/35 SP+RH with 5-factor weighted hours table). Chargebacks restored (no pay clawback, honor-system Whiteboard tracking). Glossary restored full — APPLICATION/APPOINTMENT/PREMIUM/REFERRAL/REVIEW — pay refs stripped from APPOINTMENT (no points-earned language), REFERRAL (no bonus-splitting), REVIEW (no bonus-splitting). Apparel + Champions Circle moved to 01 Benefits.'
WHERE id = '5269ab5a-e575-4287-9ea2-d529b19c90a6';

-- (b) Update 01 Benefits — add Apparel + Champions Circle before Table of Benefits
UPDATE public.handbook
SET content = $bcc$**Eligibility**

Once eligible, team members, their spouses, and their children may enroll in the benefits described here. In order to qualify for these benefits, team members must work full-time (30 hours or more per week on a consistent basis) and have reached **ACCOUNT MANAGER** status specializing in either sales or retention. This status is a promotion given to **salaried** team members who have completed their initial **thirteen-week** onboarding period and have agreed with the existing team to take on the required level of **QUOTES** and **SALES POINTS** in order to [WIN THE WEEK](#04+Win+the+Week).

**Medical, Dental, & Vision Insurance**

Unless team members have a qualified change in status, they cannot make changes to the benefits selected until the next open enrollment period. Qualified changes in status include: marriage, divorce, legal separation, domestic partnership status change, birth or adoption of a child, change in child’s dependent status, death of spouse, child or other qualified dependent, change in residence due to an employment transfer for the team member, their spouse or domestic partner, commencement or termination of adoption proceedings, or change in spouse’s or domestic partner’s benefits or employment status.

**Dental & Vision:** The agency covers **50%** of each team member’s **individual** premium on the available group dental and vision plans. Team members may opt to pay for the remaining 50% or to forgo these coverages. Team members may also choose to cover their spouse and family without any contribution from the agency.

**Medical:** The agency covers a portion of the premium on the group health plan selected by each team member. Team members may opt to pay for the remainder or to forgo this coverage.

All dental, vision, and major medical premiums are paid by the agency at the beginning of the month through the end of the month. If a team member’s employment terminates, their coverage will extend through the end of the month in progress at time of termination. Their final check will have a deduction for all remaining team member contributed premiums for that month, as well as a prorated deduction for agency-paid premiums.

Download the file below to compare available plans and complete an application.

See the maximum agency contribution table for medical insurance at the bottom of the page.

**Life Insurance**

Each team member receives a stipend toward individually owned life insurance on themselves or their immediate household. This is designed to double as life insurance that the team member controls and also a retirement plan should the team member select a permanent policy. The team member does not receive commissions and does not have any count attributed to their goals for this benefit.

The agency will own the payment account and use an agency credit card. If the monthly premium is greater than the allotted stipend, the total will be paid by the agency and the difference will be deducted from the team member’s paychecks.

See the maximum agency contribution table for life insurance stipend at the bottom of the page.

**Apparel**

Team members can select up to **$100 of State Farm branded apparel** paid for by the agency at each of the following milestones:

- Completing their 13-week onboarding period
- Celebrating an anniversary of having worked with the agency

**Champions Circle**

When the agency achieves Champions Circle, the agency hosts a celebratory dinner with plaques for all team members. Each team member also receives a commemorative gift customized by the team.

**Table of Benefits**

| Year of Employment | Max Medical Premium / Month | Max Life Insurance Stipend / Month |
| --- | --- | --- |
| Year 1  | $200 | $50  |
| Year 2  | $250 | $100 |
| Year 3  | $300 | $150 |
| Year 4  | $325 | $200 |
| Year 5  | $350 | $250 |
| Year 6  | $375 | $300 |
| Year 7  | $400 | $350 |
| Year 8  | $425 | $400 |
| Year 9  | $450 | $450 |
| Year 10 | $475 | $475 |
| Year 10+ | $500 | $500 |
$bcc$,
    updated_at = NOW(),
    fetched_at = NOW(),
    notes = 'Added Apparel + Champions Circle sections before Table of Benefits (2026-07-04). Moved from 03 Bonuses & Pay per Peter directive — these are benefits, not comp.'
WHERE id = '64a78cd2-3b85-4bfb-a514-5d28bf67f17c';

-- (c) Append two new open questions ($10 Bumps future formula, Manager Bonus % future design)
UPDATE public.persistent_memory
SET content = content || E'\n\n[OPEN 2026-07-04 — $10 Bumps programmatic wiring] Peter still plans to award $10 SP bumps programmatically as team members hit qualifying triggers. Not currently in the handbook — deferred pending formula insertion. Historical triggers list (from prior handbook version): Monday achievements (most HH quotes ≥3, first sale, most sales); post-week/CPR-confirmed achievements (agency Win the Week, personal 13-week avg SP improvement ≥1%, hitting an all-stars category, breaking a leaderboard record, first to reach a new Trailblazer Milestone). Decisions needed: (1) which of these triggers still apply under residual-pool comp; (2) do $10 bumps affect Sales Points directly (feeding pool share math) or a separate recognition track; (3) trigger detection surface — dashboard rule engine, weekly CPR compile, Telegram-bot detection; (4) new bumps table or override column on weekly_cpr_team_detail. Insert into formula in a later session.\n\n[OPEN 2026-07-04 — Manager Bonus % — keep or tweak] Peter wants to retain some form of Manager Bonus tied to agency on-time Scorecard even under residual-pool comp. Original mechanic (prior handbook): Unit Manager 0.1%, Team Manager 0.2%, Office Manager 0.3% of on-time Scorecard. Decisions needed: (1) keep percentages as-is or scale; (2) layered on top of pool share, or subtracted from pool basis before splitting; (3) if kept, need section in 03 Bonuses & Pay describing it (currently stripped in v2); (4) Peter as Owner + Marie as admin-backoffice fall outside (Owner not in comp math, Marie not in production per is_admin_backoffice rule). Design pass required before wiring or team-facing publication.',
    updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';
