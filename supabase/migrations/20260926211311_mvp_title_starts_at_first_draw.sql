-- Peter 2026-09-26: the most-valuable-player title lines up with the prize-cart draws.
-- It starts where the first draw starts (150 today), read from the same pay_scale rows, so the two can never drift.
DO $mig$
DECLARE v_src text;
BEGIN
  v_src := pg_get_functiondef('public.write_weekly_comp_v2(uuid,date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    'FROM deltas WHERE new_sp >= 100 ORDER BY new_sp DESC LIMIT 1;',
    'FROM deltas WHERE public.compute_mvp_prize_draws(p_agency_id, new_sp) > 0 /* title starts at the first draw (Peter 2026-09-26) */ ORDER BY new_sp DESC LIMIT 1;', 1);
  v_src := public.fn_source_replace_exact(v_src,
    '''no teammate had >= 100 new SP this week''',
    '''no teammate reached the first prize-cart draw this week''', 1);
  EXECUTE v_src;
END $mig$;

-- Handbook, Winning & Learning > Most Valuable Player: match the live rule (150 / 300 / 500).
DO $hb$
DECLARE v_c text; v_new text;
BEGIN
  SELECT content INTO v_c FROM public.manuals WHERE id = '0496c2de-fb44-41a5-8a3b-3542535e92a0';
  v_new := public.fn_source_replace_exact(v_c,
    'if they produced $100 or more in new **SALES POINTS**.',
    'if they produced $150 or more in new **SALES POINTS**.', 1);
  v_new := public.fn_source_replace_exact(v_new,
    '| $100 new **SALES POINTS** | 1 Draw |',
    '| $150 new **SALES POINTS** | 1 Draw |', 1);
  UPDATE public.manuals SET content = v_new, updated_at = now() WHERE id = '0496c2de-fb44-41a5-8a3b-3542535e92a0';
END $hb$;
