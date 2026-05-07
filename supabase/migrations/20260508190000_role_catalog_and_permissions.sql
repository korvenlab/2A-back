-- Catálogo formal de papéis e permissões (alinhado ao código atual)
create table if not exists public.app_roles_catalog (
  slug text primary key,
  label text not null,
  description text null,
  is_system boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.app_role_permissions (
  role_slug text not null references public.app_roles_catalog(slug) on delete cascade,
  permission text not null,
  created_at timestamptz not null default now(),
  primary key (role_slug, permission)
);

create index if not exists app_role_permissions_permission_idx on public.app_role_permissions(permission);

alter table public.app_roles_catalog enable row level security;
alter table public.app_role_permissions enable row level security;
revoke all on table public.app_roles_catalog from anon, authenticated;
revoke all on table public.app_role_permissions from anon, authenticated;
grant select, insert, update, delete on table public.app_roles_catalog to service_role;
grant select, insert, update, delete on table public.app_role_permissions to service_role;

insert into public.app_roles_catalog (slug, label, description)
values
  ('admin', 'Administrador', 'Acesso total à organização, incluindo gestão de vendedores e configurações.'),
  ('vendedor', 'Vendedor', 'Opera vendas/clientes/catálogo dentro da organização.'),
  ('cliente', 'Cliente', 'Acesso ao portal de compras e histórico próprio.'),
  ('user', 'Usuário', 'Papel genérico para integrações externas/Admin Console.')
on conflict (slug) do update
set
  label = excluded.label,
  description = excluded.description,
  updated_at = now();

-- Remove permissões antigas e reaplica matriz atual
delete from public.app_role_permissions
where role_slug in ('admin', 'vendedor', 'cliente', 'user');

-- admin
insert into public.app_role_permissions (role_slug, permission)
values
  ('admin', 'dashboard:view'),
  ('admin', 'orders:view'),
  ('admin', 'orders:manage'),
  ('admin', 'customers:view'),
  ('admin', 'customers:manage'),
  ('admin', 'products:view'),
  ('admin', 'products:manage'),
  ('admin', 'sellers:view'),
  ('admin', 'sellers:manage'),
  ('admin', 'portal:view');

-- vendedor
insert into public.app_role_permissions (role_slug, permission)
values
  ('vendedor', 'dashboard:view'),
  ('vendedor', 'orders:view'),
  ('vendedor', 'orders:manage'),
  ('vendedor', 'customers:view'),
  ('vendedor', 'customers:manage'),
  ('vendedor', 'products:view'),
  ('vendedor', 'products:manage');

-- cliente
insert into public.app_role_permissions (role_slug, permission)
values
  ('cliente', 'portal:view'),
  ('cliente', 'orders:view'),
  ('cliente', 'products:view');

-- user (genérico / mínimo)
insert into public.app_role_permissions (role_slug, permission)
values
  ('user', 'dashboard:view');

-- Normaliza app_users.role e vincula ao catálogo
update public.app_users
set role = 'cliente',
    updated_at = now()
where role is null
   or length(trim(role)) = 0
   or not exists (select 1 from public.app_roles_catalog r where r.slug = public.app_users.role);

alter table public.app_users
  alter column role set default 'cliente';

alter table public.app_users
  drop constraint if exists app_users_role_fkey;

alter table public.app_users
  add constraint app_users_role_fkey
  foreign key (role) references public.app_roles_catalog(slug) on update cascade on delete restrict;
