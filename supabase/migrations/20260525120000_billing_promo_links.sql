-- Links de cortesia (cadastro), espelhando o fluxo Wagoo: ?two_avendas_promo=código no login.

alter table public.app_users
  add column if not exists billing_complimentary_access_until timestamptz null;

comment on column public.app_users.billing_complimentary_access_until is
  'Acesso cortesia por link promocional; após este instante volta a exigir Stripe/unlock manual (se aplicável).';

create table if not exists public.billing_promo_links (
  id uuid primary key default gen_random_uuid (),
  code text not null,
  label text null,
  complimentary_days int not null check (
    complimentary_days >= 1
    and complimentary_days <= 730
  ),
  max_redemptions int null check (max_redemptions is null or max_redemptions >= 1),
  redemption_count int not null default 0 check (redemption_count >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint billing_promo_links_code_ux unique (code)
);

comment on table public.billing_promo_links is
  'Códigos promocionais administrados via Korven (X-Billing-Admin-Secret); login com ?two_avendas_promo=code.';

create table if not exists public.billing_promo_redemptions (
  id uuid primary key default gen_random_uuid (),
  promo_link_id uuid not null references public.billing_promo_links (id) on delete cascade,
  user_id uuid not null references public.app_users (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  redeemed_at timestamptz not null default now (),
  complimentary_until timestamptz not null,
  constraint billing_promo_redemptions_one_per_user unique (promo_link_id, user_id, organization_id)
);

comment on table public.billing_promo_redemptions is 'Histórico de resgates por usuário+organização.';

alter table public.billing_promo_links enable row level security;
alter table public.billing_promo_redemptions enable row level security;

revoke all on table public.billing_promo_links from anon, authenticated;
revoke all on table public.billing_promo_redemptions from anon, authenticated;

grant select, insert, update, delete on table public.billing_promo_links to service_role;
grant select, insert, update, delete on table public.billing_promo_redemptions to service_role;

create or replace function public.redeem_billing_promo_link(p_code text, p_user_id uuid, p_org_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link public.billing_promo_links%rowtype;
  v_cur_until timestamptz;
  v_stripe_at timestamptz;
  v_new_until timestamptz;
  v_normalized text := lower(trim(p_code));
begin
  if v_normalized = '' then
    return jsonb_build_object('ok', false, 'error', 'Código vazio');
  end if;

  select * into v_link
  from public.billing_promo_links
  where lower(trim(code)) = v_normalized
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Código inválido');
  end if;

  if not v_link.is_active then
    return jsonb_build_object('ok', false, 'error', 'Código inativo');
  end if;

  if v_link.max_redemptions is not null and v_link.redemption_count >= v_link.max_redemptions then
    return jsonb_build_object('ok', false, 'error', 'Código esgotado');
  end if;

  if exists (
    select 1
    from public.billing_promo_redemptions r
    where r.promo_link_id = v_link.id
      and r.user_id = p_user_id
      and r.organization_id = p_org_id
  ) then
    return jsonb_build_object('ok', false, 'error', 'Você já resgatou este código.');
  end if;

  select au.billing_complimentary_access_until, au.billing_stripe_access_at
    into v_cur_until, v_stripe_at
  from public.app_users au
  where au.id = p_user_id
    and au.organization_id = p_org_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Usuário ou organização inválidos');
  end if;

  if v_stripe_at is not null then
    return jsonb_build_object(
      'ok',
      false,
      'error',
      'Esta conta já possui acesso pago; o código promocional não se aplica.'
    );
  end if;

  v_new_until := greatest(coalesce(v_cur_until, now()), now())
    + make_interval(days => v_link.complimentary_days);

  insert into public.billing_promo_redemptions (
    promo_link_id,
    user_id,
    organization_id,
    complimentary_until
  )
  values (v_link.id, p_user_id, p_org_id, v_new_until);

  update public.billing_promo_links
  set redemption_count = redemption_count + 1
  where id = v_link.id;

  update public.app_users
  set
    billing_complimentary_access_until = v_new_until,
    updated_at = now()
  where id = p_user_id
    and organization_id = p_org_id;

  return jsonb_build_object('ok', true, 'complimentary_until', v_new_until);
end;
$$;

comment on function public.redeem_billing_promo_link(text, uuid, uuid) is
  'Resgate atómico: valida link, limites, grava redemption e estende billing_complimentary_access_until no app_users.';

revoke all on function public.redeem_billing_promo_link(text, uuid, uuid) from public;
grant execute on function public.redeem_billing_promo_link(text, uuid, uuid) to service_role;
