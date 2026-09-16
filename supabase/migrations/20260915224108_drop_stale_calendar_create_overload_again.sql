-- The version that took an event id is gone: changing an event goes through
-- calendar_patch_event_now now. One create function, one patch, one delete.
DROP FUNCTION IF EXISTS public.calendar_create_event_now(uuid,text,text,text,timestamptz,timestamptz,text[],text,boolean,boolean,text);
