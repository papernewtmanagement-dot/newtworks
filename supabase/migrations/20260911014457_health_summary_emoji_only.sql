-- Peter 2026-09-10: drop the colored circles. Line is "• Name: x/5 <emoji>".
--   🔥 ahead of schedule or goal hit, 👍 on schedule, behind rotates 😴 / 🥱
--   (same sleeping/lazy pair used for the rest-day reaction).
DO $mig$
DECLARE d text;
  a text := $s$'🟢 ' || v_row.hits || '/' || v_target || ' 🔥'$s$;
  b text := $s$'🟡 ' || v_row.hits || '/' || v_target || ' 👍'$s$;
  c text := $s$'🔴 ' || v_row.hits || '/' || v_target || ' ⏰'$s$;
BEGIN
  d := pg_get_functiondef('public.team_health_checkin_compile'::regproc);
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1
     OR (length(d) - length(replace(d, b, ''))) / length(b) <> 1
     OR (length(d) - length(replace(d, c, ''))) / length(c) <> 1 THEN
    RAISE EXCEPTION 'health status patterns not found exactly once';
  END IF;
  d := replace(d, a, $s$v_row.hits || '/' || v_target || ' 🔥'$s$);
  d := replace(d, b, $s$v_row.hits || '/' || v_target || ' 👍'$s$);
  d := replace(d, c, $s$v_row.hits || '/' || v_target || ' ' || (ARRAY['😴','🥱'])[1 + floor(random() * 2)::int]$s$);
  EXECUTE d;
END
$mig$;