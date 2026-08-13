-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-24 02:51:23 UTC (ledger name: resume_effort_split_content_and_presentation) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260724025123.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Split resume "Effort" signal into two distinct sub-signals per Peter directive 2026-07-24:
--   content_effort  = tailoring, specifics, quantification, role-alignment, real names (intellectual work in the writing)
--   presentation    = formatting, typos, length, layout, readability, no template-skeleton artifacts (artifact quality itself)
-- Both feed Drivers. Framework goes 12 signals -> 13 (6 in Drivers).

-- 1. Rename existing "Drivers: Effort" rubric row -> "Drivers: Content Effort" with content-only rubric text
UPDATE public.hiregauge_rules
SET rule_name  = 'Drivers: Content Effort',
    short_label = 'Content Effort',
    description = 'Level of care and effort invested in the CONTENT of the resume — the intellectual work in the writing, not the visual presentation. Scores role-tailoring, specificity, real-world verifiability, and thoughtful framing choices.

INDICATORS OF HIGH CONTENT EFFORT (score 70-100):
- Role-specific tailoring: industry terminology used correctly, company or program names relevant to the position, targeted skills for the posted role
- Specific and quantified claims (30% efficiency gain, 22-month tenure, $1.2M portfolio) rather than generic buzzwords
- Real institution and system names that can be verified (MOD, SF Billing, TASP designation, specific employer names)
- Thoughtful narrative choices — which experience is emphasized, how it is framed for the audience
- Objective/summary is tailored to the role sought, not template boilerplate

INDICATORS OF LOW CONTENT EFFORT (score 0-40):
- Zero role-tailoring — no industry terms, no company names, no program awareness
- Generic buzzword bullets with no verifiable specifics ("Delivered excellent customer service", "Championed communication")
- No quantified claims — only unmeasured verb phrases
- Boilerplate objective statement pattern ("Energetic professional seeking to leverage...") with no adaptation
- Wrong-industry tone applied to different role (e.g., manual labor skill emphasis applied to sales role)
- Self-superiority language woven into ordinary job descriptions

MIDDLE (score 40-70):
- Some role-adjacent tailoring but generic gaps
- Partial specificity — a few real names, mix of specific claims and buzzwords
- Objective is professional but not sharply targeted

WHY THIS MATTERS: Content effort signals the candidate''s investment in intellectual work for THIS opportunity. A candidate who researched the role, named the industry systems they know, and framed their experience specifically shows engagement. A candidate submitting boilerplate content signals mass-application.

Parser weight: 1 of 6 sub-signals averaged for Drivers.',
    notes = 'Sub-signal 5 of 6 in Drivers construct. Distinct from Presentation (which scores artifact/visual quality). Split from prior single "Effort" signal 2026-07-24 per Peter directive: the original quality concept was about the resume artifact itself; content effort is a separate parallel dimension. Both matter.',
    updated_at = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND rule_name='Drivers: Effort';

