-- Igual ao ajuste de products: garantir papel authenticated no PostgREST (evita 42501 "permission denied for table").
-- RLS continua controlando linhas permitidas.

GRANT SELECT, INSERT, UPDATE, DELETE ON public.customers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.orders TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.order_items TO authenticated;
