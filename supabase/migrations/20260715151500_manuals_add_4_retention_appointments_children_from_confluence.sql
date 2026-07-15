-- Migrate 4 Retention Appointments children from Confluence sources
-- Fixes broken [Included from: X] markers in Cancellation Process + Retention Appointments
-- Confluence source pages: Save Household 929464910, Save Life 1459060740, Review Policy 982581320, Review New Young Driver 1478033409
-- Parent in Confluence: 2717679617 (grouping page "Appointments", not in manuals)

INSERT INTO public.manuals (
  agency_id, manual_type, tree_root, title, content, content_format,
  source_url, confluence_page_id, parent_page_id, version, is_active
) VALUES
(
  '126794dd-25ff-47d2-a436-724499733365',
  'processes',
  'Checklists',
  'Save Household',
  $c$Hi <CUSTOMER>, <NAME> with Peter Story State Farm here. I'm just reaching out to get your feedback as you're headed out of our agency. When folks leave, they typically come back to State Farm. So I'd just like to take a few minutes to find out what we did well and what we could have done better so that when you do come back, we'll be able to take care of you that much better.

- So what did you like most about your time with our agency?
- And what could we have done to take better care of you?
- And what's got you thinking about switching?
- And who did you end up switching to?
  - Now we've had a few folks leave us for them, and most came back before long with two problems
    - Either the coverage was lower than advertised …
    - Or the price was higher than advertised …
    - Or both in some cases
  - I want to make sure they're taking care of you and giving you a fair deal
    - Can you please send me the declarations page they gave you?

Bring up what you've uncovered

- So I looked at your account before our call, and I noticed a few things.

If missing coverages:

- When I see exposures like this, I just want to make sure that customers are armed with the right information. What did <NEW INSURER> mention about that when you spoke to them?
- I would definitely bring that up with them. See what it means to be properly insured. In our experience, most folks only think about exposures when they have a claim, and our job is to think about it beforehand.

Well, we hate to see you go of course. But we're the number one insurer for a reason. Most folks end up coming back because our claims and service are just that much better--you get what you pay for. I'd love to call back when it gets close to your renewal, what time typically works better for you, mornings or afternoons?

Set task with all of this information, assigned to Account Manager by alphabet$c$,
  'markdown',
  'https://pjsagency.atlassian.net/wiki/spaces/PJSAGENCY/pages/929464910/Save+Household+-+Reception+Secondary+Checklists',
  '929464910',
  '2717679617',
  1,
  true
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  'processes',
  'Checklists',
  'Save Life',
  $c$Hi <CUSTOMER>, <NAME> with Peter Story State Farm here. I'm just reaching out to get your feedback as you're canceling the life insurance policy you've had with our agency. When folks leave, they typically come back to State Farm. So I'd just like to take a few minutes to find out what we did well and what we could have done better so that when you do come back, we'll be able to take care of you that much better.

- Did we explain it properly when we sold it?
- Did you feel pressured to buy something that you didn't really want?
- I see that you named <NAME> as your beneficiary. What changed to where you don't need to protect them anymore?$c$,
  'markdown',
  'https://pjsagency.atlassian.net/wiki/spaces/PJSAGENCY/pages/1459060740/Save+Life+-+Reception+Secondary+Checklists',
  '1459060740',
  '2717679617',
  1,
  true
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  'processes',
  'Checklists',
  'Review Policy',
  $c$## Cadence

- Every 6 months at AUTO RENEWAL
- Every year at HO renewal
- After a claim

If they reject one or some, that's fine, we can still review as many as possible during the reviews we do get


## Script

We scheduled <TIME> to review your <POLICY>. Is this still a good time for you?

Perfect! So we'll review your <POLICY> today, get you a refresher on coverages—what you have and what you don't have, and why it's important

And of course, at every renewal, we always expect SOME rate change

Sometimes rates go up, sometimes they go down—sometimes way down like during COVID!

It looks like this time, your rate is going <UP/DOWN>

Now corporate doesn't tell us WHY these rate changes happen—it's sort of like Coke's secret recipe

But we know that rates are affected by WHO, WHAT, and WHERE—who's being insured, what's being insured, and where it's located

The good news is, one of the things that makes State Farm #1 is that we do this review at every renewal to make sure you've got a refresher on your coverages and so we can look at both the accuracy and the quality of your policy

So let's take a look at your <POLICY>

| PIVOT | ACCURACY | COVERAGES |
| --- | --- | --- |
|  | Insured, Drivers, Birthdates, Address, Discounts, Surcharges | Go over the coverages from the auto or home below and use a cadence like this: <THIS> is what you have. <THIS> is why it matters. Most of my customers choose <THIS>. <THIS> is why it matters to YOU. How important is <THIS> to you? |


## Continue to product-specific review

Auto: see **Simple Auto FIT**

Home: see **Simple Home FIT**$c$,
  'markdown',
  'https://pjsagency.atlassian.net/wiki/spaces/PJSAGENCY/pages/982581320/Review+Policy+-+Reception+Secondary+Checklists',
  '982581320',
  '2717679617',
  1,
  true
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  'processes',
  'Checklists',
  'Review New Young Driver',
  $c$## Setup

Make first call at 15. This is a fact-finding call to see when the teenager will get their permit.

Schedule in-person appointment 6 months before teenager gets their license.

- At this appointment, set up annual review with a focus on the young driver, safety, risk and wealth management.
- Explain to parents that we want to coordinate with them and be an asset to their young driver.


## Talk-through outline

We're here to help—awareness, understanding, customization

- Cadence of reviews
- Coverages and exposures
- Accuracy then quality

Today's appointment

- Safety, save money now, save money in the future
- You've learned a lot of this
- Your parents probably repeat it
- We'll be an added voice in some cases, fill gaps in others

Vast majority of all accidents and lawsuits come from driving

- Road traffic injuries are the leading cause of death for children and young adults aged 5-29 years.

Law and safety

- Routine
  - Registration and inspection every year
  - Insurance—keep the ID card on hand, download our app
  - Check tires 4-8 weeks—pressure and tread
  - Change your oil on schedule
  - Don't ignore the check engine light
  - Keep a safety kit and a spare
    - Tow service with us
  - For routines, tell us when you've done it, and we'll set a reminder
    - Not a legal obligation
    - Just an added reminder as a courtesy
- Before you drive
  - Check yourself—tired, have you taken any substance or medication—legal or illegal?
    - Obviously, don't use illegal
    - If you do somehow accidentally, don't drive
  - Check your car—mirrors, gauges, etc.
  - Buckle up
- While driving
  - No substances
  - No devices
  - Give yourself distance
  - Also
    - Look ahead
    - Signal, Mirror, Over the shoulder, Go
- Stats:
  - Drinking super deadly
  - Texting is deadlier in some areas, and growing because more people are doing it
  - State Farm is trying to bring awareness to curb this
- Texas:
  - New drivers:
    - 18 or older with fewer than 6 months with a license OR
    - Under 18 at ANY time
    - NO mobile devices for any reason while driving, including hands-free usage
  - No driver can use a mobile device in a school zone
  - If you need to report an emergency, please pull over—technically legal, but why risk it?!?
  - Some cities, like San Antonio, will even limit use of mobile devices while temporarily stopped, this could be at a traffic light or in stand-still traffic
- What about maps?
  - If you don't have the map on a built-in dash screen, please get a mount that will keep the phone secure and remove all need to use your hands—you might have seen these with Uber drivers or taxis
  - If you have a mount, you might be tempted to answer texts since it seems "safer" now—don't do it!
- Summary:
  - It can be confusing and even overwhelming
  - Safest thing—don't touch your phone when in your car and the engine is running
  - Focus on the road 100%
- Distance is key
  - More time to
    - React
    - Handle something unexpected when you react
  - One car for every 10 miles per hour—includes stop lights!
  - You're TECHNICALLY at fault if someone rear-ends you and you hit the car in front of you
  - Don't overthink it—leave a lot of space when going fast
  - Cut your speed by a third in rain or snow

How to keep costs down now - discounts

How to keep costs down in the future

- who, what, where
- driving record, credit score, and history of stability
  - tickets: adjudication
  - credit card
  - deposits and investments
  - tenure policies—add to named insured or standalone$c$,
  'markdown',
  'https://pjsagency.atlassian.net/wiki/spaces/PJSAGENCY/pages/1478033409/Review+New+Young+Driver+-+Reception+Secondary+Checklists',
  '1478033409',
  '2717679617',
  1,
  true
);
