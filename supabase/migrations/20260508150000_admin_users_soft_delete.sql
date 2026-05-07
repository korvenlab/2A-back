alter table public.profiles
  add column if not exists active boolean not null default true;

alter table public.profiles
  add column if not exists deleted_at timestamptz null;

comment on column public.profiles.active is 'Soft status do usuário para operações administrativas.';
comment on column public.profiles.deleted_at is 'Data de soft delete administrativo.';
