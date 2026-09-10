UPDATE public.onboarding_step_templates SET
  title = 'Tech setup',
  description = 'Day 1, in this order. The Yubikey is already set up at the desk; the photo release goes with the photo.',
  substeps = '[
    {"group":"Login","items":[
      "Login sheet in hand",
      "Yubikey setup sheet in hand",
      "Logged in to the computer with the Yubikey"]},
    {"group":"VPN","items":[
      "Cisco Secure Client opened",
      "Dropdown set to Yubikey Agency (non California)",
      "Connect, then Accept"]},
    {"group":"Windows Hello and Cloud Drive","items":[
      "Windows Hello for Business set up",
      "Cloud Drive shortcut in place (CloudDrive, WORKGROUP-AN123412, WORKGROUP)"]},
    {"group":"Taskbar pins","items":[
      "File Explorer","Outlook","Teams","Cisco Jabber","Chrome","Edge",
      "Cisco Secure Client (Yubikey Agency non-California)","Snipping Tool",
      "Calculator","Voice Recorder","Philibert","NAPS2 (in-office only)",
      "Paint","Control Panel"]},
    {"group":"Teams channels — Office","items":[
      "General","Leads/Activity","Phones - Story","Retention/Story"]},
    {"group":"Teams channels — Personal Offices","items":[
      "Daily Kickoff","Peter''s office","Your own office","Each other office"]},
    {"group":"Bookmarks","items":[
      "Chrome: Ctrl+Shift+O, three dots, Import bookmarks, Cloud Drive/Setup",
      "Edge: Ctrl+Shift+O, three dots, Import from Chrome, favorites",
      "Edge favorites bar set to Always"]},
    {"group":"Outlook — signature","items":[
      "Signature template copied from W:/Setup/Signature",
      "HTML file personalized (see the naming rules on the shared drive)",
      "Photo swapped in the template folder",
      "Folder copied into %AppData%/Microsoft/Signatures",
      "Compose messages set to HTML",
      "State Farm signature set as default for new mail and replies"]},
    {"group":"Outlook — replies and groups","items":[
      "Automatic replies on, Outside My Organization text pasted in",
      "Contact group: My Office",
      "Contact group: My Office Extended",
      "Contact group: My Office Retention Only",
      "Contact group: My Office Extended + Retention"]},
    {"group":"Outlook — mailbox setup","items":[
      "Shared directory added (peter.story.yrru@statefarm.com)",
      "Reading pane no longer marks mail as read",
      "Inbox subfolders created: Peter, Notes, Info (Notes Leads, Marketing & Sales, MyBlock, Processes, Teams, Systems, Text, Other)",
      "Rules set on Peter, Notes, Notes Leads, MyBlock, Teams and Text",
      "Conversation History routed to Peter",
      "Recurring invites accepted: Daily Kickoff, SCF Scorecard Review, Weekly Wrap-up",
      "Calendar color-coded (optional)",
      "Report Phishing button present (PhishMe Reporter under Add-Ins)"]},
    {"group":"Jabber","items":[
      "Speed dials added from the speed-dial reference"]},
    {"group":"Printer","items":[
      "Add LAN Printer shortcut run",
      "Printer A532561PCL01 added"]},
    {"group":"Headset","items":[
      "Plantronics Hub installed from Software Center",
      "Headset settings adjusted for the activation delay"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_tech_setup_page';

-- The photo release belongs with taking the photo.
UPDATE public.onboarding_step_templates SET
  substeps = '["SurePayroll set up and time off applied","Group health enrollment","Photo taken for the email signature, photo release signed at the same time","Bio added to the microsite","Electronic Library team member updated","Added to call log reports, Teams groups, Whiteboard, NECHO and hot prospects","Welcome post on agency social"]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_agent_side_setup';
