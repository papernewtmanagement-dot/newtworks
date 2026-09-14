-- Seed defaults. All tunable by Peter later; nothing here is baked into code.
DELETE FROM public.task_scoring_rules
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

INSERT INTO public.task_scoring_rules
  (agency_id, rule_kind, match_category, match_pattern, importance_value, importance_bump, urgency_bump, hours_value, notes, priority)
VALUES
-- Base importance per category. Drawn from the standing principles: profit margin is the
-- most serious watch, First Who then What, Newtworks serves the rest of the business.
('126794dd-25ff-47d2-a436-724499733365','category_weight','finances',NULL,85,0,0,NULL,'Net profit margin is the standing watch item.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight','team_development',NULL,80,0,0,NULL,'People first. Every staff act is the agent contractual liability.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight','web_app',NULL,65,0,0,NULL,'Newtworks is the operating hub but it serves the other work.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight','processes',NULL,60,0,0,NULL,'The agency has to run without the owner in the chair.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight','marketing',NULL,60,0,0,NULL,'Lead generation is still an undeveloped area.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight','admin',NULL,50,0,0,NULL,'Keeps the lights on. Rarely moves the needle.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight','handbook',NULL,45,0,0,NULL,'Important, seldom time-critical.',50),
('126794dd-25ff-47d2-a436-724499733365','category_weight',NULL,NULL,50,0,0,NULL,'Fallback when a task has no category.',99),

-- Default hour estimate by level.
('126794dd-25ff-47d2-a436-724499733365','type_hours',NULL,'task',NULL,0,0,1.50,'A task is hours of work by definition.',50),
('126794dd-25ff-47d2-a436-724499733365','type_hours',NULL,'story',NULL,0,0,4.00,'A story is days of work. Only scheduled if it has no child tasks.',50),
('126794dd-25ff-47d2-a436-724499733365','type_hours',NULL,'epic',NULL,0,0,NULL,'Epics are never scheduled into a week.',50),

-- Keyword bumps. Matched against title and description, case insensitive.
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'complian|audit|licens|renew|w-2|w2|irs|tax|deadline|file by',NULL,15,25,NULL,'Anything with an outside deadline attached to it.',20),
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'hire|hiring|interview|onboard|offer|applicant|recruit',NULL,12,10,NULL,'Hiring work goes stale fast. A candidate waits days, not weeks.',30),
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'broken|bug|error|fail|down|stuck|not working|fix',NULL,10,20,NULL,'Something already broken.',30),
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'reconcil|payroll|bank|statement|ledger|close the books',NULL,12,15,NULL,'Money work that compounds if skipped.',30),
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'idea|maybe|consider|explore|research|someday|look into|think about',-0,-15,-10,NULL,'Exploratory wording. Real but not this week.',60),
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'quick|small|tweak|rename|typo|one.?liner',NULL,0,0,0.50,'Small by its own description.',40),
('126794dd-25ff-47d2-a436-724499733365','keyword',NULL,'rebuild|redesign|migrat|overhaul|from scratch|restructur',NULL,0,0,6.00,'Big by its own description.',40),

-- Single-value settings.
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'importance_weight',65,0,0,NULL,'Importance counts for 65 percent of the band, urgency 35. Deliberate tilt against the mere-urgency effect.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'band_critical',80,0,0,NULL,'Combined score at or above this is critical.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'band_high',60,0,0,NULL,'Combined score at or above this is high.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'band_medium',35,0,0,NULL,'Combined score at or above this is medium. Below it is low.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'planning_multiplier',NULL,0,0,1.00,'Every estimate is multiplied by this. Starts at 1.00 and moves as real finish data arrives. People underestimate their own tasks (Buehler, Griffin and Ross 1994).',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'weekly_hours_peter',NULL,0,0,6.00,'Hours Peter commits to backlog work per week. Placeholder until he sets it.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'weekly_hours_marie',NULL,0,0,4.00,'Hours Marie commits to backlog work per week. Placeholder until she sets it.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'weekly_item_cap',7,0,0,NULL,'Hard cap on items per person per week, regardless of hours. Fewer open items means more finished items.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'rollover_urgency_bump',12,0,0,NULL,'Urgency added per week a task has been carried without finishing.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'rollover_park_after',4,0,0,NULL,'After this many carries with no finish, the task is parked to someday and stops competing.',50),
('126794dd-25ff-47d2-a436-724499733365','setting',NULL,'stale_park_days',120,0,0,NULL,'Untouched, unowned, no due date for this many days means it is parked to someday.',50);