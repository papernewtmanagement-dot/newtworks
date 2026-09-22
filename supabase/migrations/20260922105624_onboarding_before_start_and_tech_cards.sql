-- Onboarding template, Peter 2026-09-22.
-- * On offer -> Before start. Friday before start and the now-empty
--   Once the alias is in cards removed.
-- * Softphone + call flow to the end of the Workspace column. Friday text
--   (renamed), Day 1 packet and Agent Tech Setup to the end of the left
--   column, which is renamed. Friday text and packet open on the Friday
--   before start.
-- * Day 1 -> Tech setup. The Tech setup card split into one card per
--   category. Login first; every other tech card and Weeks 1-2 wait on it.
--   Login carries the archived process as an alternative to its last line.
-- * Outlook card: Peter's Confluence copy kept word for word; the one line
--   from the old Outlook groups it did not already have is added.
-- * Jabber rebuilt from the Confluence Tech Setup page, with the speed-dial
--   reference as a pop-up. Other Tech Setup items the import dropped put back.
-- Template edits reach the open plans through trg_onboarding_templates_sync_plans.

UPDATE public.onboarding_phases
   SET name = 'Before start', stage = 'pre_start',
       blurb = 'Everything before Day 1. The Friday text and the Day 1 packet open on the Friday before they start.',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 10;

UPDATE public.onboarding_phases
   SET name = 'Tech setup',
       blurb = 'Log in first. The other tech cards and Weeks 1-2 open once Login is done.',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 50;

UPDATE public.onboarding_step_templates
   SET track = $t$Hiring, access and Day 1 prep$t$
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND track = 'Offer, checks and licensing';

