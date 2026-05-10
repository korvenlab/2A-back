-- Cliente pode estar vinculado a mais de uma representação (vários convites client_catalog aceitos).
-- Libera customers/orders/order_items na organização do convite aceito (além de current_user_org).
-- Permite aceitar convite pelo próprio cliente e ler nomes das representações do catálogo.

create or replace function public.cliente_may_access_org_for_customer_row(_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.has_role(auth.uid(), 'cliente'::public.app_role)
    and _org_id is not null
    and (
      _org_id is not distinct from public.current_user_org()
      or exists (
        select 1
        from public.seller_invitations si
        where si.organization_id = _org_id
          and si.purpose = 'client_catalog'
          and si.accepted_at is not null
          and lower(si.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      )
    );
$$;

revoke all on function public.cliente_may_access_org_for_customer_row(uuid) from public;
grant execute on function public.cliente_may_access_org_for_customer_row(uuid) to authenticated;

-- ---------- customers (cliente) ----------
drop policy if exists "Cliente reads own customer row" on public.customers;
drop policy if exists "Cliente inserts own customer row" on public.customers;
drop policy if exists "Cliente updates own customer row" on public.customers;

create policy "Cliente reads own customer row"
on public.customers
for select
to authenticated
using (
  user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::public.app_role)
  and public.cliente_may_access_org_for_customer_row(organization_id)
);

create policy "Cliente inserts own customer row"
on public.customers
for insert
to authenticated
with check (
  user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::public.app_role)
  and public.cliente_may_access_org_for_customer_row(organization_id)
);

create policy "Cliente updates own customer row"
on public.customers
for update
to authenticated
using (
  user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::public.app_role)
  and public.cliente_may_access_org_for_customer_row(organization_id)
)
with check (
  user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::public.app_role)
  and public.cliente_may_access_org_for_customer_row(organization_id)
);

-- ---------- orders (cliente): não exige organization_id = current_user_org ----------
drop policy if exists "Cliente reads own orders" on public.orders;
drop policy if exists "Cliente inserts own orders" on public.orders;

create policy "Cliente reads own orders"
on public.orders
for select
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
);

create policy "Cliente inserts own orders"
on public.orders
for insert
to authenticated
with check (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and exists (
    select 1
    from public.customers c
    where c.id = orders.customer_id
      and c.user_id = auth.uid()
      and c.organization_id = orders.organization_id
  )
);

-- ---------- order_items (cliente) ----------
drop policy if exists "Cliente reads own order items" on public.order_items;
drop policy if exists "Cliente inserts own order items" on public.order_items;

create policy "Cliente reads own order items"
on public.order_items
for select
to authenticated
using (
  exists (
    select 1
    from public.orders o
    join public.customers c on c.id = o.customer_id
    where o.id = order_items.order_id
      and c.user_id = auth.uid()
      and c.organization_id = o.organization_id
      and has_role(auth.uid(), 'cliente'::public.app_role)
  )
);

create policy "Cliente inserts own order items"
on public.order_items
for insert
to authenticated
with check (
  exists (
    select 1
    from public.orders o
    join public.customers c on c.id = o.customer_id
    where o.id = order_items.order_id
      and c.user_id = auth.uid()
      and c.organization_id = o.organization_id
      and has_role(auth.uid(), 'cliente'::public.app_role)
  )
);

-- ---------- seller_invitations: cliente marca aceite ao abrir o link ----------
drop policy if exists "Cliente accepts own catalog invite" on public.seller_invitations;

create policy "Cliente accepts own catalog invite"
on public.seller_invitations
for update
to authenticated
using (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and purpose = 'client_catalog'
  and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
)
with check (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and purpose = 'client_catalog'
  and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
);

-- ---------- organizations: nome da representação no seletor do portal ----------
drop policy if exists "Cliente reads catalog organizations" on public.organizations;

create policy "Cliente reads catalog organizations"
on public.organizations
for select
to authenticated
using (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and exists (
    select 1
    from public.seller_invitations si
    where si.organization_id = organizations.id
      and si.purpose = 'client_catalog'
      and si.accepted_at is not null
      and lower(si.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
);
