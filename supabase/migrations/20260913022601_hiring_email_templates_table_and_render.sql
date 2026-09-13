-- Hiring email templates: one editable row per letter the hiring process sends.
-- Before this, the wording lived in two SQL functions and one edge function,
-- so Peter could not read or change a letter without a code change.
-- Seeded verbatim from the live copy. The senders now read from this table.

CREATE TABLE IF NOT EXISTS public.hiring_email_templates (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id    uuid NOT NULL,
  template_key text NOT NULL,
  title        text NOT NULL,
  stage        text NOT NULL,
  sort_order   int  NOT NULL DEFAULT 0,
  subject      text NOT NULL DEFAULT '',
  body_html    text NOT NULL,
  tokens       text[] NOT NULL DEFAULT '{}',
  description  text,
  sent_when    text,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_by   uuid
);

CREATE UNIQUE INDEX IF NOT EXISTS hiring_email_templates_key_uniq
  ON public.hiring_email_templates (agency_id, template_key);

ALTER TABLE public.hiring_email_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS het_read  ON public.hiring_email_templates;
DROP POLICY IF EXISTS het_write ON public.hiring_email_templates;

CREATE POLICY het_read ON public.hiring_email_templates
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY het_write ON public.hiring_email_templates
  FOR UPDATE TO authenticated
  USING      (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

DROP TRIGGER IF EXISTS trg_hiring_email_templates_updated_at ON public.hiring_email_templates;
CREATE TRIGGER trg_hiring_email_templates_updated_at
  BEFORE UPDATE ON public.hiring_email_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Render one letter: pull the row, swap every {{token}} for its value.
-- Values arrive already HTML-escaped where they are candidate-supplied.
CREATE OR REPLACE FUNCTION public.render_hiring_email(
  p_agency_id uuid,
  p_key       text,
  p_vars      jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(subject text, body_html text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_subject text;
  v_body    text;
  v_key     text;
  v_val     text;
BEGIN
  SELECT t.subject, t.body_html INTO v_subject, v_body
  FROM public.hiring_email_templates t
  WHERE t.agency_id = p_agency_id AND t.template_key = p_key;

  IF v_body IS NULL THEN
    RAISE EXCEPTION 'hiring email template "%" not found', p_key;
  END IF;

  FOR v_key, v_val IN
    SELECT key, value FROM jsonb_each_text(COALESCE(p_vars, '{}'::jsonb))
  LOOP
    v_subject := replace(v_subject, '{{' || v_key || '}}', COALESCE(v_val, ''));
    v_body    := replace(v_body,    '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  subject := v_subject;
  body_html := v_body;
  RETURN NEXT;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.render_hiring_email(uuid, text, jsonb) TO authenticated, anon, service_role;