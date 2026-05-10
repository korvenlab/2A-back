-- Exclusão de cliente apenas por administrador (RLS). RPC em SECURITY DEFINER
-- remove oportunidades, orçamentos e pedidos vinculados antes da linha em customers.

drop policy if exists "Staff manages all customers" on public.customers;

create policy "Staff inserts customers"
on public.customers
for insert
to authenticated
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

create policy "Staff updates customers"
on public.customers
for update
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
)
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

create policy "Admin deletes customers"
on public.customers
for delete
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'admin'::public.app_role)
);

create or replace function public.admin_delete_customer(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  select c.organization_id
    into v_org
  from public.customers c
  where c.id = p_customer_id;

  if v_org is null then
    raise exception 'Cliente não encontrado';
  end if;

  if v_org is distinct from public.current_user_org() then
    raise exception 'Cliente não pertence à sua organização';
  end if;

  if not public.has_role(auth.uid(), 'admin'::public.app_role) then
    raise exception 'Apenas administradores podem excluir clientes';
  end if;

  delete from public.sales_opportunities
  where customer_id = p_customer_id;

  delete from public.budgets
  where customer_id = p_customer_id;

  delete from public.orders
  where customer_id = p_customer_id;

  delete from public.customers
  where id = p_customer_id;
end;
$$;

comment on function public.admin_delete_customer(uuid) is
  'Administrador da organização atual: remove cliente e registros dependentes (funil, orçamentos, pedidos). Visitas ficam com customer_id NULL (ON DELETE SET NULL).';

revoke all on function public.admin_delete_customer(uuid) from public;
grant execute on function public.admin_delete_customer(uuid) to authenticated;
