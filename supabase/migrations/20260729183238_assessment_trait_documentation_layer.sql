-- Trait documentation layer for the Newtworks v1 assessment.
--
-- Strategic trait labels (e.g. "recognition_drive", "self_promotion") were inherited
-- from the vendor CTS Compare Report and are what Peter's role-fit formulas were
-- reverse-engineered against. The item bank draws from the International Personality
-- Item Pool (IPIP) — the items are validated, but for several traits the label
-- doesn't match the underlying psychometric construct the items actually measure.
--
-- This table preserves the strategic labels everywhere in code and formulas while
-- documenting what each trait ACTUALLY measures. Read alongside any candidate's
-- flat trait score.
--
-- Peter directive 2026-07-29 (assessment soundness review, Option B).

CREATE TABLE IF NOT EXISTS public.hiregauge_trait_documentation (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  trait_name TEXT NOT NULL,
  strategic_label TEXT NOT NULL,
  psychometric_construct TEXT NOT NULL,
  ipip_facet TEXT,
  interpretation_warning TEXT NOT NULL,
  construct_notes TEXT NOT NULL,
  match_status TEXT NOT NULL CHECK (match_status IN ('match', 'mixed', 'mismatch')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, trait_name)
);

COMMENT ON TABLE public.hiregauge_trait_documentation IS
  'Documentation layer mapping strategic trait labels (recognition_drive, self_promotion, etc) to the psychometric constructs the underlying IPIP items actually measure. Read this when interpreting trait scores. Labels stay as-is in code and formulas — this table clarifies meaning without changing behavior. See match_status = ''mismatch'' rows for where the label diverges from the construct.';

INSERT INTO public.hiregauge_trait_documentation
  (agency_id, trait_name, strategic_label, psychometric_construct, ipip_facet, interpretation_warning, construct_notes, match_status)
