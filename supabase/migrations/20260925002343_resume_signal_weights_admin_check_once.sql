-- Same fix as board_resume_score_computed_column_and_admin_check_once, one table over.
-- resume_weighted_composite reads these 13 weight rows once per candidate, and the read rule
-- ran is_agency_admin() on every one of them: 524 candidates x 13 rows on each board load.
-- Wrapping it in a sub-select runs it once per read. Same meaning: the function takes no arguments.
ALTER POLICY anon_read_hiregauge_resume_signal_weights ON public.hiregauge_resume_signal_weights
  USING ((SELECT public.is_agency_admin()));
