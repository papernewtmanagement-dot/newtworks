UPDATE public.retention_point_values
SET points = 3.00,
    description = 'One policy that was going to cancel and did not. Counts when the customer asked to cancel or the company issued a cancelation notice, you did something about it, and the policy is still in force 30 days later. Log it the same day the request or notice comes in, with the reason the customer gave. Credited per policy, not per household. One save per policy per 90 days.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND activity_key = 'cancelation_saved';
