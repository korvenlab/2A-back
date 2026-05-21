-- Comissão da representação por indústria (% sobre o subtotal da linha do pedido).
-- A fatia do vendedor é % sobre essa comissão da indústria (organization_seller_commissions).

alter table public.organization_industries
  add column if not exists commission_pct numeric(7, 4) not null default 0
    check (commission_pct >= 0 and commission_pct <= 100);

comment on column public.organization_industries.commission_pct is
  'Percentual da representação sobre vendas de produtos desta indústria (subtotal da linha).';
