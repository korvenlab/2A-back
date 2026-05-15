-- Catálogo B2B: oferta ilimitada; pedidos não baixam nem restauram estoque.

drop trigger if exists trg_order_items_stock_after_insert on public.order_items;
drop trigger if exists trg_orders_stock_after_status on public.orders;
drop trigger if exists trg_orders_stock_before_delete on public.orders;

create or replace function public.order_status_consumes_stock(st public.order_status)
returns boolean
language sql
immutable
as $$
  select false;
$$;

create or replace function public.apply_stock_for_order_lines(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  null;
end;
$$;

create or replace function public.restore_stock_for_order_lines(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  null;
end;
$$;

comment on function public.apply_stock_for_order_lines(uuid) is
  'Desativado: catálogo sem controle de estoque.';
comment on function public.restore_stock_for_order_lines(uuid) is
  'Desativado: catálogo sem controle de estoque.';
