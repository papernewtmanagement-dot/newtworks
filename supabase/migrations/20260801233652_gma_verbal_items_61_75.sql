-- GMA verbal-reasoning items 61-75 (15 items) -- fourth and final planned
-- GMA subtest (pattern 1-30, numerical 31-45, deductive 46-60, verbal here).
-- All 4 GMA subtests now have a content bank. Shares
-- newtworks_v2_cognitive_gma section, item_number continues from 61.
-- Existing generic multi-choice renderer -- no new frontend component.
--
-- Format: classic verbal analogy (A is to B as C is to ?) -- Sternberg
-- 1977, componential analysis of analogical reasoning.
--
-- Unlike the other 3 GMA subtests, this content can't be verified by a
-- formal checker. Compensating discipline: every item built so exactly one
-- option matches the stated relationship, reviewed to rule out a second
-- defensible answer.
--
-- is_active=false, stint=0 -- same placeholder convention as every other
-- v2 item.

INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, cognitive_domain, stint, is_active)
VALUES
(
  'newtworks_v2_cognitive_gma', 61, 'Happy is to Joyful as Sad is to ___',
  '["Sorrowful", "Angry", "Excited", "Calm", "Tired", "Confused"]'::jsonb, 'Sorrowful', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 62, 'Hot is to Cold as Fast is to ___',
  '["Slow", "Quick", "Warm", "Loud", "Heavy", "Bright"]'::jsonb, 'Slow', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 63, 'Begin is to Start as End is to ___',
  '["Finish", "Middle", "Pause", "Open", "Continue", "Break"]'::jsonb, 'Finish', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 64, 'Ancient is to Modern as Rare is to ___',
  '["Common", "Old", "Valuable", "Unique", "Scarce", "Historic"]'::jsonb, 'Common', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 65, 'Page is to Book as Slice is to ___',
  '["Loaf", "Knife", "Bakery", "Butter", "Crumb", "Sandwich"]'::jsonb, 'Loaf', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 66, 'Rose is to Flower as Oak is to ___',
  '["Tree", "Leaf", "Forest", "Acorn", "Branch", "Root"]'::jsonb, 'Tree', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 67, 'Wheel is to Car as Sail is to ___',
  '["Boat", "Wind", "Ocean", "Mast", "Anchor", "Rope"]'::jsonb, 'Boat', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 68, 'Salmon is to Fish as Frog is to ___',
  '["Amphibian", "Pond", "Tadpole", "Reptile", "Lily pad", "Toad"]'::jsonb, 'Amphibian', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 69, 'Scissors is to Cut as Hammer is to ___',
  '["Pound", "Nail", "Wood", "Tool", "Build", "Saw"]'::jsonb, 'Pound', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 70, 'Chef is to Kitchen as Teacher is to ___',
  '["Classroom", "Student", "Lesson", "School", "Book", "Desk"]'::jsonb, 'Classroom', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 71, 'Key is to Lock as Password is to ___',
  '["Account", "Computer", "Security", "Username", "Hacker", "Screen"]'::jsonb, 'Account', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 72, 'Spark is to Fire as Rain is to ___',
  '["Flood", "Smoke", "Wood", "Match", "Ash", "Heat"]'::jsonb, 'Flood', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 73, 'Exercise is to Fitness as Study is to ___',
  '["Knowledge", "School", "Test", "Homework", "Teacher", "Grades"]'::jsonb, 'Knowledge', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 74, 'Warm is to Hot as Cool is to ___',
  '["Cold", "Chilly", "Freezing", "Mild", "Bright", "Windy"]'::jsonb, 'Cold', 'gma_verbal', 0, false
),
(
  'newtworks_v2_cognitive_gma', 75, 'Whisper is to Talk as Talk is to ___',
  '["Shout", "Silence", "Sing", "Mumble", "Listen", "Argue"]'::jsonb, 'Shout', 'gma_verbal', 0, false
);