-- 2. Insert new "Drivers: Presentation" rubric row
INSERT INTO public.hiregauge_rules (
  agency_id, rule_type, rule_name, short_label,
  hiring_stage, description, notes,
  calibration_status, real_world_validated, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'resume_score_rubric',
  'Drivers: Presentation',
  'Presentation',
  ARRAY['resume_review'],
  'Quality of the resume as a physical artifact — formatting, layout, readability, absence of typos and errors. Scores the visual/mechanical polish independent of what the content says.

INDICATORS OF HIGH PRESENTATION (score 70-100):
- Length appropriate to role and career stage (not one-page for 15-year career; not 4 pages for entry-level)
- Consistent formatting, clean section headers, readable spacing
- No typos, no grammatical errors, no timeline math contradictions
- Professional layout — sections logically ordered, contact info properly placed
- Custom formatting choices vs. default template output (evidence of actually building the artifact vs. auto-generating it)
- Avoids Indeed/LinkedIn skeleton artifacts (blank fields showing, auto-tag remnants like "Less than 1 year" on every skill, section labels running into content)

INDICATORS OF LOW PRESENTATION (score 0-40):
- Multiple typos or grammatical errors ("I delivery Amazon packages", "FOH amd drive thru")
- Broken formatting: ALL CAPS bullets throughout, columns colliding, section boundaries unclear, contact info sandwiched mid-page
- Indeed download artifacts: "Indeed Resume — Page 1" header still present, "Less than 1 year" auto-tag on every skill, Bachelor''s degree entry with blank field/institution/year showing
- Timeline math errors (dates that do not add up, career gaps unexplained by structure)
- Length badly mismatched to career stage
- Duplicate entries (same certification listed twice, same job appearing in multiple sections)
- Wrong casing throughout (all lowercase or all uppercase where mixed case is standard)

MIDDLE (score 40-70):
- Basic template-clean, no typos, but no custom polish either
- Minor formatting inconsistencies or one typo
- Some template skeleton visible but mostly filled in properly
- Length roughly appropriate

WHY THIS MATTERS: The resume artifact is the first physical thing you see from the candidate. Presentation quality is a proxy for: (a) how much they cared about producing THIS artifact, (b) whether they can execute a small deliverable end-to-end with polish, (c) attention to detail on things that matter but are boring. A candidate who cannot produce a clean resume artifact will likely struggle to produce clean customer-facing artifacts.

Parser weight: 1 of 6 sub-signals averaged for Drivers.',
  'Sub-signal 6 of 6 in Drivers construct. Distinct from Content Effort (which scores the intellectual work in the writing). Added 2026-07-24 per Peter directive: original quality signal concept was primarily about the resume artifact itself. Presentation is often confounded with content when scored together, so kept separate.',
  'proposed',
  false,
  true
);

-- 3. Update 4 original Drivers sub-signal rows: "1 of 5" -> "1 of 6", update notes to reflect new positions (1-4 of 6)
UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 5 sub-signals averaged for Drivers', '1 of 6 sub-signals averaged for Drivers'),
    updated_at  = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND rule_name IN ('Drivers: Trajectory Direction','Drivers: Coherent Pursuit','Drivers: Follow-Through','Drivers: Goal Orientation');

UPDATE public.hiregauge_rules SET notes='Sub-signal 1 of 6 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Trajectory Direction';
UPDATE public.hiregauge_rules SET notes='Sub-signal 2 of 6 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Coherent Pursuit';
UPDATE public.hiregauge_rules SET notes='Sub-signal 3 of 6 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Follow-Through';
UPDATE public.hiregauge_rules SET notes='Sub-signal 4 of 6 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Goal Orientation';