VALUES
  -- Direct matches
  ('126794dd-25ff-47d2-a436-724499733365',
   'assertiveness', 'Assertiveness', 'Assertiveness',
   'Extraversion / Assertiveness',
   'None — label matches items.',
   'Items measure taking charge, saying what you think, providing criticism, resisting being pushed around. Standard IPIP assertiveness items.',
   'match'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'belief_in_others', 'Belief in Others', 'Trust',
   'Agreeableness / Trust',
   'None — label matches items (after 2026-07-29 removal of off-construct forgiveness item 54).',
   'Items measure trust in others'' motives, honesty, and basic goodness. Standard IPIP trust items.',
   'match'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'compassion', 'Compassion', 'Sympathy / Altruism',
   'Agreeableness / Sympathy',
   'None — label matches items.',
   'Items measure interest in others'' emotions, willingness to comfort, time invested in others. Standard IPIP sympathy items.',
   'match'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'analytical', 'Analytical', 'Deliberation',
   'Conscientiousness / Deliberation',
   'Reasonable match after 2026-07-29 content fixes removed self-view-of-specialness items (19, 21).',
   'Items measure reflection before acting, weighing pros and cons, avoiding rash decisions and jumping to conclusions. Two prior items (self-view of specialness) were deactivated in the soundness pass because they inflated scores for narcissistic candidates without measuring analytical thinking.',
   'match'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'impression_management', 'Impression Management', 'Impression Management / Social Desirability',
   'BIDR / Impression Management',
   'High score suggests the candidate is presenting themselves favorably. Not necessarily deceptive intent — could also be conscientious self-presentation. Interpret alongside VCT nonsense-word inflation for stronger signal.',
   'Items are Balanced Inventory of Desirable Responding (BIDR) impression management items. Candidates agreeing with virtuous impossibilities ("Believe there is never an excuse for lying") or disagreeing with normal human admissions ("Have sometimes had to tell a lie") score high.',
   'match'),

  -- Mixed construct
  ('126794dd-25ff-47d2-a436-724499733365',
   'deadline_motivation', 'Deadline Motivation', 'Orderliness + Procrastination + Perfectionism (mixed)',
   'Conscientiousness / multiple facets',
   'Score muddles three different Conscientiousness facets. A perfectionist orderly person may score high yet still miss deadlines because they can''t stop tweaking. Do not interpret a high score as "will meet deadlines" — interpret as "conscientious in general."',
   'Items span orderliness ("Leave a mess in my room" reversed, "Like order"), procrastination ("Put off unpleasant tasks" reversed, "Get chores done right away"), and perfectionism ("Am exacting in my work," "Continue until everything is perfect"). These facets correlate but measure different things. Splitting into three separate traits would give cleaner reads but requires reworking the item bank and role-fit formulas.',
   'mixed'),

  -- Label / content mismatches
  ('126794dd-25ff-47d2-a436-724499733365',
   'independent_spirit', 'Independent Spirit', 'Introversion / Solitude Preference',
   'Extraversion / Gregariousness (reversed)',
   'Does NOT measure self-direction, entrepreneurial spirit, or working without supervision. A high score means "enjoys being alone." An introverted employee can still need close direction; an extravert can be highly independent-thinking. Do not use as a proxy for "self-starter."',
   'Items measure solitude preference: "Enjoy my privacy," "Prefer to do things by myself," "Want to be left alone," "Enjoy silence," "Enjoy spending time by myself." Reversed items: "Enjoy teamwork," "Enjoy being part of a group." Score interprets whether the candidate is energized by solitude vs company.',
   'mismatch'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'optimism', 'Optimism', 'Emotional Stability / low Neuroticism',
   'Neuroticism (reversed)',
   'Does NOT measure positive outlook about the future. A high score means "low anxiety, recovers from setbacks quickly." A calm realist scores high; an anxious optimist scores low. Interpret as resilience/composure, not as future-outlook.',
   'Items measure worry ("Worry about things"), reaction to setbacks ("Feel crushed by setbacks"), fear ("Am afraid I will do the wrong thing"), guilt ("Feel guilty when I say no"). Reverse-coded so high score = emotional stability.',
   'mismatch'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'recognition_drive', 'Recognition Drive', 'Extraversion / Sociability',
   'Extraversion / Gregariousness',
   'Does NOT measure desire for recognition specifically. A high score means "socially outgoing." Introverted high-achievers who deeply crave recognition and awards score low here; social extraverts who care little about recognition score high. Do not use as a proxy for "motivated by rewards" or "chase Champions Circle."',
   'Items measure social comfort and gregariousness: "Life of the party," "Love large parties," "Talk to a lot of different people at parties," "Start conversations," "Am the last to laugh at a joke" (reversed), "Keep in the background" (reversed). Fifteen items in stint 2 make this the deepest expansion pool. Interpret as classic extraversion.',
   'mismatch'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'self_promotion', 'Self-Promotion', 'Self-Disclosure / Expressiveness',
   'Extraversion / Openness variant',
   'Does NOT measure bragging, self-marketing, or building a personal brand. A high score means "talks openly about themselves and their feelings." A strategically self-promoting professional who keeps thoughts private scores low here. Do not use as a proxy for "sales-oriented" or "will build a book of business."',
   'Items measure self-disclosure: "Am open about myself to others," "Disclose my intimate thoughts," "Show my feelings," "Am open about my feelings." Reverse items: "Reveal little about myself," "Bottle up my feelings," "Keep my thoughts to myself," "Am hard to get to know." Interpret as emotional/personal expressiveness.',
   'mismatch');

-- Add column comments on the 9 flat trait columns so anyone inspecting
-- hiring_candidates via psql or a schema browser sees the pointer to documentation.
COMMENT ON COLUMN public.hiring_candidates.assertiveness IS
  'Trait score 0-100. Measures Assertiveness (label matches). See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.belief_in_others IS
  'Trait score 0-100. Measures Trust (label matches). See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.compassion IS
  'Trait score 0-100. Measures Sympathy/Altruism (label matches). See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.analytical IS
  'Trait score 0-100. Measures Deliberation (label matches after 2026-07-29 fixes). See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.deadline_motivation IS
  'Trait score 0-100. Measures MIXED Orderliness+Procrastination+Perfectionism — score muddles 3 facets. See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.independent_spirit IS
  'Trait score 0-100. LABEL MISMATCH: measures Introversion/Solitude Preference, NOT self-direction. See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.optimism IS
  'Trait score 0-100. LABEL MISMATCH: measures Emotional Stability/low Neuroticism, NOT future outlook. See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.recognition_drive IS
  'Trait score 0-100. LABEL MISMATCH: measures Extraversion/Sociability, NOT desire for recognition. See hiregauge_trait_documentation.';
COMMENT ON COLUMN public.hiring_candidates.self_promotion IS
  'Trait score 0-100. LABEL MISMATCH: measures Self-Disclosure/Expressiveness, NOT bragging/self-marketing. See hiregauge_trait_documentation.';
