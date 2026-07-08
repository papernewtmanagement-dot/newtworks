-- 20260707205346_add_icon_column_to_manuals

ALTER TABLE public.handbook    ADD COLUMN IF NOT EXISTS icon TEXT;
ALTER TABLE public.processes   ADD COLUMN IF NOT EXISTS icon TEXT;
ALTER TABLE public.admin_pages ADD COLUMN IF NOT EXISTS icon TEXT;

COMMENT ON COLUMN public.handbook.icon    IS 'Emoji or short glyph rendered as the section icon in the manual sidebar. NULL = no icon. Rendered only at depth 0 in current UI.';
COMMENT ON COLUMN public.processes.icon   IS 'Emoji or short glyph rendered as the section icon in the manual sidebar. NULL = no icon. Rendered only at depth 0 in current UI.';
COMMENT ON COLUMN public.admin_pages.icon IS 'Emoji or short glyph rendered as the section icon in the manual sidebar. NULL = no icon. Rendered only at depth 0 in current UI.';
