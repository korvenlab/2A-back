-- Cliente B2B: nome comercial distinto da razão social; segmento/indústria no perfil e na carteira.

alter table public.customers
  add column if not exists legal_name text null,
  add column if not exists industry text null;

comment on column public.customers.name is 'Nome fantasia ou nome pelo qual o cliente prefere ser identificado na carteira.';
comment on column public.customers.legal_name is 'Razão social ou denominação jurídica.';
comment on column public.customers.industry is 'Segmento ou indústria declarada pelo cliente.';

alter table public.profiles
  add column if not exists organization_client_legal text null,
  add column if not exists organization_client_industry text null;

comment on column public.profiles.organization_client is 'Nome da empresa do cliente B2B (nome fantasia / uso cotidiano).';
comment on column public.profiles.organization_client_legal is 'Razão social informada no cadastro do cliente B2B.';
comment on column public.profiles.organization_client_industry is 'Segmento ou indústria informada no cadastro do cliente B2B.';

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
begin
  invite_token := nullif(trim(new.raw_user_meta_data->>'invite_token'), '');
  invited_org_id := null;
  invite_purpose := null;
  meta_legacy := nullif(trim(new.raw_user_meta_data->>'organization_name'), '');
  meta_staff_only := nullif(trim(new.raw_user_meta_data->>'staff_organization_name'), '');
  meta_client_only := nullif(trim(new.raw_user_meta_data->>'client_organization_name'), '');
  meta_trade := nullif(trim(new.raw_user_meta_data->>'client_trade_name'), '');
  meta_legal := nullif(trim(new.raw_user_meta_data->>'client_legal_name'), '');
  meta_industry := nullif(trim(new.raw_user_meta_data->>'client_industry'), '');

  if invite_token is not null then
    select si.organization_id, trim(lower(si.purpose::text))
      into invited_org_id, invite_purpose
    from public.seller_invitations si
    where si.token = invite_token
      and si.accepted_at is null
      and si.expires_at > now()
    limit 1;
  end if;

  if invite_token is not null and invited_org_id is null then
    raise exception 'Convite inválido ou expirado.';
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

  if invite_token is not null and invited_org_id is not null then
    update public.seller_invitations
    set accepted_at = now()
    where token = invite_token
      and accepted_at is null;
  end if;

  return new;
end;
$$;
