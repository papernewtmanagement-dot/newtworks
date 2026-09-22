-- Onboarding 2026-09-21: Set up laptop card, desk checklist trim, Day 1 packet trim,
-- Day 1 login steps rewritten, and pop-up instructions for sub-items.
-- Template edits reach every open plan through trg_onboarding_templates_sync_plans.

-- 1. Pop-up instructions for a sub-item, matched on the sub-item's label.
--    Labels are already the identity of a sub-item everywhere else (substeps_done),
--    so a live plan picks up an instruction the moment its label matches.
CREATE TABLE IF NOT EXISTS public.onboarding_instructions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id     uuid NOT NULL,
  substep_label text NOT NULL,
  title         text NOT NULL,
  body_md       text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, substep_label)
);
ALTER TABLE public.onboarding_instructions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS oi_read_agency ON public.onboarding_instructions;
CREATE POLICY oi_read_agency ON public.onboarding_instructions FOR SELECT TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));
DROP POLICY IF EXISTS oi_admin_write ON public.onboarding_instructions;
CREATE POLICY oi_admin_write ON public.onboarding_instructions FOR ALL TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
         AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role = ANY (ARRAY['owner','manager'])))
  WITH CHECK (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
         AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role = ANY (ARRAY['owner','manager'])));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.onboarding_instructions TO authenticated;
DROP TRIGGER IF EXISTS trg_touch_oi ON public.onboarding_instructions;
CREATE TRIGGER trg_touch_oi BEFORE UPDATE ON public.onboarding_instructions
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

INSERT INTO public.onboarding_instructions (agency_id, substep_label, title, body_md) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Enable New Workstation', 'Steps for Enabling a New Workstation', $md$To use these instructions you must have your Workstation Password. A new user should have their first time password supplied through the New Employee Packet. Managers can reprint the packet to reset the password if needed.

If a user has a replacement laptop and does not remember their password, they can reset it through the Security and Password Change site, https://s.f/spc, on their current computer.

If those options do not work, the support center will use the Verification and Change (VNC) tool to generate a new password.

1. **Step A.** Power on the new workstation and insert your Yubikey. Laptop users should NOT connect to the docking station at this time, to minimize installation issues.
2. **Step B.** Press CTRL + ALT + DEL to log on.
3. **Step C.** Click OK on the "Domain Policy Applied" message. Do NOT enter your logon credentials (User ID and Password) at this time.
4. **Step D.** Click the wireless icon in the lower right corner of the screen and connect to your personal wireless network.
5. **Step E.** Go to the lower right corner of the screen and click the network sign-in button (it looks like two monitors). This opens Cisco Secure Client.
6. **Step F.** Remove the default connection profile shown, using the backspace key. Then type in the right address for your domain. It is case-sensitive, and there must be no extra spaces at the beginning or end.
   - OPR users: sfus2.statefarm.com/oprmachine
   - AGCY users: sfus2.statefarm.com/agcymachine
   - ASD users: sfus2.statefarm.com/asdmachine
7. **Step G.** When prompted, type your 4- or 6-digit alias in the Username field, use the Workstation Password, and click OK.
8. **Step H.** If a temporary password was obtained from the Support Center, you will be prompted to change your password now. Enter the new password in the New Password and Verify Password fields and click Continue. You will need to remember this password later.
9. **Step I.** Click Accept. You are now connected to the State Farm network.
10. **Step J.** After you are connected to the VPN, you will be prompted to log in to the workstation. Click Sign-in options and select the password option (the key icon).
11. **Step K.** After signing in, find the Zscaler icon in the system tray in the lower right corner, or type "Zscaler" in the search bar. Click it and log in with your State Farm email and Workstation password. Confirm Zscaler is active by clicking Internet Security on the left and checking that Service Status is ON.
12. **Step L.** Lock your workstation with Windows key + L and unlock it using your Yubikey.
13. **Step M.** Disconnect your VPN by clicking Disconnect in Cisco Secure Client.
14. **Step N.** After disconnecting, click the drop-down menu and select the right Yubikey VPN profile:
   - OPR users: "Yubikey-Enterprise"
   - AGCY users: "Yubikey Agency (non California)"
   - ASD users: "Yubikey Agency (California)"
