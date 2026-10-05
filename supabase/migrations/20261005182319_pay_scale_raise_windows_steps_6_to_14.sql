-- Peter 2026-10-05: steps 1-5 unchanged (1,2,3,4,4 quarters). Step 6 averages 5 quarters, step 7 six, step 8 seven, steps 9-14 (Elite) eight.
UPDATE public.pay_scale
   SET lookback_quarters = CASE raise_tier WHEN 6 THEN 5 WHEN 7 THEN 6 WHEN 8 THEN 7 ELSE 8 END,
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND role_key = 'sales'
   AND tier_starts_here
   AND raise_tier BETWEEN 6 AND 14;
