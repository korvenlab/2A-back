-- Regras de produto:
-- 1) Novo usuário padrão entra como vendedor.
-- 2) Vendedor passa a ter acesso completo aos recursos da organização.

-- Signup trigger: role padrão vendedor (mantendo fluxo de convite)
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  new_org_id uuid;
  org_name text;
  org_slug text;
  user_role app_role;
  invite_token text;
  invited_org_id uuid;
begin
  invite_token := nullif(new.raw_user_meta_data->>'invite_token', '');

  if invite_token is not null then
    select si.organization_id
      into invited_org_id
    from public.seller_invitations si
    where si.token = invite_token
      and si.accepted_at is null
      and si.expires_at > now()
    limit 1;
  end if;

  if invited_org_id is not null then
    new_org_id := invited_org_id;
    user_role := 'vendedor'::app_role;
  else
    org_name := coalesce(
      new.raw_user_meta_data->>'organization_name',
      new.raw_user_meta_data->>'full_name',
      split_part(new.email, '@', 1)
    ) || '''s Workspace';

    org_slug := lower(
      regexp_replace(
        coalesce(new.raw_user_meta_data->>'organization_name', split_part(new.email, '@', 1)),
        '[^a-zA-Z0-9]+',
        '-',
        'g'
      )
    ) || '-' || substr(new.id::text, 1, 8);

    user_role := coalesce((new.raw_user_meta_data->>'role')::app_role, 'vendedor'::app_role);

    insert into public.organizations (name, slug)
    values (org_name, org_slug)
    returning id into new_org_id;
  end if;

  insert into public.profiles (id, organization_id, full_name, email, avatar_url)
  values (
    new.id,
    new_org_id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.email,
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do update
  set
    organization_id = excluded.organization_id,
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    email = excluded.email,
    avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
    updated_at = now();

  insert into public.user_roles (user_id, organization_id, role)
  values (new.id, new_org_id, user_role)
  on conflict (user_id, organization_id) do update
  set role = excluded.role;

  if invite_token is not null and invited_org_id is not null then
    update public.seller_invitations
    set accepted_at = now()
    where token = invite_token
      and accepted_at is null;
  end if;

  return new;
end;
$$;

-- Convites: vendedor também pode gerenciar
drop policy if exists "Admin manages invites" on public.seller_invitations;
drop policy if exists "Admin or vendedor manages invites" on public.seller_invitations;
create policy "Admin or vendedor manages invites"
on public.seller_invitations for all
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

-- Customers: vendedor acessa/gerencia todos da organização
drop policy if exists "Vendedor views own customers" on public.customers;
drop policy if exists "Vendedor manages own customers" on public.customers;
drop policy if exists "Vendedor updates own customers" on public.customers;
drop policy if exists "Vendedor views all customers" on public.customers;
drop policy if exists "Vendedor manages all customers" on public.customers;

create policy "Vendedor views all customers"
on public.customers for select
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'vendedor'::app_role)
);

create policy "Vendedor manages all customers"
on public.customers for all
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'vendedor'::app_role)
)
with check (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'vendedor'::app_role)
);

-- Orders: vendedor acessa/gerencia todos da organização
drop policy if exists "Vendedor views own orders" on public.orders;
drop policy if exists "Vendedor creates own orders" on public.orders;
drop policy if exists "Vendedor updates own orders" on public.orders;
drop policy if exists "Vendedor views all orders" on public.orders;
drop policy if exists "Vendedor manages all orders" on public.orders;

create policy "Vendedor views all orders"
on public.orders for select
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'vendedor'::app_role)
);

create policy "Vendedor manages all orders"
on public.orders for all
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'vendedor'::app_role)
)
with check (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'vendedor'::app_role)
);

-- Order items: vendedor acessa/gerencia todos itens de pedidos da organização
drop policy if exists "Vendedor manages own order items" on public.order_items;
drop policy if exists "Vendedor manages org order items" on public.order_items;

create policy "Vendedor manages org order items"
on public.order_items for all
to authenticated
using (
  exists (
    select 1
    from public.orders o
    where o.id = order_items.order_id
      and o.organization_id = current_user_org()
      and has_role(auth.uid(), 'vendedor'::app_role)
  )
)
with check (
  exists (
    select 1
    from public.orders o
    where o.id = order_items.order_id
      and o.organization_id = current_user_org()
      and has_role(auth.uid(), 'vendedor'::app_role)
  )
);
