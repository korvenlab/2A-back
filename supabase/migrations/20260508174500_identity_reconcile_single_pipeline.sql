-- Pipeline único de identidade: app_users é fonte operacional (Korven + painel);
-- profiles.organization_id e user_roles ficam espelhados para RLS legado e UI.
-- Substitui gatilhos separados (sync user_roles + sync profile org) por um fluxo idempotente.

-- 1) Função central (service_role pode invocar via RPC se necessário)
create or replace function public.reconcile_app_user_identity(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  au public.app_users%rowtype;
  slug text;
  mapped public.app_role;
begin
  select * into au from public.app_users where id = p_user_id;
  if not found then
    return;
  end if;

  slug := trim(lower(au.role));

  if au.organization_id is not null
     and au.deleted_at is null
     and coalesce(au.active, true) then
    update public.profiles p
    set
      organization_id = au.organization_id,
      updated_at = now()
    where p.id = p_user_id
      and p.organization_id is distinct from au.organization_id;
  end if;

  if au.deleted_at is not null or not coalesce(au.active, true) then
    delete from public.user_roles ur where ur.user_id = p_user_id;
    return;
  end if;

  if slug in ('admin', 'vendedor', 'cliente') and au.organization_id is not null then
    mapped := slug::public.app_role;
    insert into public.user_roles (user_id, organization_id, role)
    values (p_user_id, au.organization_id, mapped)
    on conflict (user_id, organization_id)
    do update set role = excluded.role;
  end if;
end;
$$;

revoke all on function public.reconcile_app_user_identity(uuid) from public;
grant execute on function public.reconcile_app_user_identity(uuid) to service_role;

-- 2) Trigger condicional (evita disparar a cada touch em updated_at / sync redundante)
create or replace function public.trg_reconcile_app_user_identity_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.reconcile_app_user_identity(new.id);
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.role is distinct from new.role
       or old.organization_id is distinct from new.organization_id
       or old.active is distinct from new.active
       or old.deleted_at is distinct from new.deleted_at then
      perform public.reconcile_app_user_identity(new.id);
    end if;
    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_profile_org_from_app_users on public.app_users;
drop trigger if exists trg_sync_user_roles_from_app_users on public.app_users;
drop trigger if exists trg_reconcile_app_user_identity on public.app_users;

drop function if exists public.sync_profile_org_from_app_users();

drop function if exists public.sync_user_roles_from_app_users();

create trigger trg_reconcile_app_user_identity
after insert or update of role, organization_id, active, deleted_at on public.app_users
for each row
execute function public.trg_reconcile_app_user_identity_fn();

-- 3) has_role: não conceder papel via user_roles se app_users estiver inativo/removido;
-- mantém compatibilidade para linhas antigas sem app_users.
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

-- 4) Backfill único
do $$
declare
  r record;
begin
  for r in select id from public.app_users loop
    perform public.reconcile_app_user_identity(r.id);
  end loop;
end $$;
