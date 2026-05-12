-- 1) Repara linhas antigas: resgate em billing_promo_redemptions mas billing_complimentary_access_until em app_users
--    vazio ou anterior ao último complimentary_until (bugs da RPC que filtrava por organization_id no UPDATE).
-- 2) Resgate idempotente: "já resgatou" passa a devolver ok=true e sincroniza app_users a partir do redemption.

update public.app_users au
set
  billing_complimentary_access_until = greatest(
    coalesce(au.billing_complimentary_access_until, r.max_until),
    r.max_until
  ),
  updated_at = now()
from (
  select
    user_id,
    max(complimentary_until) as max_until
  from public.billing_promo_redemptions
  group by user_id
) r
where au.id = r.user_id
  and (
    au.billing_complimentary_access_until is null
    or au.billing_complimentary_access_until < r.max_until
  );

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
  v_org uuid;
  v_existing_until timestamptz;
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

  select
    au.billing_complimentary_access_until,
    au.billing_stripe_access_at,
    au.organization_id
  into v_cur_until, v_stripe_at, v_org
  from public.app_users au
  where au.id = p_user_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Usuário não encontrado');
  end if;

  if v_org is null then
    return jsonb_build_object(
      'ok',
      false,
      'error',
      'Conta sem organização. Complete o cadastro ou peça acesso a um administrador.'
    );
  end if;

  if exists (
    select 1
    from public.billing_promo_redemptions r
    where r.promo_link_id = v_link.id
      and r.user_id = p_user_id
      and r.organization_id = v_org
  ) then
    select r.complimentary_until
    into v_existing_until
    from public.billing_promo_redemptions r
    where r.promo_link_id = v_link.id
      and r.user_id = p_user_id
      and r.organization_id = v_org
    order by r.redeemed_at desc
    limit 1;

    update public.app_users
    set
      billing_complimentary_access_until = greatest(
        coalesce(billing_complimentary_access_until, v_existing_until),
        v_existing_until
      ),
      updated_at = now()
    where id = p_user_id;

    return jsonb_build_object(
      'ok',
      true,
      'complimentary_until',
      v_existing_until,
      'already_redeemed',
      true
    );
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
  values (v_link.id, p_user_id, v_org, v_new_until);

  update public.billing_promo_links
  set redemption_count = redemption_count + 1
  where id = v_link.id;

  update public.app_users
  set
    billing_complimentary_access_until = v_new_until,
    updated_at = now()
  where id = p_user_id;

  return jsonb_build_object('ok', true, 'complimentary_until', v_new_until);
end;
$$;

comment on function public.redeem_billing_promo_link(text, uuid, uuid) is
  'Resgate atómico; se já resgatou o mesmo link+org, ok=true e repara billing_complimentary_access_until.';