$md$),
  ('126794dd-25ff-47d2-a436-724499733365', 'Setup Yubikey', 'Setup Yubikey', $md$## Step 1 — Yubico Authenticator App Setup

1. Insert only the YubiKey you have picked as your primary YubiKey into the workstation. Make sure it is fully inserted. It should flash a green light.
2. From a State Farm workstation, open Microsoft Edge.
3. Copy myprofile.microsoft.com into the address bar and press Enter.
4. You may be asked to click Next on a screen that says More information required.
5. The "State Farm Terms of Use" page may appear. Agent team members do not see this and do not have to accept it. Only agents do. Read the "Terms of Use for Microsoft Authenticator" by clicking the right arrow, then click Accept.
6. You will land back on the Security info page. Click + Add method.
7. In the "Add a method" pop-up, choose Authenticator app from the drop-down and click Add.
   - On this screen you can choose Microsoft Authenticator instead. If you do not install Microsoft Authenticator on your phone, keep following these steps.
   - Microsoft Authenticator is not approved for agents who did not have Blackberry Work, or for agent team members on their personal phones.
8. On the "Set up your account" screen, click Next. A QR code will appear.
9. Click Start on the workstation. Scroll down to the Yubico Authenticator folder, click its down arrow, and open the Yubico Authenticator program.
10. If the app covers the QR code, drag it to the side. Click Add, or the + in the top right.
11. If the app asks you to scan the QR code by hand, make sure the code is showing and click Scan. If it does not ask, the code was scanned for you. Move on.
12. Your State Farm email address should now show in the app. Click Add.
13. Go back to the window with the QR code and click Next. The Enter code screen appears.
14. In Yubico Authenticator (on the taskbar), double-click the asterisks.
15. Immediately touch your YubiKey:
    - USB-C version (smaller): touch the gold tabs on the sides.
    - USB-A version (larger): touch the gold circle.
16. A six-digit code appears where the asterisks were. Right-click it and choose Copy to clipboard. Paste it into the Enter code field and click Next.
17. A green pop-up in the top right saying "Authenticator app was successfully registered" means Step 1 is done.

## Step 2 — YubiKey Enrollment: Primary Key

Registering your primary key with a PIN.

1. On the Security info page, click + Add method.
2. In the "Add a method" pop-up, choose Security key from the drop-down and click Add.
3. You may be asked to confirm it is you with your existing sign-in method. Click Next.
4. Open Yubico Authenticator from the taskbar (green square with a black lock). Double-click the asterisks to make a six-digit code.
5. Immediately touch your YubiKey:
   - USB-C version (smaller): touch the gold tabs on the sides.
   - USB-A version (larger): touch the gold circle.
6. Right-click the code and choose Copy to clipboard. Paste it into the Enter code field and click Verify.
7. On the "Security key" screen, choose USB device.
8. Have your YubiKey ready and click Next.
9. On "Windows Security – Security key setup", click OK.
10. On "Windows Security – Continue setup", click OK.
11. Your key should still be inserted from Step 1. Check that it is. Then on "Setting up your new sign-in method", click Next.
12. On "Windows Security – Making sure it's you", enter the PIN you want in the first box and again in the second box. Click OK. You will use this PIN every time you log in with your YubiKey. It must be at least four characters and can use numbers, letters and special characters.
13. When "Windows Security – Continue setup" appears, immediately touch your YubiKey. The same screen appears one more time. Touch it again.
14. Name your security key (for example, "YubiKey A"). Any name works. Click Next.
15. You can now use your YubiKey when asked to verify. Click Done.
16. Remove your primary YubiKey. Next is Step 3 in State Farm's instructions, YubiKey enrollment for the Backup Key.
$md$),
  ('126794dd-25ff-47d2-a436-724499733365', 'Setup Microsoft Authenticator', 'Microsoft Authenticator Mobile App', $md$## Overview

You need the Microsoft Authenticator mobile app to use State Farm internal apps, like My Mobile Office, and apps used for State Farm business, like Outlook and Teams.

For the same steps inside State Farm's own help, open the WalkMe Desktop Help Center on the desktop and search for "Setup MS Authenticator". It is in the Mobile Apps folder, under Step 1: Setup MS Authenticator.

You will switch between the workstation and the phone. Each step says which one to use.

## Download Instructions

If you get a replacement phone, try to set up Microsoft Authenticator on the new phone before shutting off the old one.

1. **Workstation:** Open your Microsoft profile. In the left menu, click Security Info. Click + Add sign-in method.
2. **Workstation:** In the pop-up, choose Authenticator app from the drop-down and click Add.
3. **Workstation and phone:** When prompted, download Microsoft Authenticator from the phone's app store, then click Next on the workstation.
4. **Phone:** Open the app, click through the introductions, and tap Add Work or School Account.
5. **Workstation:** Click Next to make a QR code.
6. **Phone:** Scan the QR code on the Security Info page with the phone's camera.
7. **Workstation:** A 2-digit number appears.
8. **Phone:** Enter that number in the app and tap Yes.
9. **Workstation:** Click Change next to the default sign-in method, choose Microsoft Authenticator – notification, and click Confirm.

Once Microsoft Authenticator is set up and is your default sign-in, you are done with this part.

## 2-Digit Authentication

For extra security, Microsoft uses a 2-digit number along with your password in the app. (See Passwordless below to drop the password and only enter the number.)

When asked to sign in through the app, enter your password first, unless you have set up Passwordless. If you forgot your password, contact Support after the first failed try. More wrong tries can make the reset take longer.

A pop-up then shows a 2-digit number. Enter it to finish. If you missed the number, tap "I can't see the number" (iPhone) or "Hide" (Android) to see it again.

## Passwordless Option

Passwordless removes the password prompt in the app. You still enter the 2-digit number.

Things to know:

- If you change phones, register Microsoft Authenticator on the new phone before turning on Passwordless there.
- Android phones can only have one account set to Passwordless. Agents with more than one office can only use it for their Legacy office.

Setup:

1. Open Microsoft Authenticator and tap your State Farm account.
2. Tap Enable phone sign-in.
3. Tap Continue.
4. Enter your workstation password and tap Sign in.
5. Tap Approve.
6. Tap Register, then Approve.

Passwordless is now on. The first time you sign in after this, choose "Use an app instead", then "Approve a request on my Microsoft Authenticator app". You will see the 2-digit screen and may be asked once for your PIN. After that, you only tap Send notification and enter the 2-digit number.
$md$)
ON CONFLICT (agency_id, substep_label) DO UPDATE
  SET title = EXCLUDED.title, body_md = EXCLUDED.body_md, updated_at = now();

