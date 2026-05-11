-- Admin que cria a organização: vira "espelho" de vendedor na equipe (lista + comissão própria),
-- sem segundo papel em user_roles (constraint única user_id+organization_id).

alter table public.organizations
  add column if not exists owner_user_id uuid null references auth.users (id) on delete set null;

create index if not exists idx_organizations_owner_user_id
  on public.organizations (owner_user_id)
  where owner_user_id is not null;

comment on column public.organizations.owner_user_id is
  'Usuário admin que fundou a organização (cadastro direto). Aparece na lista de vendedores com comissão própria; demais admins não recebem espelho automático.';

-- Retroativo: primeiro admin da org (por created_at em user_roles) como dono.
with first_admin as (
  select distinct on (ur.organization_id)
    ur.organization_id,
    ur.user_id
  from public.user_roles ur
  where ur.role = 'admin'::public.app_role
    and ur.organization_id is not null
  order by ur.organization_id, ur.created_at asc nulls last
)
update public.organizations o
set owner_user_id = fa.user_id
from first_admin fa
where o.id = fa.organization_id
  and o.owner_user_id is null;

insert into public.organization_seller_commissions (organization_id, seller_user_id, commission_pct)
select o.id, o.owner_user_id, 0::numeric
from public.organizations o
where o.owner_user_id is not null
  and not exists (
    select 1
    from public.organization_seller_commissions c
    where c.organization_id = o.id
      and c.seller_user_id = o.owner_user_id
  );

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org_id uuid;
  org_name text;
  org_slug text;
  user_role public.app_role;
  invite_token text;
  invited_org_id uuid;
  invite_purpose text;
  invite_commission_pct numeric;
  invite_invited_by uuid;
  invite_si_email text;
  meta_legacy text;
  meta_staff_only text;
  meta_client_only text;
  meta_staff_effective text;
  meta_client_effective text;
  meta_trade text;
  meta_legal text;
  meta_industry text;
  invited_org_display_name text;
  profile_client text;
  profile_staff text;
  profile_client_legal text;
  profile_client_industry text;
  v_customer_name text;
  v_assigned_seller uuid;
