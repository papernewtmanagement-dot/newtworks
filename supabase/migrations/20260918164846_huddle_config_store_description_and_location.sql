ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS event_description text,
  ADD COLUMN IF NOT EXISTS event_location text;

COMMENT ON COLUMN public.agency_huddle_config.event_description IS
  'Body of the calendar invite, including the Microsoft Teams join block. Held here so that if the series ever has to be rebuilt the Teams details come back with it.';
COMMENT ON COLUMN public.agency_huddle_config.event_location IS
  'Location field on the calendar invite. Held here for the same reason as event_description.';

UPDATE public.agency_huddle_config
SET event_location = 'Microsoft Teams — https://teams.microsoft.com/meet/232945666872637?p=ifll4U8rLYDCGIjmwt',
    event_description =
'Microsoft Teams meeting
Join: https://teams.microsoft.com/meet/232945666872637?p=ifll4U8rLYDCGIjmwt
Meeting ID: 232 945 666 872 637
Passcode: tn6ra9XT

Need help? https://aka.ms/JoinTeamsMeeting?omkt=en-US
System reference: https://teams.microsoft.com/l/meetup-join/19%3ameeting_NzQ3MjcwZWQtY2U2Ny00ODZhLThlMmQtNjAwYTQ0ZDUyYjRh%40thread.v2/0?context=%7b%22Tid%22%3a%22fa23982e-6646-4a33-a5c4-1a848d02fcc4%22%2c%22Oid%22%3a%22639f1ef8-8030-41a9-9da1-2741340373dc%22%7d

Dial in by phone
+1 872-215-6947,,133974151# (United States, Chicago)
Find a local number: https://dialin.teams.cloud.microsoft/ecb7bbaa-b18a-4ba6-ae43-6240994b4234?id=133974151
Phone conference ID: 133 974 151#

Full agenda + weekly theme cycle lives in Newtworks:
https://newtworks.vercel.app/processes/daily-kickoff
'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