UPDATE public.onboarding_step_templates t
   SET phase = 10, track = 'Workspace', track_order = w.track_order,
       sort_order = CASE t.template_key WHEN 't_softphone' THEN 40 ELSE 50 END
  FROM (SELECT track_order FROM public.onboarding_step_templates
         WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_order_equipment') w
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key IN ('t_softphone','t_call_flow');

UPDATE public.onboarding_step_templates t
   SET phase = 10, track = $t$Hiring, access and Day 1 prep$t$, track_order = l.track_order,
       title = CASE t.template_key WHEN 't_friday_call' THEN 'Send text Friday before start' ELSE t.title END,
       unlock_rule = CASE WHEN t.template_key IN ('t_friday_call','t_print_packet') THEN 'friday_before_start' END,
       sort_order = CASE t.template_key WHEN 't_friday_call' THEN 70 WHEN 't_print_packet' THEN 80 ELSE 90 END
  FROM (SELECT track_order FROM public.onboarding_step_templates
         WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_offer_signed') l
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key IN ('t_friday_call','t_print_packet','agent_tech_setup');

DELETE FROM public.onboarding_phases WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase IN (25, 40);

-- Login keeps the Tech setup row (and its key changes), the rest are new cards.
UPDATE public.onboarding_step_templates
   SET template_key = 't_login', title = 'Login', sort_order = 20,
       description = 'Do this first. The other tech cards and Weeks 1-2 open once it is done.',
       substeps = $j$[{"group": null, "items": ["Login with the login packet", "Follow Login packet steps to setup Yubikey"]}, {"group": "Archived", "alt_for": "Follow Login packet steps to setup Yubikey", "items": ["Enable New Workstation", "Setup Yubikey", "Setup Microsoft Authenticator"]}]$j$::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_tech_setup_page';

INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category, owner_kind, assigned_to,
   is_required, sort_order, is_active, substeps, blocked_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 't_vpn', $t$VPN$t$, NULL, 50, 'systems', 'new_hire', NULL, true, 30, true, $j$["Cisco Secure Client opened", "Dropdown set to Yubikey Agency (non California)", "Connect, then Accept"]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_windows_hello', $t$Windows Hello and Cloud Drive$t$, $t$W Drive or Cloud Drive refers to the following navigation inside of File Explorer: CloudDrive > WORKGROUP-AN123412 > WORKGROUP$t$, 50, 'systems', 'new_hire', NULL, true, 40, true, $j$["Windows Hello for Business set up", "Cloud Drive shortcut in place (CloudDrive, WORKGROUP-AN123412, WORKGROUP)"]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_taskbar', $t$Taskbar pins$t$, $t$Search for and pin the following programs$t$, 50, 'systems', 'new_hire', NULL, true, 50, true, $j$["File Explorer", "Outlook", "Teams", "Cisco Jabber", "Chrome", "Edge", "Cisco Secure Client (Yubikey Agency non-California)", "Snipping Tool", "Calculator", "Voice Recorder", "Philibert", "NAPS2 (in-office only)", "Paint", "Control Panel"]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_teams_channels', $t$Teams channels$t$, $t$Pin the following office categories and channels$t$, 50, 'systems', 'new_hire', NULL, true, 60, true, $j$[{"group": "Office", "items": ["General", "Leads/Activity", "Phones - Story", "Retention/Story"]}, {"group": "Personal Offices", "items": ["Daily Kickoff", "Peter's office", "Your own office", "Each other office"]}]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_bookmarks', $t$Bookmarks$t$, $t$Import the preset bookmarks$t$, 50, 'systems', 'new_hire', NULL, true, 70, true, $j$["Chrome: Ctrl+Shift+O > three dots > Import bookmarks > select file - Cloud Drive/Setup", "Edge: Ctrl+Shift+O > three dots > Import from Chrome > only check Favorites", "Edge favorites bar set to Always"]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_jabber', $t$Jabber$t$, $t$To search, type in the desired name or phone number. To create a custom contact: Gear > File > New > Custom Contact$t$, 50, 'systems', 'new_hire', NULL, true, 90, true, $j$[{"group": null, "items": ["Add new TM to Jabber of all other team members", "Speed dials added from the speed-dial reference"]}, {"group": "Office", "items": ["*Park (custom) - Work Phone 1: 113-0000, Work Phone 2-10: increment the last digit", "Search for the team, then add their cell phone numbers to their profiles"]}, {"group": "Speed dials - search if not already there", "items": ["Bank Call Center (Bank) - 1-877-732-4368", "Business Lines Response Center (BLRC) 1-855-275-2572", "Cat Claims Liaison (M-S, 7-7 CST) 1-844-824-1042", "CCC Support 1-877-889-2294", "Emergency Road Service and Tow Program (ERS/Tow) 1-877-627-5757", "Health Response Center (Health) 1-866-734-4584", "Initial Loss Reporting (ILR) 1-855-259-8568", "Investment Planning Services (IPS) 1-833-593-7109", "Life Response Center (Life) 1-877-543-3619", "Glass Only Claims (LYNX (glass)) 1-888-624-4410", "Personal Lines Contact Center (PLCC) 1-844-275-7522", "http://SF.com Tech Helpline 1-888-559-1922", "State Farm Payment Plan (SFPP) 1-888-311-7377"]}, {"group": "Speed dials - custom", "items": ["AFS Hotline 1-833-691-0399", "Life Questionnaire: 1-877-222-1754"]}, {"group": "Key People", "items": ["John Babiarz (SL)", "Jessica Carlos (ECRM Expert)", "Matt Warren (ECRM Coach)", "Jake Rodriguez (Business Lines Consultant)", "Kelly Oeding (Financial Services Liaison)"]}]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_printer', $t$Printer$t$, NULL, 50, 'systems', 'new_hire', NULL, true, 100, true, $j$["Click the desktop shortcut \"Add LAN Printer\"", "Printer A532561PCL01 added"]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_headset', $t$Headset$t$, NULL, 50, 'systems', 'new_hire', NULL, true, 110, true, $j$["Install headset software - Software Center > Applications > Plantronics Hub > Install", "Open that hub and fix settings for delay in activation"]$j$::jsonb, ARRAY['t_login']),
  ('126794dd-25ff-47d2-a436-724499733365', 't_other_tech', $t$Other tech setup$t$, $t$The photo release is a one-time thing for all images.$t$, 50, 'systems', 'new_hire', NULL, true, 120, true, $j$[{"group": null, "items": ["Setup ECRM Opportunity Lists: https://pjsagency.atlassian.net/wiki/x/BADAEg"]}, {"group": "Sign Photo Release", "items": ["ABS > Marketing > Advertising > Tools > Electronic Library > Launch EL tool", "Log in", "Click “My Photos”", "The form will pop-up to accept"]}]$j$::jsonb, ARRAY['t_login']);

UPDATE public.onboarding_step_templates
   SET sort_order = 80, blocked_by = ARRAY['t_login'],
       substeps = substeps || $j$[{"group": "Recurring invites", "items": ["Recurring invites accepted: Daily Kickoff, SCF Scorecard Review, Weekly Wrap-up"]}]$j$::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'outlook';

UPDATE public.onboarding_step_templates
   SET blocked_by = CASE WHEN 't_login' = ANY (COALESCE(blocked_by, '{}')) THEN blocked_by
                         ELSE array_append(COALESCE(blocked_by, '{}'), 't_login') END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 55;

-- The speed-dial reference from the Confluence Tech Setup page (Jabber Setup).
INSERT INTO public.onboarding_instructions (agency_id, substep_label, title, body_md)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'Speed dials added from the speed-dial reference', 'Speed-dial reference', $md$To search, type in the desired name or phone number. To create a custom contact: Gear > File > New > Custom Contact.

### Investing

**State Farm**
- Annuities: 877-543-3619,,2
- Big Case Life Underwriting: Kris Snow 309-763-1716 · Carson Williams 877-543-3619
- IPS Sales Support: 833-593-7109 (Mon - Fri, 8 am - 6 pm)
- Systems Experts: Jennifer Young 973-787-4956 (Philibert Expert) · Doug Black 309-763-2698 (Retirement Case/Money Guide Pro/Mutual Funds)
- 529 Plan Sales Desk: 800-321-7520

**American Funds**
- Sales Desk: 800-421-9900 (Mon - Fri, 7 am - 7 pm)
- David Ajuni: 210-474-2046 (Internal Wholesaler)

**Ascensus**
- SEP & SIMPLE IRAs: 855-537-9555
- IRA Services: 855-638-2936
- Individual 401(k) - Sales: 800-345-6363,,1
- Greg Matrangola: 866-477-3699 (Internal Sales Consultant, Texas)
- Yen Nguyen: 713-724-377 (Regional Vice President, South Texas)

**BlackRock**
- Sales Desk: 833-357-5170 (Mon - Fri, 7:30 am - 5:30 pm)
- Amira Jabrine: 609-454-7173 (Internal Wholesaler)

**Jackson National**
- Jackson - Sales Desk: 800-777-7900
- Jackson - Service Desk: 800-766-4683 (My Producer #: 212-1487)
- Chris Teague: 615-236-5534 (Advisory Integration Consultant, Money Guide Pro Wiz)
- Cameron Shulte: 281-627-5970 (External Wholesaler, helps sell Jackson)
- Jessie Wolfe: 615-205-9286 (Internal Wholesaler, helps figure out Jackson)
- Customer Trades: 800-644-4565 (ask for the trades department)

### Banking

- US Bank - Agent Sales Hotline: 800-727-8551,,,,,,,,,,,,,,,1 (Support opt. 1, for Consumer Checking, Savings, CDs, IRAs)
- US Bank - Amy Voss-Girlinghouse: 405-880-6865, amy.voss@usbank.com (South Central Market Area Field Specialist)

### Gainsco

- Agent Policy Support (underwriting, policy service, and accounting): 855-734-2467, Monday - Friday 8 a.m. - 6 p.m. CT
- Agent Sales Support (appointment, training, and sales): 866-805-1344, Monday - Friday 8:30 a.m. - 5:00 p.m. CT, SFSalesSupport@GAINSCO.com
- Agent Technical Support: 877-594-9742, Monday - Friday 7 a.m. - 6 p.m. CT
- Claims Department: 866-424-6726, Monday - Friday 7 a.m. - 7 p.m. CT, Claims Reporting 24/7
- Policyholder Customer Service (billing, payments, policy questions, no endorsements): 866-424-6726, Monday - Friday 8 a.m. - 6 p.m. CT
- https://sfnet.opr.statefarm.org/agency/resources/strategic_alliance_opportunities/index.shtml
$md$)
ON CONFLICT (agency_id, substep_label) DO UPDATE
  SET title = EXCLUDED.title, body_md = EXCLUDED.body_md;

