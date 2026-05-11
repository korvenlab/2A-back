-- Convite universal de catálogo usa e-mail marcador (catalogo+universal@2avendas.local).
-- Policies antigas exigiam seller_invitations.email = e-mail do JWT do cliente — nunca batia →
-- sem produtos no portal, sem leitura de organizations / convites.

-- Deve coincidir com frontend/src/lib/invite-links.ts (UNIVERSAL_CLIENT_INVITE_EMAIL).
create or replace function public.universal_client_catalog_invite_email()
returns text
language sql
immutable
as $$
  select 'catalogo+universal@2avendas.local'::text;
$$;

revoke all on function public.universal_client_catalog_invite_email() from public;
grant execute on function public.universal_client_catalog_invite_email() to authenticated;

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
      or (
        exists (
          select 1
          from public.seller_invitations si
          where si.organization_id = _org_id
            and si.purpose = 'client_catalog'
            and si.accepted_at is not null
            and lower(trim(si.email)) = lower(public.universal_client_catalog_invite_email())
        )
        and exists (
          select 1
          from public.customers c
          where c.organization_id = _org_id
            and c.user_id = auth.uid()
        )
      )
    );
$$;

revoke all on function public.cliente_may_access_org_for_customer_row(uuid) from public;
grant execute on function public.cliente_may_access_org_for_customer_row(uuid) to authenticated;

-- ---------- organizations ----------
drop policy if exists "Cliente reads catalog organizations" on public.organizations;

create policy "Cliente reads catalog organizations"
on public.organizations
for select
to authenticated
using (
  has_role(auth.uid(), 'cliente'::public.app_role)
  and (
    exists (
      select 1
      from public.seller_invitations si
      where si.organization_id = organizations.id
        and si.purpose = 'client_catalog'
        and si.accepted_at is not null
        and lower(si.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
    or exists (
      select 1
      from public.seller_invitations si
      where si.organization_id = organizations.id
        and si.purpose = 'client_catalog'
        and si.accepted_at is not null
        and lower(trim(si.email)) = lower(public.universal_client_catalog_invite_email())
      and exists (
        select 1
        from public.customers c
        where c.organization_id = organizations.id
          and c.user_id = auth.uid()
      )
    )
  )
);

-- ---------- products ----------
drop policy if exists "Cliente views invited seller products" on public.products;

create policy "Cliente views invited seller products"
on public.products
for select
to authenticated
using (
  active = true
  and has_role(auth.uid(), 'cliente'::app_role)
  and (
    exists (
      select 1
      from public.seller_invitations si
      where si.organization_id = products.organization_id
        and si.invited_by is not distinct from products.owner_seller_id
        and si.purpose = 'client_catalog'
        and si.accepted_at is not null
        and lower(si.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
    or (
      exists (
        select 1
        from public.customers c
        where c.organization_id = products.organization_id
          and c.user_id = auth.uid()
          and c.assigned_seller_id is null
      )
      and exists (
        select 1
        from public.seller_invitations si
        where si.organization_id = products.organization_id
          and si.purpose = 'client_catalog'
          and si.accepted_at is not null
          and lower(trim(si.email)) = lower(public.universal_client_catalog_invite_email())
      )
    )
  )
);

-- ---------- seller_invitations: leitura ----------
drop policy if exists "Cliente reads own catalog invites" on public.seller_invitations;

create policy "Cliente reads own catalog invites"
on public.seller_invitations
for select
to authenticated
using (
  has_role(auth.uid(), 'cliente'::app_role)
  and purpose = 'client_catalog'
  and (
    lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or (
      lower(trim(email)) = lower(public.universal_client_catalog_invite_email())
      and exists (
        select 1
        from public.customers c
        where c.organization_id = seller_invitations.organization_id
          and c.user_id = auth.uid()
      )
    )
  )
);

-- ---------- seller_invitations: aceite (portal) ----------
drop policy if exists "Cliente accepts own catalog invite" on public.seller_invitations;

create policy "Cliente accepts own catalog invite"
on public.seller_invitations
for update
to authenticated
using (
  has_role(auth.uid(), 'cliente'::app_role)
  and purpose = 'client_catalog'
  and (
    lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or (
      lower(trim(email)) = lower(public.universal_client_catalog_invite_email())
      and exists (
        select 1
        from public.customers c
        where c.organization_id = seller_invitations.organization_id
          and c.user_id = auth.uid()
      )
    )
  )
)
with check (
  has_role(auth.uid(), 'cliente'::app_role)
  and purpose = 'client_catalog'
  and (
    lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or (
      lower(trim(email)) = lower(public.universal_client_catalog_invite_email())
      and exists (
        select 1
        from public.customers c
        where c.organization_id = seller_invitations.organization_id
          and c.user_id = auth.uid()
      )
    )
  )
);
