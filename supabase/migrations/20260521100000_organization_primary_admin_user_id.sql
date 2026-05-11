-- Cliente no portal: produtos sem owner_seller_id usam o primeiro admin da org como vendedor do pedido.
-- Só responde se o chamador tiver linha em customers nessa organização (evita enumeração de admins).

create or replace function public.organization_primary_admin_user_id(p_organization_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select ur.user_id
  from public.user_roles ur
  where ur.organization_id = p_organization_id
    and ur.role = 'admin'::public.app_role
    and exists (
      select 1
      from public.customers c
      where c.organization_id = p_organization_id
        and c.user_id = auth.uid()
    )
  order by ur.created_at asc
  limit 1;
$$;

comment on function public.organization_primary_admin_user_id(uuid) is
  'Cliente autenticado com cadastro na org: retorna um user_id admin da representação (pedido sem owner no produto).';

revoke all on function public.organization_primary_admin_user_id(uuid) from public;
grant execute on function public.organization_primary_admin_user_id(uuid) to authenticated;
