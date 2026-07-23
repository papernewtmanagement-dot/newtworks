-- Ideas backlog: structured queue of pending ideas (scripts, training, process changes)
-- Same shape as open_questions. Contents get triaged: implement (fold into a manual page/rule) or reject.

CREATE TABLE IF NOT EXISTS public.ideas_backlog (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  domain TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','implemented','rejected','deferred')),
  priority TEXT DEFAULT 'normal' CHECK (priority IN ('urgent','normal','someday')),
  target_destination TEXT,
  resolution_note TEXT,
  source_page TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ideas_backlog_status ON public.ideas_backlog(agency_id, status);
CREATE INDEX IF NOT EXISTS idx_ideas_backlog_domain ON public.ideas_backlog(agency_id, domain);

CREATE OR REPLACE FUNCTION public.tg_ideas_backlog_updated_at()
RETURNS TRIGGER AS $tg_ideas_backlog_updated_at$
BEGIN
  NEW.updated_at = NOW();
  IF NEW.status IN ('implemented','rejected') AND OLD.status = 'pending' AND NEW.resolved_at IS NULL THEN
    NEW.resolved_at = NOW();
  END IF;
  RETURN NEW;
END;
$tg_ideas_backlog_updated_at$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tg_ideas_backlog_updated_at ON public.ideas_backlog;
CREATE TRIGGER tg_ideas_backlog_updated_at
BEFORE UPDATE ON public.ideas_backlog
FOR EACH ROW
EXECUTE FUNCTION public.tg_ideas_backlog_updated_at();

ALTER TABLE public.ideas_backlog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ideas_backlog_agency_isolation ON public.ideas_backlog;
CREATE POLICY ideas_backlog_agency_isolation ON public.ideas_backlog
  FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
