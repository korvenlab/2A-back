-- Corrige RLS excessivamente restritiva em profiles/user_roles (migration self_access):
-- a UI de Clientes faz SELECT em profiles e user_roles de outros usuários da mesma org
-- (lista de vendedores para admin). Sem isso o PostgREST retorna 42501 → toast genérico.
--
-- Também flexibiliza has_role quando app_users.role diverge do slug canônico mas user_roles
-- está alinhado ao mesmo organization_id em app_users ativo.

-- -------- profiles: próprio usuário OU staff da mesma org pode ler colegas ----------
drop policy if exists "Users read own profile" on public.profiles;

create policy "Users read own profile"
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
  or (
    organization_id = current_user_org()
    and (
      has_role(auth.uid(), 'admin'::public.app_role)
      or has_role(auth.uid(), 'vendedor'::public.app_role)
    )
  )
);

-- -------- user_roles: próprias linhas OU roster da org para staff ----------
drop policy if exists "Staff reads org user_roles" on public.user_roles;
drop policy if exists "Users read own role rows" on public.user_roles;

create policy "Users read own role rows"
on public.user_roles
for select
to authenticated
using (user_id = auth.uid());

create policy "Staff reads org user_roles"
on public.user_roles
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or (
      has_role(auth.uid(), 'vendedor'::public.app_role)
      and role = 'vendedor'::public.app_role
    )
  )
);

-- -------- has_role: incluir user_roles válido quando espelhado na mesma org em app_users ----------
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
  );
$$;