-- 2. New card: Set up laptop. Alvi's. Opens with the desk checklist once equipment is ordered.
INSERT INTO public.onboarding_step_templates (
  agency_id, template_key, title, description, phase, category,
  applies_to_roles, applies_to_role_categories, applies_to_role_levels,
  is_required, sort_order, is_active, substeps, owner_kind, assigned_to,
  track, blocked_by, track_order)
SELECT agency_id, 't_setup_laptop', 'Set up laptop',
  'Get the new laptop ready before Day 1.', phase, category,
  applies_to_roles, applies_to_role_categories, applies_to_role_levels,
  is_required, 20, true,
  '[{"group":"Laptop","items":["Plug in your own Yubikey","Log in to Zscaler","Connect with VPN"]},{"group":"Headset","items":["Tested on system audio","Tested on Teams","Tested on a phone call"]}]'::jsonb,
  'admin', 'd7431075-d29f-4833-9503-430945894b04'::uuid,
  track, ARRAY['t_order_equipment'], track_order
FROM public.onboarding_step_templates
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup'
  AND NOT EXISTS (SELECT 1 FROM public.onboarding_step_templates
                  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_setup_laptop');

-- 3. Headset tests already ticked on a plan's desk checklist move with them to the new card.
UPDATE public.team_onboarding_steps l
SET substeps_done = COALESCE((
      SELECT jsonb_agg(d) FROM jsonb_array_elements(COALESCE(dk.substeps_done,'[]'::jsonb)) d
      WHERE d #>> '{}' IN ('Tested on system audio','Tested on Teams','Tested on a phone call')), '[]'::jsonb),
    updated_at = now()
FROM public.team_onboarding_steps dk
WHERE l.template_key = 't_setup_laptop' AND dk.template_key = 'p0_desk_setup'
  AND dk.plan_id = l.plan_id AND l.completed_at IS NULL;

-- 4. Desk checklist: headset tests moved out, laptop check moved out, Yubikey group gone.
UPDATE public.onboarding_step_templates
SET sort_order = 30,
    substeps = '[{"group":"Computing hardware","items":["Monitors x 2","Wireless mouse","Keyboard","Dock","Laptop","Webcam","All cables organized and tucked away"]},{"group":"Headset","items":["Headset with charging dock"]},{"group":"Desk supplies","items":["Pen cup","Branded pens x 5","Kleenex","Business card holder","Vertical file organizer"]},{"group":"Remote or travel bag (remote hires)","items":["Laptop bag","Laptop charging cable","Wired headset","Mouse"]}]'::jsonb,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

-- 5. Friday before start: New Hire Documents now done in Newtworks.
UPDATE public.onboarding_step_templates
SET substeps = '[{"group":"Login Packet","items":["Login Packet printed — ABS, Agent Admin, Team Resources, Staff Setup & Registration"]}]'::jsonb,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_print_packet';

-- 6. Day 1 tech setup: login runs off the login packet; the old way sits under Archived.
UPDATE public.onboarding_step_templates
SET description = 'Day 1, in this order. The photo release goes with the photo.',
    substeps = jsonb_build_array(
      jsonb_build_object('group','Login','items',jsonb_build_array('Login with the login packet','Follow Login packet steps to setup Yubikey')),
      jsonb_build_object('group','Archived','items',jsonb_build_array('Enable New Workstation','Setup Yubikey','Setup Microsoft Authenticator'))
    ) || (SELECT COALESCE(jsonb_agg(g ORDER BY o), '[]'::jsonb)
          FROM jsonb_array_elements(substeps) WITH ORDINALITY AS x(g, o)
          WHERE g->>'group' IS DISTINCT FROM 'Login'),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_tech_setup_page';

-- 7. A desk checklist whose only open sub-items were the ones moved out is now finished.
UPDATE public.team_onboarding_steps s
SET completed_at = now(), updated_at = now()
WHERE s.template_key = 'p0_desk_setup' AND s.completed_at IS NULL
  AND jsonb_typeof(s.substeps) = 'array'
  AND NOT EXISTS (
    SELECT 1 FROM unnest(public.onboarding_substep_labels(s.substeps)) lbl
    WHERE NOT (COALESCE(s.substeps_done,'[]'::jsonb) ? lbl))
  AND EXISTS (SELECT 1 FROM public.team_onboarding_plans p WHERE p.id = s.plan_id AND p.status IN ('active','paused'));
