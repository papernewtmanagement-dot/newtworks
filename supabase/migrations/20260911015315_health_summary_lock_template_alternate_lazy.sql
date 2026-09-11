-- Peter 2026-09-10: health summary template is LOCKED.
--   💪 Health, Mon DD, OT: x/x      (🏁 on Saturday; date = Saturday the week ends)
--   • Name: x/5 🔥   ahead of schedule or goal hit
--   • Name: x/5 👍   on schedule (hits = weekday minus one)
--   • Name: x/5 😴/🥱 behind
-- Behind emoji now alternate down the list (random starting pick each night) so two
-- people behind never show the same one.
DO $mig$
DECLARE d text;
  old_case text := $s$v_row.hits || '/' || v_target || ' ' || (ARRAY['😴','🥱'])[1 + floor(random() * 2)::int]$s$;
  old_hdr text := $s$  -- One-line header: emoji, "Health", the Saturday the week ends, on-time count.$s$;
  old_decl text := $s$  v_status text;$s$;
  old_behind_count text := $s$    v_lines := v_lines || '• ' || v_row.first_name || ': ' || v_status || E'\n';$s$;
BEGIN
  d := pg_get_functiondef('public.team_health_checkin_compile'::regproc);
  IF position(old_case in d) = 0 OR position(old_hdr in d) = 0 OR position(old_decl in d) = 0 OR position(old_behind_count in d) = 0 THEN
    RAISE EXCEPTION 'health template anchors not found';
  END IF;
  d := replace(d, old_decl, $s$  v_status text;
  v_lazy_start int := floor(random() * 2)::int;
  v_behind_n int := 0;$s$);
  d := replace(d, old_case, $s$v_row.hits || '/' || v_target || ' ' || (ARRAY['😴','🥱'])[1 + ((v_lazy_start + v_behind_n) % 2)]$s$);
  d := replace(d, old_behind_count, $s$    IF v_row.hits < v_target AND v_row.hits < v_on_time_threshold THEN
      v_behind_n := v_behind_n + 1;
    END IF;
    v_lines := v_lines || '• ' || v_row.first_name || ': ' || v_status || E'\n';$s$);
  d := replace(d, old_hdr, $s$  -- LOCKED TEMPLATE (Peter 2026-09-10). Do not change the header or line format
  -- without Peter's direction: "💪 Health, Mon DD, OT: x/x" then "• Name: x/5 🔥|👍|😴/🥱".
  -- One-line header: emoji, "Health", the Saturday the week ends, on-time count.$s$);
  EXECUTE d;
END
$mig$;