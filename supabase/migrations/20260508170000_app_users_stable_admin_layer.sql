-- Camada estável de gestão de usuários (independente de auth.users para operação admin)
create table if not exists public.app_users (
  id uuid primary key references public.profiles (id) on delete cascade,
  organization_id uuid null references public.organizations (id) on delete set null,
  email text null,
  name text null,
  role text not null default 'cliente',
  active boolean not null default true,
  deleted_at timestamptz null,
  last_sign_in_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_users_role_check check (role in ('admin', 'vendedor', 'cliente'))
);

create index if not exists app_users_org_idx on public.app_users (organization_id);
create index if not exists app_users_email_idx on public.app_users (email);
create index if not exists app_users_active_idx on public.app_users (active);

alter table public.app_users enable row level security;
revoke all on table public.app_users from anon, authenticated;
grant select, insert, update, delete on table public.app_users to service_role;

-- Backfill inicial a partir de profiles + user_roles.
insert into public.app_users (
  id,
  organization_id,
  email,
  name,
  role,
  active,
  deleted_at,
  created_at,
  updated_at
)
select
  p.id,
  p.organization_id,
  p.email,
  p.full_name,
  coalesce(
    (
      select ur.role::text
      from public.user_roles ur
      where ur.user_id = p.id
      order by
        case ur.role
          when 'admin' then 1
          when 'vendedor' then 2
          else 3
        end,
        ur.created_at asc
      limit 1
    ),
    'cliente'
  ) as role,
  coalesce(p.active, true),
  p.deleted_at,
  p.created_at,
  now()
from public.profiles p
on conflict (id) do update
set
  organization_id = excluded.organization_id,
  email = excluded.email,
  name = excluded.name,
  role = excluded.role,
  active = excluded.active,
  deleted_at = excluded.deleted_at,
  updated_at = now();

-- Sincroniza app_users quando profile é criado/atualizado.
create or replace function public.sync_app_user_from_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.app_users (
    id,
    organization_id,
    email,
    name,
    active,
    deleted_at,
    created_at,
    updated_at
  )
  values (
    new.id,
    new.organization_id,
    new.email,
    new.full_name,
    coalesce(new.active, true),
    new.deleted_at,
    new.created_at,
    now()
  )
  on conflict (id) do update
  set
    organization_id = excluded.organization_id,
    email = excluded.email,
    name = excluded.name,
    active = excluded.active,
    deleted_at = excluded.deleted_at,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists trg_sync_app_user_from_profile on public.profiles;
create trigger trg_sync_app_user_from_profile
after insert or update on public.profiles
for each row
execute function public.sync_app_user_from_profile();
