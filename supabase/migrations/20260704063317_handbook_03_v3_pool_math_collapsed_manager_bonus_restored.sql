-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-04 06:33:17 UTC (ledger name: handbook_03_v3_pool_math_collapsed_manager_bonus_restored) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260704063317.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Handbook 03 Bonuses & Pay v3: pool-split math wrapped in <details>, Manager Bonus section restored
-- Also correct the open_questions entry that said "currently stripped in v2"
-- 2026-07-04

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

Your share is a blend of two things:

- **Your Sales Points (65% weight)** — what you personally produced this quarter through your P&C and L&H rates.
- **Your Retention Hours (35% weight)** — how much of your working time counts as book-service work, adjusted for role, location, tenure, and licenses held.

Everyone participates in both. Producers still earn retention hours for the time they spend helping the book. Retention team members still earn sales points when they contribute to a sale. There's no artificial wall.

<details>
<summary>Show me the math</summary>

**Sales Points share.** Your Sales Points share = your YTD Sales Points ÷ the team's total YTD Sales Points.

**Retention Hours share.** Every seat has a five-factor weighted-hours calculation:

| Factor | What it does | Values |
|---|---|---|
| **Hours** | Baseline for a full workweek | 40 hours |
| **Role** | Reflects how much of your hour is retention work | Reception (Account Associate): 1.00 · Account Manager (Acquisition or Inside Sales): 0.25 · Support / Owner: not in the pool |
| **Location** | Applied per shift | In-office: 1.00 · Remote: 0.75 |
| **Tenure** | Ramps weekly from your start date | Week 0: 0.00 · Week 13: 0.25 · Week 26: 0.50 · Week 39: 0.75 · Week 52+: 1.00 |
| **License** | Reflects what value-added work you can do for customers | Base 0.50 · +0.35 P&C · +0.10 L&H · +0.05 IPS · capped at 1.00 |

Your weighted hours = 40 × role × location × tenure × license. Your Retention Hours share = your weighted hours ÷ the team's total weighted hours.

**Final slice.** (0.65 × Sales Points share) + (0.35 × Retention Hours share).

Multiply that percentage by the bonus pool for the year → that's your annual bonus. Divide by 52 → that's what lands each week.

</details>

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

## Manager Bonus

If you hold a manager role, you receive a share of the agency's on-time Scorecard payout in addition to your pool share:

- **Unit Manager:** 0.1% of the agency's on-time Scorecard
- **Team Manager:** 0.2% of the agency's on-time Scorecard
- **Office Manager:** 0.3% of the agency's on-time Scorecard

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
    notes = 'v3 (2026-07-04): pool-split math wrapped in <details>/<summary> ("Show me the math"). Manager Bonus section restored with original percentages (UM 0.1% / TM 0.2% / OM 0.3% of on-time Scorecard) — tweak evaluation still pending per open_questions.'
WHERE id = '5269ab5a-e575-4287-9ea2-d529b19c90a6';

-- Correct the open_questions entry that mistakenly claimed the manager bonus was "currently stripped"
UPDATE public.persistent_memory
SET content = REPLACE(
      content,
      '(3) if kept, need section in 03 Bonuses & Pay describing it (currently stripped in v2)',
      '(3) restored in v3 handbook with original percentages — evaluate whether to keep as-is or scale under residual pool'
    ),
    updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';
