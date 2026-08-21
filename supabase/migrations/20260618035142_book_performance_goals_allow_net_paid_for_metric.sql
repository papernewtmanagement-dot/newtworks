ALTER TABLE public.book_performance_goals
  DROP CONSTRAINT IF EXISTS book_performance_goals_metric_check;

ALTER TABLE public.book_performance_goals
  ADD CONSTRAINT book_performance_goals_metric_check
  CHECK (metric IN ('new','lost','gain','pif','premium','new_pay','net_paid_for'));
