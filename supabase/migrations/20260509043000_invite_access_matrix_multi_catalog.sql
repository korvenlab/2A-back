-- Ajusta matriz de acesso para convites de catálogo:
-- - admin: gerencia qualquer convite (seller_signup/client_catalog)
-- - vendedor: gerencia apenas convites client_catalog criados por ele
-- - cliente: pode ler seus convites de catálogo por e-mail autenticado
-- - produtos para cliente: visíveis por convites client_catalog aceitos (multi-vendedor)

drop policy if exists "Admin manages invites" on public.seller_invitations;
drop policy if exists "Staff manages client invites" on public.seller_invitations;
drop policy if exists "Cliente reads own catalog invites" on public.seller_invitations;

create policy "Staff manages client invites"
on public.seller_invitations
for all
to authenticated
using (
  (
    has_role(auth.uid(), 'admin'::app_role)
    and organization_id = current_user_org()
  )
  or (
    has_role(auth.uid(), 'vendedor'::app_role)
    and organization_id = current_user_org()
    and purpose = 'client_catalog'
    and invited_by = auth.uid()
  )
)
with check (
  (
    has_role(auth.uid(), 'admin'::app_role)
    and organization_id = current_user_org()
  )
  or (
    has_role(auth.uid(), 'vendedor'::app_role)
    and organization_id = current_user_org()
    and purpose = 'client_catalog'
    and invited_by = auth.uid()
  )
);

create policy "Cliente reads own catalog invites"
on public.seller_invitations
for select
to authenticated
using (
  has_role(auth.uid(), 'cliente'::app_role)
  and purpose = 'client_catalog'
  and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
);

drop policy if exists "Cliente views assigned seller products" on public.products;
drop policy if exists "Cliente views invited seller products" on public.products;

create policy "Cliente views invited seller products"
on public.products
for select
to authenticated
using (
  active = true
  and has_role(auth.uid(), 'cliente'::app_role)
  and exists (
    select 1
    from public.seller_invitations si
    where si.organization_id = products.organization_id
      and si.invited_by = products.owner_seller_id
      and si.purpose = 'client_catalog'
      and si.accepted_at is not null
      and lower(si.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
);