begin
  perform set_config('request.jwt.claim.sub', new.id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', new.id::text,
      'role', 'authenticated',
      'email', coalesce(new.email, '')
    )::text,
    true
  );

  invite_token := nullif(trim(new.raw_user_meta_data->>'invite_token'), '');
  invited_org_id := null;
  invite_purpose := null;
  invite_commission_pct := null;
  invite_invited_by := null;
  invite_si_email := null;
  meta_legacy := nullif(trim(new.raw_user_meta_data->>'organization_name'), '');
  meta_staff_only := nullif(trim(new.raw_user_meta_data->>'staff_organization_name'), '');
  meta_client_only := nullif(trim(new.raw_user_meta_data->>'client_organization_name'), '');
  meta_trade := nullif(trim(new.raw_user_meta_data->>'client_trade_name'), '');
  meta_legal := nullif(trim(new.raw_user_meta_data->>'client_legal_name'), '');
  meta_industry := nullif(trim(new.raw_user_meta_data->>'client_industry'), '');

  if invite_token is not null then
    select
      si.organization_id,
      trim(lower(si.purpose::text)),
      si.default_commission_pct,
      si.invited_by,
      si.email
    into invited_org_id, invite_purpose, invite_commission_pct, invite_invited_by, invite_si_email
    from public.seller_invitations si
    where si.token = invite_token
      and (
        si.accepted_at is null
        or (
          si.purpose = 'client_catalog'
          and lower(trim(si.email)) = lower(public.universal_client_catalog_invite_email())
        )
      )
    limit 1;
  end if;

  if invite_token is not null and invited_org_id is null then
    raise exception 'Convite inválido.';
  end if;

  profile_client := null;
  profile_staff := null;
  profile_client_legal := null;
  profile_client_industry := null;

  if invited_org_id is not null then
    new_org_id := invited_org_id;
    if invite_purpose = 'seller_signup' then
      user_role := 'vendedor'::public.app_role;
      select o.name into invited_org_display_name
      from public.organizations o
      where o.id = invited_org_id;

      profile_staff := coalesce(
        meta_staff_only,
        meta_legacy,
        invited_org_display_name
      );
    elsif invite_purpose = 'client_catalog' then
      user_role := 'cliente'::public.app_role;
      meta_client_effective := coalesce(meta_client_only, meta_legacy);
      profile_client := coalesce(meta_trade, meta_client_effective);
      profile_client_legal := meta_legal;
      profile_client_industry := meta_industry;
    else
      user_role := 'cliente'::public.app_role;
      meta_client_effective := coalesce(meta_client_only, meta_legacy);
      profile_client := coalesce(meta_trade, meta_client_effective);
      profile_client_legal := meta_legal;
      profile_client_industry := meta_industry;
    end if;
  else
    meta_staff_effective := coalesce(meta_staff_only, meta_legacy);

    org_name := coalesce(
      meta_staff_effective,
      nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
      split_part(new.email, '@', 1)
    ) || '''s Workspace';

    org_slug := lower(
      regexp_replace(
        coalesce(
          meta_staff_effective,
          split_part(new.email, '@', 1)
        ),
        '[^a-zA-Z0-9]+',
        '-',
        'g'
      )
    ) || '-' || substr(new.id::text, 1, 8);

    user_role := 'admin'::public.app_role;
    profile_staff := meta_staff_effective;

    insert into public.organizations (name, slug)
    values (org_name, org_slug)
    returning id into new_org_id;
  end if;

  insert into public.profiles (
    id,
    organization_id,
    full_name,
    email,
    avatar_url,
    organization_client,
    organization_staff,
    organization_client_legal,
    organization_client_industry
  )
  values (
    new.id,
    new_org_id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.email,
    new.raw_user_meta_data->>'avatar_url',
    profile_client,
    profile_staff,
    profile_client_legal,
    profile_client_industry
  )
  on conflict (id) do update
  set
    organization_id = excluded.organization_id,
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    email = excluded.email,
    avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
    organization_client = coalesce(
      nullif(trim(excluded.organization_client), ''),
      public.profiles.organization_client
    ),
    organization_staff = coalesce(
      nullif(trim(excluded.organization_staff), ''),
      public.profiles.organization_staff
    ),
    organization_client_legal = coalesce(
      nullif(trim(excluded.organization_client_legal), ''),
      public.profiles.organization_client_legal
    ),
    organization_client_industry = coalesce(
      nullif(trim(excluded.organization_client_industry), ''),
      public.profiles.organization_client_industry
    ),
    updated_at = now();

  insert into public.user_roles (user_id, organization_id, role)
  values (new.id, new_org_id, user_role)
  on conflict (user_id, organization_id) do update
  set role = excluded.role;

  update public.app_users au
  set
    role = user_role::text,
    organization_id = new_org_id,
    updated_at = now()
  where au.id = new.id;

  if user_role = 'vendedor'::public.app_role then
    insert into public.organization_seller_commissions (
      organization_id,
      seller_user_id,
      commission_pct
    )
    values (
      new_org_id,
      new.id,
      coalesce(invite_commission_pct, 5::numeric)
    )
    on conflict (organization_id, seller_user_id)
    do update set
      commission_pct = excluded.commission_pct,
      updated_at = now();
  end if;

  if user_role = 'admin'::public.app_role then
    update public.organizations o
    set owner_user_id = new.id
    where o.id = new_org_id;

    insert into public.organization_seller_commissions (
      organization_id,
      seller_user_id,
      commission_pct
    )
    values (new_org_id, new.id, 0::numeric)
    on conflict (organization_id, seller_user_id) do nothing;
  end if;

  if user_role = 'cliente'::public.app_role
     and invited_org_id is not null
     and invite_purpose = 'client_catalog'
     and not exists (
       select 1
       from public.customers c
       where c.user_id = new.id
         and c.organization_id = new_org_id
     )
  then
    v_customer_name := coalesce(
      nullif(trim(profile_client), ''),
      nullif(trim(meta_trade), ''),
      nullif(trim(coalesce(meta_client_effective, '')), ''),
      split_part(new.email, '@', 1)
    );
    v_assigned_seller :=
      case
        when invite_si_email is not null
          and lower(trim(invite_si_email)) = lower(public.universal_client_catalog_invite_email())
        then null
        else invite_invited_by
      end;
    perform public.insert_customer_row_from_signup_invite(
      new_org_id,
      new.id,
      v_customer_name,
      coalesce(profile_client_legal, ''),
      coalesce(profile_client_industry, ''),
      new.email,
      v_assigned_seller
    );
  end if;

  if invite_token is not null and invited_org_id is not null then
    perform public.mark_seller_invitation_accepted_from_signup(invite_token);
  end if;

  return new;
end;
$$;

alter function public.handle_new_user() owner to postgres;
