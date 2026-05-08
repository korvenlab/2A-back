-- Access matrix hardening:
-- - admin: full operational access in organization
-- - vendedor: full operational access in organization (except invite management)
-- - cliente: portal-only flow (own customer, own orders, own order items, scoped product view)

-- Seller invitations: admin only.
drop policy if exists "Admin or vendedor manages invites" on public.seller_invitations;
drop policy if exists "Admin manages invites" on public.seller_invitations;
create policy "Admin manages invites"
on public.seller_invitations
for all
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'admin'::app_role)
)
with check (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'admin'::app_role)
);

-- Customers: admin and vendedor manage all org customers.
drop policy if exists "Vendedor views all customers" on public.customers;
drop policy if exists "Vendedor manages all customers" on public.customers;
drop policy if exists "Admin views all customers" on public.customers;
drop policy if exists "Admin manages all customers" on public.customers;
drop policy if exists "Cliente reads own customer row" on public.customers;
drop policy if exists "Cliente inserts own customer row" on public.customers;
drop policy if exists "Cliente updates own customer row" on public.customers;

create policy "Staff views all customers"
on public.customers
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
);

create policy "Staff manages all customers"
on public.customers
for all
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
)
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
);

create policy "Cliente reads own customer row"
on public.customers
for select
to authenticated
using (
  organization_id = current_user_org()
  and user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::app_role)
);

create policy "Cliente inserts own customer row"
on public.customers
for insert
to authenticated
with check (
  organization_id = current_user_org()
  and user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::app_role)
);

create policy "Cliente updates own customer row"
on public.customers
for update
to authenticated
using (
  organization_id = current_user_org()
  and user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::app_role)
)
with check (
  organization_id = current_user_org()
  and user_id = auth.uid()
  and has_role(auth.uid(), 'cliente'::app_role)
);

-- Products: admin/vendedor manage all org products; cliente can only view products
-- from assigned seller and active catalog.
drop policy if exists "Staff view org products" on public.products;
drop policy if exists "Staff manage org products" on public.products;
drop policy if exists "Cliente views assigned seller products" on public.products;

create policy "Staff view org products"
on public.products
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
);

create policy "Staff manage org products"
on public.products
for all
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
)
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
);

create policy "Cliente views assigned seller products"
on public.products
for select
to authenticated
using (
  organization_id = current_user_org()
  and active = true
  and has_role(auth.uid(), 'cliente'::app_role)
  and exists (
    select 1
    from public.customers c
    where c.organization_id = products.organization_id
      and c.user_id = auth.uid()
      and c.assigned_seller_id is not null
      and c.assigned_seller_id = products.owner_seller_id
  )
);

-- Orders: admin/vendedor full org access. Cliente can only create/read own orders.
drop policy if exists "Vendedor views all orders" on public.orders;
drop policy if exists "Vendedor manages all orders" on public.orders;
drop policy if exists "Admin views all orders" on public.orders;
drop policy if exists "Admin manages all orders" on public.orders;
drop policy if exists "Cliente reads own orders" on public.orders;
drop policy if exists "Cliente inserts own orders" on public.orders;

create policy "Staff views all orders"
on public.orders
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
);

create policy "Staff manages all orders"
on public.orders
for all
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
)
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::app_role)
    or has_role(auth.uid(), 'vendedor'::app_role)
  )
);

create policy "Cliente reads own orders"
on public.orders
for select
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'cliente'::app_role)
  and exists (
    select 1
    from public.customers c
    where c.id = orders.customer_id
      and c.organization_id = orders.organization_id
      and c.user_id = auth.uid()
  )
);

create policy "Cliente inserts own orders"
on public.orders
for insert
to authenticated
with check (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'cliente'::app_role)
  and exists (
    select 1
    from public.customers c
    where c.id = orders.customer_id
      and c.organization_id = orders.organization_id
      and c.user_id = auth.uid()
  )
);

-- Order items: staff manage all org items; cliente can create/read own order items.
drop policy if exists "Vendedor manages org order items" on public.order_items;
drop policy if exists "Admin manages org order items" on public.order_items;
drop policy if exists "Cliente reads own order items" on public.order_items;
drop policy if exists "Cliente inserts own order items" on public.order_items;

create policy "Staff manages org order items"
on public.order_items
for all
to authenticated
using (
  exists (
    select 1
    from public.orders o
    where o.id = order_items.order_id
      and o.organization_id = current_user_org()
      and (
        has_role(auth.uid(), 'admin'::app_role)
        or has_role(auth.uid(), 'vendedor'::app_role)
      )
  )
)
with check (
  exists (
    select 1
    from public.orders o
    where o.id = order_items.order_id
      and o.organization_id = current_user_org()
      and (
        has_role(auth.uid(), 'admin'::app_role)
        or has_role(auth.uid(), 'vendedor'::app_role)
      )
  )
);

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
      and o.organization_id = current_user_org()
      and c.user_id = auth.uid()
      and has_role(auth.uid(), 'cliente'::app_role)
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
      and o.organization_id = current_user_org()
      and c.user_id = auth.uid()
      and has_role(auth.uid(), 'cliente'::app_role)
  )
);
