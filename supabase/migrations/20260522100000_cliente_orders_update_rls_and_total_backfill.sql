-- Cliente multi-org: INSERT/SELECT de pedidos não usa current_user_org(), mas a policy antiga
-- "Cliente updates own draft orders" ainda exigia organization_id = current_user_org().
-- O trigger recalc_order_total() faz UPDATE em orders após inserir order_items; sem policy compatível
-- o UPDATE não alterava linhas e orders.total ficava 0 (carrinho ok, lista de pedidos errada).

drop policy if exists "Cliente updates own draft orders" on public.orders;

create policy "Cliente updates own orders"
on public.orders
for update
to authenticated
using (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and exists (
    select 1
    from public.customers c
    where c.id = orders.customer_id
      and c.user_id = auth.uid()
      and c.organization_id = orders.organization_id
  )
  and status in ('rascunho'::public.order_status, 'enviado'::public.order_status)
)
with check (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and exists (
    select 1
    from public.customers c
    where c.id = orders.customer_id
      and c.user_id = auth.uid()
      and c.organization_id = orders.organization_id
  )
  and status in ('rascunho'::public.order_status, 'enviado'::public.order_status)
);

comment on policy "Cliente updates own orders" on public.orders is
  'Cliente atualiza pedido próprio (ex.: trigger de total) em qualquer org do cadastro, alinhado a leitura/insert multi-org.';

-- Corrige pedidos já gravados com total 0 apesar de itens com subtotal.
update public.orders o
set total = s.sum_total
from (
  select order_id, coalesce(sum(subtotal), 0)::numeric(12, 2) as sum_total
  from public.order_items
  group by order_id
) s
where o.id = s.order_id
  and o.total = 0
  and s.sum_total > 0;
