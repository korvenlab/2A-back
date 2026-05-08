-- Corrige negativa RLS em clientes/catálogo para admin/vendedor quando:
-- 1) profiles.organization_id ficou defasado em relação a app_users (ex.: updates só via service_role / Korven).
-- 2) user_roles não reflete app_users (trigger não rodou ou dados legados).
--
-- current_user_org(): usa organization_id de app_users ativo como fonte principal para isolamento por tenant em RLS.
-- has_role(): reconhece papel canônico também via app_users além de user_roles.
-- Trigger: mantém profiles.organization_id alinhado a app_users para o restante do app.

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
    (select p.organization_id from public.profiles p where p.id = auth.uid())
  );
$$;

create or replace function public.has_role(_user_id uuid, _role app_role)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = _user_id
      and ur.role = _role
  )
  or exists (
    select 1
    from public.app_users au
    where au.id = _user_id
      and au.deleted_at is null
      and coalesce(au.active, true)
      and trim(lower(au.role)) = trim(lower(_role::text))
      and trim(lower(au.role)) in ('admin', 'vendedor', 'cliente')
  );
$$;

create or replace function public.sync_profile_org_from_app_users()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.organization_id is not null then
      update public.profiles
      set
        organization_id = new.organization_id,
        updated_at = now()
      where id = new.id
        and (organization_id is distinct from new.organization_id or organization_id is null);
    end if;
  elsif tg_op = 'UPDATE' then
    if new.organization_id is distinct from old.organization_id
       and new.organization_id is not null then
      update public.profiles
      set
        organization_id = new.organization_id,
        updated_at = now()
      where id = new.id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_profile_org_from_app_users on public.app_users;

create trigger trg_sync_profile_org_from_app_users
after insert or update of organization_id on public.app_users
for each row
execute function public.sync_profile_org_from_app_users();

-- Corrige profiles já divergentes (RLS passa a usar app_users, mas alinhar evita bugs na UI/outras queries).
update public.profiles p
set
  organization_id = au.organization_id,
  updated_at = now()
from public.app_users au
where au.id = p.id
  and au.deleted_at is null
  and coalesce(au.active, true)
  and au.organization_id is not null
  and p.organization_id is distinct from au.organization_id;
