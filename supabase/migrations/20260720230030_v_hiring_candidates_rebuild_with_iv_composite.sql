-- Migration: v_hiring_candidates_rebuild_with_iv_composite
-- Rebuilds v_hiring_candidates to add iv_composite computed column at end.
-- iv_composite = 0.1429*iv_nature + 0.4286*iv_nurture + 0.4286*iv_drivers (interview layer weights).
-- Requires prior migration 20260720225852 to add iv_* columns to hiring_candidates.

DROP VIEW IF EXISTS public.v_hiring_candidates;

CREATE VIEW public.v_hiring_candidates AS
 WITH resume_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'resume'::text
        ), assessment_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'assessment'::text
        ), interview_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'interview'::text
        )
 SELECT hc.*,
    round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0, 2) AS res_nature,
    round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0, 2) AS res_nurture,
    round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0, 2) AS res_drivers,
    round(rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0) + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0) + rw.w_dr * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0), 2) AS res_composite,
        CASE hc.assessment_target_role
            WHEN 'aspirant'::text THEN bf.aspirant_os
            WHEN 'sales_outbound'::text THEN bf.sales_outbound_os
            WHEN 'sales_inbound'::text THEN bf.sales_inbound_os
            WHEN 'sales_in_book'::text THEN bf.sales_in_book_os
            WHEN 'retention_reception'::text THEN bf.retention_reception_os
            WHEN 'retention_escalation'::text THEN bf.retention_escalation_os
            WHEN 'retention_support'::text THEN bf.retention_support_os
            ELSE NULL::integer
        END::numeric AS assessment_nature,
    ns.nurture AS assessment_nurture,
    round((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0, 2) AS assessment_drivers,
    round(aw.w_nat *
        CASE hc.assessment_target_role
            WHEN 'aspirant'::text THEN bf.aspirant_os
            WHEN 'sales_outbound'::text THEN bf.sales_outbound_os
            WHEN 'sales_inbound'::text THEN bf.sales_inbound_os
            WHEN 'sales_in_book'::text THEN bf.sales_in_book_os
            WHEN 'retention_reception'::text THEN bf.retention_reception_os
            WHEN 'retention_escalation'::text THEN bf.retention_escalation_os
            WHEN 'retention_support'::text THEN bf.retention_support_os
            ELSE NULL::integer
        END::numeric + aw.w_nur * ns.nurture + aw.w_dr * ((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0), 2) AS assessment_composite,
    ns.honesty AS assessment_nurture_honesty,
    ns.concern AS assessment_nurture_concern,
    ns.work_ethic AS assessment_nurture_work_ethic,
        CASE
            WHEN hc.iv_nature IS NULL AND hc.iv_nurture IS NULL AND hc.iv_drivers IS NULL THEN NULL::numeric
            ELSE round(COALESCE(iw.w_nat * hc.iv_nature, 0::numeric) + COALESCE(iw.w_nur * hc.iv_nurture, 0::numeric) + COALESCE(iw.w_dr * hc.iv_drivers, 0::numeric), 2)
        END AS iv_composite
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN LATERAL cts_best_fit_role(hc.id) bf(best_role, best_role_category, display_label, best_os, sales_outbound_os, sales_inbound_os, sales_in_book_os, retention_reception_os, retention_escalation_os, retention_support_os, aspirant_os) ON true
     LEFT JOIN LATERAL ( SELECT x.honesty,
            x.concern,
            x.work_ethic,
            round((COALESCE(x.honesty, 0::numeric) + COALESCE(x.concern, 0::numeric) + COALESCE(x.work_ethic, 0::numeric)) / NULLIF(
                CASE
                    WHEN x.honesty IS NOT NULL THEN 1
                    ELSE 0
                END +
                CASE
                    WHEN x.concern IS NOT NULL THEN 1
                    ELSE 0
                END +
                CASE
                    WHEN x.work_ethic IS NOT NULL THEN 1
                    ELSE 0
                END, 0)::numeric, 2) AS nurture
           FROM ( VALUES (
                        CASE hc.response_distortion
                            WHEN 'low'::text THEN 85
                            WHEN 'moderate'::text THEN 50
                            WHEN 'high'::text THEN 15
                            ELSE NULL::integer
                        END::numeric,
                        CASE
                            WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
                            WHEN hc.compassion IS NOT NULL THEN hc.compassion::numeric
                            WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
                            ELSE NULL::numeric
                        END,
                        CASE hc.reliability
                            WHEN 'high'::text THEN 85
                            WHEN 'moderate'::text THEN 50
                            WHEN 'low'::text THEN 15
                            ELSE NULL::integer
                        END::numeric)) x(honesty, concern, work_ethic)) ns ON true;