-- Expande compatibilidade de roles para o Admin Console central

-- 1) app_role enum: adiciona "user" (compatível com contratos externos)
do $$
begin
  if exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
      and t.typname = 'app_role'
  ) then
    begin
      alter type public.app_role add value if not exists 'user';
    exception
      when duplicate_object then null;
    end;
  end if;
end $$;

-- 2) app_users.role: permite roles custom (não limitar ao enum legado)
alter table if exists public.app_users
  drop constraint if exists app_users_role_check;

alter table if exists public.app_users
  alter column role set default 'user';

-- mantém apenas validação mínima de preenchimento
alter table if exists public.app_users
  drop constraint if exists app_users_role_not_empty;

alter table if exists public.app_users
  add constraint app_users_role_not_empty check (length(trim(role)) > 0);

-- normaliza registros antigos para "user" quando vazio/nulo
update public.app_users
set role = 'user',
    updated_at = now()
where role is null or length(trim(role)) = 0;
