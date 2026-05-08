-- Fallback de tenant quando app_users e profiles não trazem organization_id mas user_roles sim.
-- Mantém políticas de Storage (product-images) e SELECT em organizations alinhadas ao painel.

create or replace function public.current_user_org()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select au.organization_id
      from public.app_users au
      where au.id = auth.uid()
        and au.deleted_at is null
        and coalesce(au.active, true)
        and au.organization_id is not null
      limit 1
    ),
    (select p.organization_id from public.profiles p where p.id = auth.uid()),
    (
      select ur.organization_id
      from public.user_roles ur
      where ur.user_id = auth.uid()
        and ur.organization_id is not null
      order by case ur.role
        when 'admin'::public.app_role then 1
        when 'vendedor'::public.app_role then 2
        else 3
      end
      limit 1
    )
  );
$$;
