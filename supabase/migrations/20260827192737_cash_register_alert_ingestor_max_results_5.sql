-- max_results was cut to 3 while diagnosing the Groq 413. That 413 was caused
-- by unstripped HTML bodies, which automation-runner v55 now fixes: a stripped
-- Amex alert is about 1,200 characters, capped at 1,000, so five messages plus
-- the prompt sit well inside the token ceiling. Five per hourly run is 120/day
-- against roughly nine Amex alerts on a busy day.

UPDATE automation_recipes
SET input_config = jsonb_set(input_config, '{max_results}', '5'::jsonb),
    updated_at = NOW()
WHERE id = '24628de9-e206-4dea-b51c-bc40721e404d';