-- 4. Rename signals.effort -> signals.content_effort for all 21 candidates, apply 3 delta-corrections, add signals.presentation with new scores
WITH updates AS (
  SELECT * FROM (VALUES
    -- (name, content_score, content_reason_delta_note, presentation_score, presentation_reason)
    -- content_reason_delta_note: NULL if keeping current reason, or new reason if score changed
    ('Allan Piedrabuena', 50, 'Adjusted from prior blended score (was 58 with presentation-flavored polish credit). Pure content: professional but zero SF-tailoring, generic corporate-boilerplate objective, most bullets are unquantified verb phrases. One metric (35% wireless sales). Real institutions verifiable. Middle-low content effort.',
        65, 'Clean formatting, professional layout, consistent section headers. No typos. Length appropriate to 8-year career. One extraction artifact ("December 20272" bleed) is neutral. Good presentation.'),
    ('Katie Barraco', 80, 'Massively SF-tailored — 7 SF agents named specifically, SF systems (ECRM, Necho), quantified premium ($25K/month, $250K/year). Warm distinctive voice. Content effort is genuinely top-tier for SF-agency fit.',
        55, 'Clean formatting overall, no typos. Length appropriate. Uses ":)" smiley twice — informal, slightly unprofessional for a resume but not broken. Well-organized sections. Middle-high presentation.'),
    ('Maximus Moody', 32, 'Zero SF/insurance tailoring, generic Indeed-template opener, zero quantified claims, buzzword-only bullet phrases. Wrong domain for insurance role. Low content effort.',
        50, 'Clean sectioning, readable structure, no typos in narrative. Length appropriate for 2-year career. BUT one clear error: "Driver''s License" listed twice in Certifications. Otherwise middle presentation.'),
    ('Carla Sanders', 40, 'Zero SF-tailoring, pitched generically at "Sales Consultant or Sales Representative." Some quantified claims (100% growth, 15%/yr, $1M+ deals). Real employers named. Middle-low content, weak on tailoring but decent specificity.',
        25, 'Indeed template artifacts throughout: "Indeed Resume — Page 1" header, "Less than 1 year" auto-tag on 8 of 9 skills, Bachelor''s degree entry has blank fields (no institution, no year, no field of study). Skeleton not filled in. Low presentation — accepted Indeed default without polish.'),
    ('Jason Villa', 42, 'Zero SF-tailoring, corporate-vague phrasing including odd "Championed Microsoft Office products". Buzzword skills list. Statistics degree not aligned with insurance. Real employers. Middle-low content.',
        55, 'Simple clean formatting, no typos, readable structure. Length short for 6-year career but not badly so. Basic layout, no custom polish beyond default. Middle presentation.'),
    ('Alyssa Sapp', 82, 'Massively SF-tailored: SF systems named (MOD, SF Billing, SFPP, ECRM, NECHO), TASP mentioned, agency name specified, quantified metrics (30%, 39 months, 22 months, uninsured under 1%). Top-tier content effort.',
        80, 'Clean professional sections, proper contact block, no typos, real address/phone/email formatted appropriately. Length appropriate for 5-year career. Well-organized narrative flow. High presentation.'),
    ('Anthony Papini', 25, 'Very short content for 5+ year career. Zero SF/insurance tailoring. Generic objective ("Energetic and driven young man") with wrong-industry tone. Skills section reads as manual labor for insurance role. No quantification. Low content.',
        40, 'Simple template, no typos I saw, section dividers clear. Length short but readable structure. Basic-clean presentation, no polish beyond default template. Middle.'),
    ('Anthony Vela', 60, 'Adjusted upward from prior blended score (was 45 penalized for ALL CAPS). Pure content: some genuine insurance tailoring ("HIGH-NET-WORTH INDIVIDUALS... LIFE INSURANCE PROTECTION"), real quantified metrics (call-to-appointment ratios), 14 years sales experience genuine. Real employers. Content is decent tailored — presentation is what dragged prior score.',
        25, 'Severe presentation issues: half the text is ALL CAPS (bullets throughout), header shows "A V NTHONY ELA" spacing artifact, section dividers inconsistent. Real readability problem. Low presentation.'),
    ('April Varian', 40, 'Zero SF/insurance tailoring — all warehouse/logistics/inventory. Grove City OH location not TX. Wrong-domain content. Real employers, some specifics per role. Middle-low content.',
        60, 'Clean formatting, consistent structure, no typos I saw. Professional layout. Middle-high presentation, though location note is a content signal not presentation.'),
    ('Bob Williams', 28, 'Adjusted upward from prior blended score (was 20 with typo-heavy penalty). Pure content: wrong industry (Amazon delivery, choir teacher, opera transport, pizza chef, Arby''s), self-superiority language ("my work was considered superior"), Music Master''s not aligned with insurance. Some specifics (grew choir 25 to 150 students). Content low but not lowest — has some substance.',
        30, 'Multiple typos and grammatical errors: "I delivery Amazon packages" (should be "deliver"), "tosser the dough" (should be "tossed"), "FOH amd drive thru" (typo "amd"), "andn skills" typo. Real writing errors, not extraction artifacts. Low presentation — actual carelessness.'),
    ('Cheryl Hemphill', 58, 'Genuine insurance tailoring — current role Insurance Sales Agent at Globe Life-American Income Life, mentions Licensed General Lines Agent. Real institutions. Skills include CRM and remote sales. Mixed with unrelated PT Assistant background. Middle-high content — insurance narrative is real.',
        40, 'Formatting is problematic — columns broken in extraction (labels running into content), hard to read. Section boundaries unclear. Low-middle presentation.'),
    ('Jakirah Goolsby', 70, 'Insurance-industry tailored — Trellis (insurance) SDR current, Allstate agent, QuoteWizard. Strong quantified claims ($100K+ monthly premium, 95% lead efficiency, 15-20% close rates, 25% bundling, 80-90% retention). Multi-state P&C license. Real school (Mercer BBA). High content effort.',
        75, 'Clean well-organized sections, real professional resume structure, no typos. Good spacing, readable hierarchy. Middle-high presentation.'),
    ('Matthew Carlton', 62, 'Insurance-tailored ("Licensed in Property, Casualty, Life and Health Insurance, I am eager to bring over 20 years..."). Multiple named licenses (TX P&C, TX Life/Health, AHIP, AML, ACA FFM). Real estate background mixed in. Some buzzword-heavy skills. Solid content-tailored.',
        55, 'Clean formatting, no typos I saw. Simple readable layout, licenses section well-organized. Middle presentation, no polish beyond default.'),
    ('Priscilla Brito', 50, 'Some SF connection — 4 years at Andrew Hernandez State Farm CSR (2012-2016). Insurance certs listed. Career highlight claim ("closed biggest account in company history") is bold but unverifiable. Generic skills list. Middle content — has SF experience but light tailoring for this role.',
        50, 'Basic but readable layout, no obvious typos. Simple contact section. Section headers clear. Middle presentation.'),
    ('Randy Castle', 25, 'Zero SF/insurance tailoring — refrigeration dispatcher, property porter, service manager auto, oil field trucking. No metrics. Generic personal statement. Self-superiority language ("Recognition for being the Top Service Manager"). Wrong industry. Low content, adjusted slightly up from prior blended 22.',
        25, 'Broken formatting throughout: weird section splits, contact info sandwiched mid-page mid-role, section boundaries unclear. Real presentation problems. Low.'),
    ('Richard Casias', 32, 'Very short bullet points, minimal detail per role. Zero SF/insurance tailoring — DIRECTV, Cash America pawn shop, Twisted Tattoo, Wingstop. Generic objective. One specific claim (Gun Forms 4473 100%). Currently studying IT/Cyber Security, different direction. Low content.',
        55, 'Clean simple structure, no typos, readable layout. Short but well-organized. Middle presentation — nothing broken, nothing polished.'),
    ('Vicken Shakarian', 25, 'Zero SF/insurance tailoring, wrong location (San Diego CA not TX), wrong industry (streetwear/inventory). HS graduate 2016 only. Buzzword-only skills grid ("Team Building, Client Coordination, Professional Communication, Organizational Leadership") — exactly the low-effort pattern. Very low content.',
        55, 'Clean simple formatting, no typos, readable. Short but well-organized layout. Middle presentation.'),
    ('Cassandra Alves', 48, 'Zero SF/insurance tailoring, retail/customer service background at generic employers. Real school (Texas Tech Media & Communication). Bilingual (Portuguese native). Generic profile. Middle-low content, adjusted slightly up from prior blended 45.',
        30, 'Indeed template extraction artifacts throughout: broken columns, weird line breaks running section labels into content ("EDUCATION Bilingual in E..."). Not the candidate''s fault entirely but shows Indeed-generated with no cleanup. Low-middle presentation.'),
    ('John Kostov', 55, 'Zero SF/insurance tailoring — customer relationship management, property management, cleaning services. Real employers (Royal ReFresh vending, SBM Management). Detailed bullets per job with real specifics. Good content depth but not tailored to SF.',
        70, 'Very long (6,095 chars) but appropriate for 15+ year career. Well-organized real sections, detailed per-role narrative. Some minor line issues but overall clean. Includes Indeed Assessments footer — extra effort. Middle-high presentation.'),
    ('Stephanie Rogers', 45, 'Zero SF/insurance tailoring, child care and developmentally-appropriate-activities background. Generic "people-focused professional" opener. Skills adjacent to teaching/coordination not insurance. Real employers. Middle-low content, adjusted slightly up from prior 42.',
        35, 'PDF/Indeed template extraction artifacts (| for I throughout, weird em-dash placements, contact info runs into content, section labels split from body). Presentation is broken by template mess. Low.'),
    ('Thomas Lynch', 62, 'Insurance-tailored objective ("seeking a challenging position in insurance"). Accident Investigation, LEAMS/FR300, Accident Reconstruction training — insurance-adjacent specific skills. Merchant Marine background unique detail. Real institutions. Good insurance-tailored content.',
        55, 'Clean layout, real formatting with proper section dividers, no typos. Middle presentation, no custom polish beyond default template.')
  ) AS t(name, content_score, content_reason, pres_score, pres_reason)
)
UPDATE public.hiring_candidates hc
SET resume_analysis =
  -- Take current signals, remove old "effort" key, add "content_effort" and "presentation"
  (
    hc.resume_analysis
    || jsonb_build_object(
         'signals',
         (hc.resume_analysis->'signals') - 'effort'
           || jsonb_build_object(
                'content_effort',
                jsonb_build_object('score', u.content_score::numeric, 'reason', u.content_reason)
              )
           || jsonb_build_object(
                'presentation',
                jsonb_build_object('score', u.pres_score::numeric, 'reason', u.pres_reason)
              )
       )
  )
  -- Recompute avg = mean of 13 signals (11 original + content_effort + presentation)
  || jsonb_build_object(
       'avg',
       round(
         ((SELECT COALESCE(SUM((v->>'score')::numeric), 0)
           FROM jsonb_each(hc.resume_analysis->'signals') AS sig(k,v)
           WHERE sig.k NOT IN ('effort','content_effort','presentation')
         ) + u.content_score + u.pres_score) / 13.0,
         0
       )
     )
  || jsonb_build_object('effort_split_at', to_jsonb(NOW()::text))
