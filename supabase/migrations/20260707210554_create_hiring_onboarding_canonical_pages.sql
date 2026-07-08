-- 20260707210554_create_hiring_onboarding_canonical_pages

-- Phase 1: 4 canonical onboarding pages under Admin/Hiring
-- Replaces content scattered across processes.Master Ramp, processes.Admin Setup,
-- processes.Tech Setup, and the two Rework pages.
-- Originals stay in place until Peter confirms deprecation.

INSERT INTO public.admin_pages
  (agency_id, title, content, content_format, parent_page_id, is_active, notes)
VALUES
(
  '126794dd-25ff-47d2-a436-724499733365',
  '07 Orientation',
  $md$# Orientation

Universal Day 1 through Week 1 content. Every new hire starts here.

## Welcome

Absorption week. No production expectations. Watch the videos, do the paperwork, get set up, shadow calls as they arise.

## The Ten

Ten short clips covering the philosophical frame of the agency. Watch all ten in Week 1.

### 1. Scripture as the frame — Know Your Why

Principle #1000. The floor.

[Simon Sinek — Know Your Why (Facebook)](https://www.facebook.com/share/v/oPaXS7zcYNHTZEUs/?mibextid=w8EBqM)

Homework: type out your why and send it to the agent.

### 2. Who we are

**VISION — Trusted.** We are the trusted resource for anyone who wants to protect and grow their assets and wealth.

**MISSION — Understand.** We understand people, and we help them understand what they have, what they don't have, and why it's important.

**CULTURE — Dignity.** We like people. We're positive, diligent, patient problem-solvers. We tell each other the truth with respect, communicate clearly, and treat every person with dignity.

**DUTY — Deliver.** We do what we say we will do. We trust our processes, hit our deadlines, and pursue our goals with focused energy.

### 3. Foundation of ethics

- Do what's right for the company, the agency, and the customer
- Don't fudge data. Don't skirt eligibility or rating.
- Offer what the customer needs even if they don't know they need it.

### 4. Eat the elephant + 20-mile march

- [How do you eat an elephant? (YouTube)](https://youtu.be/LZpAYmUpx44?si=2oKB3Wthv-Tcvk-m)
- [Jim Collins — 20 Mile March (C-SPAN)](https://www.c-span.org/clip/news-conference/user-clip-20-mile-march-jim-collins/5067394)

Breaking down big goals to weekly work. $100k income = 6 auto + 3 fire + 1 life each week.

### 5. Big rocks + 4DX

- [Put the big rocks first (YouTube)](https://www.youtube.com/watch?v=WG7R6XodW18)
- [4 Disciplines of Execution (YouTube)](https://www.youtube.com/watch?v=mP7sq_tGZj8)

### 6. Failure is fuel — Super Mario Effect

- [Super Mario Effect / Mark Rober TEDxPenn (Facebook)](https://www.facebook.com/GrowthTribeIO/videos/the-super-mario-effect-mark-rober-tedxpenn/3742136095839571/)
- [Failure reframe clip 1 (YouTube)](https://www.youtube.com/watch?v=xKd3MD4n6ng)
- [Failure reframe clip 2 (YouTube)](https://www.youtube.com/watch?v=pTKfaVzbpJ4)

Failure is data. Reframe rejection. Just because it's taking time doesn't mean it's not happening.

### 7. Volume negates luck

[Volume negates luck (YouTube Shorts)](https://www.youtube.com/shorts/fDm1KLlQ4wM)

The harder you work, the luckier you get. Seek to get 1% better every day.

### 8. Weekly goals math

$100k income target = 6 autos + 3 fire + 1 life per week (typical). See Handbook §Getting Paid for how this maps to your comp.

### 9. Health goals

It's not about hitting goals — it's about becoming the KIND of person who hits goals. See Handbook §Getting Paid — Health Development Program for the routine, the bonus, and the Fitbit setup.

### 10. 10-to-1 rule + Bug me + Kipling's "If"

Understand at a ten, explain at a one. That's how we help customers, and how the agent trains you.

If you want to go fast, go alone. If you want to go far, go with someone. Bug me if you want to succeed — tell me your obstacles so I can help.

> *"If you can keep your head when all about you are losing theirs..."*
> — Rudyard Kipling, "If"

We keep our head. We take responsibility. We do the work.

## Sales Fundamentals — Get a No & Gap Selling

Concepts:

- **Learn to get a no.** Set no goals — target a specific number of no answers per week.
- **Tactical empathy** — the yes-and technique.
- **Gap Selling / Jeremy Miner** — problem-awareness questioning.

Clips:

- [Rejection Therapy (YouTube — start at 4:20)](https://www.youtube.com/watch?v=ZFWyseydTkQ)
- [Set no goals (YouTube)](https://www.youtube.com/watch?v=SMiJeU7nU7k)
- [Don't stop until you get a no (YouTube — funny sale until 2:59, then go for no)](https://www.youtube.com/watch?v=UZTKFJ-xipw)
- [Learn to get a no #1 (YouTube)](https://www.youtube.com/watch?v=waTzPF4P6oY)
- [Learn to get a no #2 (YouTube — watch until 4:12)](https://www.youtube.com/watch?v=hjrmd-TSmbc)
- [Tactical empathy (YouTube)](https://www.youtube.com/watch?v=QIRk382yJm4)
- [Yes and (TikTok)](https://www.tiktok.com/@askvinh/video/7415565490170449173)
- [Yes and (YouTube Short)](https://www.youtube.com/shorts/il48SeduYOY)

Example questions to ask (not scripts to recite):

- *"Is this a bad time?"*
- *"Do you think insurance is a scam?"*
- *"Would it be ridiculous to get this started today?"*

These teach a mental frame. Hear "no" without flinching. Use the truth of the moment.

## Book replacement clips

Where the old onboarding required audiobooks, watch the summary clips instead. Optional: buy the book to dig deeper.

- **Fanatical Prospecting (Jeb Blount)** — Weeks 3-4 (AM). Summary clip: TBD (the agent to source).
- **Go for No (Waltz & Fenton)** — Weeks 5-8 (AM). Covered by the "Learn to get a no" clips above.

The full 12-month audiobook plan lives in Handbook §Winning & Learning — Skill Development Program. That plan is unchanged.

## Compliance Floor

**Unlicensed staff cannot quote, bind, or solicit insurance. Ever. Even to a friend. Even for information. Even "just to help someone out."**

Every team member action becomes the agent's contractual liability under the State Farm agency agreement. Skirting compliance isn't a personal choice — it's exposure that threatens the agency's ability to operate.

If a customer asks a coverage or pricing question and you're unlicensed, the answer is *"let me get you to someone who can help"* and you transfer to a licensed team member.

Signed compliance acknowledgment on file before end of Week 1.

## Newtworks introduction

Newtworks is home base for daily work: **newtworks.vercel.app**.

Modules the team uses daily:

- **Dashboard** — daily numbers snapshot
- **CPR** — Customer Performance Review, where scorecards land
- **Hours** — time clock in/out
- **Handbook** — agency policies (read + acknowledge required)
- **Processes** — training and process pages
- **Renewals** — renewals in your book
- **Scorecards** — Simple Conversation Fit Scorecards you fill

Log in with the email address the agent set up for you. Reset password on first login.

## SCF Scorecard

Every conversation gets a self-score. Rating scale:

- **1** — spoke words but that's about it
- **2** — average job
- **3** — great job

Cadence ramps with tenure:

| Tenure | Cadence |
| --- | --- |
| Weeks 1-8 | Scorecard and record every conversation |
| Weeks 9-13 | Scorecard and record every quote/review |
| Weeks 14+ | Scorecard at end of day and record one quote/review |

Day 1 includes a live walkthrough of the SCF Scorecard: what it measures, why we do it, how to fill it.

## Ask Ladder

**Coverage question:**

1. Navi search (don't chat yet)
2. Answers (Auto, Fire, Life, Modernized)
3. ABS sections + searching
4. Ask the office (senior team member first, then the agent)
5. Chat with the back office
6. Call the back office with permission

**Tech problem:**

1. Breathe
2. Believe it's working
3. Verify not user error
4. Verify source
5. Software reset
6. Navi search
7. Google
8. Ask office
9. Hard reset
10. Chat back office
11. Call back office

## Ongoing habits

- SCF Scorecard on every conversation (per cadence above)
- Complete Daily Wrap-up end of each day
- Contribute to team WIN THE WEEK
- Read + acknowledge handbook updates as posted
- Weekly coaching with the agent
$md$,
  'markdown',
  '2716663809',
  true,
  'Canonical onboarding — universal orientation. Replaces admin_pages.06 Orientation and processes.Master Ramp philosophical/orientation content. Phase 1 rewrite 2026-07-07.'
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  '08 Admin Setup',
  $md$# Admin Setup

The agent's checklist for setting up a new team member. Runs from post-interview through Day 1.

## After the interview

- [ ] Send Can They Sell Assessment
- [ ] Meet with Steve Suggs to review it
- [ ] Request references using the email template

## On offer — Reference Check & Next Steps email

Send the offer email with:

- Base salary confirmed
- Request for 3 professional references (former managers/supervisors ideal)
- Request for SSN, DOB, address (verbal — schedule a call)
- Instruction to terminate all appointments/authorizations with other insurers in all states

The email walks the new hire through:

**Schedule the exam.** [PearsonVue](https://home.pearsonvue.com/tx/insurance) → create account → select General Lines P&C and General Lines L&H → find test center → schedule.

**Study for the exam.** [Xcelsolutions](https://www.xcelsolutions.com/) with partner code **APSTORY** (drops to $189). Or ExamFX / WebCE / Kaplan alternate. Agency reimburses $189 for both licenses regardless of course.

**Take the exam** — go to testing center on scheduled date.

**Get fingerprinted.** [IdentoGO](http://www.identogo.com/) → Get Fingerprinted → Texas → Digital Fingerprinting → DOI code **11G6QF** → enter code from exam results page.

**Apply for license + provisional permit.** [Sircon](https://www.sircon.com/) → Apply for a license → New Insurance License → Resident → Individual → EIN **831295615**.

**Apply for Texas license** (if resident state is not TX). After resident state license issues, apply for TX through Sircon. Pay fee.

**Plan CE.** Calendar reminder = 1 year 10 months from the last day of birth month this year.

## Reference & background check

When they reply to the initial email:

- [ ] Check references
- [ ] Send background check through BIG
- [ ] Review BG check
- [ ] Submit Onboarding Form with Autopilot

## Two weeks before start date

**Request system access.** ABS → Office Admin → Team Resources → Agent & Agent Team Member Licensing → Agent Team Member System Access, Licensing and Agreement → [Step 2 — System Access / Alias Request](https://sfnet.opr.statefarm.org/agency/manuals/asr_dallas/licensing/index.shtml#step2) → [Agent Team Member System Access Request](https://app.asp.ic1.statefarm/system-access-request/new).

Need: SSN, DOB, languages, skill level.

- [ ] Order equipment (ABS → Forms → search "Agent Activity Order")
- [ ] Confirm one EXTRA laptop after accounting for new TM
- [ ] Don't forget a Yubikey

## Once they have an alias

**Set up the softphone.** ABS → [Agent Telephony Request](https://notesforms001.opr.statefarm.org/sff/agent/w0058420.nsf/postform?CreateDocument&back&sffid=155795) → Add Softphone / Create New Phone Extension → type in alias → click Lookup.

**Confirm workspace:**

- In-office: verify desk checklist
- Fully remote: Yubikey + VPN access request (VPN now auto-included with system access request)

## Once they have a softphone extension

- [ ] Add them to the Team List (with personal phone, email, address)
- [ ] Change the call flow — ABS → [Agent Telephony Request](https://notesforms001.opr.statefarm.org/sff/agent/w0058420.nsf/postform?CreateDocument&back&sffid=155795)

Call flow templates (broadcast / top-down / auto-attendant) live in a separate reference.

## Friday before start date

Call or text the new hire:

- Looking forward to kicking things off
- Please arrive by 8:30 am Monday with DL and SS card

If fully remote, send the fully-remote welcome email (template on file in the agent's Outlook).

## After the Friday call — print packet

- Login Packet (ABS → Agent Admin → Team Resources → Staff Setup & Registration; temp password changes on each print; set up Yubikey on the agent's computer PIN 3276)
- New Hire Documents (W drive → Team/Hiring/New Hire Documents)
- Yubikey Setup, Windows Hello for Business, Training Schedule printouts
- Annual Certification Form (ABS → Office Admin → Compliance → Annual Certification Form)

Former State Farm hires + fully remote hires: no packet. They call 1-877-889-2294 with their alias. The agent joins the call at some point to verify employment.
$md$,
  'markdown',
  '2716663809',
  true,
  'Canonical onboarding — admin setup (the agent side). Replaces processes.Admin Setup. Phase 1 rewrite 2026-07-07.'
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  '09 Tech Setup',
  $md$# Tech Setup

Day 1 tech setup for a new team member. Follow the sequence — check items off as you go.

## Login + hardware

- [ ] Login sheet in hand
- [ ] Yubikey setup sheet in hand
- [ ] Set up Yubikey on the agent's computer (PIN provided by the agent)
- [ ] Use the Yubikey to log in to your computer

## VPN

- [ ] Open Cisco Secure Client
- [ ] Dropdown: **Yubikey Agency (non California)**
- [ ] Click Connect → Accept

## Windows Hello for Business

- [ ] Complete Windows Hello setup

## Cloud Drive shortcut

W Drive / Cloud Drive path: `CloudDrive → WORKGROUP-AN123412 → WORKGROUP`

## Taskbar — pin these programs

Search each in Windows, right-click → Pin to taskbar:

- [ ] File Explorer
- [ ] Outlook
- [ ] Teams
- [ ] Cisco Jabber
- [ ] Chrome
- [ ] Edge
- [ ] Cisco Secure Client (Yubikey Agency non-CA)
- [ ] Snipping Tool
- [ ] Calculator
- [ ] Voice Recorder
- [ ] Philibert
- [ ] NAPS2 (scanning tool — in-office only)
- [ ] Paint
- [ ] Control Panel

## Microsoft Teams — pin these channels

Under Office:

- [ ] General
- [ ] Leads/Activity
- [ ] Phones - Story
- [ ] Retention/Story

Under Personal Offices:

- [ ] Daily Kickoff
- [ ] The agent's Office
- [ ] Your office
- [ ] Repeat for each other office

## Bookmarks

**Chrome:** Open Chrome → Ctrl+Shift+O → three vertical dots (top right) → Import bookmarks → Choose file → `Cloud Drive/Setup`.

**Edge:** Open Edge → Ctrl+Shift+O → three horizontal dots (top right) → Import favorites → Import data from Google Chrome → Favorites or bookmarks → Show Favorites Bar → Always.

## Outlook

**Signature:**

- [ ] Copy signature template from `W:/Setup/Signature`
- [ ] Edit the HTML file to personalize (name matters — see naming rules on the shared drive)
- [ ] Replace the photo in the template folder
- [ ] Copy the folder into `%AppData%/Microsoft/Signatures`
- [ ] File → Options → Mail → "Compose messages in this format" = HTML
- [ ] Click Signatures button → State Farm email → set as default for new + reply

**Out of Office:**

- [ ] File → Automatic Replies (Out of Office) → Send automatic replies
- [ ] "Outside My Organization" → paste this text:

> *Thanks for reaching out. Our office is open Monday-Thursday from 10-5. We'll get back to you once we're back in office. Thanks for trusting the agent State Farm to look after you. Have a great day!*

**Contact groups:**

- [ ] "My Office" = all account representatives + account managers
- [ ] "My Office Extended" = My Office + Marie Story
- [ ] "My Office Retention Only" = receptionists
- [ ] "My Office Extended + Retention" = My Office Extended + My Office Retention Only

**Shared directory:**

- [ ] Right-click your named mailbox at top → Data File Properties → Advanced → Advanced folder tab → Add
- [ ] Add `peter.story.yrru@statefarm.com`

**Preview without marking read:**

- [ ] File → Options → Mail → Reading Pane → uncheck "Mark item as read when selection changes"

**Subfolders + rules.** Create these under Inbox:

- [ ] the agent (rule)
- [ ] Notes (rule)
- [ ] Info: Notes Leads (rule), Marketing & Sales, MyBlock (rule), Processes, Teams (rule), Systems, Text (rule), Other
- [ ] Conversation History → auto-route to the agent

**Recurring meeting invites.** Ask the agent to invite you to:

- [ ] Daily Kickoff
- [ ] SCF Scorecard Review
- [ ] Weekly Wrap-up

**Optional: color-code Calendar** — Default gray, Admin lavender, Corporate red, Customer light green, Individual peach, Office orange, PTO yellow, Travel teal.

## Jabber

**Speed dials** — search or add custom contact (Gear → File → New → Custom Contact). Full speed-dial reference (State Farm departments, banks, allies, key people) lives on a separate reference page — ask the agent for the link.

## Printer

- [ ] Click desktop shortcut "Add LAN Printer"
- [ ] Add printer: `A532561PCL01`

## Headset

- [ ] Software Center → Applications → Plantronics Hub → Install
- [ ] Open Plantronics Hub → adjust settings for delay in activation

## Report Phishing button (if missing)

- File → Options → Add-Ins
- Look for "PhishMe Reporter"
- If under Active: click Go → check the box → OK
- If under Disabled: change dropdown at bottom to "Manage Disabled Items" → Go → select PhishMe Reporter → Enable → OK → close/reopen Outlook

## Photo release

- ABS → Marketing → Advertising → Tools → Electronic Library → [Launch EL tool](https://sfnet.opr.statefarm.org/cpt/credential.do?destination=TUXELIB)
- Log in → click "My Photos" → accept form (one-time for all images)

## Once you start + fill out paperwork

The agent will complete these on your behalf:

- [ ] SurePayroll setup + PTO applied
- [ ] Group health enrollment
- [ ] Photo taken for email signature
- [ ] Photo release signed
- [ ] Bio added to microsite
- [ ] eLibrary team member updated
- [ ] Added to call log reports, Teams groups, Whiteboard, NECHO, hot prospects
$md$,
  'markdown',
  '2716663809',
  true,
  'Canonical onboarding — tech setup (new hire side, drastically simplified). Replaces processes.Tech Setup. Speed dial reference tables extracted. Phase 1 rewrite 2026-07-07.'
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  '10 Onboarding Schedule',
  $md$# Onboarding Schedule

Your weekly ramp for the first 26 weeks. Different roles have different targets — find your column.

## Phase 0 — Before Day 1

Confirmed before you start:

- Offer signed
- P&C license on file (mandatory before starting — Reception exception if starting unlicensed with licensing front-loaded in Weeks 1-4)
- Welcome text from the agent received
- First-week schedule sent to you
- Yubikey ordered
- ECRM account provisioned
- Newtworks login created

## Phase 1 — Orientation Week (Week 1)

Absorption week. No production expectations. Shadow calls as they arise.

**All new hires this week:**

- [ ] Complete the Orientation page (The Ten, Sales Fundamentals, Compliance, Newtworks intro, SCF Scorecard walkthrough)
- [ ] Complete the Tech Setup page
- [ ] Sign compliance acknowledgment
- [ ] Paperwork: W-4, I-9, SF Annual Certification, Non-Compete, Payroll & Bio
- [ ] Workday: Info Security & Privacy Training, Anti-Money Laundering — U.S., Multiline Compliance, Product Overview, Life Insurance Illustrations
- [ ] Fill first SCF Scorecard as practice

**Reception:** answer inbound calls by 3rd ring, log every conversation in ECRM, attempt pivot on every eligible call, shadow 5 quotes.

**Account Manager:** shadow 5 quote opportunities, fill SCF on every conversation you sit in on.

## Ramp table

| Week | Reception (Retention) | Account Manager (Sales) |
| --- | --- | --- |
| 1-2 | Answer + observe. SCF on every conversation. Shadow 5 quotes. No individual SP target. | Pure shadow. 5 shadow quotes. Weekly SP pace fully shadow OK. |
| 3-4 | + Late-pay list outbound (2 blocks/wk, Tue/Thu 10-11am). Service inbox complete by 5pm. 2 welcome meetings/wk. Contribute to team quote target. | 75% shadow OK. First independent quotes expected. Contribute to team quote target. |
| 5-8 | + Auto/Home Review on renewal + 30 days for your alphabet-split book. Life Review for HH with 3+ P&C but no Life. Farewell Review on cancellations. 3-5 welcome meetings/wk. 5 HH outbound/wk. | 50% shadow. Team quote share ramping. 1 Life FIT/wk. |
| 9-13 | + Service-surge quoting begins. 5 HH Home Review + 5 HH Auto Review outbound/wk. Claims Review weekly. Contribute 2-3 quotes/wk to team WTW. | 25% shadow. Full AM quote share (15/wk). 2+ Life FIT/wk. Auto Loan Process ownership. |
| 14+ | Full retention role. Life Review 2+/wk. Monthly renewal audit. Weekly claims touch. Contribute 3-5 quotes/wk to team WTW. | Fully independent (escalated shadows count 50%). Full AM quote share (15/wk) + team WTW contribution. 3+ Life FIT/wk. Champions Circle pace (60+ Life items/year). |

Weekly SP pace, quote targets, and Life-included minimums all live in Handbook §Winning & Learning → How Do We Win the Week. This page shows the ramp curve; the handbook shows the target math.

## Daily role-play

**Reception, Weeks 1-4:**

- Simple Reception Pivot — 15 min with the agent or senior AM

**Account Manager, Weeks 1-13:**

- Watch Stairs & Buckets (~15 min)
- Simple Life FIT role-play with senior AM (15 min)
- Auto Lead Process — Through GNC role-play (15 min)

**All hires:** Complete Daily Wrap-up end of each day.

## Book replacement clips

Where the old plan required audiobooks, watch the summary clips on the Orientation page instead. Optional: buy the book to dig deeper.

- **Fanatical Prospecting (Jeb Blount)** — Weeks 3-4 (AM). Summary clip on Orientation page.
- **Go for No (Waltz & Fenton)** — Weeks 5-8 (AM). Covered by the "Learn to get a no" clips on Orientation.

The full 12-month audiobook plan (Handbook §Winning & Learning — Skill Development Program) is unchanged.

## Weekly coaching

Weekly 1:1 with the agent starting Week 2. SCF Scorecard review + process check.

## Code Red grace period

**Code Red** = a specific documented process was skipped. If a manager or coworker catches it: no cost. If the agent catches it: extra HH quote toward WIN THE WEEK.

Grace period reduces the penalty for new hires:

| Weeks since start | Extra quotes owed when the agent catches Code Red |
| --- | --- |
| 1-2 | 0 (grace) |
| 3-4 | 0.2 |
| 5-8 | 0.5 |
| 9+ | 1 (full veteran penalty) |

**Code Yellow** = poorly executed process or misinformation given to customer. No quote cost. Stop-everything correction moment.

Reference: Handbook §Winning & Learning — Error Alert.

## After Week 13 — remote device access

- Only agency-owned devices allowed
- Submit form: **State Farm Agent Owned Mobile Device Access**
- Follow [setup steps](https://sfnet.opr.statefarm.org/agency/manuals/technology/agency_mobile_setup_maintenance/blackberry_work_activate_setup.shtml)
- Get [activation key](https://sfnet.opr.statefarm.org/agency/manuals/technology/agency_mobile_setup_maintenance/get_new_act_key.shtml)
$md$,
  'markdown',
  '2716663809',
  true,
  'Canonical onboarding — schedule (Reception + AM side-by-side). Replaces ramp content from processes.New Reception Setup — Rework 2026-07 and processes.New Account Manager Setup — Rework 2026-07. Phase 1 rewrite 2026-07-07.'
)
RETURNING id, title, LENGTH(content) AS chars, parent_page_id;
