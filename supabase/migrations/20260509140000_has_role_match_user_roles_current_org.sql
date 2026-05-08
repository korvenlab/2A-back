-- has_role: reconhecer papel em user_roles quando a linha pertence ao tenant atual (current_user_org),
-- mesmo que o vínculo app_users ↔ user_roles esteja inconsistente para o join anterior.

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.app_users au
    where au.id = _user_id
      and au.deleted_at is null
      and coalesce(au.active, true)
      and trim(lower(au.role)) = trim(lower(_role::text))
      and trim(lower(au.role)) in ('admin', 'vendedor', 'cliente')
  )
  or exists (
    select 1
    from public.user_roles ur
    inner join public.app_users au on au.id = ur.user_id
    where ur.user_id = _user_id
      and ur.role = _role
      and au.deleted_at is null
      and coalesce(au.active, true)
      and ur.organization_id is not distinct from au.organization_id
  )
  or (
    exists (
      select 1
      from public.user_roles ur
      where ur.user_id = _user_id
        and ur.role = _role
    )
    and not exists (select 1 from public.app_users au where au.id = _user_id)
  )
  or exists (
    select 1
    from public.user_roles ur
    where ur.user_id = _user_id
      and ur.role = _role
      and ur.organization_id is not null
      and ur.organization_id = public.current_user_org()
  );
$$;
