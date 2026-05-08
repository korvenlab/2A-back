-- Várias imagens por produto (máx. 4 no app). image_url continua como primeira URL para compatibilidade.

alter table public.products
  add column if not exists image_urls jsonb not null default '[]'::jsonb;

comment on column public.products.image_urls is
  'Lista JSON de URLs públicas de imagens (até 4). image_url deve espelhar o primeiro item.';

update public.products p
set image_urls = jsonb_build_array(trim(p.image_url))
where coalesce(trim(p.image_url), '') <> ''
  and jsonb_array_length(coalesce(p.image_urls, '[]'::jsonb)) = 0;

update public.products p
set image_url = nullif(trim(p.image_urls ->> 0), '')
where jsonb_array_length(coalesce(p.image_urls, '[]'::jsonb)) > 0;
