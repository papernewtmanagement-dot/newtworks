-- Extract email/phone from resume_extracted_text into structured fields.
-- Trigger fires BEFORE INSERT/UPDATE on hiring_candidates whenever resume_extracted_text is written.
-- Only fills email/phone if they are currently NULL/empty — never overwrites Peter's manual fills.
-- Regex takes the FIRST match in the text (candidate's own contact info is almost always at the top).

CREATE OR REPLACE FUNCTION public.extract_resume_contact_info()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
  v_email text;
  v_phone text;
BEGIN
  IF NEW.resume_extracted_text IS NULL OR NEW.resume_extracted_text = '' THEN
    RETURN NEW;
  END IF;

  IF NEW.email IS NULL OR NEW.email = '' THEN
    v_email := substring(NEW.resume_extracted_text FROM '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
    IF v_email IS NOT NULL AND v_email <> '' THEN
      NEW.email := lower(v_email);
    END IF;
  END IF;

  IF NEW.phone IS NULL OR NEW.phone = '' THEN
    v_phone := substring(NEW.resume_extracted_text FROM '\+?1?[-. ]?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}');
    IF v_phone IS NOT NULL AND v_phone <> '' THEN
      NEW.phone := trim(v_phone);
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS extract_resume_contact_info_trigger ON public.hiring_candidates;

CREATE TRIGGER extract_resume_contact_info_trigger
BEFORE INSERT OR UPDATE OF resume_extracted_text
ON public.hiring_candidates
FOR EACH ROW
EXECUTE FUNCTION public.extract_resume_contact_info();

-- Backfill: no-op UPDATE fires the trigger, populates email/phone from existing resume text.
UPDATE public.hiring_candidates
SET resume_extracted_text = resume_extracted_text
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND resume_extracted_text IS NOT NULL
  AND resume_extracted_text <> ''
  AND ((email IS NULL OR email = '') OR (phone IS NULL OR phone = ''));
