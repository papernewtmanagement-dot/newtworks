-- Reset self_superiority to informational — resume layer no longer auto-declines for character.
UPDATE public.hiregauge_rules
SET verdict_impact = 'informational', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_screen_signal'
  AND short_label = 'Self-superiority language';

-- Drop character_flag_mechanism from Config; verdict = composite only.
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object(
      'construct', 'config',
      'construct_weights', jsonb_build_object('nature', 0.35, 'nurture', 0.30, 'drivers', 0.35),
      'subsignal_averaging', 'simple mean within each construct',
      'rule_count_penalty', jsonb_build_object('penalty_per_rule', 0, 'rationale', 'rules and sub-signals draw from same evidence pool. Rules are interviewer flags only.'),
      'verdict_thresholds', jsonb_build_object(
        'pass', 'composite >= 7.0',
        'consider', 'composite 5.0 to 6.99',
        'decline', 'composite < 5.0'
      ),
      'character_judgment_layer', 'Resume layer does NOT make character judgments. Character floors are evaluated at CTS assessment + interview + reference check stages downstream.',
      'parser_read_order', ARRAY[
        'load 9 sub-signal rows',
        'score each sub-signal 1-10 using markers plus anchor calibration',
        'average sub-signals within construct',
        'weighted average across constructs per weights above',
        'evaluate resume_screen_signal rules; record fired rules for interviewer flags (no composite effect)',
        'apply verdict thresholds against composite'
      ]
    ),
    description = 'Composite math config. Weights Nature 0.35 / Nurture 0.30 / Drivers 0.35. No penalty from rules (informational flags only). Verdict = composite thresholds. Character judgments happen downstream, not at resume layer.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND short_label = 'Composite Config';

-- Expand markers_positive on 5 sub-signals to give credit for durable substrate.

-- Autonomy: add durable single-employer tenure + side projects
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{markers_positive}',
  '["self-employed / founded / owned / started own business", "concurrent independent work streams", "initiative verbs (created / developed / established / launched) tied to specific outcomes", "side projects at real scale (revenue, users, team size, or sustained multi-year presence)", "durable single-employer tenure of 3+ years (self-direction within scaffolding)", "grew a program or scope within assigned role (2x-6x expansion)"]'::jsonb
), updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Autonomy';

-- Leadership Emergence: add system-level influence + program growth
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{markers_positive}',
  '["promoted within 12 months of joining an employer", "multiple documented promotions over tenure", "earned role at unusual young age or short tenure", "picked out by system for elevation with title change", "grew a program or team significantly while in role (6x student growth, doubled team size)", "system-level influence (developed processes adopted company-wide)"]'::jsonb
), updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Leadership Emergence';

-- Concern for Others: add served-population presence
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{markers_positive}',
  '["mentions team / customers / students / patients as beneficiaries of positive outcomes", "warmth language (elbow-to-elbow, meaningful connections, well-balanced team, tight-knit)", "service-orientation language tied to specific others", "we / us / team as agents in bullet points", "served-population presence (customers, patients, students) even without explicit warmth language", "team-coordination roles (unionized workforce, cross-functional teams)"]'::jsonb
), updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Concern for Others';

-- Coherent Pursuit: add durable throughline even without upward movement
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{markers_positive}',
  '["one industry or skill stack pursued consistently over 3+ years", "late-career pivot after long tenure OK (single coherent pivot into adjacent domain)", "clear directional theme across employers", "durable domain throughline (5+ years in one domain) even without upward moves"]'::jsonb
), updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Coherent Pursuit';

-- Follow-Through: expand to include completed non-target credentials
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{markers_positive}',
  '["completed degrees in target or adjacent domain", "earned licenses (state licensing, professional certifications)", "sustained side projects with visible multi-year outcomes", "stacked credentials in target domain", "completed degrees in any domain (evidence of finishing what was started)", "certifications completed in adjacent professional domains"]'::jsonb
), updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Follow-Through';;