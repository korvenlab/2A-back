-- Regras de signup:
-- 1) Cadastro direto no site cria conta admin.
-- 2) Role vendedor só é atribuída com convite purpose='seller_signup'.
-- 3) Convite de catálogo (purpose='client_catalog') cria/entra como cliente.

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  new_org_id uuid;
  org_name text;
  org_slug text;
  user_role app_role;
  invite_token text;
  invited_org_id uuid;
  invite_purpose text;
begin
  invite_token := nullif(new.raw_user_meta_data->>'invite_token', '');

  if invite_token is not null then
    select si.organization_id, si.purpose
      into invited_org_id, invite_purpose
    from public.seller_invitations si
    where si.token = invite_token
      and si.accepted_at is null
      and si.expires_at > now()
    limit 1;
  end if;

  if invited_org_id is not null then
    new_org_id := invited_org_id;
    if invite_purpose = 'seller_signup' then
      user_role := 'vendedor'::app_role;
    else
      user_role := 'cliente'::app_role;
    end if;
  else
    org_name := coalesce(
      new.raw_user_meta_data->>'organization_name',
      new.raw_user_meta_data->>'full_name',
      split_part(new.email, '@', 1)
    ) || '''s Workspace';

    org_slug := lower(
      regexp_replace(
        coalesce(new.raw_user_meta_data->>'organization_name', split_part(new.email, '@', 1)),
        '[^a-zA-Z0-9]+',
        '-',
        'g'
      )
    ) || '-' || substr(new.id::text, 1, 8);

    user_role := 'admin'::app_role;

    insert into public.organizations (name, slug)
    values (org_name, org_slug)
    returning id into new_org_id;
  end if;

  insert into public.profiles (id, organization_id, full_name, email, avatar_url)
  values (
    new.id,
    new_org_id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.email,
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do update
  set
    organization_id = excluded.organization_id,
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    email = excluded.email,
    avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
    updated_at = now();

  insert into public.user_roles (user_id, organization_id, role)
  values (new.id, new_org_id, user_role)
  on conflict (user_id, organization_id) do update
  set role = excluded.role;

  if invite_token is not null and invited_org_id is not null then
    update public.seller_invitations
    set accepted_at = now()
    where token = invite_token
      and accepted_at is null;
  end if;

  return new;
end;
$$;

-- Somente admin gerencia convites (inclusive convites de representante).
drop policy if exists "Admin or vendedor manages invites" on public.seller_invitations;
drop policy if exists "Admin manages invites" on public.seller_invitations;
create policy "Admin manages invites"
on public.seller_invitations for all
to authenticated
using (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'admin'::app_role)
)
with check (
  organization_id = current_user_org()
  and has_role(auth.uid(), 'admin'::app_role)
);
