-- Catálogo público por slug da empresa: produtos ativos + token do convite universal (client_catalog),
-- para a página /p/{slug}/catalogo (visualização sem login; compra continua no portal com convite).

create or replace function public.public_storefront_by_org_slug(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_slug text := trim(lower(coalesce(p_slug, '')));
  v_org_id uuid;
  v_org_name text;
  v_org_slug text;
  v_token text;
  v_products jsonb;
begin
  if v_slug = '' then
    return jsonb_build_object('error', 'invalid_slug');
  end if;

  select o.id, o.name, o.slug
  into v_org_id, v_org_name, v_org_slug
  from public.organizations o
  where trim(lower(o.slug)) = v_slug
  limit 1;

  if v_org_id is null then
    return jsonb_build_object('error', 'not_found');
  end if;

  select si.token
  into v_token
  from public.seller_invitations si
  where si.organization_id = v_org_id
    and si.purpose = 'client_catalog'
    and lower(trim(si.email)) = lower(trim('catalogo+universal@2avendas.local'))
  order by si.created_at desc
  limit 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'owner_seller_id', p.owner_seller_id,
        'name', p.name,
        'sku', p.sku,
        'description', p.description,
        'price', p.price,
        'stock', p.stock,
        'category', p.category,
        'supplier', p.supplier,
        'image_url', p.image_url,
        'image_urls', p.image_urls
      )
      order by p.name
    ),
    '[]'::jsonb
  )
  into v_products
  from public.products p
  where p.organization_id = v_org_id
    and p.active = true;

  return jsonb_build_object(
    'organization_id', v_org_id,
    'organization_name', v_org_name,
    'organization_slug', v_org_slug,
    'invite_token', v_token,
    'products', v_products
  );
end;
$$;

comment on function public.public_storefront_by_org_slug(text) is
  'JSON com nome da empresa, slug, token do convite universal de catálogo (se existir) e lista de produtos ativos — uso na vitrine pública /p/{slug}/catalogo.';

grant execute on function public.public_storefront_by_org_slug(text) to anon, authenticated;
