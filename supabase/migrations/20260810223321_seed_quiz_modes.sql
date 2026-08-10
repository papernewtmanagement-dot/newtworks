INSERT INTO public.quiz_modes
  (agency_id, mode_key, title, description, question_count, seconds_per_question, passing_score, allowed_shapes, is_gating, wager_allowed, speed_clock, is_active, sort_order)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','gauntlet','The Gauntlet','Short check on one training step. Pass to tick the step off. Every retry pulls a fresh draw.',8,45,75,ARRAY['choice'],true,false,false,true,1),
  ('126794dd-25ff-47d2-a436-724499733365','phase_final','Phase Final','Longer mixed check at the end of a training phase. Unlocks the next phase.',20,45,80,ARRAY['choice'],true,false,false,true,2),
  ('126794dd-25ff-47d2-a436-724499733365','daily_five','Daily Five','Five questions a day. Keep your streak going.',5,30,NULL,ARRAY['choice'],false,false,false,true,3),
  ('126794dd-25ff-47d2-a436-724499733365','duel','Duel','Challenge a teammate. Same seven questions, play when you have a minute.',7,20,NULL,ARRAY['choice'],false,false,false,true,4),
  ('126794dd-25ff-47d2-a436-724499733365','the_grid','The Grid','Category-and-values board. Pick your square.',25,30,NULL,ARRAY['choice'],false,true,false,true,5),
  ('126794dd-25ff-47d2-a436-724499733365','spin_and_solve','Spin & Solve','Solve the hidden coverage term, then say what it means.',6,60,NULL,ARRAY['choice'],false,false,false,true,6),
  ('126794dd-25ff-47d2-a436-724499733365','trivia_night','Trivia Night','Host mode for the weekly meeting. Everyone answers on their phone.',15,20,NULL,ARRAY['choice'],false,true,true,true,7)
ON CONFLICT (agency_id, mode_key) DO NOTHING;
