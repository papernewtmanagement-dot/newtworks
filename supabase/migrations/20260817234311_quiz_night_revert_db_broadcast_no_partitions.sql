-- REVERT of 20260817-quiz_night_realtime_broadcast_nudges, same session, before
-- any frontend was written against it.
--
-- WHY IT CANNOT WORK ON THIS PROJECT: broadcasting from the database means
-- writing a row to realtime.messages and letting the Realtime service pick it
-- up. On this project realtime.messages is RANGE partitioned by inserted_at and
-- has ZERO partitions, so every write fails with "no partition of relation found
-- for row" - verified directly, both through realtime.send (which has its own
-- exception handler, so it returned success and delivered nothing) and by a bare
-- INSERT inside an exception block. Nothing has ever been broadcast from this
-- database and nothing can be until partitions exist.
--
-- Supabase's own Realtime service is what normally keeps those daily partitions
-- rolling. It is not doing so here, and there is no cron job for it. Hand-rolling
-- daily partition creation and cleanup inside a Supabase-managed schema, on a
-- schedule we own, would be a standing maintenance job that fights the platform
-- the first time it changes that table.
--
-- THE PATH INSTEAD: the browser sends the nudge. Whoever just wrote something
-- - the host advancing the question, a player answering, somebody joining -
-- broadcasts a contentless "something changed" on the session's channel right
-- after their own write succeeds, and every other screen re-calls
-- quiz_night_state. That keeps quiz_night_state as the single source of truth,
-- which was the point of the design, and needs nothing from realtime.messages.
--
-- The one thing lost by moving off database triggers: if the acting browser dies
-- between its write and its broadcast, other screens miss that one nudge. The
-- retained poll is what covers it, which is why the poll stays rather than being
-- deleted outright.

DROP TRIGGER IF EXISTS quiz_answers_night_broadcast ON public.quiz_answers;
DROP TRIGGER IF EXISTS quiz_night_players_broadcast ON public.quiz_night_players;
DROP TRIGGER IF EXISTS quiz_night_sessions_broadcast ON public.quiz_night_sessions;

DROP FUNCTION IF EXISTS public.trg_quiz_answers_night_broadcast();
DROP FUNCTION IF EXISTS public.trg_quiz_night_players_broadcast();
DROP FUNCTION IF EXISTS public.trg_quiz_night_sessions_broadcast();
DROP FUNCTION IF EXISTS public.quiz_night_notify(uuid, text);

DROP POLICY IF EXISTS quiz_night_broadcast_read ON realtime.messages;

-- ix_quiz_night_players_attempt is KEPT. It was added for the answer trigger's
-- lookup, but quiz_night_state already looks players up by attempt on every
-- call, so the index earns its place either way.

-- quiz_night_can_watch is KEPT for the same reason it was written: whatever
-- authorises a live listener has to be able to see the session, and the session
-- table is deny-all to a signed-in person.