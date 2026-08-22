-- Batch 2: full personality-item neutralization, all remaining facets except Enterprising
-- Source: planning-thread Batch 2 spec, 2026-08-08. Text-only changes; no reverse_coded flips (R3).

-- S2 step 1: baseline snapshot BEFORE any writes (reuses Batch 1's shift-log table)
INSERT INTO hiregauge_neutralization_shift_log (batch_label, candidate_id, facet, value_before)
SELECT 'batch2', c.candidate_id, f.hypothesized_trait, f.facet_score
FROM (
  SELECT DISTINCT r.candidate_id
  FROM hiregauge_candidate_responses r
  JOIN hiregauge_instrument_items i ON i.id = r.item_id
  WHERE i.section = 'newtworks_v2_personality' AND r.sitting = 1
) c
CROSS JOIN LATERAL compute_newtworks_v2_facets_as_row(c.candidate_id, NULL, 1) AS f
WHERE f.hypothesized_trait IN ('anger','anxiety','assertiveness','avoid_goal_orientation','cautiousness',
  'compassion','competitiveness','cooperation','dispositional_optimism','emotional_stability','friendliness',
  'greed_avoidance','political_skill_networking','proactive_personality','prove_goal_orientation',
  'self_discipline','self_efficacy','trust');

-- ANGER
UPDATE hiregauge_instrument_items SET item_text='There are days when small things get under my skin faster than they probably should.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=129;
UPDATE hiregauge_instrument_items SET item_text='Little things other people brush off tend to stick with me longer than they should.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=130;
UPDATE hiregauge_instrument_items SET item_text='It doesn''t always take much to throw off my mood for the rest of the day.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=131;
UPDATE hiregauge_instrument_items SET item_text='There are stretches where I notice I''ve been short with people without really meaning to.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=132;
UPDATE hiregauge_instrument_items SET item_text='When I''m pushed too far, I''ve said things in the moment that I later wish I hadn''t.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=133;
UPDATE hiregauge_instrument_items SET item_text='Most days, it takes a lot to actually get under my skin.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=134;
UPDATE hiregauge_instrument_items SET item_text='Even when things go wrong, I tend to stay pretty even about it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=135;
UPDATE hiregauge_instrument_items SET item_text='Small setbacks don''t usually change my mood much.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=136;
UPDATE hiregauge_instrument_items SET item_text='In a tense moment, I''m usually the one still thinking clearly.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=137;
UPDATE hiregauge_instrument_items SET item_text='When something bothers me, I tend to let it go rather than bring it up.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=138;

-- ANXIETY
UPDATE hiregauge_instrument_items SET item_text='My mind tends to go to what could go wrong before I''ve thought through what''s likely to actually happen.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=119;
UPDATE hiregauge_instrument_items SET item_text='When I don''t know how something will turn out, I usually expect it to go badly.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=120;
UPDATE hiregauge_instrument_items SET item_text='There''s a longer list than I''d like of situations that make me uneasy before I''m even in them.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=121;
UPDATE hiregauge_instrument_items SET item_text='It doesn''t take a big problem to leave me feeling tense for the rest of the day.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=122;
UPDATE hiregauge_instrument_items SET item_text='Most day-to-day problems don''t stay with me very long.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=124;
UPDATE hiregauge_instrument_items SET item_text='On a normal day, I''m not carrying much tension.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=125;
UPDATE hiregauge_instrument_items SET item_text='Unexpected news doesn''t usually throw me off for long.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=126;
UPDATE hiregauge_instrument_items SET item_text='Once something''s over, I tend to leave it there rather than replay it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=127;
UPDATE hiregauge_instrument_items SET item_text='New or unfamiliar situations don''t rattle me much.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=128;

-- ASSERTIVENESS
UPDATE hiregauge_instrument_items SET item_text='In a group without a clear leader, I''m usually the one who ends up setting direction.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=37;
UPDATE hiregauge_instrument_items SET item_text='Given the choice, I''d rather be the one making the call than waiting on someone else''s.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=38;
UPDATE hiregauge_instrument_items SET item_text='Even when it might not be what people want to hear, I tend to say what''s on my mind.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=39;
UPDATE hiregauge_instrument_items SET item_text='If something''s not working, I''ll say so directly rather than let it slide.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=40;
UPDATE hiregauge_instrument_items SET item_text='When a situation is unclear, I tend to step in and start organizing it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=41;
UPDATE hiregauge_instrument_items SET item_text='When something needs to happen, I''m willing to push harder than most people are comfortable with.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=42;
UPDATE hiregauge_instrument_items SET item_text='In a new group, I usually hang back and see who steps up first.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=43;
UPDATE hiregauge_instrument_items SET item_text='When a decision''s already been made, I tend to go along with it rather than push back.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=44;
UPDATE hiregauge_instrument_items SET item_text='I''m usually fine letting someone else take the lead on a call.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=45;
UPDATE hiregauge_instrument_items SET item_text='In a disagreement, I tend to give ground rather than hold my position.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=46;

-- AVOID_GOAL_ORIENTATION
UPDATE hiregauge_instrument_items SET item_text='Before raising my hand for something new, I think about whether it could make me look bad if I struggle with it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=385;
UPDATE hiregauge_instrument_items SET item_text='Given the choice, I''d rather stick with what I''m already good at than risk looking unsure while I''m learning something new.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=386;
UPDATE hiregauge_instrument_items SET item_text='There are tasks I''ve held back from because I wasn''t confident I''d do them well in front of others.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=387;
UPDATE hiregauge_instrument_items SET item_text='Given a choice between two assignments, I''ll usually pick the one where I''m less likely to fall short.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=388;

-- CAUTIOUSNESS
UPDATE hiregauge_instrument_items SET item_text='I''d rather take a bit longer on something than have to redo it because I rushed.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=199;
UPDATE hiregauge_instrument_items SET item_text='Before I say something that matters, I usually think it through first.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=200;
UPDATE hiregauge_instrument_items SET item_text='Once I''ve decided on an approach, I tend to follow it through rather than second-guess it midway.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=201;
UPDATE hiregauge_instrument_items SET item_text='Sometimes I''ll start on something before I''ve fully worked out the plan.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=202;
UPDATE hiregauge_instrument_items SET item_text='I''ve been known to change plans on short notice just because something else sounded better.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=204;
UPDATE hiregauge_instrument_items SET item_text='When I''m excited about something, I can get moving on it before I''ve thought through every detail.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=205;
UPDATE hiregauge_instrument_items SET item_text='I''ve done things on impulse that surprised even me afterward.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=206;
UPDATE hiregauge_instrument_items SET item_text='There are times I''ve said or done something before really considering how it would land.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=207;
UPDATE hiregauge_instrument_items SET item_text='I tend to firm up plans close to the last minute rather than well ahead of time.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=208;

-- COMPASSION
UPDATE hiregauge_instrument_items SET item_text='When someone I know is having a rough time, I usually have a sense of what to say.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=47;
UPDATE hiregauge_instrument_items SET item_text='I like being the one who gets a group together, even if it takes some effort to organize.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=48;
UPDATE hiregauge_instrument_items SET item_text='I tend to pick up on how someone''s feeling even before they say anything.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=49;
UPDATE hiregauge_instrument_items SET item_text='I ask people about what''s going on with them, even when it''s not really necessary.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=50;
UPDATE hiregauge_instrument_items SET item_text='People tend to relax a bit once they''ve talked to me for a few minutes.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=52;
UPDATE hiregauge_instrument_items SET item_text='I''ll set aside something I was planning to do if someone needs help.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=53;
UPDATE hiregauge_instrument_items SET item_text='When a coworker brings me a personal issue, I tend to keep some distance from it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=54;
UPDATE hiregauge_instrument_items SET item_text='I don''t usually ask people much about their personal lives.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=55;
UPDATE hiregauge_instrument_items SET item_text='Stories about people struggling aren''t something I dwell on much.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=56;
UPDATE hiregauge_instrument_items SET item_text='How someone else is feeling doesn''t usually change how I act toward them.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=57;
UPDATE hiregauge_instrument_items SET item_text='When someone''s going through something hard, my first thought isn''t usually sympathy.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=58;

-- COMPETITIVENESS (no norm row; text change only)
UPDATE hiregauge_instrument_items SET item_text='Even in a casual game, I''d rather win than just play for fun.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=390;
UPDATE hiregauge_instrument_items SET item_text='When someone outperforms me at something, it sticks with me longer than it probably should.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=391;
UPDATE hiregauge_instrument_items SET item_text='Knowing that others are being compared to me tends to push me to work harder.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=392;
UPDATE hiregauge_instrument_items SET item_text='I do better work when there''s some kind of contest or ranking involved.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=393;

-- COOPERATION
UPDATE hiregauge_instrument_items SET item_text='Most of the time, I don''t need much to be okay with how something turned out.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=149;
UPDATE hiregauge_instrument_items SET item_text='I''ll go out of my way to avoid a direct conflict if there''s another option.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=150;
UPDATE hiregauge_instrument_items SET item_text='I''m careful not to come across as demanding, even when I want something.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=151;
UPDATE hiregauge_instrument_items SET item_text='When I''m frustrated, what comes out of my mouth can come out sharper than I meant it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=152;
UPDATE hiregauge_instrument_items SET item_text='If I think someone''s wrong, I''ll say so, even in the moment.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=153;
UPDATE hiregauge_instrument_items SET item_text='I don''t mind a heated disagreement — sometimes I actually enjoy it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=154;
UPDATE hiregauge_instrument_items SET item_text='When I''m really frustrated, my voice has gotten louder than I intended.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=155;
UPDATE hiregauge_instrument_items SET item_text='In an argument, I''ve said things about the other person, not just the issue.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=156;
UPDATE hiregauge_instrument_items SET item_text='If someone wrongs me, I don''t just let it go — I look for a chance to even the score.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=157;
UPDATE hiregauge_instrument_items SET item_text='Once someone''s crossed me, it takes a long time before I see them the same way again.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=158;

-- DISPOSITIONAL_OPTIMISM
UPDATE hiregauge_instrument_items SET item_text='When I don''t know how something''s going to turn out, my first guess tends to be that it''ll be fine.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=1;
UPDATE hiregauge_instrument_items SET item_text='It sometimes feels like whatever can go wrong, does — at least for me.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=2;
UPDATE hiregauge_instrument_items SET item_text='When I picture where things are headed for me, the picture is usually a good one.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=3;
UPDATE hiregauge_instrument_items SET item_text='My default assumption going into something new is that it probably won''t go the way I want.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=4;
UPDATE hiregauge_instrument_items SET item_text='I try not to get my hopes up, because good outcomes haven''t felt like something I could count on.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=5;
UPDATE hiregauge_instrument_items SET item_text='Looking at how things have gone for me over time, the good has outweighed the bad.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=6;

-- EMOTIONAL_STABILITY
UPDATE hiregauge_instrument_items SET item_text='There are stretches where my mood is lower than I''d like without a clear reason.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=209;
UPDATE hiregauge_instrument_items SET item_text='There are things about myself I have a hard time accepting.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=210;
UPDATE hiregauge_instrument_items SET item_text='My energy and mood dip more than I''d like on a regular basis.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=211;
UPDATE hiregauge_instrument_items SET item_text='My mood can shift pretty quickly, sometimes within the same day.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=212;
UPDATE hiregauge_instrument_items SET item_text='When something goes wrong unexpectedly, my first reaction is often bigger than the situation calls for.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=213;
UPDATE hiregauge_instrument_items SET item_text='My mood tends to stay fairly steady, even when things don''t go my way.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=215;
UPDATE hiregauge_instrument_items SET item_text='For the most part, I''m at ease with who I am.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=216;
UPDATE hiregauge_instrument_items SET item_text='Looking back on how I''ve handled things, I feel good about it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=218;

-- FRIENDLINESS
UPDATE hiregauge_instrument_items SET item_text='I tend to hit it off with new people pretty quickly.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=159;
UPDATE hiregauge_instrument_items SET item_text='It doesn''t take long for me to feel comfortable around someone new.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=160;
UPDATE hiregauge_instrument_items SET item_text='Being around other people, even people I don''t know well, doesn''t put me on edge.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=161;
UPDATE hiregauge_instrument_items SET item_text='I don''t feel like I have to put on an act when I''m around other people.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=162;
UPDATE hiregauge_instrument_items SET item_text='People have told me it takes a while before they feel like they really know me.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=164;
UPDATE hiregauge_instrument_items SET item_text='In a room full of people I don''t know, I tend to feel a bit on edge.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=165;
UPDATE hiregauge_instrument_items SET item_text='Given the choice, I''ll often pick spending time alone over being around people.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=166;
UPDATE hiregauge_instrument_items SET item_text='I tend to hold back from getting too close to people, even ones I like.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=168;

-- GREED_AVOIDANCE
UPDATE hiregauge_instrument_items SET item_text='What something costs or how it looks to other people isn''t a big factor in what I choose to buy.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=28;
UPDATE hiregauge_instrument_items SET item_text='Nice, expensive things are something I genuinely enjoy having.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=29;
UPDATE hiregauge_instrument_items SET item_text='Being seen as successful by other people matters to me.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=31;
UPDATE hiregauge_instrument_items SET item_text='When I weigh my options, what pays better usually wins out.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=32;
UPDATE hiregauge_instrument_items SET item_text='In a situation where interests conflict, I look out for my own interests first.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=36;

-- POLITICAL_SKILL_NETWORKING
UPDATE hiregauge_instrument_items SET item_text='I put real time into building relationships at work beyond what my job strictly requires.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=79;
UPDATE hiregauge_instrument_items SET item_text='I''ve been able to build good working relationships with people who have real influence.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=80;
UPDATE hiregauge_instrument_items SET item_text='When I need something done, I usually know who to call — I''ve built up a lot of connections over time.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=81;
UPDATE hiregauge_instrument_items SET item_text='There aren''t many people in my professional circle I couldn''t get in touch with if I needed to.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=82;
UPDATE hiregauge_instrument_items SET item_text='Building relationships with the right people is something I actively invest time in.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=83;
UPDATE hiregauge_instrument_items SET item_text='When I need to get something done, I can usually find the right person to help make it happen.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=84;

-- PROACTIVE_PERSONALITY
UPDATE hiregauge_instrument_items SET item_text='I''m usually looking for ways to make things better, even things that already work fine.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=69;
UPDATE hiregauge_instrument_items SET item_text='At past jobs, I''ve been the one who pushed for changes that ended up helping.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=70;
UPDATE hiregauge_instrument_items SET item_text='There''s a specific satisfaction I get from watching something I proposed actually happen.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=71;
UPDATE hiregauge_instrument_items SET item_text='When I notice something that isn''t working well, I tend to do something about it rather than just note it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=72;
UPDATE hiregauge_instrument_items SET item_text='When I''m convinced something''s worth doing, I''ll keep pushing even when it''s not going well.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=73;
UPDATE hiregauge_instrument_items SET item_text='I don''t back off an idea just because someone else disagrees with it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=74;
UPDATE hiregauge_instrument_items SET item_text='I tend to notice openings or possibilities before other people point them out.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=75;
UPDATE hiregauge_instrument_items SET item_text='Even with a process that''s already working, I''ll wonder if there''s a better way to do it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=76;
UPDATE hiregauge_instrument_items SET item_text='Once I''ve committed to something, setbacks don''t usually change my mind about seeing it through.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=77;
UPDATE hiregauge_instrument_items SET item_text='I''ve noticed things worth pursuing before anyone else around me caught on.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=78;
UPDATE hiregauge_instrument_items SET item_text='Making some kind of difference beyond just my own life matters to me.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=358;
UPDATE hiregauge_instrument_items SET item_text='When a new project needs someone to kick it off, I usually wait to see if someone else will.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=359;
UPDATE hiregauge_instrument_items SET item_text='Running into resistance on something I care about doesn''t discourage me — if anything it engages me more.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=360;
UPDATE hiregauge_instrument_items SET item_text='I''m usually the one asking why something''s still done the old way.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=361;
UPDATE hiregauge_instrument_items SET item_text='When something''s wrong, my instinct is to deal with it directly rather than wait it out.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=362;
UPDATE hiregauge_instrument_items SET item_text='I''ve been able to take a bad situation and turn it into something that worked out for me.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=363;
UPDATE hiregauge_instrument_items SET item_text='When I see someone struggling with something, I tend to step in rather than walk past.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=364;

-- PROVE_GOAL_ORIENTATION
UPDATE hiregauge_instrument_items SET item_text='How I look compared to my coworkers is something I think about.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=381;
UPDATE hiregauge_instrument_items SET item_text='Part of why I do good work is so other people notice how capable I am.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=382;
UPDATE hiregauge_instrument_items SET item_text='I like it when people at work know when I''ve done something well.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=383;
UPDATE hiregauge_instrument_items SET item_text='Given the choice, I''ll pick the project where my work is more visible over one where it isn''t.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=384;

-- SELF_DISCIPLINE
UPDATE hiregauge_instrument_items SET item_text='When something needs doing, I tend to handle it before it piles up.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=189;
UPDATE hiregauge_instrument_items SET item_text='I usually have what I need ready before it''s actually required.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=190;
UPDATE hiregauge_instrument_items SET item_text='Once I know what needs to happen, I tend to get moving on it quickly.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=191;
UPDATE hiregauge_instrument_items SET item_text='I don''t spend much time easing into a task — I get started pretty directly.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=192;
UPDATE hiregauge_instrument_items SET item_text='There are days it takes me a while to actually settle into working.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=194;
UPDATE hiregauge_instrument_items SET item_text='Looking back at some days, I''m not sure where the time actually went.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=195;
UPDATE hiregauge_instrument_items SET item_text='Sometimes I need a deadline or someone else''s nudge before I actually start something.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=196;
UPDATE hiregauge_instrument_items SET item_text='There are tasks I know I need to do that I still put off starting.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=197;
UPDATE hiregauge_instrument_items SET item_text='When I''m not sure about something, I tend to put off deciding rather than commit.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=198;

-- SELF_EFFICACY
UPDATE hiregauge_instrument_items SET item_text='Even a hard problem usually gives way if I keep working at it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=59;
UPDATE hiregauge_instrument_items SET item_text='Even when someone''s pushing back against what I want, I can usually find a way through.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=60;
UPDATE hiregauge_instrument_items SET item_text='Once I''ve set a goal, seeing it through isn''t something I struggle with.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=61;
UPDATE hiregauge_instrument_items SET item_text='When something unexpected comes up, I don''t usually doubt my ability to deal with it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=62;
UPDATE hiregauge_instrument_items SET item_text='Most problems I''ve run into eventually give way if I put in the work.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=64;
UPDATE hiregauge_instrument_items SET item_text='Even under pressure, I don''t usually lose my footing.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=65;
UPDATE hiregauge_instrument_items SET item_text='When I hit a snag, I can usually think of more than one way around it.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=66;
UPDATE hiregauge_instrument_items SET item_text='Even in a bad spot, I tend to be able to find some way out.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=67;
UPDATE hiregauge_instrument_items SET item_text='Looking back, I''ve gotten through most things life has thrown at me.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=68;

-- TRUST
UPDATE hiregauge_instrument_items SET item_text='My default with new people is to give them the benefit of the doubt.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=139;
UPDATE hiregauge_instrument_items SET item_text='When someone''s motives aren''t clear, I tend to assume they mean well.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=140;
UPDATE hiregauge_instrument_items SET item_text='When someone tells me something, I generally take it at face value.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=141;
UPDATE hiregauge_instrument_items SET item_text='Given the chance, I think most people would do the right thing.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=142;
UPDATE hiregauge_instrument_items SET item_text='Even when things look uncertain, I tend to expect it''ll work out okay in the end.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=144;
UPDATE hiregauge_instrument_items SET item_text='I don''t take what people tell me at face value until I''ve had a reason to.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=145;
UPDATE hiregauge_instrument_items SET item_text='When someone does something nice for me, I sometimes wonder what they''re actually after.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=146;
UPDATE hiregauge_instrument_items SET item_text='With people I don''t know well, I keep some guard up.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=147;
UPDATE hiregauge_instrument_items SET item_text='My honest view of people, deep down, isn''t a very generous one.', updated_at=NOW() WHERE section='newtworks_v2_personality' AND item_number=148;

-- S2 step 2: recompute value_after
WITH recomputed AS (
  SELECT c.candidate_id, f.hypothesized_trait, f.facet_score
  FROM (
    SELECT DISTINCT r.candidate_id
    FROM hiregauge_candidate_responses r
    JOIN hiregauge_instrument_items i ON i.id = r.item_id
    WHERE i.section = 'newtworks_v2_personality' AND r.sitting = 1
  ) c
  CROSS JOIN LATERAL compute_newtworks_v2_facets_as_row(c.candidate_id, NULL, 1) AS f
  WHERE f.hypothesized_trait IN ('anger','anxiety','assertiveness','avoid_goal_orientation','cautiousness',
    'compassion','competitiveness','cooperation','dispositional_optimism','emotional_stability','friendliness',
    'greed_avoidance','political_skill_networking','proactive_personality','prove_goal_orientation',
    'self_discipline','self_efficacy','trust')
)
UPDATE hiregauge_neutralization_shift_log log
SET value_after = r.facet_score
FROM recomputed r
WHERE log.batch_label = 'batch2' AND log.candidate_id = r.candidate_id AND log.facet = r.hypothesized_trait AND log.value_after IS NULL;

-- S3: norm flag, 17 facets (competitiveness has no norm row, skipped by design)
UPDATE public.hiregauge_facet_norms
  SET items_reworded_after_norm = true, updated_at = NOW(), updated_by = 'claude_grunt_neutralization_batch2'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND facet IN ('anger','anxiety','assertiveness','avoid_goal_orientation','cautiousness','compassion',
    'cooperation','dispositional_optimism','emotional_stability','friendliness','greed_avoidance',
    'political_skill_networking','proactive_personality','prove_goal_orientation','self_discipline',
    'self_efficacy','trust');

-- S4: cutover marker — last item-wording batch, turn it on
UPDATE public.settings
SET setting_value = NOW()::text, updated_at = NOW(), updated_by = 'claude_grunt_neutralization_batch2'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key = 'hiregauge_neutralization_cutover_at';

