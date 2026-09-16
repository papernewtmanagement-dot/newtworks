-- Adding the event-id argument created a SECOND copy of each function rather
-- than replacing it: CREATE OR REPLACE cannot change an argument list. Drop the
-- older shapes so there is one of each, and no chance of a caller landing on
-- the version that can only create.
DROP FUNCTION IF EXISTS public.calendar_create_event_now(uuid,text,text,text,timestamptz,timestamptz,text[],text,boolean,boolean);
DROP FUNCTION IF EXISTS public.calendar_event_request(uuid,text,text,text,timestamptz,timestamptz,text[],text,boolean,boolean,boolean);
