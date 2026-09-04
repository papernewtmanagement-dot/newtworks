-- Review Ask and Referral Ask taken off the activity list (2026-09-04); rows kept inactive.
UPDATE public.retention_point_values SET is_active = false, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key IN ('review_ask','referral_ask');
