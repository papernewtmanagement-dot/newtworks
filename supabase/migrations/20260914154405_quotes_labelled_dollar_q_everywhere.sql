-- $Q is the label for a quote on every Telegram surface (Peter 2026-09-14).
-- Plain "Q" would collide with quarter, which already means something here --
-- the SP figure is quarter to date. $Q reads as one token and cannot be
-- misread. Also drops the "Wk Quotes/Qtr SP" tail from the midday and EOD
-- reminder titles: those messages carry no numbers, so the tail labelled
-- columns that were not there.
DO $migration$
DECLARE
  v_def text;
  v_pairs text[][] := ARRAY[
    ['render_team_status_block',   $x$ (MP/Quotes/SP/RP)$x$,                              $x$ (MP/$Q/SP/RP)$x$],
    ['render_team_status_block',   $x$'• Quotes: '$x$,                                    $x$'• $Q: '$x$],
    ['team_checkin_send_reminder', $x$E'☀️ Midday - Wk Quotes/Qtr SP'$x$,                 $x$E'☀️ Midday'$x$],
    ['team_checkin_send_reminder', $x$E'🌙 EOD - Wk Quotes/Qtr SP'$x$,                    $x$E'🌙 EOD'$x$],
    ['team_checkin_send_reminder', $x$' — +%s quotes carryover into this week'$x$,        $x$' — +%s $Q carryover into this week'$x$],
    ['render_daily_checklist_bridge', $x$(+1 quote each, per person, if the CPR confirms it)$x$, $x$(+1 $Q each, per person, if the CPR confirms it)$x$]
  ];
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_pairs[i][1];

    IF position(v_pairs[i][2] IN v_def) = 0 THEN
      RAISE EXCEPTION 'literal not found in %: %', v_pairs[i][1], v_pairs[i][2];
    END IF;

    EXECUTE replace(v_def, v_pairs[i][2], v_pairs[i][3]);
  END LOOP;
END
$migration$;