FROM updates u
WHERE hc.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND hc.candidate_name = u.name;

-- 5. Rewrite resume_drivers cell fn: 6 sub-signals, read content_effort + presentation. Backward-compatible: any missing signal reduces denominator, all 4 original still required.
CREATE OR REPLACE FUNCTION public.resume_drivers(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'trajectory_direction'->>'score')::numeric AS trajectory_direction,
      (hc.resume_analysis->'signals'->'coherent_pursuit'->>'score')::numeric     AS coherent_pursuit,
      (hc.resume_analysis->'signals'->'follow_through'->>'score')::numeric       AS follow_through,
      (hc.resume_analysis->'signals'->'goal_orientation'->>'score')::numeric     AS goal_orientation,
      (hc.resume_analysis->'signals'->'content_effort'->>'score')::numeric       AS content_effort,
      (hc.resume_analysis->'signals'->'presentation'->>'score')::numeric         AS presentation
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round(
    (trajectory_direction + coherent_pursuit + follow_through + goal_orientation
     + COALESCE(content_effort, 0) + COALESCE(presentation, 0))
    / (4.0
       + CASE WHEN content_effort IS NOT NULL THEN 1.0 ELSE 0.0 END
       + CASE WHEN presentation   IS NOT NULL THEN 1.0 ELSE 0.0 END),
    2)
  FROM s
  WHERE trajectory_direction IS NOT NULL
    AND coherent_pursuit    IS NOT NULL
    AND follow_through      IS NOT NULL
    AND goal_orientation    IS NOT NULL;
$function$;
