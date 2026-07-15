-- Flip 1: Payment Processes absorbs Payment Script (Payment Processes is now canonical)
-- Flip 2: DSS absorbs DSS Tech Support (DSS is now canonical; Tech Support content nested in existing <details> block)
-- Delete: Core Statements orphan excerpt (0 callers)
-- All rows are content-only (no FK downstream) → hard DELETE per op-rule "Delete means DELETE"

-- 1. Payment Processes merge
UPDATE public.manuals
SET content = $c$## Always use this script:

Will you be paying with your State Farm Credit Card and saving 3% today?

Take payment

Send the credit card offer (get their social if you don't already have it)

I just emailed you something--let me know when you get it

Great! Go ahead and open it up.

Most of my customers use their State Farm Credit Card to pay their premiums so they can save even more on their monthly bill. There's no annual fee, and you can start saving 5% today. Is there any reason you wouldn't want to start saving that money today?



Determine how payment needs to be processed:$c$,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND lower(title) = 'payment processes';

DELETE FROM public.manuals
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND lower(title) = 'payment script';

-- 2. DSS merge (Tech Support content replaces the include marker inside the existing <details> block)
UPDATE public.manuals
SET content = $c$## Stats:

- Loss Ratio: 7% fewer claims
- Conversion: 13% higher
- Retention: 12% better
- Discount: 10-15% average



Verify that their phone is eligible:

Text SAVE to 78836

Spanish: Text AHORRO to 78836



[Why DSS? Infographic](https://sfnet.opr.statefarm.org/agency/training/rollout/drive_safe_save/pdfs/quick_stats_infographic.pdf)

[DSS Onboarding Infographic](https://collab.sfcollab.org/sites/WSS005447/AgcyMrktComm/Beacon Trial/Onboarding Infographic 9.25.19.pdf)

[FAQs](https://www.statefarm.com/customer-care/faqs/drive-safe-save)



<details>
<summary>Tech Support</summary>

If they call and ask if their app is reporting, assume that it is

- If it's just about not seeing a discount change, explain the basic discount formula
- If they aren't seeing trips

  - They don't always show immediately
  - Ask how long they're waiting for a trip to show
  - If trips aren't showing at all, follow the troubleshooting tips
- If the app isn't loading or has some other legitimate error, follow the troubleshooting tips



<details>
<summary>Setup Steps</summary>

Steps and Video to text to customers: [Drive Safe & Save® Mobile - State Farm®](https://www.statefarm.com/customer-care/download-mobile-apps/drive-safe-and-save-mobile)

1. Download the **State Farm** app by texting **SAVE** to 42407 or visiting the Google Play Store or Apple App Store.
2. Open the app and log in using your **State Farm user ID and password**.
3. Navigate to the **Drive Safe & Save** tab within the app.
4. Follow the on-screen instructions to enroll your vehicle. This may include accepting consent, verifying your email, and confirming your address for the Bluetooth beacon shipment.
5. Once you receive the **Bluetooth beacon** in the mail, take it to your car along with your smartphone.
6. Open the **State Farm** app and go to the **Drive Safe & Save** tab.
7. Tap **Complete Setup** for your car.
8. Press and hold the button on the beacon until it lights up (this may take up to 8 seconds).
9. Select the beacon ID in the app that matches the one printed on the side of your beacon.
10. Use the sticker on the beacon to adhere it to your windshield behind the rearview mirror. Ensure placement complies with local laws and does not obstruct visibility.
11. In some states, you may need to enter your car's **odometer reading** into the app. Follow the app's prompts if required.
12. Keep your phone's **Bluetooth** and **GPS** activated to automatically record trips.
13. Bring your phone on every trip to ensure accurate tracking and maximize your discount.

For assistance, contact **State Farm support** at 1-800-782-8332.

</details>



<details>
<summary>Troubleshooting</summary>

**For a new beacon or troubleshooting:** 1-888-559-1922

<http://st8.fm/dsstroubleshoot>

Reorder

**Download**

If you haven't already done so, please download the Drive Safe & Save app on your eligible iPhone or your smartphone running Android right away.

Play Store: <https://bit.ly/37lTuLr>

App Store: <https://apple.co/2sTdvKs>

**Connect**

Take the enclosed Bluetooth beacon to your vehicle. It enables your phone to collect driving data, so place it somewhere safe in your vehicle and leave it there.

**Set Up**

While you're in your vehicle (and not driving), tap on the Drive Safe and app icon on your phone and log in using your [statefarm.com](http://statefarm.com) user ID and password. The app will walk you through any necessary setup.

Troubleshoot:

- Is it actually setup for this car on our end?
- If the red light comes on at all on the beacon, then the beacon is fine

  - The red light does not need to stay on at all, just to come on momentarily while you press the in-app button
  - If the red light does not come on, they can:

    - [Pick up a new one from our office](https://sfamr.com/item/1273893) OR
    - [We can have a new one sent to their home](https://notesforms001.opr.statefarm.org/sff/agent/w0058420.nsf/postform?CreateDocument&sffid=155738)
- Restart the phone
- Log out of our app and log back in
- Go to Settings > Privacy > Permissions > Location > make sure DSS is allowed for location, physical activity, camera, storage
- Make sure you have the latest version of your operating system
- Make sure you have the latest version of our app (only available if your OS is updated)
- Uninstall and reinstall our app

**Drive**

Bring your phone on every trip and keep its GPS and Bluetooth enabled. Your trips will be recorded automatically – so there's no need to start the app manually or log in again. If you have any further questions, please call State Farm Internet Support at 888-559-1922.

</details>

</details>$c$,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND lower(title) = 'dss';

DELETE FROM public.manuals
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND lower(title) = 'dss tech support';

-- 3. Delete orphan Core Statements excerpt (0 callers, verified)
DELETE FROM public.manuals
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'excerpt'
  AND lower(title) = 'core statements';
