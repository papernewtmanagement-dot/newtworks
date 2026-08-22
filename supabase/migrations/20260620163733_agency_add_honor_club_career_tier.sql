ALTER TABLE public.agency
  ADD COLUMN IF NOT EXISTS honor_club_career_tier TEXT
    CHECK (honor_club_career_tier IS NULL OR honor_club_career_tier IN ('honor','bronze','silver','gold','crystal'));

COMMENT ON COLUMN public.agency.honor_club_career_tier IS
  'Honor Club career tier as of 1/1 current year. Cumulative lifetime qualifications: honor=1-4, bronze=5-9, silver=10-14, gold=15-19, crystal=20+. Points awarded when year qualified: 85/95/105/115/125. Tier doesn''t demote — resumes at career-best next year qualified. Update manually when a new annual qualification rolls in.';

UPDATE public.agency
SET honor_club_career_tier = 'bronze'
WHERE id = '126794dd-25ff-47d2-a436-724499733365';
