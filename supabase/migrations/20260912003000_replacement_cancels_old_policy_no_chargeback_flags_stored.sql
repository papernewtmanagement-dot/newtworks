-- Peter 2026-09-11 (late): a confirmed replacement cancels the old policy automatically in the same Log click, with no
-- multiline chargeback (the household kept the line); the on-file answer (replaces / added / different household) is
-- stored on the sale; a repeat quote for the same household in the same week is marked on the My Week quote item.

ALTER TABLE public.sales_log ADD COLUMN IF NOT EXISTS on_file_answer text;
ALTER TABLE public.sales_log ADD COLUMN IF NOT EXISTS replaced_sale_product_id uuid;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS is_replacement boolean NOT NULL DEFAULT false;

-- rp_log_sale: store the on-file answer and the policy it replaced (payload: on_file_answer, replaced_sale_product_id)
DO $$
DECLARE d text; o1 text; n1 text; o2 text; n2 text;
BEGIN
  d := pg_get_functiondef('public.rp_log_sale'::regproc);
  o1 := 'marketing_source, gnc_used, vehicle_count, total_premium, note, created_by)';
  n1 := 'marketing_source, gnc_used, vehicle_count, total_premium, note, created_by, on_file_answer, replaced_sale_product_id)';
  o2 := 'v_src, v_gnc, NULLIF(v_veh_total, 0), v_total, v_note, a.actor_id)';
  n2 := 'v_src, v_gnc, NULLIF(v_veh_total, 0), v_total, v_note, a.actor_id, NULLIF(btrim(COALESCE(p->>''on_file_answer'','''')), ''''), NULLIF(p->>''replaced_sale_product_id'','''')::uuid)';
  IF position(o1 in d) = 0 OR position(o2 in d) = 0 THEN RAISE EXCEPTION 'rp_log_sale anchors not found'; END IF;
  EXECUTE replace(replace(d, o1, n1), o2, n2);
END $$;

-- rp_log_cancelation: carry the replacement marker (payload: replacement: true)
DO $$
DECLARE d text; o1 text; n1 text; o2 text; n2 text;
BEGIN
  d := pg_get_functiondef('public.rp_log_cancelation'::regproc);
  o1 := 'customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id)';
  n1 := 'customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id, is_replacement)';
  o2 := 'v_label, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id, v_pref)';
  n2 := 'v_label, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id, v_pref, COALESCE((p->>''replacement'')::boolean, false))';
  IF position(o1 in d) = 0 OR position(o2 in d) = 0 THEN RAISE EXCEPTION 'rp_log_cancelation anchors not found'; END IF;
  EXECUTE replace(replace(d, o1, n1), o2, n2);
END $$;

-- a replacement keeps the line in the household: whatever chargeback the cancelation computed is voided again
CREATE OR REPLACE FUNCTION public.cxl_replacement_no_chargeback()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT NEW.is_replacement THEN RETURN NEW; END IF;
  IF NEW.chargeback_activity_id IS NOT NULL THEN
    UPDATE public.retention_activity_log SET status = 'voided', voided_at = now(), void_reason = 'replacement policy: the household kept the line'
     WHERE id = NEW.chargeback_activity_id AND status <> 'voided';
  END IF;
  IF COALESCE(NEW.chargeback_points, 0) <> 0 OR NEW.window_fraction_left IS NOT NULL THEN
    UPDATE public.cancelation_log SET chargeback_points = 0, window_fraction_left = NULL WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zz_cxl_replacement_no_chargeback ON public.cancelation_log;
CREATE TRIGGER zz_cxl_replacement_no_chargeback AFTER INSERT ON public.cancelation_log
FOR EACH ROW EXECUTE FUNCTION public.cxl_replacement_no_chargeback();

-- scoreboard: repeat-quote marker on quote items, on-file answer on sale items
DO $$
DECLARE d text; o1 text; n1 text; o2 text; n2 text; o3 text; n3 text; o4 text; n4 text;
BEGIN
  d := pg_get_functiondef('public.rp_week_scoreboard_for'::regproc);
  o1 := 'SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.products_discussed, q.marketing_source, q.relationship_type,';
  n1 := E'SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.products_discussed, q.marketing_source, q.relationship_type,\n           EXISTS (SELECT 1 FROM public.quote_log x WHERE x.agency_id = q.agency_id AND x.status = ''active'' AND x.customer_label = q.customer_label AND x.week_end_date = q.week_end_date\n                     AND (x.quote_date < q.quote_date OR (x.quote_date = q.quote_date AND x.created_at < q.created_at))) AS dup,';
  o2 := '''source'', marketing_source, ''relationship'', relationship_type)';
  n2 := '''source'', marketing_source, ''relationship'', relationship_type, ''dup'', dup)';
  o3 := 'GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count, p.vehicle_count, p.issued_date, s.customer_label, pt.label AS type_label';
  n3 := 'GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count, p.vehicle_count, p.issued_date, s.customer_label, pt.label AS type_label, s.on_file_answer';
  o4 := '''premium'', x.premium, ''policies'', x.policy_count, ''vehicles'', x.vehicle_count)';
  n4 := '''premium'', x.premium, ''policies'', x.policy_count, ''vehicles'', x.vehicle_count, ''on_file_answer'', x.on_file_answer)';
  IF position(o1 in d) = 0 OR position(o2 in d) = 0 OR position(o3 in d) = 0 OR position(o4 in d) = 0 THEN RAISE EXCEPTION 'rp_week_scoreboard_for anchors not found'; END IF;
  EXECUTE replace(replace(replace(replace(d, o1, n1), o2, n2), o3, n3), o4, n4);
END $$;
