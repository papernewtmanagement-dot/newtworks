-- Dropping a duplicate I created. Production sales points are computed in exactly one
-- place: inside rp_week_scoreboard_for. get_sales_points_qtd reads that board's
-- sales.qtd_points as its production source. This function was a third implementation
-- with no callers. One job, one function.
DROP FUNCTION IF EXISTS public.get_production_sales_points_qtd(uuid, date);
