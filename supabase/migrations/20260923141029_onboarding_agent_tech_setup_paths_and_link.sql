-- Agent Tech Setup, Peter 2026-09-23: each click-path goes behind an (i) on
-- its line, one step per line; SurePayroll becomes the link text.
SELECT set_config('app.onboarding_template_sync', 'off', true);

UPDATE public.onboarding_step_templates
   SET substeps = '[
     {"group": "Outlook - set permission to “Editor” for the TM",
      "items": ["Named mailbox at top", "Shared folder", "Deleted folder - Set to “Contributor”", "Calendar - Main", "Calendar - Time Off (view only)"]},
     {"group": "Outlook Other",
      "items": ["Add to Local contacts", "Add to contact group, “My Office”", "Add their mailbox"],
      "item_info": {"Add their mailbox": ["My named mailbox", "Data File Properties", "Advanced button", "Advanced tab", "Add button", "Paste TM email"]}},
     {"group": "Add to Microsoft Teams Groups", "items": ["General", "Leads/Activity", "Phones"]},
     {"fill": "team_list", "group": "Add to team offices in Teams", "items": []},
     {"group": "Add to Systems",
      "items": ["NECHO", "Hot prospects", "[SurePayroll](https://secure.surepayroll.com), personal page, 2 num, spaces, unlimited chars"],
      "item_info": {"NECHO": ["Opt 9", "Opt 12", "Action A", "Alias", "Next", "F3"],
                    "Hot prospects": ["ECRM", "Search Groups", "NewHotProspectNotifications-YRRU", "Search Alias", "Add"]}}
   ]'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND template_key = 'agent_tech_setup'
   AND substeps = '[{"group": "Outlook - set permission to “Editor” for the TM", "items": ["Named mailbox at top", "Shared folder", "Deleted folder - Set to “Contributor”", "Calendar - Main", "Calendar - Time Off (view only)"]}, {"group": "Outlook Other", "items": ["Add to Local contacts", "Add to contact group, “My Office”", "Add their mailbox - My named mailbox > Data File Properties > Advanced button > Advanced tab > Add button > Paste TM email"]}, {"group": "Add to Microsoft Teams Groups", "items": ["General", "Leads/Activity", "Phones"]}, {"fill": "team_list", "group": "Add to team offices in Teams", "items": []}, {"group": "Add to Systems", "items": ["NECHO - Opt 9 > Opt 12 > Action A > Alias > Next > F3", "Hot prospects - ECRM > Search Groups > NewHotProspectNotifications-YRRU > Search Alias > Add", "SurePayroll, personal page, 2 num, spaces, unlimited chars - https://secure.surepayroll.com"]}]'::jsonb;

-- Ticks already made on the old lines carry to the new ones.
UPDATE public.team_onboarding_steps s
   SET substeps_done = (
     SELECT COALESCE(jsonb_agg(CASE d
         WHEN 'Add their mailbox - My named mailbox > Data File Properties > Advanced button > Advanced tab > Add button > Paste TM email' THEN 'Add their mailbox'
         WHEN 'NECHO - Opt 9 > Opt 12 > Action A > Alias > Next > F3' THEN 'NECHO'
         WHEN 'Hot prospects - ECRM > Search Groups > NewHotProspectNotifications-YRRU > Search Alias > Add' THEN 'Hot prospects'
         WHEN 'SurePayroll, personal page, 2 num, spaces, unlimited chars - https://secure.surepayroll.com'
           THEN '[SurePayroll](https://secure.surepayroll.com), personal page, 2 num, spaces, unlimited chars'
         ELSE d END), '[]'::jsonb)
     FROM jsonb_array_elements_text(s.substeps_done) d)
 WHERE s.template_key = 'agent_tech_setup'
   AND jsonb_typeof(s.substeps_done) = 'array'
   AND jsonb_array_length(s.substeps_done) > 0;

SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
